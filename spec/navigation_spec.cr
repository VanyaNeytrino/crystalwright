require "./spec_helper"

# Level 3: the four fixtures the milestone is judged on, against a real Chrome.
#
# Each one reproduces a pathology that a page which simply loads cannot: a
# navigation with no lifecycle event behind it, resources that arrive slowly
# enough for a quiet window to mean something, a page that is never quiet, and
# an action that navigates out from under the call that follows it.
describe "navigation", tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    describe "a navigation with no document behind it" do
      it "follows history.pushState without waiting for a load that already happened" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/spa-pushstate.html"))
            was = page.main_frame.loader_id

            page.evaluate("() => window.__go('/spa/one')")
            eventually(5.seconds, "the pushState was never seen") { page.url.ends_with?("/spa/one") }

            # The whole point. `load` fired for the document that is still
            # showing and is never going to fire again, so a wait that treated
            # this as a new document would sit here until it timed out. Two
            # seconds rather than thirty, so that a regression fails the suite
            # instead of stalling it.
            page.wait_for_load_state(Crystalwright::LoadState::Load, 2.seconds)
            page.wait_for_load_state(Crystalwright::LoadState::DOMContentLoaded, 2.seconds)

            page.evaluate("() => window.__go('/spa/two')")
            eventually(5.seconds, "the second pushState was never seen") { page.url.ends_with?("/spa/two") }
            page.wait_for_load_state(Crystalwright::LoadState::Load, 2.seconds)

            # Same document throughout: the counter survived, and so did the
            # identity of what the frame is showing.
            page.evaluate(Int32, "() => window.__pushes").should eq 2
            page.main_frame.loader_id.should eq was
          end
        end
      end

      it "follows a fragment change too" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/spa-pushstate.html"))
            was = page.main_frame.loader_id

            page.evaluate("() => { location.hash = 'section'; }")
            eventually(5.seconds, "the fragment was never seen") { page.url.ends_with?("#section") }

            page.main_frame.loader_id.should eq was
            page.wait_for_load_state(Crystalwright::LoadState::Load, 2.seconds)
          end
        end
      end
    end

    describe "networkidle" do
      it "waits 500 ms past the last resource, and not for Chrome's own idea of quiet" do
        with_fixtures do |server|
          with_page do |page|
            started = Time.instant
            page.goto(server.url("/slow-resources.html"), Crystalwright::LoadState::NetworkIdle, 10.seconds)
            elapsed = Time.instant - started

            # The last script answers 600 ms in, so quiet cannot be declared
            # before 1100 ms. A window of zero gets here in about 650 ms.
            elapsed.should be >= 1050.milliseconds

            # And it must not be Chrome's `networkIdle` lifecycle event, which
            # was measured on this fixture at 1311 ms after the last request
            # finished — roughly 1950 ms in — and which varies run to run.
            elapsed.should be < 1700.milliseconds

            server.request_count("/slow").should eq 3
          end
        end
      end

      it "reports quiet immediately once a document has been quiet before" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/plain.html"), Crystalwright::LoadState::NetworkIdle, 10.seconds)

            # Latched, like every other load state: asking again about the same
            # document is not a second wait.
            started = Time.instant
            page.wait_for_load_state(Crystalwright::LoadState::NetworkIdle, 2.seconds)
            (Time.instant - started).should be < 200.milliseconds
          end
        end
      end

      it "never reports quiet on a page that keeps polling" do
        with_fixtures do |server|
          with_page do |page|
            # Reached from a document that *did* go quiet, on purpose. A
            # `networkidle` latched into the old document and not cleared when
            # the next one commits would answer for the wrong page, and the
            # answer would be the opposite of the truth.
            page.goto(server.url("/plain.html"), Crystalwright::LoadState::NetworkIdle, 10.seconds)
            page.goto(server.url("/never-idle.html"))

            error = expect_raises(Crystalwright::TimeoutError) do
              page.wait_for_load_state(Crystalwright::LoadState::NetworkIdle, 2.seconds)
            end

            # The failure has to say what it was waiting for. An action that
            # gives up without explaining itself turns debugging a live site
            # into guesswork, which is the whole reason `Progress` keeps a log.
            error.message.to_s.should contain "NetworkIdle"
            error.message.to_s.should contain "main frame"

            # It really was polling, rather than failing to start.
            server.request_count("/poll").should be > 5
          end
        end
      end
    end

    describe "the navigation barrier" do
      it "does not return until a navigation the action started has committed" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/navigate-on-click.html"))
            page.evaluate(String, "() => document.title").should eq "before"

            page.with_navigation_signals(10.seconds) do
              page.evaluate("() => document.getElementById('go').click()")
            end

            # The destination takes 300 ms to answer, on purpose. The click
            # itself returns in single-digit milliseconds, so without the
            # barrier this is still the old document — deterministically, not
            # one time in ten.
            page.url.should contain "title=arrived"
            page.evaluate(String, "() => document.title").should eq "arrived"
          end
        end
      end

      it "returns straight away when the action navigates nowhere" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/plain.html"))

            started = Time.instant
            page.with_navigation_signals(10.seconds) do
              page.evaluate("() => document.title")
            end

            # Nothing was announced, so there is nothing to settle. A barrier
            # that waited out its grace period on every action would put a
            # second on the clock for every click in a suite.
            (Time.instant - started).should be < 500.milliseconds
          end
        end
      end
    end

    describe "waiting" do
      it "wakes every waiter when the page moves, not just one of them" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/late-iframe.html"))

            # Sixteen waiters and one burst of events. A doorbell that is a
            # single shared slot wakes at most one waiter per event, so most of
            # these would sleep out their whole budget and come back with the
            # right answer far too late — a stall rather than a wrong result,
            # and therefore the kind of bug that gets blamed on the browser.
            watchers = 16
            done = Channel(Time::Span).new(watchers)
            started = Time.instant

            watchers.times do
              spawn do
                progress = Crystalwright::Progress.new("doorbell", 6.seconds)
                page.frames_manager.wait_until(progress, "the second frame") { page.frames.size == 2 }
                done.send(Time.instant - started)
              end
            end

            watchers.times { done.receive.should be < 2.seconds }
          end
        end
      end
    end

    describe "goto" do
      it "waits for the document it asked for, not merely for a document" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/plain.html"))
            first = page.main_frame.loader_id

            page.goto(server.url("/slow?ms=300&type=html&title=second"))
            page.main_frame.loader_id.should_not eq first
            page.evaluate(String, "() => document.title").should eq "second"
          end
        end
      end

      it "says why a navigation failed instead of timing out" do
        # A port that was free a moment ago, rather than a low one: Chrome
        # refuses ports like 1 and 9 as unsafe before it ever connects, which
        # tests its blocklist instead of its error reporting.
        probe = TCPServer.new("127.0.0.1", 0)
        closed_port = probe.local_address.port
        probe.close

        with_page do |page|
          error = expect_raises(Crystalwright::Error, /failed/) do
            page.goto("http://127.0.0.1:#{closed_port}/nothing-is-listening", timeout: 10.seconds)
          end

          # The assertion is that Chrome's own reason reached the caller, not
          # which reason it was — that part is Chrome's business and changes
          # between versions.
          error.message.to_s.should contain "net::ERR_"
        end
      end
    end
  end
end
