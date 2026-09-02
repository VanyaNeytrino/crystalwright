require "json"
require "uri"
require "./errors"
require "./js_value"

module Crystalwright
  # A Crystal `Regex`'s flags as JavaScript spells them, refusing rather than
  # guessing.
  #
  # The two languages disagree about the letters, and the disagreement is not a
  # rename. Crystal's `m` is the composite `MULTILINE_ONLY | DOTALL`, so `/a/m`
  # means what JavaScript writes `/a/ms` — measured, because assuming `m` meant
  # `m` would produce a pattern matching different text and no error anywhere.
  #
  # Mapped one bit at a time rather than one letter at a time, so a `Regex`
  # built with `DOTALL` alone still arrives with its `s`. Anything with no
  # counterpart is an error instead of a silent drop.
  def self.javascript_flags(value : Regex) : String
    understood = Regex::Options::IGNORE_CASE | Regex::Options::MULTILINE_ONLY | Regex::Options::DOTALL
    leftover = value.options & ~understood
    unless leftover.none?
      raise SerializationError.new("#{value.inspect} uses #{leftover}, which JavaScript's RegExp has no \
                                    equivalent for. Pass a Crystalwright::JSRegExp with the flags you want instead.")
    end

    String.build do |io|
      io << 'i' if value.options.ignore_case?
      io << 'm' if value.options.multiline_only?
      io << 's' if value.options.dotall?
    end
  end

  # Something that can be passed into the page as a live reference rather than
  # as a copy.
  #
  # Declared here rather than on `JSHandle` so that the serializer does not have
  # to know what a handle is — it only has to know that some arguments travel by
  # `objectId` and get collected into the call's argument list.
  module RemoteReference
    # The `Runtime.RemoteObjectId` this reference stands for.
    abstract def remote_object_id : String
  end

  # Moves values across the JavaScript boundary in the tagged form that
  # `js/utility_script.js` documents.
  #
  # One format both ways. The alternative — Chrome's `returnByValue` — cannot
  # carry `undefined`, `-0`, `Date`, `Map`, `Set` or a value that contains
  # itself, which is the entire list of things worth getting right here.
  module Serialization
    # Builds the tagged form of arguments, collecting handles as it goes.
    class Encoder
      # The `objectId`s of every handle that appeared among the arguments, in
      # the order the tagged form refers to them.
      getter handle_ids : Array(String) = [] of String

      # Wire ids already handed out, keyed by the identity of the `JSValue` that
      # got them. Only `JSValue` needs this: it is the one type in this shard
      # that can hold a reference to itself, so it is the only place a cycle can
      # come from.
      @visited = {} of UInt64 => Int32

      # :nodoc:
      def encode(value : Nil) : JSON::Any
        sentinel("null")
      end

      # :nodoc:
      def encode(value : Undefined) : JSON::Any
        sentinel("undefined")
      end

      # :nodoc:
      def encode(value : Bool) : JSON::Any
        tagged("b", JSON::Any.new(value))
      end

      # :nodoc:
      def encode(value : Int) : JSON::Any
        tagged("n", JSON::Any.new(value.to_f))
      end

      # :nodoc:
      def encode(value : Float32 | Float64) : JSON::Any
        number = value.to_f64
        return sentinel("NaN") if number.nan?
        return sentinel("Infinity") if number == Float64::INFINITY
        return sentinel("-Infinity") if number == -Float64::INFINITY
        # Not `== 0.0`: that is true of both zeroes. The sign only survives in
        # the reciprocal, and losing it turns Object.is(-0, 0) from false to
        # true on the other side.
        return sentinel("-0") if number.zero? && (1.0 / number) < 0
        tagged("n", JSON::Any.new(number))
      end

      # :nodoc:
      def encode(value : String) : JSON::Any
        tagged("s", JSON::Any.new(value))
      end

      # :nodoc:
      def encode(value : Symbol) : JSON::Any
        tagged("s", JSON::Any.new(value.to_s))
      end

      # :nodoc:
      def encode(value : Time) : JSON::Any
        tagged("d", JSON::Any.new(value.to_utc.to_rfc3339(fraction_digits: 3)))
      end

      # :nodoc:
      def encode(value : URI) : JSON::Any
        tagged("u", JSON::Any.new(value.to_s))
      end

      # :nodoc:
      def encode(value : JSBigInt) : JSON::Any
        tagged("bi", JSON::Any.new(value.value))
      end

      # :nodoc:
      def encode(value : JSRegExp) : JSON::Any
        tagged("r", JSON::Any.new({"p" => JSON::Any.new(value.source), "f" => JSON::Any.new(value.flags)}))
      end

      # Converts a Crystal `Regex`, refusing rather than guessing.
      #
      # The two languages disagree about the letters, and the disagreement is
      # not a rename. Crystal's `m` is the composite `MULTILINE_ONLY | DOTALL`,
      # so `/a/m` means what JavaScript writes `/a/ms` — measured, because
      # assuming `m` meant `m` would produce a pattern that matches different
      # text and no error anywhere.
      #
      # Mapped one bit at a time rather than one letter at a time, so that a
      # `Regex` built with `DOTALL` alone still arrives with its `s`. Anything
      # with no counterpart is an error instead of a silent drop.
      def encode(value : Regex) : JSON::Any
        encode(JSRegExp.new(value.source, Crystalwright.javascript_flags(value)))
      end

      # :nodoc:
      def encode(value : JSError) : JSON::Any
        stack = value.stack
        tagged("e", JSON::Any.new({
          "n" => JSON::Any.new(value.name),
          "m" => JSON::Any.new(value.message),
          "s" => stack ? JSON::Any.new(stack) : JSON::Any.new(nil),
        }))
      end

      # :nodoc:
      def encode(value : JSTypedArray) : JSON::Any
        numbers = value.values.map { |number| JSON::Any.new(number) }
        tagged("ta", JSON::Any.new({"k" => JSON::Any.new(value.kind), "a" => JSON::Any.new(numbers)}))
      end

      # :nodoc:
      def encode(value : JSUnsupported) : JSON::Any
        raise SerializationError.new("A #{value.kind} came out of the page and cannot be sent back into it. \
                                      Use evaluate_handle to keep such a value in the page instead of copying it out.")
      end

      # :nodoc:
      def encode(value : RemoteReference) : JSON::Any
        index = @handle_ids.size
        @handle_ids << value.remote_object_id
        tagged("h", JSON::Any.new(index.to_i64))
      end

      # :nodoc:
      def encode(value : Array | Tuple) : JSON::Any
        elements = [] of JSON::Any
        value.each { |element| elements << encode(element) }
        tagged("a", JSON::Any.new(elements))
      end

      # A Crystal `Set` becomes a JavaScript `Set`, not an array.
      #
      # The types line up, and turning it into an array would mean a value
      # sent as a set comes back as something else.
      def encode(value : ::Set) : JSON::Any
        members = [] of JSON::Any
        value.each { |member| members << encode(member) }
        tagged("se", JSON::Any.new(members))
      end

      # :nodoc:
      def encode(value : JSSet) : JSON::Any
        members = value.values.map { |member| encode(member) }
        tagged("se", JSON::Any.new(members))
      end

      # :nodoc:
      def encode(value : JSMap) : JSON::Any
        pairs = value.entries.map do |(key, member)|
          JSON::Any.new([encode(key), encode(member)])
        end
        tagged("m", JSON::Any.new(pairs))
      end

      # :nodoc:
      def encode(value : Hash) : JSON::Any
        properties = [] of JSON::Any
        value.each do |key, member|
          properties << JSON::Any.new({"k" => JSON::Any.new(key.to_s), "v" => encode(member)})
        end
        tagged("o", JSON::Any.new(properties))
      end

      # :nodoc:
      def encode(value : NamedTuple) : JSON::Any
        properties = [] of JSON::Any
        value.each do |key, member|
          properties << JSON::Any.new({"k" => JSON::Any.new(key.to_s), "v" => encode(member)})
        end
        tagged("o", JSON::Any.new(properties))
      end

      # :nodoc:
      def encode(value : JSON::Any) : JSON::Any
        case raw = value.raw
        in Nil                     then encode(nil)
        in Bool                    then encode(raw)
        in Int64                   then encode(raw)
        in Float64                 then encode(raw)
        in String                  then encode(raw)
        in Array(JSON::Any)        then encode(raw)
        in Hash(String, JSON::Any) then encode(raw)
        end
      end

      # Encodes a value that came out of the page.
      #
      # This is the only overload that can meet a cycle, so it is the only one
      # that registers what it has seen. A value met a second time becomes a
      # reference to the first, which is what lets `a.push(a)` survive the trip
      # in both directions.
      def encode(value : JSValue) : JSON::Any
        if existing = @visited[value.object_id]?
          return JSON::Any.new({"ref" => JSON::Any.new(existing.to_i64)})
        end

        case raw = value.raw
        when Array(JSValue), Hash(String, JSValue), JSSet, JSMap
          id = @visited.size + 1
          @visited[value.object_id] = id
          with_id(encode_container(raw), id)
        else
          encode(raw)
        end
      end

      private def encode_container(raw : Array(JSValue) | Hash(String, JSValue) | JSSet | JSMap) : JSON::Any
        case raw
        in Array(JSValue)        then encode(raw)
        in Hash(String, JSValue) then encode(raw)
        in JSSet                 then encode(raw)
        in JSMap                 then encode(raw)
        end
      end

      private def with_id(tagged : JSON::Any, id : Int32) : JSON::Any
        fields = tagged.as_h.dup
        fields["id"] = JSON::Any.new(id.to_i64)
        JSON::Any.new(fields)
      end

      private def sentinel(name : String) : JSON::Any
        tagged("v", JSON::Any.new(name))
      end

      private def tagged(key : String, value : JSON::Any) : JSON::Any
        JSON::Any.new({key => value})
      end
    end

    # Rebuilds a Crystal value from the tagged form.
    class Decoder
      @refs = {} of Int64 => JSValue

      # Decodes one tagged value.
      def decode(tagged : JSON::Any) : JSValue
        fields = tagged.as_h? || raise SerializationError.new("expected a tagged object, got #{tagged.inspect}")

        if reference = fields["ref"]?
          id = integer(reference)
          return @refs[id]? || raise SerializationError.new("dangling reference #{id} in the page's reply")
        end

        if sentinel = fields["v"]?
          return decode_sentinel(sentinel.as_s)
        end

        return JSValue.new(number(fields["n"])) if fields["n"]?
        return JSValue.new(fields["s"].as_s) if fields["s"]?
        return JSValue.new(fields["b"].as_bool) if fields["b"]?
        return JSValue.new(JSBigInt.new(fields["bi"].as_s)) if fields["bi"]?
        return JSValue.new(Time.parse_rfc3339(fields["d"].as_s)) if fields["d"]?
        return JSValue.new(URI.parse(fields["u"].as_s)) if fields["u"]?
        return JSValue.new(JSUnsupported.new(fields["x"].as_s)) if fields["x"]?

        if pattern = fields["r"]?
          return JSValue.new(JSRegExp.new(pattern["p"].as_s, pattern["f"].as_s))
        end

        if error = fields["e"]?
          stack = error["s"]?.try &.as_s?
          return JSValue.new(JSError.new(error["n"].as_s, error["m"].as_s, stack))
        end

        if array = fields["ta"]?
          numbers = array["a"].as_a.map { |element| number(element) }
          return JSValue.new(JSTypedArray.new(array["k"].as_s, numbers))
        end

        decode_container(fields)
      end

      # Containers are registered before their contents are read.
      #
      # That ordering is the entire cycle mechanism on this side: by the time an
      # element says `{"ref": 1}`, the value it refers to has to already exist,
      # even though it is not finished yet. Filling first and registering after
      # would leave the reference dangling.
      private def decode_container(fields : Hash(String, JSON::Any)) : JSValue
        id = fields["id"]?.try { |value| integer(value) }

        if elements = fields["a"]?
          contents = [] of JSValue
          value = register(JSValue.new(contents), id)
          elements.as_a.each { |element| contents << decode(element) }
          return value
        end

        if properties = fields["o"]?
          contents = {} of String => JSValue
          value = register(JSValue.new(contents), id)
          properties.as_a.each { |property| contents[property["k"].as_s] = decode(property["v"]) }
          return value
        end

        if members = fields["se"]?
          contents = [] of JSValue
          value = register(JSValue.new(JSSet.new(contents)), id)
          members.as_a.each { |member| contents << decode(member) }
          return value
        end

        if entries = fields["m"]?
          contents = [] of {JSValue, JSValue}
          value = register(JSValue.new(JSMap.new(contents)), id)
          entries.as_a.each do |entry|
            pair = entry.as_a
            contents << {decode(pair[0]), decode(pair[1])}
          end
          return value
        end

        raise SerializationError.new("unrecognised tagged value from the page: #{fields.keys.inspect}")
      end

      private def register(value : JSValue, id : Int64?) : JSValue
        @refs[id] = value if id
        value
      end

      private def decode_sentinel(name : String) : JSValue
        case name
        when "undefined" then JSValue.new(Undefined.new)
        when "null"      then JSValue.new(nil)
        when "NaN"       then JSValue.new(Float64::NAN)
        when "Infinity"  then JSValue.new(Float64::INFINITY)
        when "-Infinity" then JSValue.new(-Float64::INFINITY)
        when "-0"        then JSValue.new(-0.0)
        else                  raise SerializationError.new("unknown sentinel #{name.inspect} from the page")
        end
      end

      private def number(value : JSON::Any) : Float64
        case raw = value.raw
        when Int64   then raw.to_f
        when Float64 then raw
        else              raise SerializationError.new("expected a number, got #{value.inspect}")
        end
      end

      private def integer(value : JSON::Any) : Int64
        case raw = value.raw
        when Int64   then raw
        when Float64 then raw.to_i64
        else              raise SerializationError.new("expected an id, got #{value.inspect}")
        end
      end
    end
  end
end
