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
  # Where `npm install playwright-core` leaves it, relative to wherever that was
  # run. Point `CRYSTALWRIGHT_PLAYWRIGHT_BUNDLE` at it directly when it lives
  # somewhere else; without either, the differential spec is pending and nothing
  # else notices.
  DEFAULT_BUNDLE = "node_modules/playwright-core/lib/coreBundle.js"

  # Where the visibility functions begin and end inside the injected script.
  FIRST = "function getElementComputedStyle("
  LAST  = "function elementSafeTagName("

  # And where the ARIA half does. It starts much earlier than the visibility
  # half and runs to the beginning of the snapshot machinery, which is a
  # different feature.
  #
  # Why so early: the accessible name includes whatever CSS put in front of an
  # element, and reading that means parsing the `content` property, which uses
  # their CSS tokenizer. A slice that starts below it leaves that call throwing
  # a `ReferenceError` into a `try` that swallows it — so the reference quietly
  # reports no pseudo-element content at all, and every disagreement about it
  # looks like a bug on this side. Measured: with the short slice the reference
  # named a button "Beta" where the page reads "X Beta". Everything between is one region: the role table,
  # the name algorithm, the state getters, and the caches they consult, which
  # are declared inside it and therefore need nothing passed in.
  #
  # Both boundaries are function declarations rather than offsets, so a new
  # release moves them without breaking this. When one of them stops existing
  # the spec goes pending, which is the right failure: a differential test that
  # cannot find the other implementation has nothing to say.
  ARIA_FIRST = "var between = "
  ARIA_LAST  = "var lastRef"

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

  # An expression that evaluates to Playwright's own role and accessible-name
  # computation, as `{ role, name }`.
  #
  # The point of having it is that "our `get_by_role` is correct" is otherwise
  # an opinion. With this, agreement is a number: both implementations run in
  # the same browser on the same elements, and every disagreement is a specific
  # element with two specific answers.
  def self.aria_expression : String?
    path = ENV["CRYSTALWRIGHT_PLAYWRIGHT_BUNDLE"]? || DEFAULT_BUNDLE
    return unless File.file?(path)

    bundle = File.read(path)
    literal = bundle.index("source4 = '")
    return unless literal

    first = bundle.index(ARIA_FIRST, literal)
    return unless first
    last = bundle.index(ARIA_LAST, first)
    return unless last

    body = bundle[first...last]

    <<-JS
      (() => {
      const build = new Function(
      "globalOptions",
      '#{body}\\nreturn { role: getAriaRole, name: getElementAccessibleName, hidden: isElementHiddenForAria };'
      );
      return build({});
      })()
      JS
  end
end
