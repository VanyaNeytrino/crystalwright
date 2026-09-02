require "cdp"
require "./errors"
require "./js_value"
require "./progress"
require "./execution_context"
require "./js_handle"

module Crystalwright
  # One tab.
  #
  # Deliberately thin at this milestone. It owns the session, the two JavaScript
  # worlds and the deadline that covers an operation; the frame tree, the
  # lifecycle signals and `networkidle` belong to the next one, and `goto` here
  # waits for the load event and nothing cleverer.
  class Page
    # The protocol session for this tab.
    getter session : CDP::Session

    # The target this tab is.
    getter target_id : String

    # The name of this page's isolated world.
    #
    # Random per page so that two pages driven at once cannot collide, and
    # prefixed so that it is obvious in a devtools context menu who made it.
    getter utility_world_name : String

    @contexts = {} of Int32 => ExecutionContext
    @main_frame_id : String = ""
    @dialog_handlers = [] of Proc(CDP::Protocol::Page::JavascriptDialogOpeningEvent, Nil)
    @bell = Channel(Nil).new(1)
    @mutex = Sync::Mutex.new
    @closed = false

    # :nodoc:
    def initialize(@session : CDP::Session, @target_id : String)
      @utility_world_name = "__crystalwright_utility_#{Random::Secure.hex(8)}"
    end

    # :nodoc:
    #
    # Subscribes first and enables afterwards, in that order and not the other
    # one. `Runtime.enable` replays the contexts that already exist, so a
    # subscription installed after it misses the main world of the current
    # document and then waits for a navigation that may never come.
    protected def start(timeout : Time::Span) : Nil
      watch_contexts
      watch_dialogs

      @session.execute(CDP::Protocol::Page::EnableRequest.new, timeout)

      # Before Runtime.enable, not after. Enabling replays every context that
      # already exists, and the handler decides whether a context is ours by
      # comparing its frame — so a frame id learned afterwards means the main
      # world of the current document is filtered out and never seen again.
      tree = @session.execute(CDP::Protocol::Page::GetFrameTreeRequest.new, timeout)
      @mutex.synchronize { @main_frame_id = tree.frame_tree.frame.id }

      @session.execute(CDP::Protocol::Runtime::EnableRequest.new, timeout)

      install_utility_world(timeout)
    end

    # Evaluates in the page's own world and copies the result out.
    #
    # The main world, not the isolated one, because that is where the page's
    # globals are: code that reaches for `window.myApp` has to see the same
    # `window` the page's scripts wrote to.
    #
    # A source that evaluates to a function is called with the arguments; any
    # other source is itself the result. That is one rule rather than a
    # heuristic, and it means `evaluate("document.title")` and
    # `evaluate("() => document.title")` both work while
    # `evaluate("(a) => a * 2", 21)` cannot be mistaken for anything else.
    def evaluate(source : String, *args, timeout : Time::Span? = nil) : JSValue
      progress = Progress.new("evaluate", timeout || DEFAULT_TIMEOUT)
      main_world(progress).evaluate(source, *args, progress: progress)
    end

    # Evaluates and converts the result to a Crystal type.
    #
    # ```
    # title = page.evaluate(String, "() => document.title")
    # count = page.evaluate(Int32, "() => document.links.length")
    # ```
    def evaluate(type : T.class, source : String, *args, timeout : Time::Span? = nil) forall T
      evaluate(source, *args, timeout: timeout).cast_to(type)
    end

    # Evaluates in the page's own world and leaves the result there.
    def evaluate_handle(source : String, *args, timeout : Time::Span? = nil) : JSHandle
      progress = Progress.new("evaluate_handle", timeout || DEFAULT_TIMEOUT)
      main_world(progress).evaluate_handle(source, *args, progress: progress)
    end

    # Evaluates in the isolated world this library works in.
    #
    # Nothing the page does can reach code running here, and nothing here shows
    # up in the page's own `window`.
    def evaluate_in_utility(source : String, *args, timeout : Time::Span? = nil) : JSValue
      progress = Progress.new("evaluate", timeout || DEFAULT_TIMEOUT)
      utility_world(progress).evaluate(source, *args, progress: progress)
    end

    # :ditto:
    def evaluate_in_utility(type : T.class, source : String, *args, timeout : Time::Span? = nil) forall T
      evaluate_in_utility(source, *args, timeout: timeout).cast_to(type)
    end

    # Navigates, and waits for the load event.
    #
    # The whole of lifecycle handling — `domcontentloaded`, a `networkidle` that
    # is ours rather than Chrome's, and the barrier that stops the next action
    # racing a navigation this one started — is the next milestone. This is
    # enough to get a document on the screen.
    def goto(url : String, timeout : Time::Span? = nil) : Nil
      progress = Progress.new("goto #{url}", timeout || DEFAULT_TIMEOUT)

      # Subscribed before the command that triggers it, which is the only
      # ordering with no race in it: the load event of a cached page can arrive
      # before `Page.navigate` has even returned.
      loaded = @session.expect(CDP::Protocol::Page::LoadEventFiredEvent)

      begin
        response = @session.execute(
          CDP::Protocol::Page::NavigateRequest.new(url: url), progress.remaining)
        if failure = response.error_text
          raise Error.new("Navigating to #{url} failed: #{failure}")
        end
        progress.log("navigated, waiting for the load event")
        loaded.wait(progress.remaining)
      rescue error : CDP::TimeoutError
        loaded.cancel
        raise progress.timed_out(error.message)
      rescue error
        loaded.cancel
        raise error
      end
    end

    # The page's own JavaScript world, waiting for it if a navigation is in
    # flight.
    def main_world(progress : Progress) : ExecutionContext
      await_context(progress, "the page's main world") do |context|
        context.name.empty? && !context.destroyed?
      end
    end

    # The isolated world this library works in.
    def utility_world(progress : Progress) : ExecutionContext
      await_context(progress, @utility_world_name) do |context|
        context.name == @utility_world_name && !context.destroyed?
      end
    end

    # Registers a handler for JavaScript dialogs.
    #
    # Registering one turns the automatic dismissal off: a page with a handler
    # has an owner for its dialogs, and answering twice is an error. The handler
    # must call `handle_dialog`, or the renderer stays blocked — which is what
    # the automatic dismissal exists to prevent in the first place.
    def on_dialog(&block : CDP::Protocol::Page::JavascriptDialogOpeningEvent ->) : Nil
      @mutex.synchronize { @dialog_handlers << block }
    end

    # Answers an open dialog.
    def handle_dialog(accept : Bool, prompt_text : String? = nil) : Nil
      @session.execute(CDP::Protocol::Page::HandleJavaScriptDialogRequest.new(
        accept: accept, prompt_text: prompt_text), 5.seconds)
    end

    # Closes the tab.
    def close(timeout : Time::Span = 10.seconds) : Nil
      return if @mutex.synchronize { was = @closed; @closed = true; was }

      contexts = @mutex.synchronize { @contexts.values.dup }
      contexts.each(&.dispose)

      @session.execute(CDP::Protocol::Target::CloseTargetRequest.new(target_id: @target_id), timeout)
    rescue CDP::ProtocolError | CDP::SessionClosedError | CDP::ConnectionClosedError
      # The tab or the browser went first, which is the outcome asked for.
    end

    # The contexts this page currently knows about, newest last.
    def contexts : Array(ExecutionContext)
      @mutex.synchronize { @contexts.values.dup }
    end

    private def install_utility_world(timeout : Time::Span) : Nil
      # This empty script is not a no-op and is not optional. Registering a
      # source — even an empty one — against a world name is what makes Chrome
      # recreate that world for every future document. Without it the isolated
      # world survives exactly one navigation and then silently stops existing,
      # which is a bug that passes any test that navigates once.
      @session.execute(CDP::Protocol::Page::AddScriptToEvaluateOnNewDocumentRequest.new(
        source: "", world_name: @utility_world_name), timeout)

      # Note the protocol's own spelling of "universal".
      @session.execute(CDP::Protocol::Page::CreateIsolatedWorldRequest.new(
        frame_id: @mutex.synchronize { @main_frame_id },
        world_name: @utility_world_name,
        grant_univeral_access: false), timeout)
    end

    private def watch_contexts : Nil
      @session.on(CDP::Protocol::Runtime::ExecutionContextCreatedEvent) do |event|
        description = event.context
        frame_id = @mutex.synchronize { @main_frame_id }
        next unless belongs_here?(description, frame_id)

        context = ExecutionContext.new(@session, description.id, description.unique_id, description.name)
        @mutex.synchronize { @contexts[description.id] = context }
        ring
      end

      @session.on(CDP::Protocol::Runtime::ExecutionContextDestroyedEvent) do |event|
        gone = @mutex.synchronize { @contexts.delete(event.execution_context_id) }
        gone.try &.mark_destroyed
        ring
      end

      @session.on(CDP::Protocol::Runtime::ExecutionContextsClearedEvent) do |_|
        cleared = @mutex.synchronize do
          values = @contexts.values.dup
          @contexts.clear
          values
        end
        cleared.each(&.mark_destroyed)
        ring
      end
    end

    private def watch_dialogs : Nil
      @session.on(CDP::Protocol::Page::JavascriptDialogOpeningEvent) do |event|
        handlers = @mutex.synchronize { @dialog_handlers.dup }
        if handlers.empty?
          # Measured, not assumed: with the Page domain enabled and nobody
          # answering, an alert() does not merely stall — the renderer stops
          # responding to every later command for the life of the page, while
          # the browser-level session goes on answering as if nothing happened.
          handle_dialog(accept: false)
        else
          handlers.each(&.call(event))
        end
      end
    end

    # Only contexts belonging to this page's main frame are ours. An iframe gets
    # its own, and confusing the two is how `evaluate` ends up running somewhere
    # the caller did not mean.
    private def belongs_here?(description : CDP::Protocol::Runtime::ExecutionContextDescription, frame_id : String) : Bool
      aux = description.aux_data
      return false unless aux
      aux["frameId"]?.try(&.as_s?) == frame_id
    end

    private def await_context(progress : Progress, what : String, &predicate : ExecutionContext -> Bool) : ExecutionContext
      loop do
        found = @mutex.synchronize { @contexts.values.find { |context| predicate.call(context) } }
        return found if found

        raise progress.timed_out("waiting for #{what}") if progress.expired?
        progress.log("waiting for #{what}")

        select
        when @bell.receive
        when timeout(progress.remaining)
        end
      end
    end

    # Wakes anything waiting on a context, without ever blocking the event
    # fiber: the doorbell holds one ring, and a second one while the first is
    # unanswered would be telling a waiter something it is already about to
    # check.
    private def ring : Nil
      select
      when @bell.send(nil)
      else
      end
    end
  end
end
