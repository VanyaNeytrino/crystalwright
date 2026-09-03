require "./spec_helper"

# Level 6: what only shows up after a while.
#
# Everything else in this suite asks whether a thing works. These ask whether it
# keeps working, which is a different question and the one nothing here had ever
# put to the library: a test suite driving a browser runs for hours, and a
# structure that grows by one entry per page is invisible for the length of an
# example and fatal for the length of a day.
#
# Off by default, because they are minutes rather than seconds:
#
#     CRYSTALWRIGHT_SOAK=1 crystal spec spec/soak_spec.cr
#
# `pending` rather than a tag so that the ordinary commands keep working and the
# report says out loud that these did not run.
private def soak(name, &block)
  if ENV["CRYSTALWRIGHT_SOAK"]?
    it(name, &block)
  else
    pending("#{name} (set CRYSTALWRIGHT_SOAK to run it)") { }
  end
end

# A page whose document abandons one request, and a page that does not.
private LEAKY = %(<!doctype html><title>leaky</title><script>fetch("/hang")</script><p>leaky)
private QUIET = %(<!doctype html><title>quiet</title><p>quiet)

describe "soak", tags: "soak" do
  soak "survives five hundred navigations in one page" do
    with_fixtures({"/a" => QUIET, "/b" => QUIET}) do |server|
      with_page do |page|
        500.times { |i| page.goto(server.url(i.even? ? "/a" : "/b")) }

        # The frame tree is a tree of one and has to stay one. Every navigation
        # discards the previous document's children, and a discard that misses
        # leaves a frame per navigation.
        page.frames.size.should eq 1
        page.text_content("p").should eq "quiet"

        # Bookkeeping that outlives the document it was made for is the shape of
        # every leak found here so far. A handful of requests may be genuinely
        # in the air; five hundred cannot be.
        page.frames_manager.tracked_requests.should be < 10

        world = page.utility_world(Crystalwright::Progress.new("soak", 5.seconds))
        world.live_handles.should eq 0
      end
    end
  end

  soak "does not grow when every document abandons a request" do
    with_fixtures({"/leaky" => LEAKY, "/quiet" => QUIET}) do |server|
      with_page do |page|
        manager = page.frames_manager

        200.times do
          page.goto(server.url("/leaky"))
          page.goto(server.url("/quiet"))
        end

        # Chrome never mentions an abandoned request again — not as finished,
        # not as failed — so anything keyed by request id and cleaned up on
        # completion grows by one per document, for ever. Two structures did.
        manager.tracked_requests.should be < 10
        page.frames.size.should eq 1

        # And the frame can still go quiet, which is the user-visible half: one
        # leftover request makes `networkidle` unreachable for the rest of the
        # page's life.
        page.goto(server.url("/quiet"), Crystalwright::LoadState::NetworkIdle, 10.seconds)
      end
    end
  end

  soak "gives every handle back" do
    with_fixtures({"/a" => QUIET}) do |server|
      with_page do |page|
        page.goto(server.url("/a"))
        world = page.utility_world(Crystalwright::Progress.new("soak", 5.seconds))
        world.live_handles.should eq 0

        500.times do
          handle = page.evaluate_handle("() => document.body")
          handle.dispose
        end

        # "Handles are released" is otherwise an intention. Each one pins a
        # value in the browser until it is let go, so a leak here is a page that
        # grows a little on every action.
        world.live_handles.should eq 0
      end
    end
  end

  soak "forgets a document's handles when the document goes" do
    with_fixtures({"/a" => QUIET, "/b" => QUIET}) do |server|
      with_page do |page|
        page.goto(server.url("/a"))
        200.times { page.evaluate_handle("() => document.body") }

        # Not disposed. The navigation is what has to collect them: the world
        # they live in is gone, and a handle into a retired context can never be
        # released by anyone.
        page.goto(server.url("/b"))

        world = page.utility_world(Crystalwright::Progress.new("soak", 5.seconds))
        world.live_handles.should eq 0
        page.text_content("p").should eq "quiet"
      end
    end
  end

  soak "opens and closes fifty pages without piling them up" do
    with_fixtures({"/a" => QUIET}) do |server|
      Crystalwright.launch do |browser|
        50.times do
          browser.new_page do |page|
            page.goto(server.url("/a"))
            page.text_content("p").should eq "quiet"
          end
        end

        # Each `new_page` block closes its tab. A target that is not really
        # closed stays in the browser's list, and the fifty-first page in a long
        # session is then competing with fifty ghosts for the same renderer
        # budget.
        browser.pages.size.should be <= 1
      end
    end
  end
end
