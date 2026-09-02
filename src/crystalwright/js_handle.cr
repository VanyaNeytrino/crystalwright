require "cdp"
require "./errors"
require "./js_value"
require "./serialization"
require "./execution_context"

module Crystalwright
  # A reference to a value that stayed in the page.
  #
  # `evaluate` copies a value out; `evaluate_handle` leaves it where it is and
  # hands back one of these. That matters for two reasons. Some values cannot be
  # copied at all — a DOM node, a function, a `Window` — and some should not be:
  # copying a large object out and back in is two serialisations and a lot of
  # bytes to answer a question the page could have answered in place.
  #
  # A handle keeps memory alive in the browser until it is disposed or its
  # context goes away with a navigation.
  class JSHandle
    include RemoteReference

    # The `Runtime.RemoteObjectId` this handle stands for.
    getter remote_object_id : String

    # The world this handle belongs to. It is only valid there.
    getter context : ExecutionContext

    # What the browser said about the value when the handle was made.
    getter remote_object : CDP::Protocol::Runtime::RemoteObject

    @disposed = false
    @mutex = Sync::Mutex.new

    # :nodoc:
    def initialize(@context : ExecutionContext, @remote_object_id : String, @remote_object : CDP::Protocol::Runtime::RemoteObject)
    end

    # Whether this handle has been released.
    def disposed? : Bool
      @mutex.synchronize { @disposed }
    end

    # Evaluates with this handle as the first argument.
    #
    # ```
    # length = handle.evaluate("(node, suffix) => node.textContent + suffix", "!")
    # ```
    def evaluate(source : String, *args, progress : Progress? = nil) : JSValue
      guard
      @context.evaluate(source, self, *args, progress: progress)
    end

    # Evaluates with this handle as the first argument, leaving the result in
    # the page.
    def evaluate_handle(source : String, *args, progress : Progress? = nil) : JSHandle
      guard
      @context.evaluate_handle(source, self, *args, progress: progress)
    end

    # A handle to one property.
    def get_property(name : String, progress : Progress? = nil) : JSHandle
      evaluate_handle("(object, key) => object[key]", name, progress: progress)
    end

    # Handles to every own enumerable property.
    def get_properties(progress : Progress? = nil) : Hash(String, JSHandle)
      guard
      response = @context.session.execute(
        CDP::Protocol::Runtime::GetPropertiesRequest.new(
          object_id: @remote_object_id, own_properties: true, generate_preview: false),
        (progress || Progress.new("get_properties", DEFAULT_TIMEOUT)).remaining)

      properties = {} of String => JSHandle
      response.result.each do |property|
        next unless property.enumerable
        value = property.value
        next unless value
        object_id = value.object_id
        next unless object_id
        properties[property.name] = @context.adopt(object_id, value)
      end
      properties
    end

    # Copies this value out of the page.
    def json_value(progress : Progress? = nil) : JSValue
      evaluate("(value) => value", progress: progress)
    end

    # Releases the reference.
    #
    # Safe to call more than once, and safe on a handle whose page navigated —
    # the value is already gone, which is what was being asked for.
    def dispose : Nil
      already = @mutex.synchronize do
        was = @disposed
        @disposed = true
        was
      end
      return if already
      @context.release(@remote_object_id)
    end

    # A short description of what the page has, for error messages.
    def to_s(io : IO) : Nil
      io << "#<JSHandle "
      io << (@remote_object.description || @remote_object.type.to_wire)
      io << " (disposed)" if disposed?
      io << '>'
    end

    private def guard : Nil
      raise Error.new("This handle has been disposed and no longer refers to anything.") if disposed?
      raise ContextDestroyedError.new if @context.destroyed?
    end
  end
end
