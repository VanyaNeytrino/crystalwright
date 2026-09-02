require "./spec_helper"

# Level 3: the same values, but they actually go out to a browser and come back.
#
# This is the suite that counts. `serialization_spec.cr` runs our encoder
# against our decoder, which is a closed loop and can be consistently wrong in
# both halves; only a real page can say whether the tagged format means what
# JavaScript means.
describe Crystalwright::Page, tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    describe "values coming out of the page" do
      it "tells undefined and null apart" do
        with_page do |page|
          page.evaluate("() => undefined").undefined?.should be_true
          page.evaluate("() => undefined").null?.should be_false
          page.evaluate("() => null").null?.should be_true
          page.evaluate("() => null").undefined?.should be_false

          # The case that motivates the distinction: a property that was never
          # set against one explicitly set to null.
          both = page.evaluate("() => ({missing: undefined, empty: null})")
          both["missing"].undefined?.should be_true
          both["empty"].null?.should be_true
        end
      end

      it "brings back negative zero as negative zero" do
        with_page do |page|
          value = page.evaluate("() => -0")
          value.negative_zero?.should be_true
          (1.0 / value.as_f).should eq(-Float64::INFINITY)

          # And the page agrees this is not the same value as 0.
          page.evaluate("() => Object.is(-0, 0)").as_bool.should be_false
          page.evaluate("() => 0").negative_zero?.should be_false
        end
      end

      it "brings back NaN and the infinities" do
        with_page do |page|
          page.evaluate("() => NaN").as_f.nan?.should be_true
          page.evaluate("() => Infinity").as_f.should eq Float64::INFINITY
          page.evaluate("() => -Infinity").as_f.should eq(-Float64::INFINITY)
        end
      end

      it "brings back a BigInt without going through a double" do
        with_page do |page|
          # 2^53 + 1 is the first integer a JavaScript number cannot hold, so a
          # BigInt that arrived as a number would come back as ...92 here.
          page.evaluate("() => 9007199254740993n").as_big_int.value.should eq "9007199254740993"
        end
      end

      it "brings back Date, URL, RegExp and Error" do
        with_page do |page|
          page.evaluate("() => new Date(0)").as_time.should eq Time.utc(1970, 1, 1)
          page.evaluate("() => new URL('https://example.com/x')").as_uri.to_s.should eq "https://example.com/x"

          pattern = page.evaluate("() => /a.b/gi").as_regex
          pattern.source.should eq "a.b"
          pattern.flags.chars.sort!.should eq ['g', 'i']

          failure = page.evaluate("() => new TypeError('nope')").as_error
          failure.name.should eq "TypeError"
          failure.message.should eq "nope"
        end
      end

      it "brings back Map and Set as themselves" do
        with_page do |page|
          set = page.evaluate("() => new Set([1, 2, 2, 3])")
          set.as_set.size.should eq 3

          map = page.evaluate("() => new Map([['b', 2], ['a', 1]])").as_map
          map.entries.map { |(key, _)| key.as_s }.should eq ["b", "a"]
          map["a"].as_f.should eq 1.0

          # A Map keyed by something that is not a string, which no Hash could
          # hold and which JSON turns into {} without complaint.
          keyed = page.evaluate("() => new Map([[{id: 1}, 'first']])").as_map
          keyed.entries.first[0]["id"].as_f.should eq 1.0
          keyed.entries.first[1].as_s.should eq "first"
        end
      end

      it "brings back a typed array with its kind" do
        with_page do |page|
          array = page.evaluate("() => new Uint8Array([1, 2, 255])").as_typed_array
          array.kind.should eq "Uint8Array"
          array.values.should eq [1.0, 2.0, 255.0]
        end
      end

      it "brings back a value that contains itself" do
        with_page do |page|
          value = page.evaluate("() => { const a = {name: 'root'}; a.self = a; return a; }")

          # Not "it did not throw". JSON.stringify throws on this, so any result
          # at all already proves the tagged format is doing something — but a
          # format that truncated the cycle would also get here. The identity is
          # the assertion.
          value["self"].should be(value)
          value["self"]["self"]["name"].as_s.should eq "root"
        end
      end

      it "brings back two references to one object as one object" do
        with_page do |page|
          pair = page.evaluate("() => { const shared = {n: 1}; return [shared, shared]; }")
          pair[0].should be(pair[1])
        end
      end

      it "survives fifty levels of nesting and characters outside the basic plane" do
        with_page do |page|
          deep = page.evaluate("() => { let v = 'bottom'; for (let i = 0; i < 50; i++) v = [v]; return v; }")
          50.times { deep = deep[0] }
          deep.as_s.should eq "bottom"

          page.evaluate("() => 'é \\u{1F600} \\u{10FFFF}'").as_s.should eq "é \u{1F600} \u{10FFFF}"
        end
      end

      it "names what cannot come out instead of pretending it was undefined" do
        with_page do |page|
          page.evaluate("() => function f() {}").as_h?.should be_nil
          page.evaluate("() => ({fn: function f() {}, node: document.body})").tap do |value|
            value["fn"].kind.should eq "function"
            value["fn"].undefined?.should be_false
            value["node"].kind.should eq "node"
          end
        end
      end
    end

    describe "values going into the page" do
      it "round-trips everything the page can tell apart" do
        with_page do |page|
          page.evaluate("(v) => v === undefined", Crystalwright::Undefined.new).as_bool.should be_true
          page.evaluate("(v) => v === null", nil).as_bool.should be_true
          page.evaluate("(v) => Object.is(v, -0)", -0.0).as_bool.should be_true
          page.evaluate("(v) => Number.isNaN(v)", Float64::NAN).as_bool.should be_true
          page.evaluate("(v) => v instanceof Date && v.getTime() === 0", Time.utc(1970, 1, 1)).as_bool.should be_true
          page.evaluate("(v) => v instanceof Map && v.get('a') === 1", crystal_map).as_bool.should be_true
          page.evaluate("(v) => v instanceof Set && v.size === 3", Set{1, 2, 3}).as_bool.should be_true
          page.evaluate("(v) => v === 9007199254740993n", Crystalwright::JSBigInt.new("9007199254740993")).as_bool.should be_true
          # "ims", not "is": Crystal's `m` is the composite MULTILINE_ONLY | DOTALL,
          # so /a.b/im carries both of JavaScript's `m` and `s`. The page is the
          # authority on that, which is why it is asserted here and not only in
          # the encoder's own spec.
          page.evaluate("(v) => v.source === 'a.b' && v.flags === 'ims'", /a.b/im).as_bool.should be_true
        end
      end

      it "sends a cycle in and gets the same cycle back" do
        with_page do |page|
          properties = {} of String => Crystalwright::JSValue
          cyclic = Crystalwright::JSValue.new(properties)
          properties["self"] = cyclic

          page.evaluate("(v) => v.self === v", cyclic).as_bool.should be_true
        end
      end

      it "passes arguments as data and never as text" do
        with_page do |page|
          # The whole injection surface. One quote style is not enough: the naive
          # implementation this is guarding against picks a quote character, and
          # a spec that only tries the other one passes against it.
          [
            "'); globalThis.__owned = true; //",
            "\"); globalThis.__owned = true; //",
            "`); globalThis.__owned = true; //",
            "\\'); globalThis.__owned = true; //",
          ].each do |hostile|
            page.evaluate("(v) => v.length", hostile).as_f.should eq hostile.size.to_f
          end
          page.evaluate("() => globalThis.__owned").undefined?.should be_true

          # Same for a value that ends up inside a template, and for one that
          # looks like our own wire format.
          page.evaluate("(v) => v", %({"ref": 1})).as_s.should eq %({"ref": 1})
        end
      end

      it "refuses arguments when the source is not a function" do
        with_page do |page|
          expect_raises(Crystalwright::EvaluationError, /not a function/) do
            page.evaluate("document.title", 1)
          end
        end
      end
    end

    describe "the shape of the source" do
      it "takes an expression, a function, and an async function" do
        with_page do |page|
          page.evaluate("1 + 1").as_f.should eq 2.0
          page.evaluate("() => 1 + 1").as_f.should eq 2.0
          page.evaluate("async () => 1 + 1").as_f.should eq 2.0
          page.evaluate("() => Promise.resolve('later')").as_s.should eq "later"
          page.evaluate("({a: 1})")["a"].as_f.should eq 1.0
        end
      end

      it "reports what the page threw, not what the protocol called it" do
        with_page do |page|
          error = expect_raises(Crystalwright::EvaluationError, /deliberate/) do
            page.evaluate("() => { throw new TypeError('deliberate'); }")
          end
          error.message.to_s.should contain "TypeError"
        end
      end

      it "converts to a Crystal type on request" do
        with_page do |page|
          page.evaluate(String, "() => 'text'").should eq "text"
          page.evaluate(Int32, "() => 6 * 7").should eq 42
          page.evaluate(Bool, "() => true").should be_true
          page.evaluate(Time, "() => new Date(0)").should eq Time.utc(1970, 1, 1)
          expect_raises(TypeCastError, /whole number/) { page.evaluate(Int32, "() => 1.5") }
        end
      end
    end

    describe "handles" do
      it "keeps a value in the page and asks it questions in place" do
        with_page do |page|
          handle = page.evaluate_handle("() => ({items: [1, 2, 3]})")
          begin
            handle.evaluate("(object) => object.items.length").as_f.should eq 3.0
            handle.get_property("items").json_value.as_a.size.should eq 3
            handle.json_value["items"][2].as_f.should eq 3.0
          ensure
            handle.dispose
          end
        end
      end

      it "hands back a handle for values that cannot be copied out" do
        with_page do |page|
          body = page.evaluate_handle("() => document.body")
          begin
            body.evaluate("(node) => node.tagName").as_s.should eq "BODY"
          ensure
            body.dispose
          end
        end
      end

      it "releases every handle it hands out" do
        with_page do |page|
          context = page.main_world(Crystalwright::Progress.new("spec", 5.seconds))
          context.live_handles.should eq 0

          handles = Array.new(10) { page.evaluate_handle("() => ({})") }
          context.live_handles.should eq 10

          handles.each(&.dispose)
          context.live_handles.should eq 0

          # Disposing twice is not an error and does not double-count.
          handles.each(&.dispose)
          context.live_handles.should eq 0
        end
      end

      it "refuses to be used after disposal" do
        with_page do |page|
          handle = page.evaluate_handle("() => ({})")
          handle.dispose
          expect_raises(Crystalwright::Error, /disposed/) { handle.evaluate("(o) => o") }
        end
      end
    end

    describe "contexts and navigation" do
      it "recreates the isolated world on every navigation, not just the first" do
        with_fixtures(navigation_fixtures) do |server|
          with_page do |page|
            page.goto(server.url("/one"))
            page.evaluate_in_utility("() => document.location.pathname").as_s.should eq "/one"

            # The second navigation is the whole point. Without the empty
            # addScriptToEvaluateOnNewDocument the world comes back exactly once,
            # so a spec that navigated once would be green with the mechanism
            # broken — measured, three runs, perfectly deterministic.
            page.goto(server.url("/two"))
            page.evaluate_in_utility("() => document.location.pathname").as_s.should eq "/two"

            page.goto(server.url("/three"))
            page.evaluate_in_utility("() => document.location.pathname").as_s.should eq "/three"
          end
        end
      end

      it "keeps the isolated world out of the page's own" do
        with_fixtures(navigation_fixtures) do |server|
          with_page do |page|
            page.goto(server.url("/one"))

            page.evaluate_in_utility("() => { globalThis.__hidden = 1; return 1; }").as_f.should eq 1.0
            page.evaluate("() => globalThis.__hidden").undefined?.should be_true

            page.evaluate("() => { globalThis.__theirs = 2; return 2; }").as_f.should eq 2.0
            page.evaluate_in_utility("() => globalThis.__theirs").undefined?.should be_true

            # Same document either way, which is what makes it a world and not a
            # different page.
            page.evaluate_in_utility("() => document.title").as_s.should eq(
              page.evaluate(String, "() => document.title"))
          end
        end
      end

      it "keeps working across a navigation that changes origin" do
        with_fixtures(navigation_fixtures) do |server|
          with_page do |page|
            page.goto(server.url("/one"))
            page.evaluate(String, "() => document.title").should eq "one"

            # Same server, different origin. Measured on Chrome 152: crossing
            # origins restarts the protocol's execution context ids at 1, so a
            # command addressed by `executionContextId` can land in a context
            # that merely inherited the number of the one it meant. Everything
            # here is addressed by `uniqueContextId` for that reason, and this
            # is the spec that would notice.
            page.goto("http://localhost:#{server.port}/two")
            page.evaluate(String, "() => document.title").should eq "two"
            page.evaluate_in_utility(String, "() => document.title").should eq "two"
          end
        end
      end

      it "says the context is gone rather than reporting a protocol code" do
        with_fixtures(navigation_fixtures) do |server|
          with_page do |page|
            page.goto(server.url("/one"))
            handle = page.evaluate_handle("() => ({kept: true})")

            page.goto(server.url("/two"))

            eventually(5.seconds, "the old context was never marked destroyed") do
              handle.context.destroyed?
            end
            expect_raises(Crystalwright::ContextDestroyedError, /navigated/) do
              handle.evaluate("(o) => o.kept")
            end

            # And disposing what is already gone is not an error, because that
            # is what a page navigating does to every handle in it.
            handle.dispose
          end
        end
      end

      it "evaluates again in the new document" do
        with_fixtures(navigation_fixtures) do |server|
          with_page do |page|
            page.goto(server.url("/one"))
            page.evaluate(String, "() => document.title").should eq "one"
            page.goto(server.url("/two"))
            page.evaluate(String, "() => document.title").should eq "two"
          end
        end
      end
    end

    describe "dialogs" do
      it "does not let an unanswered alert wedge the renderer" do
        with_fixtures(dialog_fixtures) do |server|
          with_page do |page|
            page.goto(server.url("/alert"))

            # Enabling the Page domain is what makes this our problem: with it on
            # and nobody answering, the renderer stops responding to every later
            # command for the life of the page while the browser goes on looking
            # healthy. Measured, which is why the default is to dismiss.
            page.evaluate("() => { alert('blocked'); return 'after'; }").as_s.should eq "after"
            page.evaluate("() => 1 + 1").as_f.should eq 2.0
          end
        end
      end

      it "steps aside once the caller takes responsibility" do
        with_fixtures(dialog_fixtures) do |server|
          with_page do |page|
            page.goto(server.url("/alert"))

            seen = [] of String
            page.on_dialog do |event|
              seen << event.message
              page.handle_dialog(accept: true)
            end

            page.evaluate("() => { alert('mine'); return 'after'; }").as_s.should eq "after"
            seen.should eq ["mine"]
          end
        end
      end
    end
  end
end

private def crystal_map
  Crystalwright::JSMap.new([
    {Crystalwright::JSValue.new("a"), Crystalwright::JSValue.new(1.0)},
  ])
end

private def navigation_fixtures
  {
    "/one"   => "<html><head><title>one</title></head><body>one</body></html>",
    "/two"   => "<html><head><title>two</title></head><body>two</body></html>",
    "/three" => "<html><head><title>three</title></head><body>three</body></html>",
  }
end

private def dialog_fixtures
  {"/alert" => "<html><head><title>alert</title></head><body>ready</body></html>"}
end

# Opens a browser and one tab, and always closes both.
private def with_page(&)
  Crystalwright.launch do |browser|
    browser.new_page do |page|
      yield page
    end
  end
end
