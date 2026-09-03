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
