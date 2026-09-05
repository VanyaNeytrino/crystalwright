require "./errors"
require "./locator"

module Crystalwright
  # Assertions that wait.
  #
  # `expect(locator).to_have_text("Saved")` does not ask once and fail. It asks,
  # and keeps asking until the answer is the one wanted or the deadline passes —
  # which is the only shape that works against a page, where every answer is
  # about a moment and the interesting moment is usually a few frames away.
  #
  # Three steps, repeated: resolve the locator, ask the page one question about
  # what it found, compare. Resolving again each time is what makes this work
  # across a re-render; a version that resolved once would be asserting about a
  # node the page had already thrown away.
  class LocatorAssertions
    # :nodoc:
    def initialize(@locator : Locator, @negated : Bool = false)
    end

    # The opposite of whatever follows.
    #
    # ```
    # expect(page.get_by_text("Error")).not.to_be_visible
    # ```
    def not : LocatorAssertions
      LocatorAssertions.new(@locator, !@negated)
    end

    # It is in the document, has a box, and is not `visibility: hidden`.
    def to_be_visible(timeout : Time::Span? = nil) : Nil
      state("to_be_visible", "visible", timeout) { |element| element.visible? }
    end

    # It is absent, or has no box.
    def to_be_hidden(timeout : Time::Span? = nil) : Nil
      settle("to_be_hidden", "hidden", timeout) do
        found = @locator.element(1.second)
        begin
          hidden = found.nil? || !found.visible?
          {hidden, hidden ? "hidden" : "visible"}
        ensure
          found.try &.dispose
        end
      end
    end

    # It is not disabled.
    def to_be_enabled(timeout : Time::Span? = nil) : Nil
      element_state("to_be_enabled", "enabled", timeout)
    end

    # It is disabled.
    def to_be_disabled(timeout : Time::Span? = nil) : Nil
      element_state("to_be_disabled", "disabled", timeout)
    end

    # It is a control that can be typed into.
    def to_be_editable(timeout : Time::Span? = nil) : Nil
      element_state("to_be_editable", "editable", timeout)
    end

    # Its text is exactly this, once whitespace is collapsed.
    def to_have_text(expected : String | Regex, timeout : Time::Span? = nil) : Nil
      compare("to_have_text", expected, timeout, READ_TEXT, EXACTLY)
    end

    # Its text contains this.
    def to_contain_text(expected : String | Regex, timeout : Time::Span? = nil) : Nil
      compare("to_contain_text", expected, timeout, READ_TEXT, WITHIN)
    end

    # The value of the input, textarea, select or contenteditable it names.
    def to_have_value(expected : String | Regex, timeout : Time::Span? = nil) : Nil
      compare("to_have_value", expected, timeout, READ_VALUE, EXACTLY)
    end

    # One of its attributes has this value.
    def to_have_attribute(name : String, expected : String | Regex, timeout : Time::Span? = nil) : Nil
      compare("to_have_attribute(#{name.inspect})", expected, timeout,
        ->(element : ElementHandle) { element.get_attribute(name) }, EXACTLY)
    end

    # It names exactly this many elements.
    #
    # The one assertion that is not strict, because counting is how a caller
    # discovers there is more than one.
    def to_have_count(expected : Int32, timeout : Time::Span? = nil) : Nil
      settle("to_have_count", expected.to_s, timeout) do
        actual = @locator.count(1.second)
        {actual == expected, actual.to_s}
      end
    end

    private def state(what : String, wanted : String, timeout : Time::Span?, &check : ElementHandle -> Bool) : Nil
      settle(what, wanted, timeout) do
        found = @locator.element(1.second)
        begin
          next {false, "not found"} unless found
          held = check.call(found)
          {held, held ? wanted : "not #{wanted}"}
        ensure
          found.try &.dispose
        end
      end
    end

    private def element_state(what : String, wanted : String, timeout : Time::Span?) : Nil
      settle(what, wanted, timeout) do
        found = @locator.element(1.second)
        begin
          next {false, "not found"} unless found
          answer = found.state(wanted, 1.second)
          {answer[0], answer[1]}
        ensure
          found.try &.dispose
        end
      end
    end

    private def compare(what : String, expected : String | Regex, timeout : Time::Span?,
                        read : ElementHandle -> String?, test : String, String | Regex -> Bool) : Nil
      settle(what, expected.is_a?(Regex) ? expected.inspect : expected.inspect, timeout) do
        found = @locator.element(1.second)
        begin
          next {false, "not found"} unless found
          actual = read.call(found) || ""
          {test.call(actual, expected.as(String | Regex)), actual.inspect}
        ensure
          found.try &.dispose
        end
      end
    end

    # A regular expression is always a search, so `to_have_text(/^Saved$/)` and
    # `to_contain_text(/Saved/)` differ in the pattern rather than in the check.
    # A plain string is compared whole for one and searched for in the other,
    # which is the distinction people expect from the two names.
    EXACTLY = ->(actual : String, wanted : String | Regex) do
      wanted.is_a?(Regex) ? !wanted.match(actual).nil? : actual == wanted
    end

    WITHIN = ->(actual : String, wanted : String | Regex) do
      wanted.is_a?(Regex) ? !wanted.match(actual).nil? : actual.includes?(wanted)
    end

    READ_TEXT  = ->(element : ElementHandle) { element.text.as(String?) }
    READ_VALUE = ->(element : ElementHandle) { element.value }

    # Ask, compare, wait, ask again.
    #
    # The probe is allowed to fail: an element that is not there yet is one of
    # the ordinary answers, not an error, and the whole point of waiting is that
    # the first answer is often the wrong one.
    private def settle(what : String, expected : String, timeout : Time::Span?,
                       &probe : -> Tuple(Bool, String)) : Nil
      progress = Progress.new("expect(#{@locator.selector}).#{what}", timeout || @locator.frame.default_timeout)
      seen = "nothing yet"

      loop do
        begin
          matched, actual = probe.call
          seen = actual
          return if matched != @negated
        rescue error : StrictModeError
          # Ambiguity will be just as true in thirty seconds.
          raise error
        rescue error : Error | CDP::Error
          seen = error.message.to_s.lines.first? || error.class.name
        end

        if progress.expired?
          raise AssertionError.new(
            "expect(#{@locator.selector}).#{@negated ? "not." : ""}#{what} failed after #{progress.timeout.total_seconds}s\n  expected: #{@negated ? "not " : ""}#{expected}\n  \
             actual:   #{seen}")
        end
        sleep({SELECTOR_POLL, progress.remaining}.min)
      end
    end
  end

  # Starts an assertion that waits.
  def self.expect(locator : Locator) : LocatorAssertions
    LocatorAssertions.new(locator)
  end
end
