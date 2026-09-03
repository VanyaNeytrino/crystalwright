require "./errors"
require "./element_handle"

module Crystalwright
  # A selector under construction.
  #
  # Split out from `Locator` so that the part with all the escaping in it can be
  # tested without a browser. Every rule here is about producing a string that
  # says what was meant no matter what is in the text — and text on a real page
  # contains quotes, backslashes, angle brackets and, sooner or later, `>>`.
  struct SelectorBuilder
    # The selector built so far.
    getter selector : String

    def initialize(@selector : String = "")
    end

    # Appends a step.
    def step(text : String) : SelectorBuilder
      SelectorBuilder.new(@selector.empty? ? text : "#{@selector} >> #{text}")
    end

    def by_text(text : String | Regex, exact : Bool = false) : SelectorBuilder
      step("text=#{SelectorBuilder.body(text, exact)}")
    end

    def by_test_id(id : String) : SelectorBuilder
      step("data-testid=#{id}")
    end

    # `role=button[name="Save"i][checked]`
    #
    # Every value is written as JSON rather than pasted in, for the same reason
    # every other builder here does: a button whose accessible name contains a
    # quote or a `]` is a button with an awkward name, not a way to write a
    # different selector.
    def by_role(role : String, exact : Bool = false, name : String? = nil,
                checked : (Bool | String)? = nil, disabled : Bool? = nil,
                expanded : Bool? = nil, level : Int32? = nil,
                pressed : (Bool | String)? = nil, selected : Bool? = nil,
                include_hidden : Bool = false) : SelectorBuilder
      body = String.build do |io|
        io << role
        if name
          io << "[name=" << name.to_json
          io << 'i' unless exact
          io << ']'
        end
        io << "[checked=" << checked << ']' unless checked.nil?
        io << "[disabled=" << disabled << ']' unless disabled.nil?
        io << "[expanded=" << expanded << ']' unless expanded.nil?
        io << "[level=" << level << ']' if level
        io << "[pressed=" << pressed << ']' unless pressed.nil?
        io << "[selected=" << selected << ']' unless selected.nil?
        io << "[include-hidden=true]" if include_hidden
      end
      step("role=#{body}")
    end

    def by_label(text : String | Regex, exact : Bool = false) : SelectorBuilder
      step("label=#{SelectorBuilder.body(text, exact)}")
    end

    def by_placeholder(text : String | Regex, exact : Bool = false) : SelectorBuilder
      step("placeholder=#{SelectorBuilder.body(text, exact)}")
    end

    def by_alt_text(text : String | Regex, exact : Bool = false) : SelectorBuilder
      step("alt=#{SelectorBuilder.body(text, exact)}")
    end

    def by_title(text : String | Regex, exact : Bool = false) : SelectorBuilder
      step("title=#{SelectorBuilder.body(text, exact)}")
    end

    def narrow(has_text : (String | Regex)? = nil, has : String? = nil, visible : Bool? = nil) : SelectorBuilder
      built = self
      built = built.step("internal:has-text=#{SelectorBuilder.body(has_text, false)}") if has_text
      built = built.step("internal:has=#{has.to_json}") if has
      built = built.step("visible=#{visible}") unless visible.nil?
      built
    end

    def at(index : Int32) : SelectorBuilder
      step("nth=#{index}")
    end

    # The body of a `text=`-style step, quoted so nothing in it reads as syntax.
    #
    # Everything a builder emits is quoted, without exception. An unquoted body
    # is fine when a person writes it and a bug waiting to happen when a builder
    # does: the first `>>` inside would be read as a step separator and the
    # first quote as the start of one. `to_json` is the escaper because the
    # other side parses it with `JSON.parse`, so the two agree by construction
    # rather than by two hand-written escape tables staying in step.
    def self.body(text : (String | Regex)?, exact : Bool) : String
      case text
      in Regex  then "/#{text.source}/#{Crystalwright.javascript_flags(text)}"
      in String then exact ? text.to_json : "#{text.to_json}i"
      in Nil    then raise Error.new("no text was given")
      end
    end

    def to_s(io : IO) : Nil
      io << @selector
    end
  end

  # A way of naming elements, resolved fresh every time it is used.
  #
  # A `Locator` is a builder of selector strings and nothing else. That is not a
  # simplification of Playwright's design — it *is* the design, and it is what
  # makes the lazy re-resolution people describe as the point of locators fall
  # out for free: nothing is held on to, so there is nothing to go stale. A
  # handle refers to one node and dies with it; a locator refers to a question,
  # and the answer is looked up again at every use.
  #
  # Locators are strict. A locator that matches two elements is an error rather
  # than a silent choice of the first, because "the first thing that matched" is
  # exactly the behaviour that turns a renamed button into a test which passes
  # while clicking the wrong control.
  class Locator
    # The frame this locator will be resolved in.
    getter frame : Frame

    # The selector string this locator has built.
    getter selector : String

    # :nodoc:
    def initialize(@frame : Frame, @selector : String)
    end

    # ---- building ------------------------------------------------------------

    # Narrows to elements inside the ones this locator names.
    def locator(selector : String) : Locator
      rebuilt(builder.step(selector))
    end

    # Elements whose text matches.
    #
    # `exact` is false by default, meaning a case-insensitive substring with
    # whitespace collapsed — which is how people describe a button out loud, and
    # is robust against the space a designer adds inside it next week.
    def get_by_text(text : String | Regex, exact : Bool = false) : Locator
      rebuilt(builder.by_text(text, exact))
    end

    # Elements carrying this `data-testid`.
    def get_by_test_id(id : String) : Locator
      rebuilt(builder.by_test_id(id))
    end

    # Elements by the role a screen reader would report, and optionally by the
    # name it would read out.
    #
    # The closest thing here to how a person finds a control, and the reason it
    # is worth the two computations behind it: `get_by_role("button", name:
    # "Save")` keeps working when the markup under it changes, because what it
    # names is what the button *is* rather than where it sits or what class
    # somebody gave it.
    #
    # `name` matches case-insensitively as a substring unless `exact` is set,
    # and is compared after the same whitespace flattening a screen reader
    # applies. Hidden elements are excluded unless `include_hidden` is set —
    # a name is still computed for them as though they were shown, so that
    # "the button is there but hidden" is a thing that can be asked.
    def get_by_role(role : String, exact : Bool = false, name : String? = nil,
                    checked : (Bool | String)? = nil, disabled : Bool? = nil,
                    expanded : Bool? = nil, level : Int32? = nil,
                    pressed : (Bool | String)? = nil, selected : Bool? = nil,
                    include_hidden : Bool = false) : Locator
      rebuilt(builder.by_role(role, exact, name, checked, disabled, expanded,
        level, pressed, selected, include_hidden))
    end

    # The control a `<label>` names, or an element with this `aria-label`.
    def get_by_label(text : String | Regex, exact : Bool = false) : Locator
      rebuilt(builder.by_label(text, exact))
    end

    # Elements whose `placeholder` matches.
    def get_by_placeholder(text : String | Regex, exact : Bool = false) : Locator
      rebuilt(builder.by_placeholder(text, exact))
    end

    # Elements whose `alt` matches.
    def get_by_alt_text(text : String | Regex, exact : Bool = false) : Locator
      rebuilt(builder.by_alt_text(text, exact))
    end

    # Elements whose `title` matches.
    def get_by_title(text : String | Regex, exact : Bool = false) : Locator
      rebuilt(builder.by_title(text, exact))
    end

    # Narrows the set this locator already names.
    #
    # Not the same as chaining, and the difference is the whole reason it
    # exists: `locator("li").locator("text=Delete")` names the *button* inside
    # the row, while `locator("li").filter(has_text: "Delete")` names the row.
    def filter(has_text : (String | Regex)? = nil, has : Locator? = nil, visible : Bool? = nil) : Locator
      rebuilt(builder.narrow(has_text, has.try(&.selector), visible))
    end

    # The element at this index, counting from the end when negative.
    def nth(index : Int32) : Locator
      rebuilt(builder.at(index))
    end

    # The first of the elements this locator names.
    def first : Locator
      nth(0)
    end

    # The last of them.
    def last : Locator
      nth(-1)
    end

    # ---- using ---------------------------------------------------------------

    # How many elements this locator names right now.
    #
    # The one question that is never strict: counting is how a caller finds out
    # there is more than one in the first place.
    def count(timeout : Time::Span? = nil) : Int32
      progress = Progress.new("count #{@selector}", timeout || DEFAULT_TIMEOUT)
      @frame.utility_world(progress)
        .invoke("count", @selector, nil, progress: progress).as_f.to_i
    end

    # The element this locator names, or `nil` if nothing matches yet.
    #
    # Raises `StrictModeError` if it matches more than one.
    def element(timeout : Time::Span? = nil) : ElementHandle?
      progress = Progress.new("resolve #{@selector}", timeout || DEFAULT_TIMEOUT)
      @frame.resolve(@selector, progress, strict: true)
    end

    # Every element this locator names.
    def elements(timeout : Time::Span? = nil) : Array(ElementHandle)
      @frame.query_selector_all(@selector, timeout)
    end

    # Waits for the element to reach a state.
    def wait_for(state : ElementState = ElementState::Visible, timeout : Time::Span? = nil) : Nil
      @frame.wait_for_selector(@selector, state, timeout)
    end

    # Clicks it, waiting for it to be ready.
    def click(button : MouseButton = MouseButton::Left, click_count : Int32 = 1,
              force : Bool = false, timeout : Time::Span? = nil) : Nil
      @frame.click(@selector, button, click_count, force, timeout, strict: true)
    end

    # Moves the pointer over it.
    def hover(force : Bool = false, timeout : Time::Span? = nil) : Nil
      @frame.hover(@selector, force, timeout, strict: true)
    end

    # Replaces its contents.
    def fill(value : String, timeout : Time::Span? = nil) : Nil
      @frame.fill(@selector, value, timeout, strict: true)
    end

    # Focuses it and presses one key.
    def press(key : String, timeout : Time::Span? = nil) : Nil
      @frame.press(@selector, key, timeout, strict: true)
    end

    # Its text, including text in elements inside it.
    def text_content(timeout : Time::Span? = nil) : String?
      with_element(timeout, &.text_content)
    end

    # Its text as rendered.
    def inner_text(timeout : Time::Span? = nil) : String?
      with_element(timeout, &.inner_text)
    end

    # One of its attributes.
    def get_attribute(name : String, timeout : Time::Span? = nil) : String?
      with_element(timeout, &.get_attribute(name))
    end

    # The value of an input, textarea, select or contenteditable.
    def value(timeout : Time::Span? = nil) : String?
      with_element(timeout, &.value)
    end

    # Whether it has a box and is not `visibility: hidden`.
    #
    # `false` when nothing matches, because "is it visible" about something that
    # is not there has an obvious answer and raising would make every caller
    # write a rescue.
    def visible?(timeout : Time::Span? = nil) : Bool
      with_element(timeout, &.visible?) || false
    end

    # :nodoc:
    def to_s(io : IO) : Nil
      io << @selector
    end

    private def builder : SelectorBuilder
      SelectorBuilder.new(@selector)
    end

    private def rebuilt(built : SelectorBuilder) : Locator
      Locator.new(@frame, built.selector)
    end

    private def with_element(timeout : Time::Span?, &block : ElementHandle -> _)
      found = element(timeout)
      return unless found
      begin
        block.call(found)
      ensure
        found.dispose
      end
    end
  end
end
