require "./spec_helper"

# Level 3: the frame tree, with frames actually in it.
#
# A `FrameManager` exercised only against a page with one frame is a tree of one
# node: nothing about parents, children, detaching or per-frame worlds is
# covered, and the code that handles them is written on faith. These are also
# where `Runtime.executionContextDestroyed` finally gets a spec — M3 shipped the
# handler unproven, having measured that the event only fires when a frame goes
# away, and frames are this milestone.
describe "frames", tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    describe "the tree" do
      it "builds itself from events, with parents and children joined up" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/iframe-same-origin.html"))
            child = frame_named(page, "kid")

            page.frames.size.should eq 2
            child.parent.should be(page.main_frame)
            page.main_frame.parent.should be_nil
            page.main_frame.child_frames.map(&.id).should eq [child.id]
            child.url.should end_with "/frame-inner.html"
            child.detached?.should be_false
          end
        end
      end

      it "goes three deep" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/nested-iframes.html"))
            two = frame_named(page, "two")
            three = frame_named(page, "three")

            page.frames.size.should eq 3
            two.parent.should be(page.main_frame)
            three.parent.should be(two)

            page.evaluate(String, "() => document.title").should eq "level one"
            two.evaluate(String, "() => document.title").should eq "level two"
            three.evaluate(String, "() => document.title").should eq "level three"
          end
        end
      end
    end

    describe "evaluating in a frame" do
      it "runs in that frame's document and no other" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/iframe-same-origin.html"))
            child = frame_named(page, "kid")

            child.evaluate(String, "() => window.__whoami").should eq "inner"
            page.evaluate("() => window.__whoami").undefined?.should be_true

            child.evaluate(String, "() => document.title").should eq "inner"
            page.evaluate(String, "() => document.title").should eq "outer"
          end
        end
      end

      it "gives every frame an isolated world without being asked for one" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/iframe-same-origin.html"))
            child = frame_named(page, "kid")

            # Measured: registering the empty
            # `addScriptToEvaluateOnNewDocument` against a world name is enough
            # for every later document in every frame to get that world.
            # `createIsolatedWorld` is only ever sent for frames that already
            # existed when the script was registered.
            child.evaluate_in_utility("() => { globalThis.__hidden = 1; return 1; }").as_f.should eq 1.0
            child.evaluate("() => globalThis.__hidden").undefined?.should be_true
            child.evaluate_in_utility(String, "() => document.title").should eq "inner"
          end
        end
      end
    end

    describe "a frame going away" do
      it "retires the contexts of a frame that is removed" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/iframe-same-origin.html"))
            child = frame_named(page, "kid")

            context = child.main_world(Crystalwright::Progress.new("spec", 5.seconds))
            context.destroyed?.should be_false

            page.evaluate("() => document.getElementById('kid').remove()")

            # This is the path `Runtime.executionContextDestroyed` exists for.
            # Measured: a navigation never sends it — that is
            # `executionContextsCleared` — and it only ever arrives per context
            # when a frame disappears.
            eventually(5.seconds, "the frame's context was never retired") { context.destroyed? }
            eventually(5.seconds, "the frame was never detached") { child.detached? }
            page.frames.size.should eq 1

            # Not a timeout. A detached frame will never get another document,
            # so waiting out the deadline would be waiting for something that
            # cannot happen, and reporting it as "not yet" would be a lie.
            expect_raises(Crystalwright::FrameDetachedError, /detached/) do
              child.evaluate("() => 1", timeout: 1.second)
            end
          end
        end
      end

      it "takes the whole subtree with it" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/nested-iframes.html"))
            two = frame_named(page, "two")
            three = frame_named(page, "three")

            page.evaluate("() => document.querySelector('iframe').remove()")

            eventually(5.seconds, "the middle frame stayed attached") { two.detached? }
            eventually(5.seconds, "the deepest frame stayed attached") { three.detached? }
            page.frames.size.should eq 1
          end
        end
      end
    end

    describe "a frame in another process" do
      it "is absent rather than present and unusable" do
        pages = {
          "/outer" => "<html><head><title>outer</title></head><body>" \
                      "<iframe name='kid' src='http://localhost:PORT/frame-inner.html'></iframe>" \
                      "</body></html>",
        }
        server = FixtureServer.new(pages)
        begin
          pages["/outer"] = pages["/outer"].gsub("PORT", server.port.to_s)

          with_page do |page|
            page.goto(server.url("/outer"))

            # `localhost` and `127.0.0.1` are different sites to Chrome, so the
            # iframe's document goes into its own process — and measured, the
            # parent's session is then not told about the frame at all.
            # `Page.getFrameTree` reports no children either. Driving it needs a
            # session of its own, which is deliberately not implemented yet.
            #
            # Absent is the right failure: a caller gets `nil` from `frame` and
            # can say so, where a frame that was present but permanently
            # unusable would hang every call made through it.
            page.frames.size.should eq 1
            page.frame("kid").should be_nil

            # It really did load, in a target of its own, rather than failing to
            # load and only looking like isolation.
            targets = page.session.connection.root.execute(
              CDP::Protocol::Target::GetTargetsRequest.new, 5.seconds)
            targets.target_infos.map(&.url).should contain(
              "http://localhost:#{server.port}/frame-inner.html")
          end
        ensure
          server.close
        end
      end
    end

    describe "navigating away" do
      it "forgets the frames of the document it left" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/iframe-same-origin.html"))
            frame_named(page, "kid")
            page.frames.size.should eq 2

            page.goto(server.url("/plain.html"))

            # Chrome says nothing about the frames of the document it just
            # threw away — no `frameDetached`, measured — so this is ours to
            # notice. A tree that did not would report a frame that is not
            # there, hand it to a caller, and hang on the first call made
            # through it.
            page.frames.size.should eq 1
            page.frame("kid").should be_nil
          end
        end
      end
    end

    describe "a child navigating" do
      it "leaves the main frame's contexts alone" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/iframe-same-origin.html"))
            child = frame_named(page, "kid")

            main = page.main_world(Crystalwright::Progress.new("spec", 5.seconds))
            page.evaluate("() => { globalThis.__survivor = 'still here'; return 1; }")

            was = child.loader_id
            page.evaluate("() => { document.getElementById('kid').src = '/plain.html'; }")
            eventually(5.seconds, "the child never navigated") { child.loader_id != was }

            # Measured, and the reason contexts are retired by the commit
            # rather than by `executionContextsCleared`: a child navigating
            # sends `executionContextDestroyed` per context and never the
            # frameless cleared event, so the page's own world is untouched.
            main.destroyed?.should be_false
            page.evaluate(String, "() => globalThis.__survivor").should eq "still here"
            child.evaluate(String, "() => document.title").should eq "plain"
          end
        end
      end
    end
  end
end
