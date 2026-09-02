require "./spec_helper"

# Level 3: the selector engine, against a real page.
#
# The three fixtures the milestone is judged on are here — `shadow-dom`,
# `csp-strict` and `hostile` — and two of them turned out to be satisfied by a
# decision made two milestones ago rather than by anything written for them.
# That is worth a spec precisely because it is invisible: nothing in the code
# says "this is why the page cannot break us", and the day somebody moves this
# work into the main world to save a round trip, these go red.
describe "selectors", tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    describe "the engines" do
      it "finds by css, and by nothing at all, which means css" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            page.text_content("#cancel").should eq "Cancel"
            page.text_content("css=#cancel").should eq "Cancel"
            page.query_selector_all("p.para").size.should eq 4
            page.query_selector(".no-such-thing").should be_nil
          end
        end
      end

      it "finds by text, and takes the smallest element that has it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            # Unquoted is a case-insensitive substring with whitespace
            # collapsed, so this is the ordinary way to name a button.
            found = page.query_selector("text=save changes")
            found.should_not be_nil
            found.try(&.get_attribute("data-testid")).should eq "save"

            # Quoted is exact and case sensitive.
            page.query_selector(%(text="Save changes")).should_not be_nil
            page.query_selector(%(text="save changes")).should be_nil

            # A regular expression, anchored, to prove it is compiled rather
            # than compared.
            page.query_selector("text=/^Cancel$/").should_not be_nil
            page.query_selector("text=/^ancel$/").should be_nil

            # The smallest element containing the text, not every ancestor of
            # it: without that rule `text=Total` also matches #root and <body>.
            total = page.query_selector("text=Total")
            total.try(&.get_attribute("class")).should eq "label"
          end
        end
      end

      it "reads the value of a submit button as its text" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))
            element = page.query_selector("text=Submit form")
            element.try(&.get_attribute("type")).should eq "submit"
          end
        end
      end

      it "finds by xpath, spelled out or implied by the leading slashes" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            page.query_selector("xpath=//button[@id='cancel']").should_not be_nil
            page.query_selector("//button[@id='cancel']").should_not be_nil
            page.query_selector_all("//p[@class='para']").size.should eq 4
          end
        end
      end

      it "finds by id and by test id" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            page.text_content("id=cancel").should eq "Cancel"
            page.query_selector_all("data-testid=save").size.should eq 2
          end
        end
      end

      it "chains with >> and searches inside what came before" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            # The same test id exists twice; the step before it decides which.
            page.text_content("#other >> data-testid=save").should eq "Save in the other place"
            page.text_content("#root >> data-testid=save").should eq "Save changes"
            page.text_content(".card >> .value").should eq "42"

            # An intermediate step that matches several elements has to try all
            # of them, and the branch that works has to be reachable when it is
            # not the first: #other is the second div on the page, so a chain
            # that only followed the first hit of `div` would never see it.
            page.text_content("div >> text=Save in the other place").should eq "Save in the other place"
          end
        end
      end

      it "leaves >> alone inside quoted text" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            # A splitter that did not understand quotes would read this as two
            # steps and find nothing.
            page.query_selector(%(text="Go >> there")).should_not be_nil
          end
        end
      end

      it "says which selector was wrong rather than reporting a JavaScript error" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            expect_raises(Crystalwright::EvaluationError, /valid CSS selector/) do
              page.query_selector("div[[[")
            end
            expect_raises(Crystalwright::EvaluationError, /valid XPath/) do
              page.query_selector("xpath=//[[[")
            end
          end
        end
      end
    end

    describe "shadow DOM" do
      it "looks inside open roots, however deep" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/shadow-dom.html"))

            # One selector, three roots: the light DOM, a shadow root, and a
            # shadow root inside that one.
            page.query_selector_all("button.target").size.should eq 3
            page.text_content("#in-open").should eq "open button"
            page.text_content("#in-deep").should eq "deep button"
          end
        end
      end

      it "stays in the light DOM when asked to" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/shadow-dom.html"))

            page.query_selector_all("css:light=button.target").size.should eq 1
            page.query_selector("css:light=#in-open").should be_nil
          end
        end
      end

      it "cannot see into a closed root, and neither can the page" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/shadow-dom.html"))

            # Measured: a closed root is unreachable from an isolated world even
            # through the reference the page kept for itself, because that
            # `window` is a different global. This is a limit of the platform
            # rather than of the engine, and it is asserted so that a future
            # attempt to work around it is a decision.
            page.query_selector("#in-closed").should be_nil
            page.evaluate("() => !!window.__closed").as_bool.should be_true
            page.evaluate_in_utility("() => !!window.__closed").as_bool.should be_false
          end
        end
      end
    end

    describe "a page that fights back" do
      it "is not affected by anything the page redefines" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/hostile.html"))

            # The page really did break its own world.
            expect_raises(Crystalwright::EvaluationError, /map is mine/) do
              page.evaluate("() => [1, 2].map((x) => x)")
            end
            page.evaluate("() => document.getElementById('target')").null?.should be_true

            # And none of it reaches the engine, which runs in a world with its
            # own copies of every built-in. Not defensive coding: measured, all
            # sixteen overrides in that fixture are invisible from here.
            page.text_content("#target").should eq "the real text"
            page.query_selector("text=Press me").should_not be_nil
            page.query_selector_all("div").size.should be > 0
            page.query_selector("//div[@id='target']").should_not be_nil

            element = page.query_selector("#target")
            element.should_not be_nil
            if element
              element.get_attribute("class").should eq "mine"
              element.visible?.should be_true
            end
          end
        end
      end
    end

    describe "a page with a strict Content-Security-Policy" do
      it "works under a policy that forbids every script" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict-csp/selectors.html"))

            # `default-src 'none'; script-src 'none'`. Nothing here goes through
            # the page's script loader: the utility script and the caller's
            # source are both compiled by `Runtime.callFunctionOn`, which is
            # why there is no `eval` anywhere in this shard.
            page.text_content("#cancel").should eq "Cancel"
            page.query_selector("text=Save changes").should_not be_nil
            page.evaluate(String, "() => document.title").should eq "selectors"
            page.evaluate_in_utility(String, "() => document.title").should eq "selectors"
          end
        end
      end
    end

    describe "waiting for an element" do
      it "waits for one that is not there yet" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/delayed-content.html"))

            # Asking now is a fact about now, and the answer is no.
            page.query_selector("#arrives-late").should be_nil

            element = page.wait_for_selector("#arrives-late", timeout: 5.seconds)
            element.should_not be_nil
            element.try(&.text_content).should eq "here at last"
          end
        end
      end

      it "waits for one to go away" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/delayed-content.html"))

            page.query_selector("#goes-away").should_not be_nil
            page.wait_for_selector("#goes-away", Crystalwright::ElementState::Hidden, 5.seconds).should be_nil

            # Hidden is not detached: it is still in the document.
            page.query_selector("#goes-away").should_not be_nil
          end
        end
      end

      it "tells visible from merely attached" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            # `visibility: hidden` and `hidden` are both in the document and
            # neither can be seen, so waiting for either to be visible has to
            # fail rather than succeed on the first poll.
            page.wait_for_selector("text=Invisible paragraph",
              Crystalwright::ElementState::Attached, 2.seconds).should_not be_nil

            error = expect_raises(Crystalwright::TimeoutError) do
              page.wait_for_selector("text=Invisible paragraph",
                Crystalwright::ElementState::Visible, 1.second)
            end
            error.message.to_s.should contain "visible"

            # `visibility: hidden` and `display: none` are invisible for
            # different reasons — the first keeps its box and the second has
            # none — so one check does not cover both, and a spec that only
            # tried one would let half of this rot.
            page.wait_for_selector("text=Display-none paragraph",
              Crystalwright::ElementState::Attached, 2.seconds).should_not be_nil
            expect_raises(Crystalwright::TimeoutError) do
              page.wait_for_selector("text=Display-none paragraph",
                Crystalwright::ElementState::Visible, 1.second)
            end
          end
        end
      end

      it "says what it was waiting for when nothing ever matches" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            error = expect_raises(Crystalwright::TimeoutError) do
              page.wait_for_selector("#never-appears", timeout: 1.second)
            end
            error.message.to_s.should contain "#never-appears"
          end
        end
      end
    end
  end
end
