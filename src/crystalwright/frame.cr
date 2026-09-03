require "cdp"
require "./errors"
require "./lifecycle"
require "./network_accountant"
require "./execution_context"
require "./element_handle"
require "./progress"

module Crystalwright
  # One frame of one page: the main document, or an iframe inside it.
  #
  # A frame outlives the documents shown in it. Its identity is the frame id,
  # which Chrome keeps for the life of the element; the identity of what it is
  # *showing* is the `loader_id`, and that is what everything here keys off.
  # Navigating replaces the document, which retires the frame's execution
  # contexts, forgets which lifecycle states have been reached and starts the
  # network clock again — while the frame itself, its place in the tree and any
  # reference a caller is holding all survive.
  #
  # Every field is guarded by one mutex shared with the `FrameManager` and every
  # other frame. One lock rather than one per frame because the interesting
  # operations span several frames at once — a detach takes out a subtree, a
  # cleared runtime takes out every context on the page — and a lock per frame
  # would need an order to take them in.
  class Frame
    # The protocol's id for this frame, stable for as long as the frame exists.
    getter id : String

    # The frame this one is inside, or `nil` for the page's main frame.
    getter parent : Frame?

    # :nodoc:
    protected getter accountant : NetworkAccountant

    @manager : FrameManager
    @mutex : Sync::Mutex
    @children = [] of Frame
    @contexts = {} of Int32 => ExecutionContext
    @reached = Set(LoadState).new
    @recent_loaders = Deque(String).new
    @url = ""
    @name = ""
    @loader_id = ""
    @detached = false

    # How many committed documents to remember per frame.
    #
    # Enough that `goto` can tell "the document I asked for came and went while
    # I was being told about it" from "it never arrived at all". Anything that
    # only looks at the current loader sees one state for both, and they call
    # for opposite behaviour: the first has to return, the second to keep
    # waiting.
    RECENT_LOADERS = 8

    # :nodoc:
    def initialize(@manager : FrameManager, @mutex : Sync::Mutex, @id : String, @parent : Frame?)
      @accountant = NetworkAccountant.new
    end

    # The frame's current address.
    def url : String
      @mutex.synchronize { @url }
    end

    # The `name` or `id` attribute of the iframe element, empty for the main frame.
    def name : String
      @mutex.synchronize { @name }
    end

    # The identity of the document this frame is showing.
    #
    # Empty until the frame has committed one. Changes on every cross-document
    # navigation and — measured — on no same-document one, which is what makes
    # it usable as the answer to "is this still the page I was looking at".
    def loader_id : String
      @mutex.synchronize { @loader_id }
    end

    # Whether the frame has been removed from the page.
    def detached? : Bool
      @mutex.synchronize { @detached }
    end

    # The frames directly inside this one.
    def child_frames : Array(Frame)
      @mutex.synchronize { @children.dup }
    end

    # This frame and every frame inside it, parents before children.
    def subtree : Array(Frame)
      [self] + child_frames.flat_map(&.subtree)
    end

    # The execution contexts alive in this frame.
    def contexts : Array(ExecutionContext)
      @mutex.synchronize { @contexts.values.dup }
    end

    # Whether the current document has got this far.
    #
    # `NetworkIdle` is latched the first time it is observed rather than being
    # recomputed on every call, matching the other states: a document that went
    # quiet has gone quiet, and a later request does not un-fire it. Without the
    # latch, `wait_for_load_state(:networkidle)` on a page that polls would
    # answer differently depending on when it was asked.
    def reached?(state : LoadState) : Bool
      @mutex.synchronize do
        case state
        in LoadState::Commit
          !@loader_id.empty?
        in LoadState::DOMContentLoaded, LoadState::Load
          @reached.includes?(state)
        in LoadState::NetworkIdle
          next true if @reached.includes?(state)
          if @accountant.idle?
            @reached << LoadState::NetworkIdle
            true
          else
            false
          end
        end
      end
    end

    # Navigates this frame and waits for it to get where it was told to.
    #
    # `wait_until` is where the caller wants to be by the time this returns.
    # `Load` is the default because it is what "the page is up" means to most
    # people; `NetworkIdle` is available and is ours, not Chrome's.
    def goto(url : String, wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Nil
      progress = Progress.new("goto #{url}", timeout || DEFAULT_TIMEOUT)
      navigate(url, wait_until, progress)
    end

    # Waits until the current document has reached a state.
    #
    # Returns at once if it already has. That is not an optimisation: after a
    # same-document navigation the `load` event has already fired and is never
    # going to fire again, so an implementation that always waits for the event
    # hangs on every single-page application.
    def wait_for_load_state(state : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Nil
      progress = Progress.new("wait_for_load_state #{state}", timeout || DEFAULT_TIMEOUT)
      await_state(state, progress)
    end

    # Evaluates in this frame's own world and copies the result out.
    def evaluate(source : String, *args, timeout : Time::Span? = nil) : JSValue
      progress = Progress.new("evaluate", timeout || DEFAULT_TIMEOUT)
      main_world(progress).evaluate(source, *args, progress: progress)
    end

    # Evaluates and converts the result to a Crystal type.
    def evaluate(type : T.class, source : String, *args, timeout : Time::Span? = nil) forall T
      evaluate(source, *args, timeout: timeout).cast_to(type)
    end

    # Evaluates in this frame's own world and leaves the result there.
    def evaluate_handle(source : String, *args, timeout : Time::Span? = nil) : JSHandle
      progress = Progress.new("evaluate_handle", timeout || DEFAULT_TIMEOUT)
      main_world(progress).evaluate_handle(source, *args, progress: progress)
    end

    # Evaluates in the isolated world this library works in.
    def evaluate_in_utility(source : String, *args, timeout : Time::Span? = nil) : JSValue
      progress = Progress.new("evaluate", timeout || DEFAULT_TIMEOUT)
      utility_world(progress).evaluate(source, *args, progress: progress)
    end

    # :ditto:
    def evaluate_in_utility(type : T.class, source : String, *args, timeout : Time::Span? = nil) forall T
      evaluate_in_utility(source, *args, timeout: timeout).cast_to(type)
    end

    # A locator for this selector, resolved fresh at every use.
    #
    # Prefer this to `query_selector` for anything that will be acted on: a
    # handle refers to one node and dies with it, while a locator refers to a
    # question and asks it again each time.
    def locator(selector : String) : Locator
      Locator.new(self, selector)
    end

    # A locator for elements whose text matches.
    def get_by_text(text : String | Regex, exact : Bool = false) : Locator
      Locator.new(self, "").get_by_text(text, exact)
    end

    # A locator for elements carrying this `data-testid`.
    def get_by_test_id(id : String) : Locator
      Locator.new(self, "").get_by_test_id(id)
    end

    # A locator for the control a `<label>` names, or an element with this `aria-label`.
    def get_by_label(text : String | Regex, exact : Bool = false) : Locator
      Locator.new(self, "").get_by_label(text, exact)
    end

    # A locator for elements whose `placeholder` matches.
    def get_by_placeholder(text : String | Regex, exact : Bool = false) : Locator
      Locator.new(self, "").get_by_placeholder(text, exact)
    end

    # A locator for elements whose `alt` matches.
    def get_by_alt_text(text : String | Regex, exact : Bool = false) : Locator
      Locator.new(self, "").get_by_alt_text(text, exact)
    end

    # A locator for elements whose `title` matches.
    def get_by_title(text : String | Regex, exact : Bool = false) : Locator
      Locator.new(self, "").get_by_title(text, exact)
    end

    # The first element in this frame matching the selector, or `nil`.
    #
    # Asks once and answers. Nothing here waits — a page that has not built the
    # element yet gets `nil`, which is a fact about right now. Waiting for it to
    # appear is `wait_for_selector`, and it is a different question.
    def query_selector(selector : String, timeout : Time::Span? = nil) : ElementHandle?
      resolve(selector, Progress.new("query_selector #{selector}", timeout || DEFAULT_TIMEOUT))
    end

    # Every element in this frame matching the selector.
    def query_selector_all(selector : String, timeout : Time::Span? = nil) : Array(ElementHandle)
      progress = Progress.new("query_selector_all #{selector}", timeout || DEFAULT_TIMEOUT)
      utility_world(progress).invoke_elements("querySelectorAll", selector, nil, progress: progress)
    end

    # Waits until an element matching the selector reaches a state.
    #
    # Returns the element for `Attached` and `Visible`, and `nil` for `Hidden`
    # and `Detached`, because in those two the answer is that there is nothing
    # to hand back.
    #
    # This is the point of the library rather than a convenience. A test that
    # queries and then acts is a test that fails whenever the machine is busy;
    # one that waits for a condition it can name fails only when the condition
    # is genuinely never met, and then says which one it was.
    def wait_for_selector(selector : String, state : ElementState = ElementState::Visible, timeout : Time::Span? = nil) : ElementHandle?
      progress = Progress.new("wait_for_selector #{selector} #{state.to_wire}", timeout || DEFAULT_TIMEOUT)
      wanted = state.to_wire

      # Polled rather than pushed. Nothing in the protocol fires when an element
      # appears, so there is no doorbell to wait on — Playwright answers this
      # with a MutationObserver inside the page, which is a round trip saved and
      # a moving part added, and is worth doing when the round trips show up in
      # a measurement rather than before.
      @manager.wait_until(progress, "#{selector} to be #{wanted}", recheck: -> { SELECTOR_POLL.as(Time::Span?) }) do
        check_attached!
        matched?(selector, wanted, progress)
      end

      case state
      in ElementState::Attached, ElementState::Visible
        resolve(selector, progress)
      in ElementState::Hidden, ElementState::Detached
        nil
      end
    end

    # The text of the first element matching the selector.
    def text_content(selector : String, timeout : Time::Span? = nil) : String?
      progress = Progress.new("text_content #{selector}", timeout || DEFAULT_TIMEOUT)
      element = resolve(selector, progress)
      raise no_match(selector) unless element
      begin
        element.text_content(progress.remaining)
      ensure
        element.dispose
      end
    end

    # ---- actions -------------------------------------------------------------
    #
    # An action is three nested loops, and every one of them earns its place.
    #
    # The outer one resolves the selector again, because a framework that
    # re-renders between resolving and clicking leaves a handle pointing at a
    # node no longer in the document. The middle one retries the attempt itself
    # with a longer pause and a different scroll anchoring each time, because
    # "not stable yet" and "parked under a header" are both fixed by trying
    # again differently. The inner one lives in the page and counts animation
    # frames, because that is the only place the question "has it stopped
    # moving" can be asked.
    #
    # None of the three has its own clock. One deadline covers the lot, which is
    # what makes a click that failed twelve times fail after the timeout the
    # caller asked for rather than after twelve of them.

    # Clicks the first element matching the selector.
    #
    # Waits for it to be visible, enabled and holding still, scrolls it into
    # view, aims at the middle of what is actually on screen, checks nothing is
    # on top of it, and keeps checking while the events are in flight.
    def click(selector : String, button : MouseButton = MouseButton::Left, click_count : Int32 = 1,
              force : Bool = false, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      progress = Progress.new("click #{selector}", timeout || DEFAULT_TIMEOUT)
      pointer_action(selector, "click", progress, wait_for_enabled: true, force: force, strict: strict) do |point|
        @manager.mouse.click(point, button, click_count, progress: progress)
      end
    end

    # Moves the pointer over the first element matching the selector.
    #
    # Does not wait for it to be enabled: hovering a disabled control is a
    # perfectly ordinary thing to want, since that is often what shows the
    # tooltip explaining why it is disabled.
    def hover(selector : String, force : Bool = false, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      progress = Progress.new("hover #{selector}", timeout || DEFAULT_TIMEOUT)
      pointer_action(selector, "hover", progress, wait_for_enabled: false, force: force, strict: strict) do |point|
        @manager.mouse.move(point.x, point.y, progress)
      end
    end

    # Replaces the contents of an input, textarea or contenteditable.
    #
    # Not a pointer action: there is no point to aim at and nothing to be
    # covered by, so it neither scrolls nor checks a hit target. It does clear
    # the field and enter the text through real input events, because a page
    # that listens for `input` — which is every page built on a framework —
    # never learns about a value assigned directly.
    def fill(selector : String, value : String, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      progress = Progress.new("fill #{selector}", timeout || DEFAULT_TIMEOUT)

      retry_action(progress, "fill #{selector}") do |_|
        element = resolve(selector, progress, strict)
        next ActionOutcome.new(ActionFailure::NotConnected) unless element

        begin
          outcome = element.check_states(["visible", "enabled", "editable"], progress)
          next outcome unless outcome.done?

          outcome = element.prepare_fill(value, progress)
          next outcome unless outcome.done?

          @manager.with_signals(progress) { @manager.keyboard.type(value, progress) }
          ActionOutcome.done
        ensure
          element.dispose
        end
      end
    end

    # Focuses the first element matching the selector and presses one key.
    def press(selector : String, key : String, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      progress = Progress.new("press #{key} on #{selector}", timeout || DEFAULT_TIMEOUT)

      retry_action(progress, "press #{key} on #{selector}") do |_|
        element = resolve(selector, progress, strict)
        next ActionOutcome.new(ActionFailure::NotConnected) unless element

        begin
          outcome = element.check_states(["visible", "enabled"], progress)
          next outcome unless outcome.done?

          outcome = element.focus(progress)
          next outcome unless outcome.done?

          @manager.with_signals(progress) { @manager.keyboard.press(key, progress) }
          ActionOutcome.done
        ensure
          element.dispose
        end
      end
    end

    private def pointer_action(selector : String, name : String, progress : Progress,
                               wait_for_enabled : Bool, force : Bool, strict : Bool, &action : Point -> Nil) : Nil
      retry_action(progress, "#{name} on #{selector}") do |attempt|
        element = resolve(selector, progress, strict)
        next ActionOutcome.new(ActionFailure::NotConnected) unless element

        begin
          attempt_pointer(element, name, progress, attempt, wait_for_enabled, force, action)
        ensure
          element.dispose
        end
      end
    end

    private def attempt_pointer(element : ElementHandle, name : String, progress : Progress, attempt : Int32,
                                wait_for_enabled : Bool, force : Bool, action : Point -> Nil) : ActionOutcome
      alignment = SCROLL_ALIGNMENTS[attempt % SCROLL_ALIGNMENTS.size]

      unless force
        states = wait_for_enabled ? ["visible", "enabled", "stable"] : ["visible", "stable"]
        progress.log("  waiting for the element to be #{states.join(", ")}")
        outcome = element.check_states(states, progress)
        return outcome unless outcome.done?
      end

      progress.log(alignment ? "  scrolling into view, anchored to #{alignment}" : "  scrolling into view if needed")
      outcome = element.scroll_into_view(alignment, progress)
      return outcome unless outcome.done?

      aimed = element.clickable_point(progress)
      return aimed if aimed.is_a?(ActionOutcome)
      progress.log("  aiming at #{aimed}")

      token = Random::Secure.hex(6)
      unless force
        outcome = element.intercept_hit_target(name, aimed, token, progress)
        return outcome unless outcome.done?
      end

      begin
        # Inside the barrier, so that a click which navigates does not return
        # before the new document has committed.
        @manager.with_signals(progress) { action.call(aimed) }
      rescue error
        element.stop_intercepting(token, progress) unless force
        raise error
      end

      # Asked after the event rather than only before it. The gap between aiming
      # and the page handling the click is where a banner sliding in changes the
      # answer, and that gap is exactly what makes this class of bug rare enough
      # to be blamed on the machine.
      force ? ActionOutcome.done : element.stop_intercepting(token, progress)
    end

    # The middle loop: try, wait a little longer, try again, until the deadline.
    private def retry_action(progress : Progress, what : String, &attempt : Int32 -> ActionOutcome) : Nil
      tries = 0
      loop do
        if tries.zero?
          progress.log("attempting #{what}")
        else
          progress.log("retrying #{what}, attempt ##{tries + 1}")
          delay = RETRY_DELAYS[Math.min(tries - 1, RETRY_DELAYS.size - 1)]
          unless delay.zero?
            progress.log("  waiting #{delay.total_milliseconds.to_i}ms")
            sleep({delay, progress.remaining}.min)
          end
        end

        progress.check!
        check_attached!
        outcome = attempt.call(tries)
        tries += 1
        return if outcome.done?
        progress.log("  #{outcome}")
      end
    rescue error : CDP::TimeoutError
      # Belt and braces over `Crystalwright.command`. Everything an attempt does
      # is supposed to go through that and come back as this shard's own
      # timeout, but "supposed to" is a property of every call site, and the one
      # that did not was found by the gate rather than by reading. This is a
      # property of the loop instead: a caller who gave `click` a deadline never
      # sees the shard below, whatever a future attempt learns to call.
      raise progress.timed_out(error.message)
    end

    # This frame's own JavaScript world, waiting for it if a navigation is in flight.
    def main_world(progress : Progress) : ExecutionContext
      await_context(progress, "the main world of #{describe}", ->(context : ExecutionContext) { context.name.empty? })
    end

    # The isolated world this library works in, in this frame.
    def utility_world(progress : Progress) : ExecutionContext
      wanted = @manager.utility_world_name
      await_context(progress, "the utility world of #{describe}", ->(context : ExecutionContext) { context.name == wanted })
    end

    # :nodoc:
    protected def resolve(selector : String, progress : Progress, strict : Bool = false) : ElementHandle?
      check_attached!
      utility_world(progress).invoke_element("querySelector", selector, nil, strict, progress: progress)
    rescue error : EvaluationError
      # The page raised it, but it is not a page error: it is this shard saying
      # the caller was ambiguous, and it should not arrive looking like
      # JavaScript went wrong.
      raise StrictModeError.new(error.message.to_s) if error.message.to_s.includes?("strict mode violation")
      raise error
    end

    private def matched?(selector : String, wanted : String, progress : Progress) : Bool
      utility_world(progress)
        .invoke("selectorState", selector, nil, wanted, progress: progress)["found"].as_bool
    rescue ContextDestroyedError
      # The document went out from under the poll. The next document gets the
      # same question rather than the caller getting an error about a page that
      # is already gone.
      false
    end

    private def no_match(selector : String) : Error
      Error.new("No element matched #{selector.inspect} in #{describe}. Use \
                 wait_for_selector if it is expected to appear later.")
    end

    # :nodoc:
    protected def navigate(url : String, wait_until : LoadState, progress : Progress) : Nil
      check_attached!

      response = Crystalwright.command(@manager.session,
        CDP::Protocol::Page::NavigateRequest.new(url: url, frame_id: @id), progress, "Page.navigate")

      if failure = response.error_text
        raise Error.new("Navigating to #{url} failed: #{failure}")
      end

      # No loader means the browser resolved this without replacing the
      # document — a fragment, or an address the frame is already at. There is
      # nothing to wait for, and waiting for a commit that will not happen is
      # how a `goto` to `#section` hangs for thirty seconds.
      if loader = response.loader_id
        progress.log("navigated, waiting for document #{loader} to commit")
        @manager.wait_until(progress, "document #{loader} to commit") { committed?(loader) }
      end

      await_state(wait_until, progress)
    end

    # :nodoc:
    protected def await_state(state : LoadState, progress : Progress) : Nil
      # `NetworkIdle` is the one state that arrives through the passage of time
      # rather than through a message, so it is the one that has to say when to
      # look again. Everything else waits on the doorbell alone.
      recheck = state.network_idle? ? -> { @mutex.synchronize { @accountant.idle_in } } : nil
      @manager.wait_until(progress, "#{describe} to reach #{state}", recheck: recheck) { reached?(state) }
    end

    private def await_context(progress : Progress, what : String, predicate : ExecutionContext -> Bool) : ExecutionContext
      @manager.wait_until(progress, what) do
        check_attached!
        !find_context(predicate).nil?
      end

      # Looked up again rather than carried out of the block: a context found
      # inside a closure stays nilable to the compiler, and the second lookup
      # is a scan of the two or three worlds one frame has.
      find_context(predicate) || raise progress.timed_out("waiting for #{what}")
    end

    private def find_context(predicate : ExecutionContext -> Bool) : ExecutionContext?
      @mutex.synchronize do
        @contexts.values.find { |context| !context.destroyed? && predicate.call(context) }
      end
    end

    # Whether this frame has committed the given document, now or recently.
    private def committed?(loader : String) : Bool
      @mutex.synchronize { @loader_id == loader || @recent_loaders.includes?(loader) }
    end

    # Waiting for a detached frame is waiting for something that cannot happen.
    #
    # Without this the caller gets a timeout, which says "not yet" about a frame
    # that is never going to have another document — and it says it thirty
    # seconds later by default, having blocked for all of them.
    private def check_attached! : Nil
      raise FrameDetachedError.new(describe) if detached?
    end

    private def describe : String
      @mutex.synchronize { @parent ? "frame #{@name.empty? ? @id : @name}" : "the main frame" }
    end

    # ---- mutation, called by FrameManager with the shared lock already held --

    # :nodoc:
    protected def adopt_locked(child : Frame) : Nil
      @children << child unless @children.includes?(child)
    end

    # :nodoc:
    protected def orphan_locked(child : Frame) : Nil
      @children.delete(child)
    end

    # :nodoc:
    #
    # A new document is showing. Everything tied to the old one goes.
    protected def commit_locked(url : String, name : String, loader_id : String) : Nil
      @recent_loaders << @loader_id unless @loader_id.empty?
      while @recent_loaders.size > RECENT_LOADERS
        @recent_loaders.shift
      end
      @url = url
      @name = name
      @loader_id = loader_id
      @reached.clear
      retire_contexts_locked
      @accountant.restart
    end

    # :nodoc:
    #
    # The address changed without the document changing — `history.pushState`,
    # or a fragment. Measured: no lifecycle event follows and the loader does
    # not move, so nothing here may be reset. Resetting is what makes
    # `wait_for_load_state(:load)` wait for a `load` that already happened.
    protected def same_document_locked(url : String) : Nil
      @url = url
    end

    # :nodoc:
    protected def reach_locked(state : LoadState) : Nil
      @reached << state
    end

    # :nodoc:
    protected def add_context_locked(context : ExecutionContext) : Nil
      @contexts[context.id] = context
    end

    # :nodoc:
    protected def remove_context_locked(id : Int32) : Bool
      gone = @contexts.delete(id)
      gone.try &.mark_destroyed
      !gone.nil?
    end

    # :nodoc:
    protected def retire_contexts_locked : Nil
      @contexts.each_value(&.mark_destroyed)
      @contexts.clear
    end

    # :nodoc:
    protected def detach_locked : Nil
      @detached = true
      retire_contexts_locked
    end

    # :nodoc:
    protected def loader_id_locked : String
      @loader_id
    end

    # :nodoc:
    protected def child_frames_locked : Array(Frame)
      @children.dup
    end

    # :nodoc:
    #
    # `subtree` without taking the lock, for a caller that already holds it.
    protected def subtree_locked : Array(Frame)
      found = [self]
      @children.each { |child| found.concat(child.subtree_locked) }
      found
    end
  end
end
