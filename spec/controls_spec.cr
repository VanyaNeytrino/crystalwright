require "./spec_helper"

describe "controls", tags: "integration" do
  describe "select_option" do
    it "names an option by value, by label or by position" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          page.select_option("#one", "b").should eq ["b"]
          page.select_option("#one", label: "Alpha").should eq ["a"]
          page.select_option("#one", index: 1).should eq ["b"]

          # The three are tried in that order because a value and a label can
          # be the same string, and the value is the one the form submits.
          page.evaluate(String, "() => document.getElementById('one').value").should eq "b"
        end
      end
    end

    it "fires the events a page listens for" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          page.select_option("#one", "b")

          # Setting `selected` from script fires nothing at all, so a page that
          # only listens for `change` would never learn anything happened.
          # Both, in order, because a form library may want either.
          page.text_content("#log").should eq "input change:b"
        end
      end
    end

    it "takes several only where several are allowed" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          page.select_option("#many", values: ["x", "y"]).should eq ["x", "y"]

          expect_raises(Crystalwright::Error, /more than one/) do
            page.select_option("#one", values: ["a", "b"], timeout: DOOMED_ACTION)
          end
        end
      end
    end

    it "waits for an option that is not there rather than choosing something else" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          # A missing option is "not yet" and not "never": a script may still
          # add it. What must never happen is a different option being chosen.
          expect_raises(Crystalwright::TimeoutError, /not there/) do
            page.select_option("#one", "nope", timeout: DOOMED_ACTION)
          end
          page.evaluate(String, "() => document.getElementById('one').value").should eq "a"
        end
      end
    end

    it "refuses a disabled option and a disabled select" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          expect_raises(Crystalwright::TimeoutError) do
            page.select_option("#one", "c", timeout: DOOMED_ACTION)
          end
          expect_raises(Crystalwright::TimeoutError, /enabled/) do
            page.select_option("#off", "z", timeout: DOOMED_ACTION)
          end
        end
      end
    end

    it "says so when it is not a select at all" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          expect_raises(Crystalwright::Error, /<select>/) do
            page.select_option("#notabox", "a", timeout: DOOMED_ACTION)
          end
        end
      end
    end
  end

  describe "check and uncheck" do
    it "leaves a box that is already right alone" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          # Idempotent on purpose. A click toggles, and a toggle is only what
          # was wanted by somebody who already knew the state — which is the
          # thing this exists to save them from knowing.
          page.check("#ticked")
          page.evaluate(Bool, "() => document.getElementById('ticked').checked").should be_true

          # Not clicked at all, which is the difference between "left alone" and
          # "clicked until it agreed". The retry loop re-reads the state after
          # every click, so a `check` that always clicks still converges on the
          # right answer and looks identical from the outside — measured, the
          # mutation that removes the early return turns nothing else red.
          page.text_content("#clicks").should eq "0"

          page.check("#box")
          page.check("#box")
          page.evaluate(Bool, "() => document.getElementById('box').checked").should be_true

          page.uncheck("#box")
          page.uncheck("#box")
          page.evaluate(Bool, "() => document.getElementById('box').checked").should be_false
        end
      end
    end

    it "works on anything with a role that can be checked" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          page.check("#aria")
          page.evaluate(String, "() => document.getElementById('aria').getAttribute('aria-checked')")
            .should eq "true"
          page.uncheck("#aria")
          page.evaluate(String, "() => document.getElementById('aria').getAttribute('aria-checked')")
            .should eq "false"
        end
      end
    end

    it "refuses something that cannot be ticked" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          # Rather than clicking a paragraph forever and reporting a timeout.
          expect_raises(Crystalwright::EvaluationError, /checkbox/) do
            page.check("#notabox", timeout: DOOMED_ACTION)
          end
        end
      end
    end
  end

  describe "dblclick" do
    it "produces the sequence a browser produces" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          page.dblclick("#dbl")

          # Two clicks and then a double, which is what the browser synthesises
          # after a press of count one followed by one of count two. Sending
          # only the second gives two mouse events and no `dblclick` at all —
          # a page whose editor never opens.
          page.text_content("#log").should eq "click click dbl"
        end
      end
    end
  end

  describe "navigation the page did not ask for" do
    it "loads the address again" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/counting.html"))
          page.text_content("#visits").should eq "visit 1"

          page.reload
          page.text_content("#visits").should eq "visit 2"
        end
      end
    end

    it "goes back and forward through history" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/plain.html"))
          page.goto(server.url("/controls.html"))
          page.title.should eq "controls"

          page.go_back.should be_true
          page.url.should end_with "/plain.html"

          page.go_forward.should be_true
          page.title.should eq "controls"
        end
      end
    end

    it "answers rather than raising when there is nowhere to go" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/plain.html"))

          # A tab starts at `about:blank`, and that is a history entry, so one
          # step back is real. Two is not.
          page.go_back.should be_true
          page.go_back.should be_false
          page.go_forward.should be_true
        end
      end
    end
  end

  describe "reading the document" do
    it "reports the title and the html, doctype included" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/controls.html"))

          page.title.should eq "controls"

          html = page.content
          # `outerHTML` on the root leaves the doctype out, and a page without
          # one renders differently from a page where it merely went missing on
          # the way here.
          html.should start_with "<!DOCTYPE html>"
          html.should contain %(id="one")
        end
      end
    end
  end
end
