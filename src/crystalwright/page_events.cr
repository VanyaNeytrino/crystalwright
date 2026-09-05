require "./errors"

module Crystalwright
  # Something the page printed.
  #
  # The arguments are rendered rather than handed over as handles. A console
  # line is read, not inspected: keeping a handle per argument would pin the
  # page's memory for the life of a subscription, and a test that logs a
  # thousand lines would hold a thousand objects alive to print a string.
  struct ConsoleMessage
    # `"log"`, `"warning"`, `"error"`, `"debug"` and the rest of them.
    getter type : String

    # The line, with every argument rendered and joined by a space.
    getter text : String

    # Where the call was, when the page said.
    getter url : String?

    # One-based, as a browser counts them.
    getter line : Int32?

    def initialize(@type : String, @text : String, @url : String? = nil, @line : Int32? = nil)
    end

    def to_s(io : IO) : Nil
      io << '[' << @type << "] " << @text
      io << " (" << @url << ':' << @line << ')' if @url
    end
  end

  # An exception the page threw and nobody caught.
  #
  # Not an error this shard raises: a page throwing is the page's business, and
  # a caller that wants to fail a test on it can. What matters is that it is
  # possible to know at all — a `window.onerror` that nothing reports is how a
  # test fails ten minutes later, somewhere else.
  struct PageError
    # What the page said, e.g. `"TypeError: x is not a function"`.
    getter message : String

    # The JavaScript stack, when there was one.
    getter stack : String?

    # Where it was thrown, when the page said.
    getter url : String?

    def initialize(@message : String, @stack : String? = nil, @url : String? = nil)
    end

    def to_s(io : IO) : Nil
      io << @message
      io << "\n" << @stack if @stack
    end
  end
end
