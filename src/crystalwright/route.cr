require "base64"
require "cdp"
require "./errors"
require "./url_pattern"

module Crystalwright
  # A request the browser has stopped and is waiting to be told about.
  #
  # Exactly one of `fulfill`, `abort` or `continue` has to be called, and only
  # once. That is not a style rule: the browser is holding the request open, and
  # a handler that returns without answering leaves the page waiting until its
  # own timeout, which looks like a slow server and is not one.
  class Route
    # What the page asked for.
    getter request : CDP::Protocol::Network::Request

    # What kind of resource it is — `Document`, `XHR`, `Image` and so on.
    getter resource_type : CDP::Protocol::Network::ResourceType

    @answered = false
    @mutex = Sync::Mutex.new

    # :nodoc:
    def initialize(@session : CDP::Session, @request_id : String,
                   @request : CDP::Protocol::Network::Request,
                   @resource_type : CDP::Protocol::Network::ResourceType)
    end

    # The address that was asked for.
    def url : String
      @request.url
    end

    # The method that was used.
    def method : String
      @request.method
    end

    # Answers with a response of your own, without the request leaving the
    # machine.
    def fulfill(status : Int32 = 200, body : String = "",
                headers : Hash(String, String) = {} of String => String,
                content_type : String? = nil) : Nil
      answer_once("fulfill")

      wire = headers.map { |name, value| CDP::Protocol::Fetch::HeaderEntry.new(name: name, value: value) }
      wire << CDP::Protocol::Fetch::HeaderEntry.new(name: "Content-Type", value: content_type) if content_type

      @session.execute(CDP::Protocol::Fetch::FulfillRequestRequest.new(
        request_id: @request_id,
        response_code: status,
        response_headers: wire,
        # Base64 because the body is bytes as far as the protocol is concerned,
        # and a JSON string cannot carry every byte.
        body: Base64.strict_encode(body),
      ), 10.seconds)
    end

    # Refuses the request, the way a blocked or failed one is refused.
    def abort(reason : CDP::Protocol::Network::ErrorReason = CDP::Protocol::Network::ErrorReason::Failed) : Nil
      answer_once("abort")
      @session.execute(CDP::Protocol::Fetch::FailRequestRequest.new(
        request_id: @request_id, error_reason: reason), 10.seconds)
    end

    # Lets it go, optionally changed on the way out.
    def continue(url : String? = nil, method : String? = nil, post_data : String? = nil,
                 headers : Hash(String, String)? = nil) : Nil
      answer_once("continue")
      @session.execute(CDP::Protocol::Fetch::ContinueRequestRequest.new(
        request_id: @request_id,
        url: url,
        method: method,
        post_data: post_data.try { |data| Base64.strict_encode(data) },
        headers: headers.try(&.map { |name, value| CDP::Protocol::Fetch::HeaderEntry.new(name: name, value: value) }),
      ), 10.seconds)
    end

    # :nodoc:
    #
    # Whether anybody has answered yet, so that an unhandled request can be let
    # through rather than left hanging.
    protected def answered? : Bool
      @mutex.synchronize { @answered }
    end

    private def answer_once(what : String) : Nil
      already = @mutex.synchronize do
        was = @answered
        @answered = true
        was
      end
      return unless already
      raise Error.new("This route has already been answered, so #{what} has nothing to do. \
                       A request can be fulfilled, aborted or continued exactly once.")
    end
  end

  # :nodoc:
  #
  # One registered handler: which addresses it wants, and what to do with them.
  class RouteHandler
    getter pattern : URLPattern

    def initialize(@pattern : URLPattern, @handler : Route -> Nil)
    end

    def handles?(url : String) : Bool
      @pattern.matches?(url)
    end

    def call(route : Route) : Nil
      @handler.call(route)
    end
  end
end
