require "cdp"
require "./errors"
require "./js_value"
require "./serialization"
require "./progress"

module Crystalwright
  # One JavaScript world in one frame.
  #
  # A page has at least two: the main world, where the page's own scripts live
  # and where `evaluate` runs so that globals the page set up are visible; and
  # an isolated utility world, where this library's own code runs so that a page
  # cannot see it, break it, or be broken by it.
  #
  # A context does not survive a navigation. Every handle resolved in one dies
  # with it, which is not a failure mode but the normal course of events, and is
  # why `ContextDestroyedError` exists as its own type.
  class ExecutionContext
    # The utility script, read at compile time.
    #
    # Not read from disk at runtime: a shard that reads its own source at
    # runtime cannot be shipped as one static binary, which is most of the
    # reason to be writing this in Crystal.
    UTILITY_SCRIPT = {{ read_file("#{__DIR__}/js/utility_script.js") }}

    # The protocol id of this context.
    getter id : Int32

    # The id that stays valid across a cross-process navigation.
    #
    # Commands are addressed with this rather than with `id`. The protocol
    # documents `executionContextId` as reusable between processes, which means
    # a command aimed at a context that has just gone can land in a different
    # one that happens to have inherited the number.
    getter unique_id : String

    # The world's name — empty for the page's own, ours for the utility world.
    getter name : String

    # The session this context is reached through.
    getter session : CDP::Session

    # The object group every handle from this context belongs to, so that the
    # whole context can be released in one command instead of N.
    getter object_group : String

    @utility_object_id : String?
    @destroyed = false
    @issued = 0
    @released = 0
    @mutex = Sync::Mutex.new

    # :nodoc:
    def initialize(@session : CDP::Session, @id : Int32, @unique_id : String, @name : String)
      @object_group = "crystalwright-#{@unique_id}"
    end

    # Whether the document this context belonged to has gone.
    def destroyed? : Bool
      @mutex.synchronize { @destroyed }
    end

    # How many handles this context has handed out and not released.
    #
    # The counter is not decoration: "handles are released" is otherwise an
    # intention rather than a fact, and a leak here is a page that grows a
    # little on every action until it does not fit in memory.
    def live_handles : Int32
      @mutex.synchronize { @issued - @released }
    end

    # Evaluates in this world and copies the result out.
    def evaluate(source : String, *args, progress : Progress? = nil) : JSValue
      progress ||= Progress.new("evaluate", DEFAULT_TIMEOUT)
      response = call(declaration(source), args, by_value: true, progress: progress, what: "the caller's expression")
      raw = response.result.value || raise SerializationError.new("the page returned nothing at all for #{source}")
      Serialization::Decoder.new.decode(raw)
    end

    # Evaluates in this world and leaves the result in the page.
    def evaluate_handle(source : String, *args, progress : Progress? = nil) : JSHandle
      progress ||= Progress.new("evaluate_handle", DEFAULT_TIMEOUT)
      response = call(declaration(source), args, by_value: false, progress: progress, what: "the caller's expression")
      object = response.result
      object_id = object.object_id
      unless object_id
        raise SerializationError.new("#{source} produced #{object.type.to_wire}, which has no handle. \
                                      Primitives have to come out by value — use evaluate.")
      end
      track_issue
      JSHandle.new(self, object_id, object)
    end

    # :nodoc:
    #
    # Wraps an object the browser handed us for a value we did not evaluate for
    # directly — a property of another handle, say — so that it is counted and
    # released like every other handle from this world.
    protected def adopt(object_id : String, object : CDP::Protocol::Runtime::RemoteObject) : JSHandle
      track_issue
      JSHandle.new(self, object_id, object)
    end

    # :nodoc:
    #
    # Called by `JSHandle#dispose`, so the counter stays with the context that
    # handed the handle out.
    protected def release(object_id : String) : Nil
      track_release
      return if destroyed?
      @session.execute(CDP::Protocol::Runtime::ReleaseObjectRequest.new(object_id: object_id), 5.seconds)
    rescue CDP::ProtocolError | CDP::SessionClosedError | CDP::TimeoutError | ContextDestroyedError
      # The object is gone, which is what was being asked for. A page that
      # navigated has already released everything in the old document.
    end

    # Releases every handle from this context at once.
    def dispose : Nil
      return if destroyed?
      @session.execute(CDP::Protocol::Runtime::ReleaseObjectGroupRequest.new(object_group: @object_group), 5.seconds)
    rescue CDP::ProtocolError | CDP::SessionClosedError | CDP::TimeoutError
      # Same as above: nothing to release means nothing to do.
    end

    # :nodoc:
    #
    # Marks the document gone. Called from the `Runtime.executionContextDestroyed`
    # handler, so it must not talk to the browser.
    protected def mark_destroyed : Nil
      @mutex.synchronize { @destroyed = true }
    end

    # Calls one of the utility script's own functions by name.
    #
    # Nothing of the caller's is compiled here: a selector arrives as a string
    # argument through the same tagged encoding an `evaluate` argument uses, so
    # `text="'); alert(1); //"` is a piece of text on both sides of the wire.
    protected def invoke(name : String, *args, progress : Progress) : JSValue
      response = call(utility_declaration(name), args, by_value: true, progress: progress, what: name)
      raw = response.result.value || raise SerializationError.new("#{name} returned nothing at all")
      Serialization::Decoder.new.decode(raw)
    end

    # :ditto:
    #
    # Returns `nil` when the function answered with JavaScript `null`, which is
    # how "no element matched" arrives — an answer rather than a failure.
    protected def invoke_handle(name : String, *args, progress : Progress) : JSHandle?
      object = call(utility_declaration(name), args, by_value: false, progress: progress, what: name).result
      object_id = object.object_id
      return unless object_id
      track_issue
      JSHandle.new(self, object_id, object)
    end

    # :ditto:
    protected def invoke_element(name : String, *args, progress : Progress) : ElementHandle?
      object = call(utility_declaration(name), args, by_value: false, progress: progress, what: name).result
      object_id = object.object_id
      return unless object_id
      track_issue
      ElementHandle.new(self, object_id, object)
    end

    # :ditto:
    #
    # For a function that answers with an array of elements. The array itself is
    # a handle too and is released here — leaving it behind would pin every
    # element in a query result for the life of the document.
    protected def invoke_elements(name : String, *args, progress : Progress) : Array(ElementHandle)
      array = invoke_handle(name, *args, progress: progress)
      return [] of ElementHandle unless array

      begin
        response = execute(CDP::Protocol::Runtime::GetPropertiesRequest.new(
          object_id: array.remote_object_id, own_properties: true, generate_preview: false), progress)

        indexed = [] of Tuple(Int32, ElementHandle)
        response.result.each do |property|
          # `length` and anything else that is not an index is not an element.
          index = property.name.to_i?
          next unless index
          value = property.value
          next unless value
          object_id = value.object_id
          next unless object_id
          track_issue
          indexed << {index, ElementHandle.new(self, object_id, value)}
        end

        # Document order is the order the page answered in, and a hash of string
        # keys is not obliged to keep it.
        indexed.sort_by! { |(index, _)| index }
        indexed.map { |(_, element)| element }
      ensure
        array.dispose
      end
    end

    private def call(declaration : String, args, by_value : Bool, progress : Progress,
                     what : String) : CDP::Protocol::Runtime::CallFunctionOnResponse
      raise ContextDestroyedError.new if destroyed?
      progress.check!

      encoder = Serialization::Encoder.new
      # Built by appending rather than by mapping the tuple: an empty argument
      # list maps to an empty tuple, whose `to_a` has element type NoReturn and
      # does not satisfy Array(JSON::Any).
      encoded = [] of JSON::Any
      args.each { |argument| encoded << encoder.encode(argument) }
      payload = JSON::Any.new({
        "a" => JSON::Any.new(encoded),
        "r" => JSON::Any.new(by_value),
      })

      arguments = [CDP::Protocol::Runtime::CallArgument.new(value: payload)]
      encoder.handle_ids.each do |handle_id|
        arguments << CDP::Protocol::Runtime::CallArgument.new(object_id: handle_id)
      end

      response = execute(CDP::Protocol::Runtime::CallFunctionOnRequest.new(
        function_declaration: declaration,
        object_id: utility_object_id(progress),
        arguments: arguments,
        return_by_value: by_value,
        await_promise: true,
        user_gesture: false,
        object_group: @object_group,
      ), progress, what)

      if details = response.exception_details
        raise evaluation_error(details)
      end
      response
    end

    # The wrapper Chrome compiles around the caller's source.
    #
    # The source is interpolated, and that is not the injection the security
    # rules are about: this is code the caller wrote, compiled by Chrome exactly
    # the way `Runtime.evaluate` would compile it. Arguments never appear here —
    # they travel as data in `arguments` and are decoded inside the page. The
    # moment a value is interpolated into this string instead, the whole
    # argument path stops being safe.
    #
    # Compiling it as part of the declaration rather than with `eval` inside the
    # utility script is what lets `evaluate` work on a page whose
    # Content-Security-Policy forbids `eval`.
    private def declaration(source : String) : String
      "function (payload, ...handles) { return this.evaluate(payload, handles, (#{source})); }"
    end

    # The same wrapper for a function the utility script already defines.
    #
    # The name is a literal from this shard and never anything a caller supplied,
    # and it is still quoted rather than interpolated bare — the moment that
    # stops being true by accident, this is the line that would have to change.
    private def utility_declaration(name : String) : String
      "function (payload, ...handles) { return this.invoke(#{name.to_json}, payload, handles); }"
    end

    # Evaluates the utility script once, and keeps the object it returns.
    private def utility_object_id(progress : Progress) : String
      if existing = @mutex.synchronize { @utility_object_id }
        return existing
      end

      response = execute(CDP::Protocol::Runtime::EvaluateRequest.new(
        expression: UTILITY_SCRIPT,
        unique_context_id: @unique_id,
        return_by_value: false,
        await_promise: false,
        object_group: @object_group,
      ), progress)

      if details = response.exception_details
        raise evaluation_error(details)
      end

      object_id = response.result.object_id
      raise SerializationError.new("the utility script did not produce an object") unless object_id
      @mutex.synchronize { @utility_object_id ||= object_id }
      object_id
    end

    # Sends a command, translating "that context is gone" into our own error.
    #
    # Chrome reports a destroyed context as a generic `-32000` whose text is the
    # only thing distinguishing it from any other internal error. Letting that
    # through would make every retry loop above match on English prose.
    private def execute(request, progress : Progress, what : String? = nil)
      progress.check!
      @session.execute(request, progress.remaining)
    rescue error : CDP::ProtocolError
      raise ContextDestroyedError.new(error.message.to_s) if context_gone?(error)
      raise error
    rescue error : CDP::TimeoutError
      # Named here rather than logged before every call. A line per round trip
      # doubles the length of a message whose whole value is that it reads in
      # one glance: "waiting for the element to be visible, enabled, stable"
      # followed by "running checkStates" says the same thing twice. The name
      # earns its place only when the deadline expires inside the call, which is
      # the one case where the log otherwise stops mid-step and blames the
      # protocol for whatever this shard happened to be asking.
      raise progress.timed_out(what ? "  running #{what} in #{world_description}: #{error.message}" : error.message)
    end

    # Which world, without the random suffix that makes the name unrepeatable.
    private def world_description : String
      @name.empty? ? "the page's own world" : "the isolated world"
    end

    private def context_gone?(error : CDP::ProtocolError) : Bool
      text = error.message.to_s
      text.includes?("Cannot find context") ||
        text.includes?("Execution context was destroyed") ||
        text.includes?("Inspected target navigated or closed") ||
        text.includes?("Session with given id not found")
    end

    private def evaluation_error(details : CDP::Protocol::Runtime::ExceptionDetails) : EvaluationError
      thrown = details.exception
      described = thrown.try(&.description) || thrown.try(&.value).try(&.to_s)
      EvaluationError.new(described || details.text, details.stack_trace.try(&.description))
    end

    private def track_issue : Nil
      @mutex.synchronize { @issued += 1 }
    end

    private def track_release : Nil
      @mutex.synchronize { @released += 1 }
    end
  end
end
