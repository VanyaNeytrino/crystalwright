# Playwright's own visibility check, borrowed from a copy on this machine.
#
# For the differential spec, which asks whether this shard and Playwright agree
# about which elements a person can see. Ours was ported from their source, so
# agreement is expected — and an expectation nobody checks is how a port drifts.
#
# Nothing of theirs is copied into this repository. The bundle is read at spec
# time from wherever it happens to be installed, and the spec is pending when it
# is not there. It is a reference on one machine and never a dependency: the
# shard itself has no Node.js in it at any stage, and this does not change that,
# because what runs is the browser's own JavaScript engine on both sides.
module PlaywrightSource
  # Where `npm install playwright-core` tends to leave it. Override with
  # `CRYSTALWRIGHT_PLAYWRIGHT_BUNDLE`.
  DEFAULT_BUNDLE = "/Users/ivanrubyst/coding/a11y-probe/node_modules/playwright-core/lib/coreBundle.js"

  # Where the visibility functions begin and end inside the injected script.
  FIRST = "function getElementComputedStyle("
  LAST  = "function elementSafeTagName("

  # An expression that evaluates to Playwright's `isElementVisible`.
  #
  # Found by searching rather than by scanning. The injected script is stored in
  # the bundle as one escaped single-quoted literal of eight hundred kilobytes,
  # and walking it character by character in Crystal is quadratic — `String#[]`
  # is only constant time on an ASCII-only string, and that one is not. An
  # earlier version did exactly that and took five minutes for two examples.
  # `index` is a substring search over bytes and finds the same place in no
  # time.
  #
  # The text is left escaped and handed back to a JavaScript parser as the
  # literal it already is, so the browser does the un-escaping. Reimplementing
  # `\n`, `\\` and `\uXXXX` in Crystal means getting one of them subtly wrong.
  def self.visibility_expression : String?
    path = ENV["CRYSTALWRIGHT_PLAYWRIGHT_BUNDLE"]? || DEFAULT_BUNDLE
    return unless File.file?(path)

    bundle = File.read(path)
    literal = bundle.index("source4 = '")
    return unless literal

    first = bundle.index(FIRST, literal)
    return unless first
    last = bundle.index(LAST, first)
    return unless last

    # Interpolated into a single-quoted literal, which is the one place in this
    # project where source is built by concatenation. Safe by construction
    # rather than by inspection: this text came out of a single-quoted literal,
    # already escaped for exactly this position, and it is a file on this
    # machine rather than anything a page supplied.
    body = bundle[first...last]

    <<-JS
      (() => {
      // The caches these consult are left undefined, which turns caching off —
      // the right choice against a page whose elements the spec keeps changing.
      const build = new Function(
      "globalOptions", "cacheStyle", "cacheStyleBefore", "cacheStyleAfter", "cacheStyleVisibility",
      '#{body}\\nreturn isElementVisible;'
      );
      return build({}, undefined, undefined, undefined, undefined);
      })()
      JS
  end
end
