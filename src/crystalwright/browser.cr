require "cdp"
require "file_utils"
require "./errors"
require "./page"

module Crystalwright
  # A running browser, and the tabs opened in it.
  #
  # Thin over `CDP::BrowserProcess`, which already starts the browser safely —
  # sandbox on, no listening socket, a private profile removed on close — and
  # already shuts it down at exit. There is nothing to improve on there, so this
  # adds tabs and gets out of the way.
  class Browser
    # The browser process and its protocol connection.
    getter process : CDP::BrowserProcess

    # Where downloaded files land.
    #
    # A directory of this shard's making, not the user's Downloads folder: a
    # test that scatters files into somewhere a person keeps things is a test
    # nobody runs twice. Created with `0700` and removed when the browser
    # closes.
    getter downloads_path : String

    @pages = [] of Page
    @popups = [] of Page
    @popup_bell = Channel(Nil).new(1)
    @downloads_enabled = false
    @init_scripts = [] of String
    @mutex = Sync::Mutex.new

    # :nodoc:
    def initialize(@process : CDP::BrowserProcess)
      @downloads_path = File.join(Dir.tempdir, "crystalwright-downloads-#{Random::Secure.hex(8)}")
      watch_for_popups
    end

    # Runs this source at the start of every document, in every tab, before
    # anything the page itself runs.
    #
    # Has to be registered before the tab exists, which is what makes it work
    # for a popup: a tab opened by a page is held still before its own first
    # statement, given the scripts registered here, and only then released.
    def add_init_script(source : String) : Nil
      @mutex.synchronize { @init_scripts << source }
    end

    # :nodoc:
    protected def init_scripts : Array(String)
      @mutex.synchronize { @init_scripts.dup }
    end

    # Opens a tab.
    def new_page(timeout : Time::Span = DEFAULT_TIMEOUT) : Page
      root = @process.connection.root
      target = root.execute(CDP::Protocol::Target::CreateTargetRequest.new(url: "about:blank"), timeout)
      session = root.attach(target.target_id, timeout)

      page = Page.new(session, target.target_id, self)
      page.start(timeout)
      @mutex.synchronize { @pages << page }
      page
    end

    # Opens a tab, yields it, and always closes it.
    def new_page(timeout : Time::Span = DEFAULT_TIMEOUT, &)
      page = new_page(timeout)
      begin
        yield page
      ensure
        page.close
      end
    end

    # The tabs that are open.
    #
    # Not the tabs ever opened: a closed one is removed here as it closes. The
    # difference is not bookkeeping. Every `Page` holds a protocol session, a
    # frame tree and the execution contexts under it, so a list that only ever
    # grows pins all of that for as long as the browser lives — and a caller
    # iterating this to act on its tabs would be handed dead ones. Fifty opened
    # and closed in a row left fifty here.
    def pages : Array(Page)
      @mutex.synchronize { @pages.dup }
    end

    # :nodoc:
    #
    # A tab saying it has closed. Called from `Page#close`, which is the only
    # place that knows it happened — a caller may close a tab directly rather
    # than through the block form.
    protected def forget(page : Page) : Nil
      @mutex.synchronize do
        @pages.delete(page)
        @popups.delete(page)
      end
    end

    # The cookies the browser is holding.
    def cookies(timeout : Time::Span = DEFAULT_TIMEOUT) : Array(CDP::Protocol::Network::Cookie)
      @process.connection.root.execute(CDP::Protocol::Storage::GetCookiesRequest.new, timeout).cookies
    end

    # Gives the browser cookies it did not earn.
    #
    # What a saved session is restored from, which is most of what people want
    # cookies for: signing in once and starting every later run already signed
    # in.
    def add_cookies(cookies : Array(CDP::Protocol::Network::CookieParam),
                    timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      @process.connection.root.execute(
        CDP::Protocol::Storage::SetCookiesRequest.new(cookies: cookies), timeout)
    end

    # Forgets all of them.
    def clear_cookies(timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      @process.connection.root.execute(CDP::Protocol::Storage::ClearCookiesRequest.new, timeout)
    end

    # Lets pages on this origin use capabilities a person would be asked about.
    #
    # ```
    # browser.grant_permissions(["geolocation"], origin: "https://a.test")
    # ```
    def grant_permissions(permissions : Array(String), origin : String? = nil,
                          timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      wire = permissions.map { |name| CDP::Protocol::Browser::PermissionType.parse(name) }
      @process.connection.root.execute(CDP::Protocol::Browser::GrantPermissionsRequest.new(
        permissions: wire, origin: origin), timeout)
    end

    # Takes them all back.
    def reset_permissions(timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      @process.connection.root.execute(CDP::Protocol::Browser::ResetPermissionsRequest.new, timeout)
    end

    # Shuts the browser down and removes its temporary profile.
    def close(timeout : Time::Span = 10.seconds) : Nil
      @process.close(timeout)
    ensure
      FileUtils.rm_rf(@downloads_path) if Dir.exists?(@downloads_path)
    end

    # :nodoc:
    #
    # Turned on the first time somebody waits for a download, and not before.
    # Enabling it means the browser reports every download over the protocol,
    # which is a cost a program that never downloads anything should not pay.
    protected def enable_downloads(timeout : Time::Span) : Nil
      return if @mutex.synchronize { was = @downloads_enabled; @downloads_enabled = true; was }

      Dir.mkdir_p(@downloads_path, 0o700)
      @process.connection.root.execute(CDP::Protocol::Browser::SetDownloadBehaviorRequest.new(
        behavior: CDP::Protocol::Browser::SetDownloadBehaviorRequestBehavior::AllowAndName,
        download_path: @downloads_path,
        events_enabled: true), timeout)
    end

    # :nodoc:
    #
    # A tab that opened while somebody was watching, with this page as its
    # opener.
    protected def take_popup(opener : String) : Page?
      @mutex.synchronize do
        index = @popups.index { |page| page.opener_target_id == opener }
        index ? @popups.delete_at(index) : nil
      end
    end

    # :nodoc:
    protected def popup_bell : Channel(Nil)
      @popup_bell
    end

    # Catches a tab the page opened, and holds it still until it is configured.
    #
    # `waitForDebuggerOnStart` is the whole mechanism. Without it a popup starts
    # running its own scripts the instant it exists, and anything this shard
    # wants in place first — the isolated world, an init script — arrives after
    # the page has already done whatever it was going to do. With it, the new
    # target is frozen before its first statement, stays frozen while it is set
    # up, and is released by `Runtime.runIfWaitingForDebugger`.
    private def watch_for_popups : Nil
      root = @process.connection.root

      root.execute(CDP::Protocol::Target::SetAutoAttachRequest.new(
        auto_attach: true, wait_for_debugger_on_start: true, flatten: true), 10.seconds)

      root.on(CDP::Protocol::Target::AttachedToTargetEvent) do |event|
        info = event.target_info
        next unless info.type == "page"

        session = @process.connection.session(event.session_id)
        next unless session

        # Every attached tab is frozen, not only the ones somebody opened — a
        # tab this shard creates itself is held just the same, and a tab nobody
        # releases never runs a line. Forgetting that is a page whose `goto`
        # waits out its whole deadline for a document the browser has not been
        # allowed to start.
        opener = info.opener_id

        # Off the event fiber: setting a page up is a dozen round trips, and
        # they are answered on the fiber this handler is holding.
        if opener
          spawn(name: "popup") { adopt_popup(session, info.target_id, opener) }
        else
          # One we opened. `new_page` attaches and configures it itself, so
          # there is nothing to do here but let it start.
          spawn(name: "release") { release(session) }
        end
      end
    end

    private def adopt_popup(session : CDP::Session, target_id : String, opener : String) : Nil
      page = Page.new(session, target_id, self, opener_target_id: opener)
      page.start(10.seconds)
      page.resync_after_first_commit
      @mutex.synchronize { @popups << page; @pages << page }
    rescue error
      Log.error(exception: error) { "could not set up a popup" }
    ensure
      release(session)
      select
      when @popup_bell.send(nil)
      else
      end
    end

    private def release(session : CDP::Session) : Nil
      session.execute(CDP::Protocol::Runtime::RunIfWaitingForDebuggerRequest.new, 10.seconds)
    rescue CDP::Error
      # It went away before it ever ran, which is its own answer.
    end

    Log = ::Log.for("crystalwright.browser")
  end
end
