require "base64"
require "cdp"
require "./errors"
require "./js_value"
require "./progress"
require "./lifecycle"
require "./execution_context"
require "./js_handle"
require "./frame_manager"
require "./download"
require "./file_chooser"

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

    # The target of the tab that opened this one, when it is a popup.
    getter opener_target_id : String?

    @dialog_handlers = [] of Proc(CDP::Protocol::Page::JavascriptDialogOpeningEvent, Nil)
    @mutex = Sync::Mutex.new
    @closed = false

    # :nodoc:
    def initialize(@session : CDP::Session, @target_id : String, @browser : Browser,
                   @opener_target_id : String? = nil)
      @utility_world_name = "__crystalwright_utility_#{Random::Secure.hex(8)}"
      @frames_manager = FrameManager.new(@session, @utility_world_name)
    end

    # :nodoc:
    #
    # `init_scripts_sent` is for a tab that was adopted rather than opened here.
    # Such a tab is held at `waitForDebuggerOnStart`, and its init scripts have
    # to be *sent* before it is released rather than registered after it starts,
    # so `Browser` does that itself and says so here. Registering them twice is
    # not harmless: a script that counts would count twice.
    protected def start(timeout : Time::Span, init_scripts_sent : Bool = false) : Nil
      watch_dialogs
      watch_crashes(timeout)
      @frames_manager.start(timeout)
      if init_scripts_sent
        # An adopted tab was already running before any of this was subscribed,
        # so what it has already done has to be asked for rather than waited on.
        @frames_manager.seed_load_state(timeout)
        return
      end
      @browser.init_scripts.each { |source| add_init_script(source, timeout) }
    end

    # :nodoc:
    protected def resync_after_first_commit : Nil
      @frames_manager.resync_after_first_commit
    end

    # Runs this source at the start of every document in this tab, before
    # anything the page itself runs.
    #
    # For every tab rather than this one, and for tabs that do not exist yet,
    # use `Browser#add_init_script`.
    def add_init_script(source : String, timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      @session.execute(CDP::Protocol::Page::AddScriptToEvaluateOnNewDocumentRequest.new(
        source: source), timeout)
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

    # Loads the current address again.
    def reload(wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Nil
      main_frame.reload(wait_until, timeout)
    end

    # Goes back one entry in this tab's history, or answers `false`.
    def go_back(wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Bool
      main_frame.go_back(wait_until, timeout)
    end

    # Goes forward one entry in this tab's history, or answers `false`.
    def go_forward(wait_until : LoadState = LoadState::Load, timeout : Time::Span? = nil) : Bool
      main_frame.go_forward(wait_until, timeout)
    end

    # The document's title.
    def title(timeout : Time::Span? = nil) : String
      main_frame.title(timeout)
    end

    # The document as HTML, doctype included.
    def content(timeout : Time::Span? = nil) : String
      main_frame.content(timeout)
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

    # A PNG of the page.
    #
    # Returns the bytes, and writes them to `path` as well when one is given.
    # `full_page` captures everything there is to scroll rather than what
    # happens to be on screen.
    def screenshot(path : String? = nil, full_page : Bool = false,
                   timeout : Time::Span = DEFAULT_TIMEOUT) : Bytes
      response = @session.execute(CDP::Protocol::Page::CaptureScreenshotRequest.new(
        format: CDP::Protocol::Page::CaptureScreenshotRequestFormat::Png,
        capture_beyond_viewport: full_page), timeout)

      bytes = Base64.decode(response.data)
      if path
        Dir.mkdir_p(File.dirname(path)) unless Dir.exists?(File.dirname(path))
        File.write(path, bytes)
      end
      bytes
    end

    # Sets the size of the area the page is rendered into.
    #
    # An override rather than a window resize: the window keeps whatever size
    # the operating system gave it, and the page is told it has this one. That
    # is the only version that works when the browser is headless and has no
    # window at all.
    def set_viewport(width : Int32, height : Int32, device_scale_factor : Float64 = 1.0,
                     mobile : Bool = false, timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      @session.execute(CDP::Protocol::Emulation::SetDeviceMetricsOverrideRequest.new(
        width: width, height: height,
        device_scale_factor: device_scale_factor, mobile: mobile), timeout)
    end

    # Tells the page it is somewhere.
    #
    # Only answers a request for a position; it does not grant permission to
    # ask. `grant_permissions("geolocation")` is the other half, and without it
    # a page gets the same refusal a person's browser would give it.
    def set_geolocation(latitude : Float64, longitude : Float64, accuracy : Float64 = 10.0,
                        timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      @session.execute(CDP::Protocol::Emulation::SetGeolocationOverrideRequest.new(
        latitude: latitude, longitude: longitude, accuracy: accuracy), timeout)
    end

    # Runs an action that downloads a file, and hands back the file.
    #
    # ```
    # download = page.expect_download { page.click("#report") }
    # download.save_into("tmp/reports")
    # ```
    def expect_download(timeout : Time::Span? = nil, &) : Download
      progress = Progress.new("expect_download", timeout || DEFAULT_TIMEOUT)
      @browser.enable_downloads(progress.remaining)

      root = @session.connection.root
      beginning = Channel(CDP::Protocol::Browser::DownloadWillBeginEvent).new(1)
      finished = Channel(String).new(4)

      began = root.on(CDP::Protocol::Browser::DownloadWillBeginEvent) do |event|
        select
        when beginning.send(event)
        else
        end
      end
      progressed = root.on(CDP::Protocol::Browser::DownloadProgressEvent) do |event|
        unless event.state.in_progress?
          select
          when finished.send(event.guid)
          else
          end
        end
      end

      begin
        yield

        started = receive_within(beginning, progress, "a download to begin")
        # The identifier, not the suggested name: with the naming behaviour this
        # shard asks for, that is what the file on disk is called, and nothing
        # the page says can change it.
        loop do
          guid = receive_within(finished, progress, "the download to finish")
          break if guid == started.guid
          raise progress.timed_out("waiting for the download to finish") if progress.expired?
        end

        Download.new(started.url, started.suggested_filename,
          File.join(@browser.downloads_path, started.guid))
      ensure
        began.cancel
        progressed.cancel
      end
    end

    # Runs an action that opens a file picker, and hands back the picker.
    #
    # The action has to produce a real input event — `page.click` does, and
    # calling `.click()` from JavaScript does not, because a picker only opens
    # for a user gesture.
    def expect_file_chooser(timeout : Time::Span? = nil, &) : FileChooser
      progress = Progress.new("expect_file_chooser", timeout || DEFAULT_TIMEOUT)
      @session.execute(CDP::Protocol::Page::SetInterceptFileChooserDialogRequest.new(
        enabled: true), progress.remaining)

      opened = Channel(CDP::Protocol::Page::FileChooserOpenedEvent).new(1)
      watching = @session.on(CDP::Protocol::Page::FileChooserOpenedEvent) do |event|
        select
        when opened.send(event)
        else
        end
      end

      begin
        yield
        event = receive_within(opened, progress, "a file picker to open")
        node = event.backend_node_id
        raise Error.new("The file picker did not say which input it belongs to.") unless node
        FileChooser.new(@session, node, event.mode.select_multiple?)
      ensure
        watching.cancel
        begin
          @session.execute(CDP::Protocol::Page::SetInterceptFileChooserDialogRequest.new(
            enabled: false), 5.seconds)
        rescue CDP::Error
        end
      end
    end

    # Hands files to a file input directly, without opening a picker.
    #
    # What most callers want: there is no dialog to intercept and no user
    # gesture to arrange, because the input is set rather than the picker
    # answered.
    def set_input_files(selector : String, *paths : String, timeout : Time::Span? = nil) : Nil
      set_input_files(selector, paths.to_a, timeout)
    end

    # :ditto:
    def set_input_files(selector : String, paths : Array(String), timeout : Time::Span? = nil) : Nil
      progress = Progress.new("set_input_files #{selector}", timeout || DEFAULT_TIMEOUT)
      element = main_frame.wait_for_selector(selector, ElementState::Attached, progress.remaining)
      raise Error.new("No element matched #{selector.inspect}.") unless element

      begin
        missing = paths.reject { |path| File.exists?(path) }
        raise Error.new("No such file: #{missing.join(", ")}") unless missing.empty?

        @session.execute(CDP::Protocol::DOM::SetFileInputFilesRequest.new(
          files: paths.map { |path| File.expand_path(path) },
          object_id: element.remote_object_id), progress.remaining)
      ensure
        element.dispose
      end
    end

    # Runs an action that opens a tab, and hands back the new tab.
    #
    # The new tab is held still before its own first statement runs, set up, and
    # only then released — so an init script registered on it is genuinely in
    # place before anything the page does.
    def expect_popup(timeout : Time::Span? = nil, &) : Page
      progress = Progress.new("expect_popup", timeout || DEFAULT_TIMEOUT)
      yield

      loop do
        if found = @browser.take_popup(@target_id)
          return found
        end
        raise progress.timed_out("waiting for a tab to open") if progress.expired?

        select
        when @browser.popup_bell.receive
        when timeout({progress.remaining, 50.milliseconds}.min)
        end
      end
    end

    # Answers matching requests yourself instead of letting them out.
    #
    # ```
    # page.route("**/api/**") do |route|
    #   route.fulfill(status: 200, body: %({"items": []}), content_type: "application/json")
    # end
    # ```
    #
    # The handler runs on a fiber of its own and may take as long as it likes,
    # including waiting on the page. Exactly one of `fulfill`, `abort` or
    # `continue` has to be called; a handler that returns without answering has
    # the request let through for it, because a request left hanging looks to
    # the page like a server that never replied.
    #
    # The most recently added handler that matches wins, so a specific route
    # added later overrides a general one added earlier.
    def route(pattern : String | Regex, timeout : Time::Span = DEFAULT_TIMEOUT, &handler : Route -> Nil) : Nil
      @frames_manager.add_route(URLPattern.new(pattern), handler, timeout)
    end

    # Stops answering requests for this pattern, or for all of them.
    def unroute(pattern : (String | Regex)? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      @frames_manager.remove_routes(pattern.try { |value| URLPattern.new(value) }, timeout)
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
      main_frame.get_by_role(role, exact, name, checked, disabled, expanded,
        level, pressed, selected, include_hidden)
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

    # Double-clicks the first element matching the selector.
    def dblclick(selector : String, button : MouseButton = MouseButton::Left,
                 force : Bool = false, timeout : Time::Span? = nil, strict : Bool = false) : Nil
      main_frame.dblclick(selector, button, force, timeout, strict)
    end

    # Moves the pointer over the first element matching the selector.
    def hover(selector : String, force : Bool = false, timeout : Time::Span? = nil) : Nil
      main_frame.hover(selector, force, timeout)
    end

    # Replaces the contents of an input, textarea or contenteditable.
    def fill(selector : String, value : String, timeout : Time::Span? = nil) : Nil
      main_frame.fill(selector, value, timeout)
    end

    # Chooses among a `<select>`'s options, and answers what is selected.
    def select_option(selector : String, value : String? = nil, label : String? = nil,
                      index : Int32? = nil, values : Array(String)? = nil,
                      timeout : Time::Span? = nil, strict : Bool = false) : Array(String)
      main_frame.select_option(selector, value, label, index, values, timeout, strict)
    end

    # Ticks a checkbox or a radio, or leaves it ticked.
    def check(selector : String, force : Bool = false, timeout : Time::Span? = nil,
              strict : Bool = false) : Nil
      main_frame.check(selector, force, timeout, strict)
    end

    # Unticks a checkbox or a radio, or leaves it unticked.
    def uncheck(selector : String, force : Bool = false, timeout : Time::Span? = nil,
                strict : Bool = false) : Nil
      main_frame.uncheck(selector, force, timeout, strict)
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
    ensure
      # In an `ensure`, because a tab that could not be closed politely is still
      # not a tab any more, and leaving it on the browser's list would keep this
      # object and everything under it alive for the rest of the session.
      @browser.forget(self)
    end

    # Every execution context alive in the tab, across every frame.
    def contexts : Array(ExecutionContext)
      frames.flat_map(&.contexts)
    rescue Error
      # Asked before the frame tree was read.
      [] of ExecutionContext
    end

    private def receive_within(channel : Channel(T), progress : Progress, what : String) : T forall T
      select
      when value = channel.receive
        value
      when timeout(progress.remaining)
        raise progress.timed_out("waiting for #{what}")
      end
    end

    # A renderer that dies says so once, and then answers nothing.
    #
    # Subscribed before anything else is enabled, and the domain turned on
    # afterwards, for the reason the frame manager writes down at length: a
    # subscription installed after the event is a subscription that missed it.
    private def watch_crashes(timeout : Time::Span) : Nil
      @session.on(CDP::Protocol::Inspector::TargetCrashedEvent) do
        Log.warn { "the page's renderer crashed" }
        @frames_manager.crashed!
      end
      @session.execute(CDP::Protocol::Inspector::EnableRequest.new, timeout)
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
