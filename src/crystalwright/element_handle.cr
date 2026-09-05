require "./js_handle"
require "./input"

module Crystalwright
  # How far along an element has to be before a wait is satisfied.
  enum ElementState
    # It is in the document. Says nothing about whether anyone can see it.
    Attached

    # It is in the document, has a box, and is not `visibility: hidden`.
    Visible

    # It is either not in the document or not visible. The opposite of
    # `Visible`, and not the same as `Detached`.
    Hidden

    # It is not in the document at all.
    Detached

    # :nodoc:
    def to_wire : String
      to_s.downcase
    end
  end

  # How long to wait before each retry of an action.
  #
  # Playwright's array, carried across rather than reinvented. It is not a curve
  # anybody would derive: the first two retries are effectively immediate,
  # because most failures are a frame of layout settling, and only a genuinely
  # stuck page reaches the half-second at the end.
  RETRY_DELAYS = [
    Time::Span.zero,
    20.milliseconds,
    100.milliseconds,
    100.milliseconds,
    500.milliseconds,
  ]

  # The scroll anchorings an action rotates through, one per attempt.
  #
  # `nil` is the browser's own "scroll it just far enough", which is right
  # almost always and wrong in one specific way: it parks the element exactly at
  # the edge it scrolled from, which on a page with a sticky header means
  # underneath it. The three explicit anchorings are the way out, and rotating
  # through them costs nothing when the first one works.
  SCROLL_ALIGNMENTS = [nil, "end", "center", "start"]

  # Why an action could not be performed yet.
  #
  # Every one of these is a reason to try again rather than to give up: the
  # element was replaced, or is still moving, or something is on top of it. The
  # deadline is what decides when trying again stops being worth it, which is
  # why none of these is an exception.
  enum ActionFailure
    # The node went away. The selector has to be resolved again.
    NotConnected

    # It has no box at all, so there is nowhere to aim.
    NotVisible

    # It has a box, and none of it is on the screen.
    NotInViewport

    # It is not yet visible, stable, enabled or editable — `detail` says which.
    MissingState

    # Something else would receive the click — `detail` names it.
    HitTarget

    # What was asked for is not on the page yet — `detail` says what. Distinct
    # from a missing state: the element is there and fine, and the thing named
    # inside it is what has not appeared, which a script may still add.
    NotFound
  end

  # What one attempt at an action came to.
  struct ActionOutcome
    # The reason to try again, or `nil` when the attempt succeeded.
    getter failure : ActionFailure?

    # What was missing, or what was in the way.
    getter detail : String?

    def initialize(@failure : ActionFailure? = nil, @detail : String? = nil)
    end

    # :nodoc:
    def self.done : ActionOutcome
      new
    end

    def done? : Bool
      @failure.nil?
    end

    # One line for the progress log, which is what a failure prints.
    def to_s(io : IO) : Nil
      case @failure
      in Nil                          then io << "done"
      in ActionFailure::NotConnected  then io << "the element was replaced or removed"
      in ActionFailure::NotVisible    then io << "the element is not visible"
      in ActionFailure::NotInViewport then io << "the element is outside the viewport"
      in ActionFailure::MissingState  then io << "the element is not " << (@detail || "ready")
      in ActionFailure::HitTarget     then io << (@detail || "something else") << " intercepts pointer events"
      in ActionFailure::NotFound      then io << (@detail || "what was asked for") << " is not there"
      end
    end
  end

  # A handle to an element in the page.
  #
  # Everything here runs in the isolated world, which is why none of it can be
  # fooled by a page that reassigns `document.querySelector` or
  # `Element.prototype.getBoundingClientRect`: measured, that world has its own
  # copies of every built-in, and the page's are not among them. The elements
  # themselves are shared — there is one DOM — so what is read here is what the
  # page has.
  class ElementHandle < JSHandle
    # The first element inside this one matching the selector, or `nil`.
    def query_selector(selector : String, timeout : Time::Span? = nil) : ElementHandle?
      progress = Progress.new("query_selector #{selector}", timeout || DEFAULT_TIMEOUT)
      guard
      @context.invoke_element("querySelector", selector, self, progress: progress)
    end

    # Every element inside this one matching the selector.
    def query_selector_all(selector : String, timeout : Time::Span? = nil) : Array(ElementHandle)
      progress = Progress.new("query_selector_all #{selector}", timeout || DEFAULT_TIMEOUT)
      guard
      @context.invoke_elements("querySelectorAll", selector, self, progress: progress)
    end

    # The element's text, including text in elements inside it.
    def text_content(timeout : Time::Span? = nil) : String?
      call("textContent", timeout).as_s?
    end

    # The element's text as rendered, which is not the same thing: this is what
    # a person would read, with hidden elements left out and whitespace as the
    # layout produced it.
    def inner_text(timeout : Time::Span? = nil) : String
      call("innerText", timeout).as_s
    end

    # One attribute, or `nil` when the element does not carry it.
    def get_attribute(name : String, timeout : Time::Span? = nil) : String?
      progress = Progress.new("get_attribute #{name}", timeout || DEFAULT_TIMEOUT)
      guard
      @context.invoke("getAttribute", self, name, progress: progress).as_s?
    end

    # Whether the element has a box and is not `visibility: hidden`.
    #
    # Deliberately not the whole question of whether it can be clicked — that
    # also involves being stable, enabled, and actually on top at the point the
    # click would land, and those belong with clicking.
    def visible?(timeout : Time::Span? = nil) : Bool
      call("visible", timeout).as_bool
    end

    # A short description of the element, for failure messages.
    def preview(timeout : Time::Span? = nil) : String
      call("previewNode", timeout).as_s
    rescue Error | CDP::Error
      "<an element that could no longer be described>"
    end

    # :inherit:
    def to_s(io : IO) : Nil
      io << "#<ElementHandle "
      io << (disposed? || @context.destroyed? ? (@remote_object.description || "element") : preview(5.seconds))
      io << " (disposed)" if disposed?
      io << '>'
    end

    # ---- what an action needs to know, all of it answered by the page --------

    # :nodoc:
    #
    # Waits for the element to reach every one of these states.
    #
    # Stability is measured inside the page across animation frames rather than
    # by sampling twice from here: an element moving smoothly is caught on the
    # very next frame, and one already at rest costs two frames instead of a
    # fixed guess. It is also the only check that takes time, which is why it
    # goes first — nothing else is worth asking about something still in motion.
    protected def check_states(states : Array(String), progress : Progress) : ActionOutcome
      answer = @context.invoke("checkStates", self, states, progress: progress)
      return ActionOutcome.new(ActionFailure::NotConnected) if answer["notConnected"]?.try(&.as_bool?)
      if missing = answer["missingState"]?.try(&.as_s?)
        return ActionOutcome.new(ActionFailure::MissingState, missing)
      end
      ActionOutcome.done
    end

    # :nodoc:
    #
    # Brings the element on screen. `alignment` of `nil` means the browser's own
    # "scroll it just far enough", and anything else is an explicit anchoring —
    # which is what gets an element out from under a sticky header the built-in
    # scroll parks it behind.
    protected def scroll_into_view(alignment : String?, progress : Progress) : ActionOutcome
      if alignment
        options = JSON::Any.new({"block" => JSON::Any.new(alignment), "inline" => JSON::Any.new(alignment)})
        answer = @context.invoke("scrollIntoView", self, options, progress: progress)
        return ActionOutcome.new(ActionFailure::NotConnected) if answer["notConnected"]?.try(&.as_bool?)
        return ActionOutcome.done
      end

      Crystalwright.command(@context.session, CDP::Protocol::DOM::ScrollIntoViewIfNeededRequest.new(
        object_id: @remote_object_id), progress, "DOM.scrollIntoViewIfNeeded")
      ActionOutcome.done
    rescue error : CDP::ProtocolError
      # "Node does not have a layout object" and friends: the element is not
      # where it was, which is a retry rather than a failure.
      ActionOutcome.new(ActionFailure::NotConnected, error.message)
    end

    # :nodoc:
    #
    # Where to aim.
    #
    # Content quads rather than a bounding box, because a box is wrong for
    # anything rotated and for an inline element that wraps across lines — the
    # rectangle enclosing both halves of a wrapped link has a middle that is on
    # neither half.
    protected def clickable_point(progress : Progress) : Point | ActionOutcome
      quads = Crystalwright.command(@context.session, CDP::Protocol::DOM::GetContentQuadsRequest.new(
        object_id: @remote_object_id), progress, "DOM.getContentQuads").quads
      return ActionOutcome.new(ActionFailure::NotVisible) if quads.empty?

      viewport = @context.invoke("viewport", progress: progress)
      width = viewport["width"].as_f
      height = viewport["height"].as_f

      usable = quads.map { |quad| clip(quad, width, height) }.select { |quad| area(quad) > 0.99 }
      return ActionOutcome.new(ActionFailure::NotInViewport) if usable.empty?

      corners = usable.first
      x = corners.each_slice(2).sum { |pair| pair[0] } / 4
      y = corners.each_slice(2).sum { |pair| pair[1] } / 4
      Point.new(((x * 100).to_i / 100.0), ((y * 100).to_i / 100.0))
    rescue error : CDP::ProtocolError
      ActionOutcome.new(ActionFailure::NotConnected, error.message)
    end

    # :nodoc:
    #
    # Checks nothing is in the way, and starts watching in case something
    # arrives while the events are in flight.
    protected def intercept_hit_target(action : String, point : Point, token : String, progress : Progress) : ActionOutcome
      read(@context.invoke("interceptHitTarget", self, action, point.x, point.y, token, progress: progress))
    end

    # :nodoc:
    #
    # Stops watching, and says whether anything got in the way after all.
    protected def stop_intercepting(token : String, progress : Progress) : ActionOutcome
      read(@context.invoke("stopInterception", token, progress: progress))
    rescue ContextDestroyedError | CDP::Error
      # The action navigated the page, which took the interceptor with it. That
      # is a successful click, not a failed one.
      ActionOutcome.done
    end

    # :nodoc:
    protected def prepare_fill(value : String, progress : Progress) : ActionOutcome
      answer = @context.invoke("prepareFill", self, value, progress: progress)
      outcome = read(answer)
      return outcome unless answer["needsTyping"]?.try(&.as_bool?)
      ActionOutcome.done
    end

    # :nodoc:
    protected def focus(progress : Progress) : ActionOutcome
      read(@context.invoke("focus", self, progress: progress))
    end

    # The element's text with whitespace collapsed, as the selector engine sees
    # it.
    #
    # Normalised in the page rather than here, so that an assertion and a
    # `text=` selector cannot disagree about what the text is.
    def text(timeout : Time::Span? = nil) : String
      call("text", timeout).as_s
    end

    # Whether the element is in a named state, and what it is instead.
    #
    # Returns both, because an assertion that fails has to say what was actually
    # there — "expected enabled" on its own tells the reader what they already
    # typed.
    def state(name : String, timeout : Time::Span? = nil) : Tuple(Bool, String)
      progress = Progress.new("state #{name}", timeout || DEFAULT_TIMEOUT)
      guard
      answer = @context.invoke("elementState", self, name, progress: progress)
      {answer["matches"].as_bool, answer["received"].as_s}
    end

    # The ARIA role a screen reader would report for this element, or `nil`.
    #
    # Public because "why did `get_by_role` not find this?" is a question a
    # caller has to be able to answer without reading this shard's source. The
    # answer is usually that the element's role is not the one it looks like:
    # a `<section>` with no accessible name has no role at all, an `<img>` with
    # an empty `alt` is presentational, and a `<th>` is a column header or a row
    # header depending on its neighbours.
    def aria_role(timeout : Time::Span? = nil) : String?
      call("ariaRole", timeout).as_s?
    end

    # What a screen reader would read out for this element.
    #
    # Empty rather than `nil` when the element has no name: "unnamed" is an
    # answer here, not a failure. `include_hidden` computes the name the element
    # *would* have if it were shown, which is what a locator asking about a
    # hidden element needs.
    def accessible_name(include_hidden : Bool = false, timeout : Time::Span? = nil) : String
      progress = Progress.new("accessible_name", timeout || DEFAULT_TIMEOUT)
      guard
      @context.invoke("accessibleName", self, include_hidden, progress: progress).as_s? || ""
    end

    # :nodoc:
    protected def select_options(wanted : Array(Hash(String, JSON::Any)), progress : Progress) : JSValue
      @context.invoke("selectOptions", self, wanted, progress: progress)
    end

    # The current value of an input, textarea, select or contenteditable.
    def value(timeout : Time::Span? = nil) : String?
      call("value", timeout).as_s?
    end

    private def read(answer : JSValue) : ActionOutcome
      return ActionOutcome.new(ActionFailure::NotConnected) if answer["notConnected"]?.try(&.as_bool?)
      if description = answer["hitTargetDescription"]?.try(&.as_s?)
        return ActionOutcome.new(ActionFailure::HitTarget, description)
      end
      if missing = answer["missingState"]?.try(&.as_s?)
        return ActionOutcome.new(ActionFailure::MissingState, missing)
      end
      ActionOutcome.done
    end

    private def clip(quad : Array(Float64), width : Float64, height : Float64) : Array(Float64)
      clipped = Array(Float64).new(8)
      quad.each_slice(2) do |pair|
        clipped << pair[0].clamp(0.0, width)
        clipped << pair[1].clamp(0.0, height)
      end
      clipped
    end

    # The shoelace formula. A quad clipped to nothing has zero area, which is
    # how "the element is off screen" is told from "the element has no box".
    private def area(quad : Array(Float64)) : Float64
      points = quad.each_slice(2).to_a
      total = 0.0
      points.each_with_index do |point, index|
        following = points[(index + 1) % points.size]
        total += (point[0] * following[1] - following[0] * point[1]) / 2
      end
      total.abs
    end

    private def call(name : String, timeout : Time::Span?) : JSValue
      progress = Progress.new(name, timeout || DEFAULT_TIMEOUT)
      guard
      @context.invoke(name, self, progress: progress)
    end
  end
end
