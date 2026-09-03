require "./lifecycle"

module Crystalwright
  # Whether one frame's network has gone quiet, and when it will.
  #
  # Deliberately knows nothing about `CDP::Session`: it takes what the protocol
  # said and answers questions. That is what makes the rule testable without a
  # browser, which matters because the rule has three edges Chrome will not
  # reproduce on demand — a redirect that reuses its request id, a request that
  # fails instead of finishing, and a document that commits with requests still
  # in the air.
  #
  # There is no timer and no fiber. Idleness is a property computed from the
  # clock, so nothing has to be scheduled, cancelled and rescheduled every time
  # a page asks for an image. A waiter that needs to be woken when idleness
  # arrives asks `idle_in` how long that will be.
  class NetworkAccountant
    # How long the quiet has to last.
    getter window : Time::Span

    # Request id to the loader whose document asked for it. A set would do for
    # the tally; the loader is what makes a request attributable to a document
    # that may since have been replaced.
    @inflight = Hash(String, String).new
    @quiet_since : Time::Instant?

    def initialize(@window : Time::Span = NETWORK_IDLE_WINDOW, now : Time::Instant = Time.instant)
      @quiet_since = now
    end

    # Records a request going out.
    #
    # A redirect arrives as a second `Network.requestWillBeSent` carrying the
    # *same* request id and a `redirectResponse`, and the pair produces exactly
    # one completion. Measured. Counting the continuation as a second request
    # leaves the tally permanently one short of draining, so `networkidle`
    # never fires again for the life of the document — on any page with a
    # single redirect anywhere in it.
    def started(request_id : String, loader_id : String, redirect_continuation : Bool = false) : Nil
      return if redirect_continuation
      @inflight[request_id] = loader_id
      @quiet_since = nil
    end

    # Records a request finishing, whether it succeeded or failed.
    #
    # An id that was never counted is ignored rather than being an error: a page
    # that was already loading when we attached will report completions for
    # requests nobody saw begin.
    def finished(request_id : String, now : Time::Instant = Time.instant) : Nil
      return unless @inflight.delete(request_id)
      @quiet_since = now if @inflight.empty?
    end

    # Starts the clock again for a new document, and forgets the last one's.
    #
    # Not a plain clear, and not a plain keep. The committing document's own
    # request is still in the air at this moment — the commit arrives between
    # its `requestWillBeSent` and its `loadingFinished` — so emptying the tally
    # would declare the network quiet while the page is still downloading. But
    # keeping everything is worse, and it was what this did:
    #
    # **Chrome does not report a request the old document abandoned.** Measured,
    # after a real site would not go idle: a `fetch()` still waiting on its
    # response when the page navigates away produces no `loadingFinished` and no
    # `loadingFailed`, ever. One of those and the frame's tally never drains
    # again — `networkidle` is unreachable for the rest of the page's life, and
    # the failure appears one navigation after the page that caused it.
    #
    # The loader is what tells the two apart. Everything the new document asked
    # for already carries the new loader id, including its own main request, and
    # everything the old one asked for carries the old.
    def restart(loader_id : String, now : Time::Instant = Time.instant) : Nil
      @inflight.reject! { |_, loader| loader != loader_id }
      @quiet_since = @inflight.empty? ? now : nil
    end

    # How many requests are outstanding.
    def in_flight : Int32
      @inflight.size
    end

    # Whether the network has been quiet for the whole window.
    def idle?(now : Time::Instant = Time.instant) : Bool
      since = @quiet_since
      return false unless since
      now - since >= @window
    end

    # How long until `idle?` turns true, or `nil` while something is in flight.
    #
    # A waiter needs this because idleness arrives through the passage of time
    # and not through an event: there is no message from the browser to wake up
    # on, so the waiter has to be told when to look again.
    def idle_in(now : Time::Instant = Time.instant) : Time::Span?
      since = @quiet_since
      return unless since
      left = @window - (now - since)
      left.positive? ? left : Time::Span.zero
    end
  end
end
