require "./spec_helper"

# Whether the tab's renderer has been reported dead yet.
#
# The event arrives on its own fiber a moment after the navigation is refused,
# so the spec waits for it rather than assuming the order.
private def crashed?(page) : Bool
  page.evaluate("() => 1", timeout: 1.second)
  false
rescue Crystalwright::PageCrashedError
  true
rescue Crystalwright::TimeoutError
  false
end

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

            # The protocol's own way of crashing a tab, sent through the raw
            # session this shard deliberately leaves reachable. `chrome://crash`
            # was the first attempt and it is not portable: on the Chromium the
            # Linux runners install it produced no crash at all, and the spec
            # failed for the wrong reason.
            #
            # The command never answers — the renderer it would answer from is
            # what it destroys — so the timeout is the success case.
            begin
              page.session.execute_raw("Page.crash", timeout: 2.seconds)
            rescue CDP::Error
            end

            eventually(5.seconds, "the crash was never reported") { crashed?(page) }

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
