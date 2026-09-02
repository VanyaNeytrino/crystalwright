require "./spec_helper"

# Level 3: the seven fixtures this milestone is judged on, and the actions.
#
# Every one of them reproduces a way a click goes wrong on a real page, and
# none of them can be caught by a test that opens a page and presses a button.
# That is the whole argument for the library existing: without these checks the
# result is a nicer syntax for the same flakes.
describe "actions", tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    describe "clicking something that is not ready" do
      it "waits for a button to stop moving, and lands on it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/moving.html"))
            page.click("#target", timeout: 8.seconds)

            # Not "it did not throw". The fixture compares where the click
            # landed against where the button was at that moment, so a click
            # aimed at the position the button had when the selector resolved
            # reports "missed" rather than failing.
            page.text_content("#result").should eq "hit"
          end
        end
      end

      it "waits for a button to be enabled" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/late-enable.html"))
            page.click("#target", timeout: 8.seconds)

            # A disabled button does not receive clicks at all, so this alone
            # says the wait happened.
            page.text_content("#result").should eq "clicked"

            # And the page's own clock says it in a form no amount of machine
            # load can shift: the click arrived after the button was enabled.
            # Comparing elapsed wall time against 300 ms measured from the wrong
            # zero — the page loads before the click begins — is what an earlier
            # version of this spec did, and it failed twice in twenty runs.
            page.evaluate("() => window.__clickedAt >= window.__enabledAt").as_bool.should be_true
          end
        end
      end

      it "resolves the selector again when the node is replaced under it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/re-render.html"))
            page.click(".target", timeout: 8.seconds)

            # The node is replaced by the act of aiming at it, so the button
            # that received the click cannot be the one the selector first
            # resolved to. "after 1 swaps" is the proof.
            page.text_content("#result").should eq "clicked after 1 swaps"
          end
        end
      end
    end

    describe "clicking something covered" do
      it "refuses, and says what is in the way" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/covered.html"))

            error = expect_raises(Crystalwright::TimeoutError) do
              page.click("#target", timeout: DOOMED_ACTION)
            end

            # A fully transparent overlay is visible by every measure and still
            # eats the click, which is why visibility is not the question a
            # hit-target check answers. Naming the overlay is the point: "not
            # clickable" on its own sends you to the browser's devtools.
            error.message.to_s.should contain "intercepts pointer events"
            error.message.to_s.should contain "blanket"
            page.text_content("#result").should eq "not clicked"
          end
        end
      end

      it "names the dialog rather than the div under the cursor" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/modal.html"))

            error = expect_raises(Crystalwright::TimeoutError) do
              page.click("#target", timeout: DOOMED_ACTION)
            end

            # The element under the pointer is the dialog, but what a person
            # needs to know is that a modal is up. The walk up to the topmost
            # thing in the way that is not also an ancestor of the target is
            # what produces the "from ... subtree" half.
            error.message.to_s.should contain "from"
            error.message.to_s.should contain "subtree"
            error.message.to_s.should contain "overlay"
          end
        end
      end
    end

    describe "clicking something out of reach" do
      it "gets a button out from under a sticky header" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/sticky-header.html"))

            # The browser's own "scroll it just far enough" parks the button
            # exactly where the fixed header covers it. Getting to it needs a
            # different anchoring, which is what the rotation is for.
            page.click("#target", timeout: 8.seconds)
            page.text_content("#result").should eq "clicked"
          end
        end
      end

      it "gives up readably on an element that removes itself when approached" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/detach-on-hover.html"))

            started = Time.instant
            error = expect_raises(Crystalwright::TimeoutError) do
              page.click("#target", timeout: 2.seconds)
            end
            elapsed = Time.instant - started

            # The failure mode being guarded against is a hang: every attempt
            # finds the element and then loses it, for ever. It has to end on
            # the caller's deadline and print what it kept trying.
            elapsed.should be < 4.seconds
            error.message.to_s.should contain "click #target"
            error.message.to_s.should contain "attempting"
            page.text_content("#result").should eq "gone"
          end
        end
      end
    end

    describe "one deadline for the whole action" do
      it "fails after the timeout it was given, not after however many attempts happen" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/covered.html"))

            started = Time.instant
            expect_raises(Crystalwright::TimeoutError) { page.click("#target", timeout: 1.second) }
            first = Time.instant - started

            started = Time.instant
            expect_raises(Crystalwright::TimeoutError) { page.click("#target", timeout: 3.seconds) }
            second = Time.instant - started

            # This is the property `Progress` exists for and the one nothing has
            # been able to observe until now: the retries are nested three deep
            # and none of them has a clock of its own, so the caller's number is
            # the only one that decides when to stop.
            # Stated as a relationship rather than as two wall-clock windows.
            # What has to be true is that the budget is what decides — not the
            # number of attempts, which is what a per-attempt timeout would give
            # and which would make both of these take the same time.
            first.should be < 2.seconds
            second.should be >= first + 1.second
            second.should be < 5.seconds
          end
        end
      end

      it "keeps a log of what it tried" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/covered.html"))

            error = expect_raises(Crystalwright::TimeoutError) do
              page.click("#target", timeout: DOOMED_ACTION)
            end

            # An action that failed twelve times has to be able to say what it
            # saw on each of them. Debugging a live site otherwise is guessing.
            message = error.message.to_s
            message.should contain "attempting click"
            message.should contain "retrying click"
            message.should contain "aiming at"
            message.should contain "waiting for the element to be"
          end
        end
      end

      it "names what it was asking when the deadline lands inside a round trip" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/covered.html"))

            # The budget is searched for rather than guessed. A deadline that
            # expires *between* two round trips stops the log at a whole step,
            # which is the ordinary case every other spec here covers; landing
            # *inside* one needs a budget shorter than a single call, and how
            # short that is belongs to the machine. So the loop grows the budget
            # until it lands there, and the spec is about the shape of the
            # message rather than about any number in it.
            message = nil
            30.times do |i|
              error = expect_raises(Crystalwright::TimeoutError) do
                page.click("#target", timeout: (20 + i * 5).milliseconds)
              end
              text = error.message.to_s
              if text.includes?("running")
                message = text
                break
              end
            end

            # This is the failure that went red once and could not be read: the
            # log said which CDP method was busy and which internal world it
            # was busy in, and nothing about what the library wanted. What a
            # caller needs is the question, not the plumbing.
            message.should_not be_nil
            text = message.to_s
            text.should contain "waiting for the element to be"
            text.should contain "running checkStates in the isolated world"
            text.should contain "Runtime.callFunctionOn"

            # The world's name is generated per browser, so a message carrying
            # it is a message that reads differently every run and can never be
            # searched for twice.
            text.should_not contain "__crystalwright_utility_"
          end
        end
      end
    end

    describe "force" do
      it "skips the checks when told to, and clicks nothing useful" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/covered.html"))

            # An escape hatch, and the spec says what it costs: the click is
            # dispatched at the right coordinates and the overlay receives it,
            # exactly as it would for a person clicking there.
            page.click("#target", force: true, timeout: 5.seconds)
            page.text_content("#result").should eq "not clicked"
          end
        end
      end
    end

    describe "filling a field" do
      it "replaces the value and tells the page about it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/forms.html"))

            page.fill("#text", "typed in")
            page.query_selector("#text").try(&.value).should eq "typed in"

            page.fill("#area", "a longer piece of text")
            page.query_selector("#area").try(&.value).should eq "a longer piece of text"

            page.fill("#editable", "edited")
            page.text_content("#editable").should eq "edited"

            # Setting `.value` would leave this empty, and a page built on any
            # framework would never learn the field had changed.
            log = page.text_content("#log").to_s
            log.should contain "text"
            log.should contain "area"
            log.should contain "editable"
          end
        end
      end

      it "refuses a field nobody could type into" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/forms.html"))

            expect_raises(Crystalwright::TimeoutError, /editable/) do
              page.fill("#readonly", "nope", timeout: DOOMED_ACTION)
            end
            expect_raises(Crystalwright::TimeoutError, /enabled/) do
              page.fill("#disabled", "nope", timeout: DOOMED_ACTION)
            end
            page.query_selector("#readonly").try(&.value).should eq "fixed"
          end
        end
      end

      it "knows the legend of a disabled fieldset is still usable" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/forms.html"))

            # A disabled <fieldset> disables what it contains, except the
            # contents of its own first <legend>. That exception is in the HTML
            # specification and is not the kind of thing anybody guesses.
            expect_raises(Crystalwright::TimeoutError, /enabled/) do
              page.fill("#in-fieldset", "nope", timeout: DOOMED_ACTION)
            end
            page.fill("#in-legend", "allowed", timeout: 5.seconds)
            page.query_selector("#in-legend").try(&.value).should eq "allowed"
          end
        end
      end
    end

    describe "hover and press" do
      it "moves the pointer over an element" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/hoverable.html"))

            # The page reacting is the proof the pointer arrived, rather than
            # coordinates having been dispatched into nothing.
            page.hover("#target", timeout: 5.seconds)
            page.text_content("#result").should eq "hovered"
          end
        end
      end

      it "does not wait for a disabled element before hovering it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/late-enable.html"))

            # Hovering a disabled control is ordinary: it is usually what shows
            # the tooltip explaining why it is disabled. So hover asks for
            # visible and stable, and click also asks for enabled.
            started = Time.instant
            page.hover("#target", timeout: 5.seconds)
            (Time.instant - started).should be < 300.milliseconds
          end
        end
      end

      it "presses a named key into the focused element" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/forms.html"))

            page.fill("#text", "abc")
            page.press("#text", "Backspace")
            page.query_selector("#text").try(&.value).should eq "ab"

            page.press("#text", "End")
            page.keyboard.type("cd")
            page.query_selector("#text").try(&.value).should eq "abcd"
          end
        end
      end

      it "says so when asked for a key it does not know" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/forms.html"))
            expect_raises(Crystalwright::Error, /not a key/) do
              page.press("#text", "SuperMegaKey")
            end
          end
        end
      end
    end
  end
end
