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
      progress = Progress.new("goto #{url}", timeout || default_timeout)
      navigate(url, wait_until, progress)
    end

    # Loads the current address again.
    #
    # `Page.reload` answers with no loader id, unlike `Page.navigate`, so what
    # is waited for is the frame committing a document that is not the one it
    # had. Recorded before the command goes out, because the commit can arrive
    # while it is still in flight.
    def reload(wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Nil
      progress = Progress.new("reload #{url}", timeout || default_timeout)
      renew(progress, wait_until) do
        Crystalwright.command(@manager.session,
          CDP::Protocol::Page::ReloadRequest.new, progress, "Page.reload")
      end
    end

    # Goes back one entry in this tab's history.
    #
    # Answers `false` when there is nowhere to go, rather than raising: "was
    # there a previous page" is a question with two ordinary answers, and a
    # caller that has to rescue an exception to find out is a caller writing
    # `begin` around a boolean.
    def go_back(wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Bool
      history_step(-1, wait_until, timeout || default_timeout, "go_back")
    end

    # Goes forward one entry in this tab's history.
    def go_forward(wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Bool
      history_step(1, wait_until, timeout || default_timeout, "go_forward")
    end

    # The document's title.
    def title(timeout : Time::Span? = nil) : String
      evaluate_in_utility(String, "() => document.title", timeout: timeout)
    end

    # The document as HTML, doctype included.
    #
    # Serialised by the browser rather than assembled here: `outerHTML` on the
    # root element leaves out the doctype, and a page whose doctype is missing
    # renders differently from one where it was merely not reported.
    def content(timeout : Time::Span? = nil) : String
      evaluate_in_utility(String, <<-JS, timeout: timeout)
        () => {
          const doctype = document.doctype;
          const prologue = doctype
            ? "<!DOCTYPE " + doctype.name +
              (doctype.publicId ? ' PUBLIC "' + doctype.publicId + '"' : "") +
              (!doctype.publicId && doctype.systemId ? " SYSTEM" : "") +
              (doctype.systemId ? ' "' + doctype.systemId + '"' : "") + ">"
            : "";
          return prologue + (document.documentElement ? document.documentElement.outerHTML : "");
        }
        JS
    end

    # Waits until the current document has reached a state.
    #
    # Returns at once if it already has. That is not an optimisation: after a
    # same-document navigation the `load` event has already fired and is never
    # going to fire again, so an implementation that always waits for the event
    # hangs on every single-page application.
    def wait_for_load_state(state : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Nil
      progress = Progress.new("wait_for_load_state #{state}", timeout || default_timeout)
      await_state(state, progress)
    end

    # Evaluates in this frame's own world and copies the result out.
    def evaluate(source : String, *args, timeout : Time::Span? = nil) : JSValue
      progress = Progress.new("evaluate", timeout || default_timeout)
      # The contexts of a crashed renderer are still on record, so nothing here
      # would wait for one: the call would go out and never be answered.
      check_attached!
      main_world(progress).evaluate(source, *args, progress: progress)
    end

    # Evaluates and converts the result to a Crystal type.
    def evaluate(type : T.class, source : String, *args, timeout : Time::Span? = nil) forall T
      evaluate(source, *args, timeout: timeout).cast_to(type)
    end

    # Evaluates in this frame's own world and leaves the result there.
    def evaluate_handle(source : String, *args, timeout : Time::Span? = nil) : JSHandle
      progress = Progress.new("evaluate_handle", timeout || default_timeout)
      check_attached!
      main_world(progress).evaluate_handle(source, *args, progress: progress)
    end

    # Evaluates in the isolated world this library works in.
    def evaluate_in_utility(source : String, *args, timeout : Time::Span? = nil) : JSValue
      progress = Progress.new("evaluate", timeout || default_timeout)
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

    # Elements by the role a screen reader would report, and optionally by the
    # name it would read out.
    #
    # The closest thing here to how a person finds a control, and the reason it
    # is worth the two computations behind it: `get_by_role("button", name:
    # "Save")` keeps working when the markup under it changes, because what it
    # names is what the button *is* rather than where it sits or what class
    # somebody gave it.
    #
    # `name` matches case-insensitively as a substring unless `exact` is set,
    # and is compared after the same whitespace flattening a screen reader
    # applies. Hidden elements are excluded unless `include_hidden` is set —
    # a name is still computed for them as though they were shown, so that
    # "the button is there but hidden" is a thing that can be asked.
    def get_by_role(role : String, exact : Bool = false, name : String? = nil,
                    checked : (Bool | String)? = nil, disabled : Bool? = nil,
                    expanded : Bool? = nil, level : Int32? = nil,
                    pressed : (Bool | String)? = nil, selected : Bool? = nil,
                    include_hidden : Bool = false) : Locator
      Locator.new(self, "").get_by_role(role, exact, name, checked, disabled, expanded,
        level, pressed, selected, include_hidden)
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
      resolve(selector, Progress.new("query_selector #{selector}", timeout || default_timeout))
    end

    # Every element in this frame matching the selector.
    def query_selector_all(selector : String, timeout : Time::Span? = nil) : Array(ElementHandle)
      progress = Progress.new("query_selector_all #{selector}", timeout || default_timeout)
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
      progress = Progress.new("wait_for_selector #{selector} #{state.to_wire}", timeout || default_timeout)
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
      progress = Progress.new("text_content #{selector}", timeout || default_timeout)
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
      progress = Progress.new("click #{selector}", timeout || default_timeout)
      pointer_action(selector, "click", progress, wait_for_enabled: true, force: force, strict: strict) do |point|
        @manager.mouse.click(point, button, click_count, progress: progress)
      end
    end

    # Double-clicks the first element matching the selector.
    def dblclick(selector : String, button : MouseButton = MouseButton::Left,
                 force : Bool = false, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      progress = Progress.new("dblclick #{selector}", timeout || default_timeout)
      pointer_action(selector, "dblclick", progress, wait_for_enabled: true, force: force, strict: strict) do |point|
        @manager.mouse.click(point, button, 2, progress: progress)
      end
    end

    # Moves the pointer over the first element matching the selector.
    #
    # Does not wait for it to be enabled: hovering a disabled control is a
    # perfectly ordinary thing to want, since that is often what shows the
    # tooltip explaining why it is disabled.
    def hover(selector : String, force : Bool = false, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      progress = Progress.new("hover #{selector}", timeout || default_timeout)
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
      progress = Progress.new("fill #{selector}", timeout || default_timeout)

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

    # Chooses among a `<select>`'s options, and answers what is selected.
    #
    # An option is named by its value, its label, or its position, in that
    # order of preference: a value and a label can be the same string and the
    # value is the one the form submits. `values` selects several, which only a
    # `<select multiple>` will accept.
    #
    # Not a click: a native dropdown is drawn by the operating system and there
    # is nothing on the page to aim at. The selection is made in the document
    # and the `input` and `change` events are dispatched by hand, because
    # setting `selected` from script fires neither and a page listening for
    # `change` would never learn anything happened.
    def select_option(selector : String, value : String? = nil, label : String? = nil,
                      index : Int32? = nil, values : Array(String)? = nil,
                      timeout : Time::Span? = nil, strict : Bool = false) : Array(String)
      wanted = [] of Hash(String, JSON::Any)
      values.try(&.each { |v| wanted << {"value" => JSON::Any.new(v)} })
      wanted << {"value" => JSON::Any.new(value)} if value
      wanted << {"label" => JSON::Any.new(label)} if label
      wanted << {"index" => JSON::Any.new(index.to_i64)} if index
      raise Error.new("select_option needs a value, a label, an index or values") if wanted.empty?

      progress = Progress.new("select_option #{selector}", timeout || default_timeout)
      chosen = [] of String

      retry_action(progress, "select_option #{selector}") do |_|
        element = resolve(selector, progress, strict)
        next ActionOutcome.new(ActionFailure::NotConnected) unless element

        begin
          answer = element.select_options(wanted, progress)
          if problem = answer["error"]?.try(&.as_s?)
            raise Error.new("#{problem} — select_option only works on a <select>")
          end
          if missing = answer["missing"]?.try(&.as_s?)
            # Retried rather than raised: an option a script has not added yet
            # is the same kind of "not yet" as an element that has not appeared.
            next ActionOutcome.new(ActionFailure::NotFound, "no such option: #{missing}")
          end
          next ActionOutcome.new(ActionFailure::NotConnected) if answer["notConnected"]?.try(&.as_bool?)
          if state = answer["missingState"]?.try(&.as_s?)
            next ActionOutcome.new(ActionFailure::MissingState, state)
          end

          chosen = answer["values"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
          ActionOutcome.done
        ensure
          element.dispose
        end
      end

      chosen
    end

    # Ticks a checkbox or a radio, or leaves it ticked.
    #
    # Idempotent on purpose: a test that says "make sure this is on" should not
    # turn it off because it was already on. That is also why this is not the
    # same as clicking — a click toggles, and a toggle is only what you wanted
    # if you already knew the state.
    def check(selector : String, force : Bool = false, timeout : Time::Span? = nil,
              strict : Bool = false) : Nil
      set_checked(selector, true, force, timeout, strict)
    end

    # Unticks a checkbox or a radio, or leaves it unticked.
    def uncheck(selector : String, force : Bool = false, timeout : Time::Span? = nil,
                strict : Bool = false) : Nil
      set_checked(selector, false, force, timeout, strict)
    end

    # Focuses the first element matching the selector and presses one key.
    def press(selector : String, key : String, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      progress = Progress.new("press #{key} on #{selector}", timeout || default_timeout)

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

    # How long an operation here gets when the caller does not say.
    def default_timeout : Time::Span
      @manager.default_timeout
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

    # The shared half of `check` and `uncheck`.
    #
    # Reads the state, clicks only if it is wrong, and reads it again. The
    # second read is the part that matters: a click that lands on a label whose
    # `for` points at nothing, or on a control a script re-renders underneath
    # it, leaves the box exactly as it was — and an implementation that stops
    # after clicking reports success for a checkbox it never ticked.
    private def set_checked(selector : String, wanted : Bool, force : Bool,
                            timeout : Time::Span?, strict : Bool) : Nil
      what = wanted ? "check" : "uncheck"
      progress = Progress.new("#{what} #{selector}", timeout || default_timeout)
      state = wanted ? "checked" : "unchecked"

      retry_action(progress, "#{what} #{selector}") do |attempt|
        element = resolve(selector, progress, strict)
        next ActionOutcome.new(ActionFailure::NotConnected) unless element

        begin
          next ActionOutcome.done if element.state(state)[0]

          outcome = attempt_pointer(element, what, progress, attempt, true, force,
            ->(point : Point) { @manager.mouse.click(point, MouseButton::Left, 1, progress: progress) })
          next outcome unless outcome.done?

          matched, received = element.state(state)
          next ActionOutcome.done if matched
          ActionOutcome.new(ActionFailure::MissingState,
            "it was clicked and is still #{received}")
        ensure
          element.dispose
        end
      end
    end

    # Runs something that replaces the document, and waits for the replacement.
    #
    # The loader the frame is showing is read *before* the command is sent: the
    # commit can arrive while the command is still in flight, and a version that
    # reads it afterwards can wait for a document that has already arrived.
    private def renew(progress : Progress, wait_until : LoadState, &) : Nil
      raise FrameDetachedError.new(describe) if detached?
      @manager.recovering!
      before = loader_id

      yield

      @manager.wait_until(progress, "a new document to commit") { loader_id != before }
      await_state(wait_until, progress)
    end

    private def history_step(offset : Int32, wait_until : LoadState,
                             timeout : Time::Span, what : String) : Bool
      progress = Progress.new(what, timeout)
      history = Crystalwright.command(@manager.session,
        CDP::Protocol::Page::GetNavigationHistoryRequest.new, progress,
        "Page.getNavigationHistory")

      wanted = history.current_index + offset
      return false if wanted < 0 || wanted >= history.entries.size

      entry = history.entries[wanted]
      raise FrameDetachedError.new(describe) if detached?
      @manager.recovering!
      before = loader_id

      Crystalwright.command(@manager.session,
        CDP::Protocol::Page::NavigateToHistoryEntryRequest.new(entry_id: entry.id),
        progress, "Page.navigateToHistoryEntry")

      @manager.wait_until(progress, "a new document to commit") { loader_id != before }
      await_state(wait_until, progress)
      true
    end

    # :nodoc:
    protected def navigate(url : String, wait_until : LoadState, progress : Progress) : Nil
      # Detached, but deliberately not "crashed": navigating is how a crashed
      # tab gets a renderer again, so refusing it here would make the crash
      # permanent.
      raise FrameDetachedError.new(describe) if detached?
      @manager.recovering!

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
      @manager.check_alive!
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
      @accountant.restart(loader_id)
      @manager.forget_abandoned(@id, loader_id)
      # A document committing means a renderer is running again.
      @manager.recovered_locked
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
