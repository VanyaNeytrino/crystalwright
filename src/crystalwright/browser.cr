require "cdp"
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

    @pages = [] of Page
    @mutex = Sync::Mutex.new

    # :nodoc:
    def initialize(@process : CDP::BrowserProcess)
    end

    # Opens a tab.
    def new_page(timeout : Time::Span = DEFAULT_TIMEOUT) : Page
      root = @process.connection.root
      target = root.execute(CDP::Protocol::Target::CreateTargetRequest.new(url: "about:blank"), timeout)
      session = root.attach(target.target_id, timeout)

      page = Page.new(session, target.target_id)
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

    # The tabs this object opened.
    def pages : Array(Page)
      @mutex.synchronize { @pages.dup }
    end

    # Shuts the browser down and removes its temporary profile.
    def close(timeout : Time::Span = 10.seconds) : Nil
      @process.close(timeout)
    end
  end
end
