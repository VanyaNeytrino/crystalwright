require "./spec_helper"

# Level 3: answering the page's requests instead of letting them out.
describe "route", tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    it "answers with a response of its own" do
      with_fixtures do |server|
        with_page do |page|
          page.route("**/api/**") do |route|
            route.fulfill(status: 200, body: %({"items": ["made up"]}), content_type: "application/json")
          end

          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#items")).to_have_text("made up")

          # The request never left the machine, which is the point: a test that
          # depends on somebody else's server is a test that fails when their
          # afternoon goes badly.
          server.request_count("/api/items").should eq 0
        end
      end
    end

    it "lets everything else through untouched" do
      with_fixtures do |server|
        with_page do |page|
          page.route("**/never-matches/**", &.abort)

          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#items")).to_have_text("from the server")
          server.request_count("/api/items").should eq 1
        end
      end
    end

    it "refuses a request the way a blocked one is refused" do
      with_fixtures do |server|
        with_page do |page|
          page.route("**/api/**", &.abort)

          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#failure")).to_have_text("fetch failed")
        end
      end
    end

    it "lets a handler change a request on its way out" do
      with_fixtures do |server|
        with_page do |page|
          page.route("**/api/items") do |route|
            route.continue(url: server.url("/api/items?rewritten=1"))
          end

          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#items")).to_have_text("from the server")
          server.requests.any?(&.includes?("rewritten=1")).should be_true
        end
      end
    end

    it "gives the most recently added handler the request" do
      with_fixtures do |server|
        with_page do |page|
          page.route("**/api/**") { |route| route.fulfill(body: %({"items": ["the general one"]})) }
          page.route("**/api/items") { |route| route.fulfill(body: %({"items": ["the specific one"]})) }

          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")

          # Last one wins, so a narrow route added later overrides a broad one
          # added earlier — which is the order people write them in.
          Crystalwright.expect(page.locator("#items")).to_have_text("the specific one")
        end
      end
    end

    it "stops when the route is removed" do
      with_fixtures do |server|
        with_page do |page|
          page.route("**/api/**") { |route| route.fulfill(body: %({"items": ["made up"]})) }
          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#items")).to_have_text("made up")

          page.unroute("**/api/**")
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#items")).to_have_text("from the server")
        end
      end
    end

    it "sees what was asked for" do
      with_fixtures do |server|
        with_page do |page|
          seen = [] of String
          page.route("**/*") do |route|
            seen << "#{route.method} #{route.resource_type}"
            route.continue
          end

          page.goto(server.url("/routed.html"))
          eventually(5.seconds, "the document was never routed") do
            seen.any?(&.includes?("Document"))
          end
          seen.first.should eq "GET Document"
        end
      end
    end

    it "answers a request whose handler forgot to" do
      with_fixtures do |server|
        with_page do |page|
          # A handler that returns without answering leaves the browser holding
          # the request open, and the page waits for its own timeout — which
          # looks exactly like a slow server and is not one.
          page.route("**/api/**") { |_| }

          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#items")).to_have_text("from the server", 5.seconds)
        end
      end
    end

    it "refuses to answer twice" do
      with_fixtures do |server|
        with_page do |page|
          complaints = [] of String
          page.route("**/api/**") do |route|
            route.fulfill(body: %({"items": ["once"]}))
            begin
              route.abort
            rescue error : Crystalwright::Error
              complaints << error.message.to_s
            end
          end

          page.goto(server.url("/routed.html"))
          page.evaluate("() => window.__load()")
          Crystalwright.expect(page.locator("#items")).to_have_text("once")
          complaints.first.should contain "already been answered"
        end
      end
    end
  end
end
