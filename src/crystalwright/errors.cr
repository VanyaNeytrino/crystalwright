module Crystalwright
  # Base class for everything this shard raises.
  #
  # Every error lives in this one file, following `CDP::Error`: scattering
  # exception classes next to the code that raises them means nobody can answer
  # "what can this call throw?" without reading the whole shard.
  #
  # Errors from the layer below arrive as `CDP::Error` and are deliberately not
  # wrapped. A timeout on the socket is not the same event as a timeout waiting
  # for an element, and flattening them into one type would lose the distinction
  # exactly when it matters.
  class Error < Exception
  end

  # The page threw while evaluating.
  #
  # Carries what JavaScript said rather than a protocol code, because the
  # interesting part is the exception the page raised, not the fact that
  # `Runtime.callFunctionOn` reported one.
  class EvaluationError < Error
    # The `stack` of the JavaScript error, when it had one.
    getter js_stack : String?

    def initialize(message : String, @js_stack : String? = nil)
      super(message)
    end
  end

  # The execution context this call belongs to no longer exists.
  #
  # Ordinary rather than exceptional: every navigation destroys the contexts of
  # the document it left, and every handle into them dies with it. It is its own
  # type so that a retry loop can rescue exactly this and resolve again, which is
  # what "the node was replaced between resolving it and clicking it" needs.
  class ContextDestroyedError < Error
    def initialize(reason : String = "the page navigated")
      super("The execution context was destroyed: #{reason}. Handles and \
             selectors resolved in it have to be resolved again.")
    end
  end

  # The frame this call belongs to has been removed from the page.
  #
  # Its own type rather than a timeout, because the two mean opposite things to
  # a caller: a timeout says "not yet, and I gave up", and this says "never
  # again, stop waiting". A frame that has been detached will never get another
  # execution context, so anything waiting for one is waiting for good.
  class FrameDetachedError < Error
    def initialize(what : String = "the frame")
      super("#{what} was detached from the page. A frame that has been removed \
             never gets another document, so nothing resolved in it can be \
             retried.")
    end
  end

  # A value could not be moved across the JavaScript boundary.
  class SerializationError < Error
  end

  # An operation ran out of its deadline.
  #
  # One deadline covers a whole operation including every retry inside it, so
  # this says what the operation was trying to do, not which internal attempt
  # happened to be in flight when the clock ran out.
  class TimeoutError < Error
    # What the operation was, e.g. `"evaluate"`.
    getter operation : String

    # How long the whole operation was given.
    getter timeout : Time::Span

    def initialize(@operation : String, @timeout : Time::Span, detail : String? = nil)
      text = "#{@operation} timed out after #{@timeout.total_seconds}s"
      text += "\n#{detail}" if detail
      super(text)
    end
  end
end
