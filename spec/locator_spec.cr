require "./spec_helper"

# Level 3: locators against a real page.
#
# The criterion fixture for this milestone is `strict`, and what it is really
# about is a failure that is worse than a crash: a selector that matches three
# things, silently picks the first, and passes for months while testing the
# wrong control.
describe Crystalwright::Locator, tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    describe "strict mode" do
      it "refuses to choose between two matches, and shows both" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            error = expect_raises(Crystalwright::StrictModeError) do
              page.locator("button.remove").click(timeout: 2.seconds)
            end

            message = error.message.to_s
            message.should contain "resolved to 3 elements"
            # A preview of each, so the reader can see they are genuinely
            # different elements rather than counting on trust.
            message.should contain "1) <button"
            message.should contain "2) <button"
            message.should contain "Delete"
            # And what to do about it, because "be more specific" is not advice.
            message.should contain ".nth()"
          end
        end
      end

      it "is not a timeout, and does not spend one" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            # Ambiguity will be just as true in thirty seconds, so retrying it
            # is only a way of taking longer to say the same thing.
            started = Time.instant
            expect_raises(Crystalwright::StrictModeError) do
              page.locator("button.remove").click(timeout: 10.seconds)
            end
            (Time.instant - started).should be < 3.seconds
          end
        end
      end

      it "lets nth, first and last say which one" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            page.locator(".row").first.locator(".name").text_content.should eq "Ada"
            page.locator(".row").nth(1).locator(".name").text_content.should eq "Grace"
            page.locator(".row").last.locator(".name").text_content.should eq "Barbara"
            page.locator(".row").nth(-2).locator(".name").text_content.should eq "Grace"
          end
        end
      end

      it "counts without being strict about it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            # Counting is how a caller finds out there is more than one, so it
            # is the one question strictness must not refuse.
            page.locator(".row").count.should eq 3
            page.locator("button.remove").count.should eq 3
            page.locator(".no-such-thing").count.should eq 0
          end
        end
      end
    end

    describe "filtering" do
      it "narrows a set instead of searching inside it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            # The distinction that makes `filter` worth having: chaining names
            # the button inside the row, filtering names the row itself.
            page.locator(".row").filter(has_text: "Grace").locator(".name")
              .text_content.should eq "Grace"

            page.locator(".row").filter(has_text: "Ada").locator("button.remove").click
            page.text_content("#result").should eq "removed Ada"
          end
        end
      end

      it "narrows by something inside" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            rows = page.locator(".row").filter(has: page.locator("button.remove[disabled]"))
            rows.count.should eq 1
            rows.locator(".name").text_content.should eq "Barbara"
          end
        end
      end

      it "narrows by whether it can be seen" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            # Asymmetric on purpose. Two visible and one hidden, because with
            # one of each an inverted filter swaps a 1 for a 1 and the spec
            # cannot tell — which is what an earlier version of this did.
            page.locator("#forms input").count.should eq 3
            page.locator("#forms input").filter(visible: true).count.should eq 2
            page.locator("#forms input").filter(visible: false).count.should eq 1
          end
        end
      end
    end

    describe "naming things the way a person would" do
      it "finds by text, label, placeholder, alt, title and test id" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            page.get_by_label("Your name").get_attribute("id").should eq "who"
            page.get_by_placeholder("Type it here").get_attribute("id").should eq "who"
            page.get_by_title("the name field").get_attribute("id").should eq "who"
            page.get_by_alt_text("A photograph").get_attribute("id").should eq "picture"

            # An aria-label, for a control with no visible label of its own.
            page.get_by_label("Secret").get_attribute("id").should eq "hidden-one"

            page.get_by_text("Grace").text_content.should eq "Grace"
          end
        end
      end

      it "is case-insensitive unless told otherwise" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            page.get_by_text("grace").count.should eq 1
            page.get_by_text("grace", exact: true).count.should eq 0
            page.get_by_text("Grace", exact: true).count.should eq 1
          end
        end
      end

      it "survives text that would otherwise be read as syntax" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/selectors.html"))

            # `>>` inside the text of the link. Unquoted this would be two
            # steps; the builder quotes everything for exactly this.
            page.get_by_text("Go >> there").count.should eq 1
          end
        end
      end
    end

    describe "being a question rather than an answer" do
      it "resolves again at every use, so a re-render does not matter" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/delayed-content.html"))

            # Built before the element exists. A handle could not be.
            late = page.locator("#arrives-late")
            late.count.should eq 0

            Crystalwright.expect(late).to_be_visible(5.seconds)
            late.text_content.should eq "here at last"
          end
        end
      end
    end

    describe "expect" do
      it "waits for what has not happened yet" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/delayed-content.html"))

            Crystalwright.expect(page.locator("#arrives-late")).to_have_text("here at last", 5.seconds)
            Crystalwright.expect(page.locator("#goes-away")).to_be_hidden(5.seconds)
          end
        end
      end

      it "checks text, value, attributes, count and state" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            Crystalwright.expect(page.locator("#result")).to_have_text("nothing yet")
            Crystalwright.expect(page.locator("#result")).to_contain_text("nothing")
            Crystalwright.expect(page.locator("#result")).to_have_text(/^nothing/)
            Crystalwright.expect(page.locator(".row")).to_have_count(3)
            Crystalwright.expect(page.get_by_label("Your name")).to_have_attribute("id", "who")
            Crystalwright.expect(page.locator(".row").last.locator("button")).to_be_disabled
            Crystalwright.expect(page.locator(".row").first.locator("button")).to_be_enabled
            Crystalwright.expect(page.get_by_label("Your name")).to_be_editable

            page.get_by_label("Your name").fill("typed")
            Crystalwright.expect(page.get_by_label("Your name")).to_have_value("typed")
          end
        end
      end

      it "negates" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            Crystalwright.expect(page.locator("#hidden-one")).not.to_be_visible
            Crystalwright.expect(page.locator("#result")).not.to_have_text("something else")
            Crystalwright.expect(page.locator(".row")).not.to_have_count(2)
          end
        end
      end

      it "says what was actually there when it gives up" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            error = expect_raises(Crystalwright::AssertionError) do
              Crystalwright.expect(page.locator("#result")).to_have_text("removed Ada", 1.second)
            end

            # "expected: removed Ada" on its own tells the reader what they
            # already typed. The value that was really there is the half worth
            # printing.
            message = error.message.to_s
            message.should contain "to_have_text"
            message.should contain "expected"
            message.should contain "removed Ada"
            message.should contain "actual"
            message.should contain "nothing yet"
          end
        end
      end

      it "reports ambiguity as ambiguity rather than as a failed wait" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/strict.html"))

            expect_raises(Crystalwright::StrictModeError, /resolved to 3/) do
              Crystalwright.expect(page.locator("button.remove")).to_be_visible(5.seconds)
            end
          end
        end
      end
    end
  end
end
