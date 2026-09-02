require "./spec_helper"

# Level 1: the tagged format, with no browser anywhere near it.
#
# What this proves is limited on purpose, and worth saying out loud: it tests
# our encoder against our decoder, which is a closed loop that can be
# consistently wrong in both halves. The proof that the format matches
# JavaScript is in `evaluate_spec.cr`, where the value actually goes out to a
# page and comes back. This suite is here to be fast, to be exhaustive, and to
# fail with a small diff when one half changes.
private def round_trip(value)
  encoder = Crystalwright::Serialization::Encoder.new
  Crystalwright::Serialization::Decoder.new.decode(encoder.encode(value))
end

describe Crystalwright::Serialization do
  describe "the values JSON cannot carry" do
    it "keeps undefined apart from null" do
      round_trip(Crystalwright::Undefined.new).undefined?.should be_true
      round_trip(Crystalwright::Undefined.new).null?.should be_false

      round_trip(nil).null?.should be_true
      round_trip(nil).undefined?.should be_false
    end

    it "keeps the sign of negative zero" do
      negative = round_trip(-0.0)
      negative.negative_zero?.should be_true

      # The assertion above is the whole spec, and `should eq 0.0` would pass
      # for a plain zero too. This is the check that the value really is the
      # one that divides into -Infinity.
      (1.0 / negative.as_f).should eq(-Float64::INFINITY)

      round_trip(0.0).negative_zero?.should be_false
      (1.0 / round_trip(0.0).as_f).should eq Float64::INFINITY
    end

    it "carries NaN and both infinities" do
      round_trip(Float64::NAN).as_f.nan?.should be_true
      round_trip(Float64::INFINITY).as_f.should eq Float64::INFINITY
      round_trip(-Float64::INFINITY).as_f.should eq(-Float64::INFINITY)
    end

    it "carries a BigInt as exact text rather than as a double" do
      # 2^53 + 1, the first integer a JavaScript number cannot represent.
      round_trip(Crystalwright::JSBigInt.new("9007199254740993")).as_big_int.value.should eq "9007199254740993"
    end

    it "carries a Date" do
      moment = Time.utc(1970, 1, 1, 0, 0, 0)
      round_trip(moment).as_time.should eq moment
    end

    it "carries a URL" do
      round_trip(URI.parse("https://example.com/a?b=c")).as_uri.to_s.should eq "https://example.com/a?b=c"
    end

    it "keeps a Map's arbitrary keys and its order" do
      map = Crystalwright::JSMap.new([
        {Crystalwright::JSValue.new("b"), Crystalwright::JSValue.new(2.0)},
        {Crystalwright::JSValue.new("a"), Crystalwright::JSValue.new(1.0)},
      ])
      decoded = round_trip(map).as_map
      decoded.size.should eq 2
      decoded.entries.map { |(key, _)| key.as_s }.should eq ["b", "a"]
      decoded["a"].as_f.should eq 1.0
    end

    it "keeps a Set distinct from an array" do
      decoded = round_trip(Set{1, 2, 3})
      decoded.as_set.size.should eq 3
      decoded.as_a?.should be_nil
    end

    it "keeps a typed array's kind" do
      decoded = round_trip(Crystalwright::JSTypedArray.new("Uint8Array", [1.0, 2.0, 255.0]))
      decoded.as_typed_array.kind.should eq "Uint8Array"
      decoded.as_typed_array.values.should eq [1.0, 2.0, 255.0]
    end
  end

  describe "cycles" do
    it "rebuilds a value that contains itself" do
      contents = [] of Crystalwright::JSValue
      cyclic = Crystalwright::JSValue.new(contents)
      contents << cyclic

      decoded = round_trip(cyclic)

      # Not "it did not crash" — that passes with the cycle silently truncated
      # to one level. The reconstructed value has to be the same object as the
      # one nested inside it, which is the only thing that makes it a cycle.
      decoded[0].should be(decoded)
    end

    it "rebuilds a cycle through an object" do
      properties = {} of String => Crystalwright::JSValue
      cyclic = Crystalwright::JSValue.new(properties)
      properties["self"] = cyclic
      properties["name"] = Crystalwright::JSValue.new("root")

      decoded = round_trip(cyclic)
      decoded["self"].should be(decoded)
      decoded["self"]["self"]["name"].as_s.should eq "root"
    end

    it "preserves sharing without a cycle" do
      shared = Crystalwright::JSValue.new({"n" => Crystalwright::JSValue.new(1.0)})
      decoded = round_trip([shared, shared])

      # One object referenced twice stays one object. This is observable in the
      # page too — `a[0] === a[1]` — which is why it is asserted about a
      # container and not about a string: primitives have no identity in
      # JavaScript, so sharing one would be a claim about our own bookkeeping
      # rather than about the value.
      decoded[0].should be(decoded[1])
    end

    it "renders a cycle instead of hanging on it" do
      contents = [] of Crystalwright::JSValue
      cyclic = Crystalwright::JSValue.new(contents)
      contents << cyclic

      # Spec failure output calls inspect. Without the guard a single failing
      # assertion about a cyclic value takes the whole suite down with it.
      cyclic.inspect.should eq "[#<cycle>]"
    end
  end

  describe "reading a value back out" do
    it "reads the values that are indistinguishable from absence" do
      # `as?(T) || raise` reads well and is wrong: false and 0.0 are perfectly
      # good values of their types and take the raise branch. Found by a page
      # that answered `false`, which is not an exotic thing for a page to do.
      round_trip(false).as_bool.should be_false
      round_trip(true).as_bool.should be_true
      round_trip(0.0).as_f.should eq 0.0
      round_trip("").as_s.should eq ""
      round_trip([] of Crystalwright::JSValue).as_a.should be_empty
    end

    it "says what it got when it is asked for the wrong type" do
      error = expect_raises(TypeCastError) { round_trip("text").as_f }
      error.message.to_s.should contain "string"
    end
  end

  describe "structures" do
    it "round-trips fifty levels of nesting" do
      deep = Crystalwright::JSValue.new("bottom")
      50.times { deep = Crystalwright::JSValue.new([deep]) }

      decoded = round_trip(deep)
      50.times { decoded = decoded[0] }
      decoded.as_s.should eq "bottom"
    end

    it "round-trips a string with characters outside the basic plane" do
      text = "é \u{1F600} \u{10FFFF}"
      round_trip(text).as_s.should eq text
    end

    it "takes a NamedTuple as an object" do
      decoded = round_trip({name: "ok", count: 2})
      decoded["name"].as_s.should eq "ok"
      decoded["count"].as_f.should eq 2.0
    end

    it "takes a JSON::Any" do
      decoded = round_trip(JSON.parse(%({"a": [1, true, null]})))
      decoded["a"][0].as_f.should eq 1.0
      decoded["a"][1].as_bool.should be_true
      decoded["a"][2].null?.should be_true
    end
  end

  describe "the things it refuses" do
    it "will not guess at a regex flag JavaScript does not have" do
      error = expect_raises(Crystalwright::SerializationError, /EXTENDED/) do
        Crystalwright::Serialization::Encoder.new.encode(/a b/x)
      end
      error.message.to_s.should contain "JSRegExp"
    end

    it "maps the regex flags the two languages spell differently" do
      # Crystal's `m` is the composite MULTILINE_ONLY | DOTALL, so it means what
      # JavaScript writes `ms`. Measured, not assumed: `/a.b/m` matches "a\nb"
      # and `/^b$/m` matches at a line start, so both halves are really there.
      Crystalwright::Serialization::Encoder.new.encode(/a/im)["r"]["f"].as_s.chars.sort!.should eq ['i', 'm', 's']

      # And a Regex built with only DOTALL keeps its `s`, which a letter-by-letter
      # mapping would have dropped on the floor without saying anything.
      dotall = Regex.new("a.b", Regex::Options::DOTALL)
      Crystalwright::Serialization::Encoder.new.encode(dotall)["r"]["f"].as_s.should eq "s"
    end

    it "will not send a function back into the page" do
      expect_raises(Crystalwright::SerializationError, /evaluate_handle/) do
        Crystalwright::Serialization::Encoder.new.encode(Crystalwright::JSUnsupported.new("function"))
      end
    end
  end

  describe "handles among the arguments" do
    it "collects them by objectId and refers to them by index" do
      encoder = Crystalwright::Serialization::Encoder.new
      encoded = encoder.encode([FakeHandle.new("obj-1"), FakeHandle.new("obj-2")])

      encoder.handle_ids.should eq ["obj-1", "obj-2"]
      encoded["a"][0]["h"].as_i.should eq 0
      encoded["a"][1]["h"].as_i.should eq 1
    end
  end
end

# A stand-in for a real handle, so the encoder can be tested without a browser.
private struct FakeHandle
  include Crystalwright::RemoteReference

  getter remote_object_id : String

  def initialize(@remote_object_id : String)
  end
end
