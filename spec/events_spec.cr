require "./spec_helper"

describe "what the page says", tags: "integration" do
  describe "console" do
    it "reports what was printed, with the arguments rendered" do
      with_fixtures do |server|
        with_page do |page|
          seen = [] of Crystalwright::ConsoleMessage
          page.on_console { |message| seen << message }

          page.goto(server.url("/noisy.html"))
          eventually(message: "nothing was reported") { seen.size >= 2 }

          first = seen.first
          first.type.should eq "log"

          # An object's own description is the word "Object", which in a log is
          # worse than nothing: seeing inside it is the entire reason to print
          # one. The protocol sends a preview for exactly this.
          first.text.should eq %(plain 42 {a: 1, b: "two"} [0: 1, 1: 2, 2: 3])
          first.url.to_s.should end_with "/noisy.html"
          first.line.should eq 6

          seen.map(&.type).should contain "warning"
        end
      end
    end

    it "costs nothing when nobody is listening" do
      with_fixtures do |server|
        with_page do |page|
          # No handler, so the arguments are never rendered and no fiber is
          # spawned. Worth pinning because rendering a console argument is a
          # walk over a preview, and a page in a loop can print thousands.
          page.goto(server.url("/noisy.html"))
          page.title.should eq "noisy"
        end
      end
    end
  end

  describe "uncaught exceptions" do
    it "reports one the page threw" do
      with_fixtures do |server|
        with_page do |page|
          thrown = [] of Crystalwright::PageError
          page.on_page_error { |error| thrown << error }

          page.goto(server.url("/noisy.html"))
          page.click("#throw")
          eventually(message: "the exception was never reported") { thrown.size >= 1 }

          error = thrown.first
          error.message.should contain "missingFunction"
          error.message.should contain "ReferenceError"

          # A thrown `Error` describes itself with its stack already attached,
          # so a separate one would print it twice.
          error.stack.should be_nil
        end
      end
    end

    it "does not raise into the caller" do
      with_fixtures do |server|
        with_page do |page|
          page.on_page_error { |_| }
          page.goto(server.url("/noisy.html"))

          # A page throwing is the page's business. The click that caused it
          # succeeded, and the caller decides what an uncaught exception means.
          page.click("#throw")
          page.title.should eq "noisy"
        end
      end
    end
  end

  describe "the default timeout" do
    it "applies to everything that did not say otherwise" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/plain.html"))
          page.default_timeout.should eq 30.seconds

          page.default_timeout = (1.second)
          page.default_timeout.should eq 1.second

          # Actions, locators and assertions all read the same setting: thirty
          # seconds is right for a person watching and wrong for a suite on a
          # runner at half the speed, and changing it in one place has to mean
          # all of them.
          expect_raises(Crystalwright::TimeoutError) { page.click("#never-there") }
          expect_raises(Crystalwright::TimeoutError) { page.locator("#never-there").click }
          expect_raises(Crystalwright::AssertionError) do
            Crystalwright.expect(page.locator("#never-there")).to_be_visible
          end
        end
      end
    end

    it "loses to a timeout the caller gave" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/plain.html"))
          page.default_timeout = (30.seconds)

          error = expect_raises(Crystalwright::TimeoutError) do
            page.click("#never-there", timeout: 1.second)
          end
          error.timeout.should eq 1.second
        end
      end
    end

    it "reaches the frames inside the tab" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/iframe-same-origin.html"))
          inner = frame_named(page, "kid")

          page.default_timeout = (1.second)

          # One tab, one setting. A suite that raises it because its CI is slow
          # means the whole tab, not the main frame only.
          inner.default_timeout.should eq 1.second
          expect_raises(Crystalwright::TimeoutError) { inner.click("#never-there") }
        end
      end
    end
  end
end
