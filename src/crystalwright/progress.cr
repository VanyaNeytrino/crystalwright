require "./errors"

module Crystalwright
  # How long an operation gets when the caller does not say.
  #
  # Thirty seconds, matching Playwright, because the number is not really about
  # speed: it is how long a person will wait before deciding something is stuck.
  DEFAULT_TIMEOUT = 30.seconds

  # Issues one protocol command inside an operation's budget.
  #
  # Every protocol call on a public operation's path has to come through here,
  # and the reason is a promise rather than tidiness. The shard below raises
  # `CDP::TimeoutError`, which is true and is not what this shard undertakes: a
  # caller who asked for a click and gave it a deadline gets this shard's
  # `TimeoutError`, carrying the log of what was tried, or nothing at all. Only
  # one call site used to translate it, so `DOM.scrollIntoViewIfNeeded` escaped
  # raw out of `click` — found by the gate on the eighth run at parallelism 8,
  # after seventeen runs that did not.
  #
  # It also checks the budget first. Without that a call is issued with whatever
  # is left even when that is half a millisecond, and the failure that comes
  # back describes the protocol giving up rather than the operation running out
  # — which is the same failure wearing a different coat.
  def self.command(session, request, progress : Progress?, what : String, fallback : Time::Span = 5.seconds)
    progress.try(&.check!)
    session.execute(request, progress.try(&.remaining) || fallback)
  rescue error : CDP::TimeoutError
    raise progress ? progress.timed_out("  running #{what}: #{error.message}") : TimeoutError.new(what, fallback, error.message.to_s)
  end

  # One deadline for a whole operation, and a record of what it tried.
  #
  # Deliberately not a timeout per attempt. An action here is a loop — resolve
  # the selector, check the element is stable, aim, click, discover the node was
  # replaced, start again — and giving each attempt its own clock means the
  # caller's thirty seconds turns into however many attempts happen to occur.
  # One clock, entered at the top, consulted by everything underneath.
  #
  # The log is the other half of it. An action that fails after twelve attempts
  # has to be able to say what it saw on each of them, because the alternative
  # is debugging a live website by guessing.
  class Progress
    # What the whole operation is, e.g. `"evaluate"`.
    getter operation : String

    # The budget the operation was given.
    getter timeout : Time::Span

    @deadline : Time::Instant
    @entries = [] of String
    @mutex = Sync::Mutex.new

    def initialize(@operation : String, @timeout : Time::Span)
      @deadline = Time.instant + @timeout
    end

    # How much of the budget is left, never negative.
    def remaining : Time::Span
      left = @deadline - Time.instant
      left.positive? ? left : Time::Span.zero
    end

    # Whether the budget is gone.
    def expired? : Bool
      remaining.zero?
    end

    # Notes something that was tried, for the failure message.
    def log(message : String) : Nil
      @mutex.synchronize { @entries << message }
    end

    # Raises if the budget is gone, with everything that was tried.
    def check! : Nil
      raise timed_out if expired?
    end

    # The error this operation would fail with right now.
    def timed_out(detail : String? = nil) : TimeoutError
      entries = @mutex.synchronize { @entries.dup }
      entries << detail if detail
      TimeoutError.new(@operation, @timeout, entries.empty? ? nil : entries.join('\n'))
    end
  end
end
