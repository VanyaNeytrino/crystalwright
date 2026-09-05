# crystalwright

A Playwright-style browser automation API for Crystal, built on the Chrome
DevTools Protocol.

This is the upper half of a two-shard stack. [`cdp.cr`](https://github.com/VanyaNeytrino/cdp.cr)
speaks the protocol — transport, a session tree, typed bindings for every
command and event Chrome knows about — and this shard is the part with opinions:
JavaScript worlds, handles to live values, and eventually locators and
auto-waiting actions. No Node.js, no driver process, one static binary.

Status: **usable**. Navigation, frames, selectors, locators, auto-waiting
actions, assertions that wait, network interception, downloads, file pickers,
popups, screenshots and cookies all work. What is deliberately absent is listed
under *Not here* below.

```crystal
require "crystalwright"

Crystalwright.launch do |browser|
  browser.new_page do |page|
    page.goto("https://example.com")
    puts page.evaluate(String, "() => document.title")
  end
end
```

## Actions that wait

A click is not a click. It waits for the element to be visible, enabled and
holding still; scrolls it into view, and if that parks it under a sticky header,
scrolls differently; aims at the middle of what is actually on the screen rather
than the middle of its bounding box; checks nothing is on top of it; and keeps
checking while the events are in flight, because a banner sliding in between
aiming and firing is the classic way a passing suite starts clicking the wrong
thing once a week.

```crystal
page.click("#submit")
page.dblclick("#row")
page.fill("#email", "someone@example.com")
page.hover("text=Account")
page.press("#search", "Enter")
page.check("#terms")
page.uncheck("#newsletter")
page.select_option("#country", "no")
page.select_option("#country", label: "Norway")
page.select_option("#tags", values: ["a", "b"])
```

`check` and `uncheck` are not clicks: a click toggles, and a toggle is only what
you meant if you already knew the state. They read it, act only if it is wrong,
and read it again — because a click that lands on a label pointing at nothing
leaves the box exactly as it was, and an implementation that stops after
clicking would report success.

`select_option` is not a click either. A native dropdown is drawn by the
operating system and there is nothing on the page to aim at, so the selection is
made in the document and `input` and `change` are dispatched by hand: setting
`selected` from script fires neither, and a page listening for `change` would
never learn anything happened.

All of that is retried until it works or the deadline passes, and there is one
deadline for the whole action rather than one per attempt — so a click that
tried eleven times fails after the thirty seconds you asked for, not after
eleven times thirty. When it fails it prints what it tried:

```
click #target timed out after 1.0s
attempting click on #target
  waiting for the element to be visible, enabled, stable
  scrolling into view if needed
  aiming at (90.0, 80.0)
  <div id="blanket"></div> intercepts pointer events
retrying click on #target, attempt #2
  ...
```

`force: true` skips the checks when you mean to click whatever is there.

## Navigation

```crystal
page.reload
page.go_back        # => false when there is nowhere to go
page.go_forward
page.title          # => "Example Domain"
page.content        # the html, doctype included
```

A page restored from the back/forward cache is not a new document: it sends no
lifecycle events, because it loaded once already, and the script that builds
this library's isolated world does not run again. Both are repaired when the
restore is announced, so going back behaves like any other navigation instead of
hanging for thirty seconds.

`goto` waits for the document it asked for, and then for however far into
loading you want to be:

```crystal
page.goto("https://example.com")                                    # the load event
page.goto("https://example.com", Crystalwright::LoadState::NetworkIdle)
page.wait_for_load_state(Crystalwright::LoadState::DOMContentLoaded)
```

`NetworkIdle` means 500 ms with nothing in flight. It is this library's own
rule rather than Chrome's `networkIdle` lifecycle event, which means something
else: measured on a page whose last resource arrives 600 ms in, Chrome announces
idle about 1.3 seconds after that, and the gap varies between runs on the same
page.

A navigation that does not replace the document — `history.pushState`, or a
fragment — is still a navigation. The address changes, the document does not,
and `wait_for_load_state` returns straight away rather than waiting for a `load`
event that already fired and is not coming back. Single-page applications work
without being a special case.

An action that navigates can be held open until it has:

```crystal
page.with_navigation_signals do
  page.evaluate("() => document.querySelector('a#next').click()")
end
# the new document has committed; the next call is not racing it
```

## Frames

Every frame has the same API the page does, because `Page` is a thin facade
over its main frame — `page.goto` and `page.main_frame.goto` are the same call.

```crystal
page.goto("https://example.com/with-an-iframe")

page.frames                                  # every frame, parents first
inner = page.frame("checkout")               # by name or id attribute
inner.url
inner.parent                                 # => page.main_frame
inner.evaluate(String, "() => document.title")
inner.wait_for_load_state
```

A frame keeps its identity for as long as its element exists, while what it is
*showing* is replaced on every navigation — so a `Frame` you are holding stays
valid across navigations, and the handles resolved in it do not. A frame that is
removed from the page raises `Crystalwright::FrameDetachedError` rather than
waiting out its timeout, because a frame that is gone is never getting another
document.

## Locators

A locator names elements. It holds no reference to anything, so there is nothing
to go stale: it is a question, asked again at every use.

```crystal
page.locator("#submit").click
page.get_by_role("button", name: "Save changes").click
page.get_by_text("Save changes").click
page.get_by_label("Email").fill("someone@example.com")
page.get_by_test_id("row").filter(has_text: "Ada").locator("button").click
page.locator(".row").first.text_content
```

`get_by_role` is the one that survives a redesign, because it names what the
control *is* rather than where it sits:

```crystal
page.get_by_role("button", name: "Save")           # substring, case-insensitive
page.get_by_role("button", name: "Save", exact: true)
page.get_by_role("heading", level: 2)
page.get_by_role("checkbox", checked: true)
page.get_by_role("button", disabled: true)
page.get_by_role("option", selected: true)
page.get_by_role("button", include_hidden: true)   # hidden ones too
```

The role is computed, not read off the element: an `<a>` with no `href` is not a
link, a `<section>` is only a region once it has a name, an `<img alt="">` is
decoration, a `<header>` inside an `<article>` is not the page's banner, and a
`<th>` is a column header or a row header depending on its neighbours. The name
is computed too — `aria-labelledby` first, then `aria-label`, then the native
label, then the element's own text including whatever CSS put in front of it.

Both are checked against Playwright's own implementation, element by element,
on a fixture built to disagree. Ask about one element directly when a locator
does not find what you expected:

```crystal
element = page.query_selector("#save").not_nil!
element.aria_role          # => "button"
element.accessible_name    # => "Save changes"
```

Locators are **strict**: one that matches two elements is an error, not a silent
choice of the first — because "the first thing that matched" is exactly what
turns a renamed button into a test that passes while clicking the wrong control.
The error shows what matched:

```
strict mode violation: button.remove resolved to 3 elements:
  1) <button class="remove">Delete</button>
  2) <button class="remove">Delete</button>
  3) <button class="remove">Delete</button>

Use .nth(), .first or .last to say which one, or narrow the selector.
```

`filter` narrows the set; chaining searches inside it. `locator("li")
.locator("text=Delete")` names the button, `locator("li").filter(has_text:
"Delete")` names the row.

## Assertions that wait

```crystal
Crystalwright.expect(page.locator("#status")).to_have_text("Saved")
Crystalwright.expect(page.get_by_text("Error")).not.to_be_visible
Crystalwright.expect(page.locator(".row")).to_have_count(3)
```

Each asks, and keeps asking until the answer is the one wanted or the deadline
passes — the only shape that works against a page, where every answer is about a
moment and the interesting moment is usually a few frames away. When one gives
up it prints what was actually there, not merely that the check failed.

## Selectors

```crystal
page.click("#submit")                        # css by default
page.click("text=Save changes")              # case-insensitive substring
page.click(%(text="Save changes"))           # exact
page.click("text=/^Save/")                   # a regular expression
page.click("//button[@type='submit']")       # xpath, implied by the slashes
page.click("data-testid=save")
page.click("#dialog >> text=Confirm")        # chained: search inside what came before
```

`css=` looks inside open shadow roots; `css:light=` stays in the light DOM.
Closed shadow roots are unreachable — not a decision, a property of the
platform.

Everything here runs in an isolated JavaScript world, so a page that reassigns
`document.querySelector` or `Element.prototype.getBoundingClientRect` breaks its
own world and reaches nothing of ours.

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

## Answering requests yourself

```crystal
page.route("**/api/**") do |route|
  route.fulfill(status: 200, body: %({"items": []}), content_type: "application/json")
end

page.route("**/*.{png,jpg}", &.abort)     # no images, for a faster suite
page.unroute("**/api/**")                 # and back to the real thing
```

The handler runs on a fiber of its own and may take as long as it likes,
including waiting on the page. A pattern is a glob — `*` is one path segment,
`**` is any number, `{a,b}` is either — because the alternative is escaping
every dot in a hostname by hand, and the version with one dot left unescaped
matches hosts nobody meant.

## Files, popups and pictures

```crystal
download = page.expect_download { page.click("#report") }
download.save_into("tmp/reports")         # a name that cannot leave the directory

page.set_input_files("#avatar", "spec/fixtures/face.png")

popup = page.expect_popup { page.click("#terms") }
popup.wait_for_load_state

page.screenshot(path: "tmp/page.png", full_page: true)
page.set_viewport(1280, 720)
```

A popup is held still before its own first statement, configured, and only then
released — so `browser.add_init_script` is genuinely in place before anything
the page does.

## What the page says

```crystal
page.on_console { |message| puts message }          # [error] Cannot read ... (app.js:41)
page.on_page_error { |error| failures << error }    # an exception nobody caught
```

The single most useful thing to have when a test fails on somebody else's
machine. Arguments are rendered the way a console renders them — an object shows
what is in it rather than the word `Object` — and nothing is kept alive: a
subscription that held a handle per argument would pin the page's memory for as
long as it lived.

## Timeouts

Thirty seconds by default, which is right for a person watching and wrong for a
suite on a runner at half the speed. One setting covers the tab and every frame
in it; an explicit timeout always wins.

```crystal
page.default_timeout = 5.seconds
page.click("#submit")                    # five seconds
page.click("#submit", timeout: 1.minute) # one minute
```

## Not here

Deliberately, and worth knowing before you start:

* **Cross-origin iframes.** Chrome puts one in its own process and does not
  report it to the parent at all, so `page.frame(...)` returns `nil` rather than
  something that hangs. Driving one needs a protocol session per frame.
* **Closed shadow roots**, which are unreachable from an isolated world — a
  property of the platform rather than a decision.
* Tracing, video, HAR, the code generator, and a test runner. Integrating with
  Crystal's own `spec` is a helper, not a framework.

## Requirements

Crystal 1.21 or newer, and a Chrome or Chromium on the machine. Nothing is
downloaded at build time and no browser is downloaded at all: the path comes
from `CDP_CHROME_PATH`, from `CHROME_PATH`, or from the usual install locations.

There is no Node.js anywhere in this — not at build time, not at run time, and
not as a hidden driver process. A program that uses this shard is one binary
talking to Chrome. There *is* JavaScript, and it runs inside the page, executed
by the browser's own engine: selecting an element and asking what it says are
questions only the page can answer. That script is read into the binary at
compile time, so there is nothing beside the executable to ship.

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

# Crystal 1.21 runs fibers at a parallelism of one unless told otherwise, so
# this is the only run that can fail on a data race.
CRYSTALWRIGHT_SPEC_PARALLEL=8 crystal spec

# What only shows up after a while: five hundred navigations in one page, a
# document that abandons a request on every load, fifty tabs opened and closed.
# Minutes rather than seconds, so it is pending unless asked for.
CRYSTALWRIGHT_SOAK=1 crystal spec spec/soak_spec.cr
```

The soak specs are not a formality. A structure that grows by one entry per page
is invisible for the length of an example and fatal for the length of a working
day, and every example everywhere else in this suite finishes in under a second.

The specs that drive a browser are tagged `integration` and CI runs them ten
times in a row, because a browser test that fails one time in ten is a bug that
has been found rather than a test that needs a retry.

## License

MIT.
