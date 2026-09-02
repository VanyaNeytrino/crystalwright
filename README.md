# crystalwright

A Playwright-style browser automation API for Crystal, built on the Chrome
DevTools Protocol.

This is the upper half of a two-shard stack. [`cdp.cr`](https://github.com/VanyaNeytrino/cdp.cr)
speaks the protocol — transport, a session tree, typed bindings for every
command and event Chrome knows about — and this shard is the part with opinions:
JavaScript worlds, handles to live values, and eventually locators and
auto-waiting actions. No Node.js, no driver process, one static binary.

Status: **early**. Execution contexts, handles and `evaluate` work, including
the parts of JavaScript that JSON cannot express. Frames, selectors and the
auto-waiting actions are not written yet.

```crystal
require "crystalwright"

Crystalwright.launch do |browser|
  browser.new_page do |page|
    page.goto("https://example.com")
    puts page.evaluate(String, "() => document.title")
  end
end
```

## Values, not JSON

`evaluate` does not hand back parsed JSON, because JSON cannot say what a page
can say. `undefined` is not `null`, `-0` is not `0`, `Map` and `Set` are not
objects, and a value is allowed to contain itself. All of it survives the round
trip:

```crystal
value = page.evaluate("() => ({ d: new Date(0), s: new Set([1, 2]), u: undefined })")

value["d"].as_time     # => 1970-01-01 00:00:00.0 UTC
value["s"].as_set.size # => 2
value["u"].undefined?  # => true
value["u"].null?       # => false

cyclic = page.evaluate("() => { const a = {}; a.self = a; return a; }")
cyclic["self"].same?(cyclic) # => true
```

`JSON.stringify` throws on the last one and silently flattens the rest, so
nothing here goes through Chrome's `returnByValue`. Both directions use one
tagged format, serialised by a small script that runs inside the page.

When a plain Crystal type is what you want, ask for it:

```crystal
title = page.evaluate(String, "() => document.title")
count = page.evaluate(Int32, "() => document.links.length")
```

## Arguments

Arguments are passed as data and never spliced into the source:

```crystal
page.evaluate("(name, times) => name.repeat(times)", "ab", 3) # => "ababab"
```

There is no escaping to get right because there is no string being built. A
value that looks like code is a value:

```crystal
page.evaluate("(v) => v.length", "'); alert(1); //") # => 16
```

## Handles

Some values cannot be copied out of a page — a DOM node, a function, a `Window` —
and some should not be. `evaluate_handle` leaves the value where it is:

```crystal
body = page.evaluate_handle("() => document.body")
body.evaluate("(node) => node.tagName") # => "BODY"
body.get_property("childNodes")
body.dispose
```

A handle keeps memory alive in the browser until it is disposed or the page
navigates away from the document it belongs to. Using one after that raises
`Crystalwright::ContextDestroyedError` rather than a protocol code, because
"the page navigated, resolve it again" is a thing a caller can act on.

## Two worlds

`page.evaluate` runs in the page's own world, where the page's globals are
visible — code reaching for `window.myApp` has to see the same `window` the
page's scripts wrote to.

This library's own code runs in an isolated world instead, so that a page cannot
see it, break it, or be broken by it. `page.evaluate_in_utility` reaches it
directly.

## Requirements

Crystal 1.21 or newer, and a Chrome or Chromium on the machine. Nothing is
downloaded at build time and no browser is downloaded at all: the path comes
from `CDP_CHROME_PATH`, from `CHROME_PATH`, or from the usual install locations.

## Safety

Inherited from the shard below and not weakened here: the sandbox stays on, no
debugging port is opened at all — the browser is driven over a pipe — and the
profile is a fresh directory only the current user can read, removed when the
browser closes.

## Installation

```yaml
dependencies:
  crystalwright:
    github: VanyaNeytrino/crystalwright
```

## Development

```sh
crystal spec --tag "~integration"   # no browser
crystal spec                        # everything, needs Chrome
crystal tool format --check && ./bin/ameba
node --check src/crystalwright/js/utility_script.js
```

The specs that drive a browser are tagged `integration` and CI runs them ten
times in a row, because a browser test that fails one time in ten is a bug that
has been found rather than a test that needs a retry.

## License

MIT.
