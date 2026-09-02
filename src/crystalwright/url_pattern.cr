require "./errors"

module Crystalwright
  # Which addresses a pattern names.
  #
  # A glob rather than a regular expression, because the thing being matched is
  # a URL and the thing people want to say about one is "anything under this
  # path". Writing that as a regular expression means escaping every dot in a
  # hostname, and the version with a dot left unescaped matches hosts nobody
  # meant — which is a security bug in a route that fulfils requests.
  #
  # ```
  # "**/api/*"          # anything, then /api/ and one more segment
  # "https://a.test/**" # everything on one host
  # "**/*.{png,jpg}"    # either extension
  # ```
  struct URLPattern
    # The pattern as it was written.
    getter source : String | Regex

    @regex : Regex

    def initialize(@source : String | Regex)
      given = @source
      @regex = given.is_a?(Regex) ? given : URLPattern.compile(given)
    end

    # Whether this pattern names that address.
    def matches?(url : String) : Bool
      !@regex.match(url).nil?
    end

    # The regular expression a glob turns into.
    #
    # The rules are Playwright's, because a pattern is something people copy
    # between projects and a dialect of one's own is a trap for anybody who has
    # seen the other:
    #
    # * `*` is anything but a slash, so `/api/*` is one segment.
    # * `**` is anything at all, slashes included.
    # * `?` is exactly one character.
    # * `{a,b}` is either.
    # * everything else, dots very much included, matches itself.
    #
    # Anchored at both ends. An unanchored pattern would make `"/login"` match
    # `https://evil.test/not-really/login/no`, and a route that fulfils requests
    # is exactly the place where that becomes somebody's afternoon.
    def self.compile(glob : String) : Regex
      pattern = String.build do |io|
        io << '^'
        index = 0
        groups = 0

        while index < glob.size
          case character = glob[index]
          when '*'
            if glob[index + 1]? == '*'
              io << ".*"
              index += 1
            else
              io << "[^/]*"
            end
          when '?'
            io << '.'
          when '{'
            groups += 1
            io << '('
          when '}'
            if groups.zero?
              io << "\\}"
            else
              groups -= 1
              io << ')'
            end
          when ','
            groups.zero? ? io << "\\," : io << '|'
          else
            io << Regex.escape(character.to_s)
          end
          index += 1
        end

        raise Error.new("#{glob.inspect} has an unclosed {") unless groups.zero?
        io << '$'
      end

      Regex.new(pattern)
    end

    def to_s(io : IO) : Nil
      io << @source
    end
  end
end
