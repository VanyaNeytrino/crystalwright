require "cdp"
require "./errors"
require "./js_value"
require "./progress"
require "./lifecycle"
require "./execution_context"
require "./js_handle"
require "./frame_manager"

module Crystalwright
  # One tab.
  #
  # A page is its main frame plus the things that belong to the tab rather than
  # to any one frame: the session, the dialogs, and closing. Everything about
  # documents, navigation and waiting is the frame's, and `Page` forwards to
  # `main_frame` for it — so `page.goto` and `page.main_frame.goto` are the same
  # call, and an iframe gets the same API as the page it is inside.
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

    # The frame tree and everything that keeps it current.
    getter frames_manager : FrameManager

    @dialog_handlers = [] of Proc(CDP::Protocol::Page::JavascriptDialogOpeningEvent, Nil)
    @mutex = Sync::Mutex.new
    @closed = false

    # :nodoc:
    def initialize(@session : CDP::Session, @target_id : String)
      @utility_world_name = "__crystalwright_utility_#{Random::Secure.hex(8)}"
      @frames_manager = FrameManager.new(@session, @utility_world_name)
    end

    # :nodoc:
    protected def start(timeout : Time::Span) : Nil
      watch_dialogs
      @frames_manager.start(timeout)
    end

    # The tab's top frame.
    def main_frame : Frame
      @frames_manager.main_frame
    end

    # Every frame in the tab, parents before children.
    def frames : Array(Frame)
      @frames_manager.frames
    end

    # The frame with this `name` or `id` attribute, if it is still attached.
    def frame(name : String) : Frame?
      @frames_manager.frame(name)
    end

    # The address of the main frame.
    def url : String
      main_frame.url
    end

    # Navigates the main frame and waits for it to get where it was told to.
    def goto(url : String, wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Nil
      main_frame.goto(url, wait_until, timeout)
    end

    # Waits until the main frame's current document has reached a state.
    def wait_for_load_state(state : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Nil
      main_frame.wait_for_load_state(state, timeout)
    end

    # Runs an action that might navigate, and does not return until it has.
    #
    # This is the seam the actions of a later milestone wrap themselves in:
    # every click, `fill` and `press` runs inside one of these so that the call
    # after it is not racing a navigation this one started. It is public now
    # because the barrier is testable before there is anything to click.
    def with_navigation_signals(timeout : Time::Span? = nil, &)
      progress = Progress.new("action", timeout || DEFAULT_TIMEOUT)
      @frames_manager.with_signals(progress) { yield }
    end

    # A locator for this selector, resolved fresh at every use.
    #
    # Prefer this to `query_selector` for anything that will be acted on. A
    # handle refers to one node and dies with it; a locator refers to a question
    # and asks it again each time — which is what survives a re-render.
    #
    # Locators are strict: naming two elements is an error rather than a silent
    # choice of the first.
    def locator(selector : String) : Locator
      main_frame.locator(selector)
    end

    # A locator for elements whose text matches.
    def get_by_text(text : String | Regex, exact : Bool = false) : Locator
      main_frame.get_by_text(text, exact)
    end

    # A locator for elements carrying this `data-testid`.
    def get_by_test_id(id : String) : Locator
      main_frame.get_by_test_id(id)
    end

    # A locator for the control a `<label>` names, or an element with this `aria-label`.
    def get_by_label(text : String | Regex, exact : Bool = false) : Locator
      main_frame.get_by_label(text, exact)
    end

    # A locator for elements whose `placeholder` matches.
    def get_by_placeholder(text : String | Regex, exact : Bool = false) : Locator
      main_frame.get_by_placeholder(text, exact)
    end

    # A locator for elements whose `alt` matches.
    def get_by_alt_text(text : String | Regex, exact : Bool = false) : Locator
      main_frame.get_by_alt_text(text, exact)
    end

    # A locator for elements whose `title` matches.
    def get_by_title(text : String | Regex, exact : Bool = false) : Locator
      main_frame.get_by_title(text, exact)
    end

    # The mouse, in page coordinates.
    #
    # Low level: it goes where it is told and checks nothing. `click` is what
    # you almost always want instead.
    def mouse : Mouse
      @frames_manager.mouse
    end

    # The keyboard.
    def keyboard : Keyboard
      @frames_manager.keyboard
    end

    # Clicks the first element matching the selector.
    #
    # Waits for it to be visible, enabled and holding still, scrolls it into
    # view, aims at the middle of what is actually on screen, checks nothing is
    # on top of it, and keeps checking while the events are in flight. Retries
    # all of that until it works or the deadline passes.
    def click(selector : String, button : MouseButton = MouseButton::Left, click_count : Int32 = 1,
              force : Bool = false, timeout : Time::Span? = nil) : Nil
      main_frame.click(selector, button, click_count, force, timeout)
    end

    # Moves the pointer over the first element matching the selector.
    def hover(selector : String, force : Bool = false, timeout : Time::Span? = nil) : Nil
      main_frame.hover(selector, force, timeout)
    end

    # Replaces the contents of an input, textarea or contenteditable.
    def fill(selector : String, value : String, timeout : Time::Span? = nil) : Nil
      main_frame.fill(selector, value, timeout)
    end

    # Focuses the first element matching the selector and presses one key.
    def press(selector : String, key : String, timeout : Time::Span? = nil) : Nil
      main_frame.press(selector, key, timeout)
    end

    # The first element in the page matching the selector, or `nil`.
    #
    # Selectors are `css=`, `text=`, `xpath=`, `id=` and `data-testid=`, chained
    # with `>>`; a step with no engine is xpath when it starts with `//` and css
    # otherwise. `css=` looks inside open shadow roots, and `css:light=` does
    # not.
    def query_selector(selector : String, timeout : Time::Span? = nil) : ElementHandle?
      main_frame.query_selector(selector, timeout)
    end

    # Every element in the page matching the selector.
    def query_selector_all(selector : String, timeout : Time::Span? = nil) : Array(ElementHandle)
      main_frame.query_selector_all(selector, timeout)
    end

    # Waits until an element matching the selector reaches a state.
    def wait_for_selector(selector : String, state : ElementState = ElementState::Visible, timeout : Time::Span? = nil) : ElementHandle?
      main_frame.wait_for_selector(selector, state, timeout)
    end

    # The text of the first element matching the selector.
    def text_content(selector : String, timeout : Time::Span? = nil) : String?
      main_frame.text_content(selector, timeout)
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
      main_frame.evaluate(source, *args, timeout: timeout)
    end

    # Evaluates and converts the result to a Crystal type.
    #
    # ```
    # title = page.evaluate(String, "() => document.title")
    # count = page.evaluate(Int32, "() => document.links.length")
    # ```
    def evaluate(type : T.class, source : String, *args, timeout : Time::Span? = nil) forall T
      main_frame.evaluate(type, source, *args, timeout: timeout)
    end

    # Evaluates in the page's own world and leaves the result there.
    def evaluate_handle(source : String, *args, timeout : Time::Span? = nil) : JSHandle
      main_frame.evaluate_handle(source, *args, timeout: timeout)
    end

    # Evaluates in the isolated world this library works in.
    #
    # Nothing the page does can reach code running here, and nothing here shows
    # up in the page's own `window`.
    def evaluate_in_utility(source : String, *args, timeout : Time::Span? = nil) : JSValue
      main_frame.evaluate_in_utility(source, *args, timeout: timeout)
    end

    # :ditto:
    def evaluate_in_utility(type : T.class, source : String, *args, timeout : Time::Span? = nil) forall T
      main_frame.evaluate_in_utility(type, source, *args, timeout: timeout)
    end

    # The main frame's own JavaScript world, waiting for it if a navigation is
    # in flight.
    def main_world(progress : Progress) : ExecutionContext
      main_frame.main_world(progress)
    end

    # The isolated world this library works in, in the main frame.
    def utility_world(progress : Progress) : ExecutionContext
      main_frame.utility_world(progress)
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

      contexts.each(&.dispose)
      @session.execute(CDP::Protocol::Target::CloseTargetRequest.new(target_id: @target_id), timeout)
    rescue CDP::ProtocolError | CDP::SessionClosedError | CDP::ConnectionClosedError
      # The tab or the browser went first, which is the outcome asked for.
    end

    # Every execution context alive in the tab, across every frame.
    def contexts : Array(ExecutionContext)
      frames.flat_map(&.contexts)
    rescue Error
      # Asked before the frame tree was read.
      [] of ExecutionContext
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
  end
end
