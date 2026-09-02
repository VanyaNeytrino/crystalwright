require "./js_handle"

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

    private def call(name : String, timeout : Time::Span?) : JSValue
      progress = Progress.new(name, timeout || DEFAULT_TIMEOUT)
      guard
      @context.invoke(name, self, progress: progress)
    end
  end
end
