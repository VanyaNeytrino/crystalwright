require "uri"
require "./errors"

module Crystalwright
  # Declared before the types it holds so that they can name it back.
  #
  # `JSSet` and `JSMap` are defined in terms of `JSValue`, and `JSValue`'s union
  # names them, so one of the two has to come first as a bare declaration.
  class JSValue
  end

  # The JavaScript `undefined`.
  #
  # A distinct type rather than `nil`, because `undefined` and `null` are
  # different values in the language and code that tells them apart — a missing
  # property against a property explicitly set to `null` — is ordinary.
  struct Undefined
  end

  # A JavaScript `BigInt`, kept as the decimal text it was written as.
  #
  # Not converted to Crystal's `BigInt`: that would link libgmp into every
  # program that drives a browser, for a type most of them never see. The text
  # is exact, and a caller who wants arithmetic can `require "big"` and parse it.
  struct JSBigInt
    # The decimal digits, e.g. `"9007199254740993"`.
    getter value : String

    def initialize(@value : String)
    end
  end

  # A JavaScript `RegExp`, kept as its own source and flags.
  #
  # Deliberately not converted to a Crystal `Regex`. The two disagree on what
  # the letters mean — Crystal's `m` is "`.` matches a newline", which is
  # JavaScript's `s`, while JavaScript's `m` is Crystal's `MULTILINE_ONLY` — and
  # `g`, `y` and `u` have no Crystal equivalent at all. Converting silently
  # would hand back a pattern that matches different text than the page's did.
  struct JSRegExp
    # The pattern between the slashes.
    getter source : String

    # The flag letters, e.g. `"gi"`.
    getter flags : String

    def initialize(@source : String, @flags : String)
    end
  end

  # A JavaScript `Error`, flattened to what it can say about itself.
  struct JSError
    # The constructor name, e.g. `"TypeError"`.
    getter name : String

    # The message it was constructed with.
    getter message : String

    # The stack as the page rendered it, when it had one.
    getter stack : String?

    def initialize(@name : String, @message : String, @stack : String? = nil)
    end
  end

  # A JavaScript `Set`, in insertion order.
  #
  # Backed by an array rather than a Crystal `Set` on purpose: JavaScript
  # compares members with SameValueZero, so two distinct objects stay distinct
  # members even when Crystal would consider them equal. Rehashing them into a
  # `Set` would silently merge entries the page keeps apart.
  struct JSSet
    # The members, in the order the page inserted them.
    getter values : Array(JSValue)

    def initialize(@values : Array(JSValue) = [] of JSValue)
    end

    # The number of members.
    def size : Int32
      @values.size
    end

    # Yields each member.
    def each(&)
      @values.each { |value| yield value }
    end
  end

  # A JavaScript `Map`, in insertion order.
  #
  # Backed by pairs rather than a Crystal `Hash` for the same reason `JSSet` is
  # backed by an array, and for one more: a `Map` key can be any value at all,
  # including an object or `NaN`, which a `Hash(String, JSValue)` cannot express.
  struct JSMap
    # The entries, in the order the page inserted them.
    getter entries : Array({JSValue, JSValue})

    def initialize(@entries : Array({JSValue, JSValue}) = [] of {JSValue, JSValue})
    end

    # The number of entries.
    def size : Int32
      @entries.size
    end

    # The value stored under a key, compared the way `JSValue#==` compares.
    def [](key)
      pair = @entries.find { |(candidate, _)| candidate == key }
      raise KeyError.new("no such key in the Map") unless pair
      pair[1]
    end

    # Yields each key and value.
    def each(&)
      @entries.each { |(key, value)| yield key, value }
    end
  end

  # A JavaScript typed array, e.g. `Int8Array` or `Float64Array`.
  #
  # Given its own representation rather than being allowed to fall through to
  # the object branch, where it would arrive as `{"0" => …, "1" => …}` and lose
  # which kind of array it was.
  struct JSTypedArray
    # The constructor name, e.g. `"Uint8Array"`.
    getter kind : String

    # The elements.
    getter values : Array(Float64)

    def initialize(@kind : String, @values : Array(Float64))
    end

    # The number of elements.
    def size : Int32
      @values.size
    end
  end

  # A value that cannot cross the boundary, naming what it was.
  #
  # Functions, symbols and DOM nodes have no representation outside the page.
  # They arrive as this rather than as `undefined`, because a function that
  # silently becomes `undefined` is indistinguishable from a property that was
  # never there, and the two are debugged very differently. Reach for
  # `evaluate_handle` when the value has to stay in the page.
  struct JSUnsupported
    # What it was, e.g. `"function"`, `"symbol"` or `"node"`.
    getter kind : String

    def initialize(@kind : String)
    end
  end

  # A value that came back from JavaScript.
  #
  # This is not `JSON::Any`, and the difference is the whole point of it.
  # JavaScript has values that JSON cannot express — `undefined` is not `null`,
  # `-0` is not `0`, `Map` and `Set` are not objects, and a value is allowed to
  # contain itself. Every one of those survives the round trip here, because a
  # library that quietly turns `undefined` into `nil` is lying about what the
  # page said.
  #
  # ```
  # value = page.evaluate("() => ({d: new Date(0), s: new Set([1]), u: undefined})")
  # value["d"].as_time    # => 1970-01-01 00:00:00.0 UTC
  # value["s"].as_set     # => a JSSet
  # value["u"].undefined? # => true
  # value["u"].null?      # => false
  # ```
  #
  # It is a class rather than a struct so that a cycle is representable: a
  # `JSValue` whose array contains that same `JSValue` is what
  # `const a = []; a.push(a)` actually is, and flattening it would be a
  # different value.
  class JSValue
    # Everything a `JSValue` can hold.
    #
    # JavaScript numbers are all doubles, so there is no integer case: `1` and
    # `1.0` are the same value in the page and pretending otherwise here would
    # invent a distinction the language does not have.
    alias Raw = (Bool |
                 Float64 |
                 String |
                 Undefined |
                 Time |
                 URI |
                 JSBigInt |
                 JSRegExp |
                 JSError |
                 JSSet |
                 JSMap |
                 JSTypedArray |
                 JSUnsupported |
                 Array(JSValue) |
                 Hash(String, JSValue))?

    # The value itself.
    getter raw : Raw

    def initialize(@raw : Raw)
    end

    # The JavaScript `undefined`, which is not `null`.
    def undefined? : Bool
      @raw.is_a?(Undefined)
    end

    # The JavaScript `null`, which is not `undefined`.
    def null? : Bool
      @raw.nil?
    end

    # Whether this is the negative zero.
    #
    # `-0 == 0` in both languages, so this cannot be asked with `==`. It matters
    # because `Object.is(-0, 0)` is false and because dividing by it gives
    # `-Infinity`, which is exactly the kind of thing that turns up in a chart
    # library at the worst possible moment.
    def negative_zero? : Bool
      value = @raw
      value.is_a?(Float64) && value.zero? && (1.0 / value) < 0
    end

    {% for name, type in {f: Float64, s: String, bool: Bool, time: Time, uri: URI,
                          a: Array(JSValue), h: Hash(String, JSValue),
                          set: JSSet, map: JSMap, regex: JSRegExp, error: JSError,
                          big_int: JSBigInt, typed_array: JSTypedArray} %}
      # Reads this value as a {{ type }}, or `nil` if it is something else.
      def as_{{ name.id }}? : {{ type }}?
        @raw.as?({{ type }})
      end

      # Reads this value as a {{ type }}, raising if it is something else.
      #
      # Written as a type check rather than as `as?(T) || raise`, which reads
      # more neatly and is wrong: `false` and `0.0` are perfectly good values of
      # their types and would take the raise branch.
      def as_{{ name.id }} : {{ type }}
        value = @raw
        return value if value.is_a?({{ type }})
        raise TypeCastError.new("Expected {{ type }}, got #{kind}")
      end
    {% end %}

    # Reads this value as an integer, raising unless it is a whole number.
    #
    # JavaScript has no integers, so this is a claim about the value rather than
    # about its type, and a fractional number is a mistake worth hearing about.
    def as_i : Int64
      number = as_f
      unless number.finite? && number == number.trunc
        raise TypeCastError.new("#{number} is not a whole number")
      end
      number.to_i64
    end

    # Reads this value as an integer, or `nil` if it is not a whole number.
    def as_i? : Int64?
      as_i
    rescue TypeCastError
      nil
    end

    # A property of an object, or an element of an array.
    def [](key : String) : JSValue
      as_h[key]
    end

    # :ditto:
    def [](index : Int) : JSValue
      as_a[index]
    end

    # A property of an object, or `nil` when there is no such key.
    def []?(key : String) : JSValue?
      as_h?.try &.[key]?
    end

    # :ditto:
    def []?(index : Int) : JSValue?
      as_a?.try &.[index]?
    end

    # The number of elements or properties.
    def size : Int32
      case value = @raw
      in Array(JSValue)        then value.size
      in Hash(String, JSValue) then value.size
      in JSSet                 then value.size
      in JSMap                 then value.size
      in JSTypedArray          then value.size
      in String                then value.size
      in Nil, Bool, Float64, Undefined, Time, URI, JSBigInt, JSRegExp, JSError, JSUnsupported
        raise TypeCastError.new("#{kind} has no size")
      end
    end

    # A short name for what this holds, for error messages.
    def kind : String
      case value = @raw
      in Nil                   then "null"
      in Undefined             then "undefined"
      in Bool                  then "boolean"
      in Float64               then "number"
      in String                then "string"
      in Time                  then "Date"
      in URI                   then "URL"
      in JSBigInt              then "BigInt"
      in JSRegExp              then "RegExp"
      in JSError               then "Error"
      in JSSet                 then "Set"
      in JSMap                 then "Map"
      in JSTypedArray          then value.kind
      in JSUnsupported         then value.kind
      in Array(JSValue)        then "Array"
      in Hash(String, JSValue) then "Object"
      end
    end

    # Compares against a plain Crystal value.
    #
    # Deliberately only against primitives. Two `JSValue`s compare by identity,
    # because a deep comparison of two separately built cyclic values does not
    # terminate, and a spec that hangs is worse than one that fails.
    def ==(other : Number) : Bool
      value = @raw
      value.is_a?(Float64) && value == other
    end

    # :ditto:
    def ==(other : String) : Bool
      @raw == other
    end

    # :ditto:
    def ==(other : Bool) : Bool
      @raw == other
    end

    # Converts to a Crystal type, raising if the page sent something else.
    #
    # Overloads rather than one clever generic method: an unsupported type is
    # then a missing overload named at the call site, instead of a macro error
    # pointing into this file. Structures come back as `JSValue` and are read
    # with the accessors — there is no schema here to map them onto.
    def cast_to(type : JSValue.class) : JSValue
      self
    end

    # :ditto:
    def cast_to(type : String.class) : String
      as_s
    end

    # :ditto:
    def cast_to(type : Bool.class) : Bool
      as_bool
    end

    # :ditto:
    def cast_to(type : Float64.class) : Float64
      as_f
    end

    # :ditto:
    def cast_to(type : Float32.class) : Float32
      as_f.to_f32
    end

    # :ditto:
    def cast_to(type : Int32.class) : Int32
      as_i.to_i32
    end

    # :ditto:
    def cast_to(type : Int64.class) : Int64
      as_i
    end

    # :ditto:
    def cast_to(type : Time.class) : Time
      as_time
    end

    # :ditto:
    def cast_to(type : URI.class) : URI
      as_uri
    end

    # :nodoc:
    def to_s(io : IO) : Nil
      inspect(io)
    end

    # Renders the value, stopping at a cycle rather than recursing into it.
    #
    # The guard is not decoration. Spec failure output calls `inspect`, so
    # without it a single failing assertion on a self-referential value hangs
    # the suite instead of reporting anything.
    def inspect(io : IO) : Nil
      inspect(io, Set(UInt64).new)
    end

    # :nodoc:
    protected def inspect(io : IO, seen : Set(UInt64)) : Nil
      if seen.includes?(object_id)
        io << "#<cycle>"
        return
      end
      seen.add(object_id)

      case value = @raw
      in Nil           then io << "null"
      in Undefined     then io << "undefined"
      in Bool, Float64 then io << value
      in String        then value.inspect(io)
      in Time          then io << "Date(" << value.to_rfc3339 << ")"
      in URI           then io << "URL(" << value << ")"
      in JSBigInt      then io << value.value << 'n'
      in JSRegExp      then io << '/' << value.source << '/' << value.flags
      in JSError       then io << value.name << ": " << value.message
      in JSUnsupported then io << '<' << value.kind << '>'
      in JSTypedArray
        io << value.kind << '('
        value.values.join(io, ", ")
        io << ')'
      in Array(JSValue)
        io << '['
        value.each_with_index do |element, index|
          io << ", " if index > 0
          element.inspect(io, seen)
        end
        io << ']'
      in Hash(String, JSValue)
        io << '{'
        value.each_with_index do |(key, element), index|
          io << ", " if index > 0
          key.inspect(io)
          io << " => "
          element.inspect(io, seen)
        end
        io << '}'
      in JSSet
        io << "Set{"
        value.values.each_with_index do |element, index|
          io << ", " if index > 0
          element.inspect(io, seen)
        end
        io << '}'
      in JSMap
        io << "Map{"
        value.entries.each_with_index do |(key, element), index|
          io << ", " if index > 0
          key.inspect(io, seen)
          io << " => "
          element.inspect(io, seen)
        end
        io << '}'
      end
    ensure
      seen.delete(object_id)
    end
  end
end
