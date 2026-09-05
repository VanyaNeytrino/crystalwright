require "./spec_helper"

describe "browser", tags: "integration" do
  describe "the list of tabs" do
    it "holds the ones that are open, not the ones that were" do
      with_fixtures({"/a" => %(<!doctype html><title>a</title><p>a)}) do |server|
        Crystalwright.launch do |browser|
          browser.pages.size.should eq 0

          3.times do
            browser.new_page do |page|
              page.goto(server.url("/a"))
              browser.pages.size.should eq 1
            end
          end

          # A list that only grows is not a list of open tabs, and the cost is
          # not the array: every `Page` holds a protocol session, a frame tree
          # and the contexts under it, so a closed one left here pins all of
          # that until the browser goes. The soak spec opens fifty.
          browser.pages.size.should eq 0
        end
      end
    end

    it "says the renderer crashed instead of waiting out every deadline" do
      pages = {"/a" => %(<!doctype html><meta charset="utf-8"><p id="p">a)}
      with_fixtures(pages) do |server|
        # Its own browser: a crashed renderer is not something to leave lying
        # around for the next example.
        Crystalwright.launch do |browser|
          browser.new_page do |page|
            page.goto(server.url("/a"))

            # Told rather than made to happen. Two ways of crashing a tab
            # were tried first and neither is portable: on the Chromium the
            # Linux runners install, `chrome://crash` does nothing at all and
            # `Page.crash` leaves `evaluate` still answering, so CI failed
            # twice reporting a crash that never occurred.
            #
            # What this shard promises is what it does when the browser says a
            # renderer died, and that is the half worth pinning. Whether a
            # particular Chromium will die on demand is the platform's business.
            page.frames_manager.crashed!

            # A dead renderer answers nothing, so without noticing the crash
            # every call waits out its own deadline and then reports a timeout
            # — thirty seconds, measured, to say nothing useful.
            expect_raises(Crystalwright::PageCrashedError) { page.evaluate("() => 1") }
            expect_raises(Crystalwright::PageCrashedError) { page.click("#p", timeout: 5.seconds) }

            # And the tab is not lost: navigating it gets a renderer again,
            # which is why the crash is a state rather than a death sentence.
            page.goto(server.url("/a"), timeout: 10.seconds)
            page.text_content("#p").should eq "a"
          end
        end
      end
    end

    it "drops a tab that could not be closed politely" do
      with_fixtures({"/a" => %(<!doctype html><title>a</title><p>a)}) do |server|
        Crystalwright.launch do |browser|
          page = browser.new_page
          page.goto(server.url("/a"))
          browser.pages.size.should eq 1

          # Closing it twice: the second call finds the tab already gone and
          # takes the error path. A tab that could not be closed politely is
          # still not a tab, which is why the browser is told in an `ensure`
          # rather than after a successful round trip.
          page.close
          page.close
          browser.pages.size.should eq 0
        end
      end
    end
  end
end
