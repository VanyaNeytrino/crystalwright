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
            settled = Time.instant

            # The last script answers 600 ms in, so quiet cannot be declared
            # before 1100 ms. A window of zero gets here in about 650 ms.
            (settled - started).should be >= 1050.milliseconds

            # And it must not be Chrome's own `networkIdle`, which was measured
            # on this fixture at 1311 ms after the last request finished.
            #
            # Measured from when the *server* last answered rather than from
            # when this spec started, which is the only reference point that
            # does not move with the load on the machine. An earlier version
            # compared elapsed wall time against a fixed ceiling and failed once
            # in twenty runs while the library was doing exactly the right
            # thing.
            answered = server.last_response_at
            answered.should_not be_nil
            if answered
              (settled - answered).should be < 900.milliseconds
            end

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

            # Against this library's own quiet window rather than a number
            # chosen by eye: unlatched, this call cannot return in less than the
            # window, because that is what it would be waiting out. The machine
            # would have to be five hundred times slower to confuse the two.
            (Time.instant - started).should be < Crystalwright::NETWORK_IDLE_WINDOW
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

      it "goes quiet again after a document that left a request hanging" do
        pages = {
          "/leaky" => %(<!doctype html><title>leaky</title><script>fetch("/hang")</script>),
          "/quiet" => %(<!doctype html><title>quiet</title><p>nothing else to fetch),
        }
        with_fixtures(pages) do |server|
          with_page do |page|
            page.goto(server.url("/leaky"))
            eventually(message: "the leaky page never asked for /hang") do
              server.request_count("/hang") == 1
            end

            # `/hang` never answers, and the page is now navigated away from the
            # document that asked for it. Chrome then mentions that request
            # again in neither direction — no `loadingFinished`, no
            # `loadingFailed` — so a tally that keeps it never drains and this
            # frame can never be idle again. Found on a real site, one
            # navigation after the page that caused it, which is what makes it
            # worth a fixture: there is nothing suspicious about the page that
            # fails.
            page.goto(server.url("/quiet"), Crystalwright::LoadState::NetworkIdle, 8.seconds)

            page.text_content("p").should eq "nothing else to fetch"

            # The tally is one of two structures keyed by request id; the other
            # is the manager's map from request to frame. Both are cleaned up on
            # completion, and a request nobody completes stays in both.
            #
            # Exactly zero, not "small". The page has reached network idle, so
            # everything it asked for has finished and the only entry that could
            # survive is the one `/hang` left behind. A loose bound here passed
            # while the map leaked, which is what the mutation run is for.
            page.frames_manager.tracked_requests.should eq 0
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
            # second on the clock for every click in a suite — so the bound is
            # the grace period itself, which is the thing that would be waited
            # out, rather than a number chosen by eye.
            (Time.instant - started).should be < Crystalwright::SignalBarrier::GRACE
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
