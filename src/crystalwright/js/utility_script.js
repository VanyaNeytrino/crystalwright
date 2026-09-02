// The value serializer that lives inside the page.
//
// Everything crossing the JavaScript boundary goes through the tagged form
// below, in both directions. Chrome's own returnByValue is never used on a page
// value, because its JSON projection destroys exactly what has to survive:
// `undefined` disappears, `-0` becomes `0`, `Date` flattens to a string, `Map`
// and `Set` become `{}`, and a value that contains itself is an error. The only
// thing returnByValue is ever applied to is the tagged envelope this file
// produces, which is plain JSON by construction.
//
// Tags:
//   {v:"undefined"|"null"|"NaN"|"Infinity"|"-Infinity"|"-0"}
//   {n:<number>} {s:<string>} {b:<bool>} {bi:"<digits>"}
//   {d:"<iso>"} {u:"<href>"} {r:{p:<source>,f:<flags>}}
//   {e:{n:<name>,m:<message>,s:<stack>}}
//   {ta:{k:<ctor>,a:[<number>...]}}
//   {a:[...],id:N} {o:[{k,v}...],id:N} {m:[[k,v]...],id:N} {se:[...],id:N}
//   {ref:N} a value already seen — this is what makes cycles work
//   {h:N}   an index into the handle arguments
//   {x:"<kind>"} something with no representation outside the page
(() => {
  "use strict";

  // Captured now, while they are still the real ones. A page is allowed to
  // reassign its own globals, and page.evaluate runs in the main world where it
  // already has. Reaching for Array.isArray at call time asks the page what it
  // would like the answer to be.
  const ObjectIs = Object.is;
  const ObjectKeys = Object.keys;
  const ObjectPrototypeToString = Object.prototype.toString;
  const ArrayIsArray = Array.isArray;
  const ArrayBufferIsView = ArrayBuffer.isView;
  const DatePrototypeToISOString = Date.prototype.toISOString;
  const MapPrototypeForEach = Map.prototype.forEach;
  const SetPrototypeForEach = Set.prototype.forEach;
  const ErrorCaptureName = "Error";

  const brand = (value) => ObjectPrototypeToString.call(value);

  const isDate = (value) => brand(value) === "[object Date]";
  const isRegExp = (value) => brand(value) === "[object RegExp]";
  const isMap = (value) => brand(value) === "[object Map]";
  const isSet = (value) => brand(value) === "[object Set]";
  const isURL = (value) => brand(value) === "[object URL]";
  const isError = (value) => {
    const tag = brand(value);
    return tag === "[object Error]" || tag === "[object DOMException]";
  };
  const isNode = (value) =>
    typeof value.nodeType === "number" && typeof value.nodeName === "string";

  // --- page value -> tagged --------------------------------------------------

  function serialize(value, visited) {
    if (value === undefined) return { v: "undefined" };
    if (value === null) return { v: "null" };

    const type = typeof value;
    if (type === "number") {
      if (ObjectIs(value, -0)) return { v: "-0" };
      if (value === Infinity) return { v: "Infinity" };
      if (value === -Infinity) return { v: "-Infinity" };
      if (ObjectIs(value, NaN)) return { v: "NaN" };
      return { n: value };
    }
    if (type === "string") return { s: value };
    if (type === "boolean") return { b: value };
    if (type === "bigint") return { bi: String(value) };
    if (type === "symbol") return { x: "symbol" };
    if (type === "function") return { x: "function" };

    // Values that cannot contain themselves are not registered, so two
    // references to one Date come back as two equal Dates rather than as a
    // shared one. Object identity of a leaf is not worth a wire id.
    if (isDate(value)) return { d: DatePrototypeToISOString.call(value) };
    if (isRegExp(value)) return { r: { p: value.source, f: value.flags } };
    if (isURL(value)) return { u: String(value) };
    if (isError(value)) {
      return {
        e: {
          n: String(value.name || ErrorCaptureName),
          m: String(value.message || ""),
          s: value.stack === undefined ? null : String(value.stack),
        },
      };
    }
    if (isNode(value)) return { x: "node" };
    if (ArrayBufferIsView(value) && brand(value) !== "[object DataView]") {
      const numbers = [];
      for (let i = 0; i < value.length; i++) numbers.push(value[i]);
      return { ta: { k: value.constructor ? value.constructor.name : "TypedArray", a: numbers } };
    }

    // Containers, which can. Registered before their contents are walked —
    // that ordering is the whole cycle mechanism, and reversing it turns
    // `a.push(a)` into a stack overflow.
    const seen = visited.get(value);
    if (seen !== undefined) return { ref: seen };
    const id = visited.size + 1;
    visited.set(value, id);

    if (ArrayIsArray(value)) {
      const out = { id, a: [] };
      for (let i = 0; i < value.length; i++) out.a.push(serialize(value[i], visited));
      return out;
    }
    if (isMap(value)) {
      const out = { id, m: [] };
      MapPrototypeForEach.call(value, (v, k) => {
        out.m.push([serialize(k, visited), serialize(v, visited)]);
      });
      return out;
    }
    if (isSet(value)) {
      const out = { id, se: [] };
      SetPrototypeForEach.call(value, (v) => out.se.push(serialize(v, visited)));
      return out;
    }

    const out = { id, o: [] };
    const keys = ObjectKeys(value);
    for (let i = 0; i < keys.length; i++) {
      out.o.push({ k: keys[i], v: serialize(value[keys[i]], visited) });
    }
    return out;
  }

  // --- tagged -> page value --------------------------------------------------

  function parse(tagged, handles, refs) {
    if ("n" in tagged) return tagged.n;
    if ("s" in tagged) return tagged.s;
    if ("b" in tagged) return tagged.b;
    if ("v" in tagged) {
      switch (tagged.v) {
        case "undefined": return undefined;
        case "null": return null;
        case "NaN": return NaN;
        case "Infinity": return Infinity;
        case "-Infinity": return -Infinity;
        case "-0": return -0;
      }
      throw new Error("unknown sentinel: " + tagged.v);
    }
    if ("bi" in tagged) return BigInt(tagged.bi);
    if ("d" in tagged) return new Date(tagged.d);
    if ("u" in tagged) return new URL(tagged.u);
    if ("r" in tagged) return new RegExp(tagged.r.p, tagged.r.f);
    if ("e" in tagged) {
      const error = new Error(tagged.e.m);
      error.name = tagged.e.n;
      if (tagged.e.s !== null && tagged.e.s !== undefined) error.stack = tagged.e.s;
      return error;
    }
    if ("ta" in tagged) {
      const ctor = globalThis[tagged.ta.k];
      if (typeof ctor !== "function") throw new Error("no such typed array: " + tagged.ta.k);
      return ctor.from(tagged.ta.a);
    }
    if ("h" in tagged) return handles[tagged.h];
    if ("ref" in tagged) {
      if (!refs.has(tagged.ref)) throw new Error("dangling reference: " + tagged.ref);
      return refs.get(tagged.ref);
    }
    if ("x" in tagged) throw new Error("cannot send a " + tagged.x + " into the page");

    // Containers again, and again registered before being filled.
    if ("a" in tagged) {
      const out = [];
      if (tagged.id !== undefined) refs.set(tagged.id, out);
      for (let i = 0; i < tagged.a.length; i++) out.push(parse(tagged.a[i], handles, refs));
      return out;
    }
    if ("o" in tagged) {
      const out = {};
      if (tagged.id !== undefined) refs.set(tagged.id, out);
      for (let i = 0; i < tagged.o.length; i++) {
        out[tagged.o[i].k] = parse(tagged.o[i].v, handles, refs);
      }
      return out;
    }
    if ("m" in tagged) {
      const out = new Map();
      if (tagged.id !== undefined) refs.set(tagged.id, out);
      for (let i = 0; i < tagged.m.length; i++) {
        out.set(parse(tagged.m[i][0], handles, refs), parse(tagged.m[i][1], handles, refs));
      }
      return out;
    }
    if ("se" in tagged) {
      const out = new Set();
      if (tagged.id !== undefined) refs.set(tagged.id, out);
      for (let i = 0; i < tagged.se.length; i++) out.add(parse(tagged.se[i], handles, refs));
      return out;
    }
    throw new Error("unrecognised tagged value: " + JSON.stringify(tagged));
  }

  const finish = (value, byValue) => (byValue ? serialize(value, new Map()) : value);

  // --- selectors -------------------------------------------------------------
  //
  // A selector is one or more steps joined by ">>", and each step names an
  // engine: "css=div.foo", "text=Sign in", "xpath=//button", "id=submit". A step
  // with no engine is xpath when it starts with "//" or "..", and css otherwise.
  // Chaining searches inside what the step before it found.
  //
  // Parsing lives here rather than in Crystal on purpose. The alternative is a
  // CSS tokenizer in a second language, kept in step with this one by hand, to
  // answer questions the browser can already answer.
  //
  // None of this defends itself against the page, because it does not have to:
  // this runs in an isolated world with its own copies of every built-in.
  // Measured against a page that reassigns Array.prototype.map,
  // document.querySelector, Element.prototype.getBoundingClientRect,
  // Object.defineProperty and JSON.stringify — all nine overrides are invisible
  // from here, while the same calls in the page's own world do break.

  const NON_TEXT_NODES = { SCRIPT: true, STYLE: true, NOSCRIPT: true, TEMPLATE: true };

  const normalizeText = (text) =>
    String(text == null ? "" : text).replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();

  // Splits on ">>" while leaving quoted text and bracketed CSS alone, so that
  // `text="a >> b"` and `div[data-x=">>"]` survive.
  function splitSteps(selector) {
    const steps = [];
    let start = 0;
    let quote = null;
    let depth = 0;

    for (let i = 0; i < selector.length; i++) {
      const c = selector[i];
      if (quote) {
        if (c === "\\") i++;
        else if (c === quote) quote = null;
        continue;
      }
      if (c === '"' || c === "'" || c === "`") quote = c;
      else if (c === "(" || c === "[") depth++;
      else if (c === ")" || c === "]") depth--;
      else if (depth === 0 && c === ">" && selector[i + 1] === ">") {
        steps.push(selector.slice(start, i));
        i++;
        start = i + 1;
      }
    }
    steps.push(selector.slice(start));

    const trimmed = [];
    for (let i = 0; i < steps.length; i++) {
      const step = steps[i].trim();
      if (step.length) trimmed.push(step);
    }
    return trimmed;
  }

  function parseStep(step) {
    const eq = step.indexOf("=");
    if (eq > 0) {
      const name = step.slice(0, eq).trim();
      // Only a name that is actually an engine counts, so `[href="x"]` and
      // `css=div[a=b]` both mean what they look like.
      if (ENGINES[name]) return { engine: name, body: step.slice(eq + 1).trim() };
    }
    if (step.slice(0, 2) === "//" || step.slice(0, 2) === "..") return { engine: "xpath", body: step };
    return { engine: "css", body: step };
  }

  // Every place a query can look: the root, plus every open shadow root under
  // it, recursively. Closed roots are absent by construction — measured, they
  // are unreachable from here even through a reference the page kept itself.
  function scopesUnder(root) {
    const scopes = [root];
    if (root.shadowRoot) scopes.push(root.shadowRoot);
    for (let i = 0; i < scopes.length; i++) {
      const elements = scopes[i].querySelectorAll("*");
      for (let j = 0; j < elements.length; j++) {
        const shadow = elements[j].shadowRoot;
        if (shadow) scopes.push(shadow);
      }
    }
    return scopes;
  }

  function queryCSS(root, body, pierce, all) {
    const found = [];
    const scopes = pierce ? scopesUnder(root) : [root];
    for (let s = 0; s < scopes.length; s++) {
      let list;
      try {
        list = scopes[s].querySelectorAll(body);
      } catch (error) {
        throw new Error("Not a valid CSS selector: " + body);
      }
      for (let i = 0; i < list.length; i++) {
        found.push(list[i]);
        if (!all) return found;
      }
    }
    return found;
  }

  // `text=Sign in`   case-insensitive substring, whitespace collapsed
  // `text="Sign in"` exact after collapsing, case sensitive
  // `text=/^Sign/i`  regular expression
  function textMatcher(body) {
    if (body.length > 1 && body[0] === '"' && body[body.length - 1] === '"') {
      const literal = normalizeText(JSON.parse(body));
      return (text) => text === literal;
    }
    if (body.length > 2 && body[0] === "/") {
      const end = body.lastIndexOf("/");
      if (end > 0) {
        const pattern = new RegExp(body.slice(1, end), body.slice(end + 1));
        return (text) => {
          pattern.lastIndex = 0;
          return pattern.test(text);
        };
      }
    }
    const needle = normalizeText(body).toLowerCase();
    return (text) => text.toLowerCase().indexOf(needle) !== -1;
  }

  const elementText = (element) => {
    if (NON_TEXT_NODES[element.nodeName]) return "";
    if (element.nodeName === "INPUT" && (element.type === "submit" || element.type === "button")) {
      return normalizeText(element.value);
    }
    return normalizeText(element.textContent);
  };

  function queryText(root, body, all) {
    const matches = textMatcher(body);
    const found = [];
    const scopes = scopesUnder(root);

    for (let s = 0; s < scopes.length; s++) {
      const elements = scopes[s].querySelectorAll("*");
      for (let i = 0; i < elements.length; i++) {
        const element = elements[i];
        if (!matches(elementText(element))) continue;

        // The smallest element that contains the text, not every ancestor of
        // it. Without this, `text=Save` on any page also matches <body>.
        const inside = element.querySelectorAll("*");
        let deeper = false;
        for (let j = 0; j < inside.length && !deeper; j++) {
          if (matches(elementText(inside[j]))) deeper = true;
        }
        if (deeper) continue;

        found.push(element);
        if (!all) return found;
      }
    }
    return found;
  }

  // XPath does not cross shadow boundaries and is not made to: the language has
  // no way to express the hop, and pretending otherwise would mean a selector
  // that means different things here and in the browser's own console.
  function queryXPath(root, body, all) {
    const document_ = root.ownerDocument || root;
    const found = [];
    let result;
    try {
      result = document_.evaluate(body, root, null, XPathResult.ORDERED_NODE_ITERATOR_TYPE, null);
    } catch (error) {
      throw new Error("Not a valid XPath expression: " + body);
    }
    let node = result.iterateNext();
    while (node) {
      if (node.nodeType === 1) {
        found.push(node);
        if (!all) return found;
      }
      node = result.iterateNext();
    }
    return found;
  }

  const cssQuote = (value) => '"' + String(value).replace(/(["\\])/g, "\\$1") + '"';

  const ENGINES = {
    css: (root, body, all) => queryCSS(root, body, true, all),
    "css:light": (root, body, all) => queryCSS(root, body, false, all),
    text: (root, body, all) => queryText(root, body, all),
    xpath: (root, body, all) => queryXPath(root, body, all),
    id: (root, body, all) => queryCSS(root, "[id=" + cssQuote(body) + "]", true, all),
    "data-testid": (root, body, all) => queryCSS(root, "[data-testid=" + cssQuote(body) + "]", true, all),
  };

  function query(selector, root, all) {
    const steps = splitSteps(selector);
    if (!steps.length) throw new Error("The selector is empty.");

    let current = [root || document];
    for (let s = 0; s < steps.length; s++) {
      const step = parseStep(steps[s]);
      const last = s === steps.length - 1;
      const engine = ENGINES[step.engine];
      const next = [];
      const seen = new Set();

      for (let c = 0; c < current.length; c++) {
        // Every branch of an intermediate step has to be explored even when the
        // caller only wants one element in the end, because the first match of
        // step one need not be the one whose subtree contains step two.
        const hits = engine(current[c], step.body, all || !last);
        for (let h = 0; h < hits.length; h++) {
          if (seen.has(hits[h])) continue;
          seen.add(hits[h]);
          next.push(hits[h]);
          if (last && !all) return next;
        }
      }

      if (!next.length) return [];
      current = next;
    }
    return current;
  }

  // What an element looks like in a failure message. A selector that did not
  // match is debugged by seeing what was there instead.
  function previewNode(node) {
    if (!node) return "nothing";
    if (node.nodeType === 3) return '#text="' + normalizeText(node.nodeValue).slice(0, 50) + '"';
    if (node.nodeType !== 1) return "#node";

    const name = node.nodeName.toLowerCase();
    let attributes = "";
    const interesting = ["id", "data-testid", "name", "type", "class"];
    for (let i = 0; i < interesting.length; i++) {
      const value = node.getAttribute(interesting[i]);
      if (value) attributes += " " + interesting[i] + '="' + clip(value, 40) + '"';
    }

    const body = node.children.length ? "…" : clip(elementText(node), 40);
    return "<" + name + attributes + ">" + body + "</" + name + ">";
  }

  const clip = (text, limit) => (text.length > limit ? text.slice(0, limit) + "…" : text);

  // --- actionability ---------------------------------------------------------
  //
  // Everything an element has to be before it can be acted on, and the check
  // that the action will land where it was aimed.
  //
  // Carried across from Playwright's injected script rather than reasoned out
  // again. Every constant here — the number of still frames that counts as
  // stable, the retargeting rules, the shape of the hit-target walk — is the
  // residue of a bug report somebody already paid for, and a fresh guess would
  // have to earn its way back to the same place one flake at a time.

  // How many consecutive animation frames an element has to hold still.
  //
  // One, which means two frames with the same rectangle: the first records it
  // and the second confirms it. Chromium's own answer through Playwright's
  // `rafCountForStablePosition`.
  const STABLE_FRAMES = 1;

  const CONTINUE_POLLING = Symbol("continuePolling");

  // Which element an action on this node really concerns.
  //
  // Clicking the text inside a button means clicking the button; typing into a
  // label means typing into the control it labels. Without this, a selector
  // that resolves to a <span> inside a <button> aims at the span's box, which
  // is usually smaller and sometimes not where the click has to land.
  function retarget(node, behavior) {
    let element = node.nodeType === 1 ? node : node.parentElement;
    if (!element) return null;
    if (behavior === "none") return element;

    if (!element.matches("input, textarea, select") && !element.isContentEditable) {
      if (behavior === "button-link") {
        element = element.closest("button, [role=button], a, [role=link]") || element;
      } else {
        element = element.closest("button, [role=button], [role=checkbox], [role=radio]") || element;
      }
    }

    if (behavior === "follow-label") {
      const alreadyControl = element.matches(
        "a, input, textarea, button, select, [role=link], [role=button], [role=checkbox], [role=radio]"
      );
      if (!alreadyControl && !element.isContentEditable) {
        const label = element.closest("label");
        if (label && label.control) element = label.control;
      }
    }
    return element;
  }

  const computedStyle = (element) => {
    const view = element.ownerDocument && element.ownerDocument.defaultView;
    return view ? view.getComputedStyle(element) : null;
  };

  const visibleTextNode = (node) => {
    const range = node.ownerDocument.createRange();
    range.selectNode(node);
    const rect = range.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };

  // `display: contents` is the case that makes this more than a rectangle
  // check: such an element has no box of its own and is visible exactly when
  // something it contains is.
  function isVisible(element) {
    if (!element || element.nodeType !== 1) return false;
    const style = computedStyle(element);
    if (!style) return true;

    if (style.display === "contents") {
      for (let child = element.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === 1 && isVisible(child)) return true;
        if (child.nodeType === 3 && visibleTextNode(child)) return true;
      }
      return false;
    }

    if (Element.prototype.checkVisibility) {
      if (!element.checkVisibility()) return false;
    }
    if (style.visibility !== "visible") return false;

    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  const NATIVE_CONTROLS = ["BUTTON", "INPUT", "SELECT", "TEXTAREA", "OPTION", "OPTGROUP"];

  // A disabled <fieldset> disables what it contains — except the contents of
  // its own first <legend>, which stay usable. That exception is in the HTML
  // specification and is not the kind of thing anybody guesses.
  function inDisabledFieldset(element) {
    const fieldset = element.closest("FIELDSET[DISABLED]");
    if (!fieldset) return false;
    const legend = fieldset.querySelector(":scope > LEGEND");
    return !legend || !legend.contains(element);
  }

  function isDisabled(element) {
    if (NATIVE_CONTROLS.indexOf(element.tagName.toUpperCase()) === -1) return false;
    if (element.hasAttribute("disabled")) return true;
    if (element.tagName.toUpperCase() === "OPTION" && element.closest("OPTGROUP[DISABLED]")) return true;
    return inDisabledFieldset(element);
  }

  // Only the native half of the question. Playwright also honours `aria-disabled`
  // and `aria-readonly` on elements whose ARIA role allows them, which needs the
  // role computation this shard deliberately does not have yet.
  function isReadonly(element) {
    const tag = element.tagName.toUpperCase();
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return element.hasAttribute("readonly");
    if (element.isContentEditable) return false;
    return "error";
  }

  function elementState(node, state) {
    const element = retarget(node, state === "visible" || state === "hidden" ? "none" : "follow-label");
    if (!element || !element.isConnected) {
      if (state === "hidden") return { matches: true, received: "hidden" };
      return { matches: false, received: "error:notconnected" };
    }

    if (state === "visible" || state === "hidden") {
      const visible = isVisible(element);
      return { matches: state === "visible" ? visible : !visible, received: visible ? "visible" : "hidden" };
    }
    if (state === "disabled" || state === "enabled") {
      const disabled = isDisabled(element);
      return { matches: state === "disabled" ? disabled : !disabled, received: disabled ? "disabled" : "enabled" };
    }
    if (state === "editable") {
      const disabled = isDisabled(element);
      const readonly = isReadonly(element);
      if (readonly === "error") {
        throw new Error(
          "Element is not an <input>, <textarea>, <select> or [contenteditable], so it cannot be edited."
        );
      }
      return {
        matches: !disabled && !readonly,
        received: disabled ? "disabled" : readonly ? "readOnly" : "editable",
      };
    }
    throw new Error("Unexpected element state: " + state);
  }

  // Holds still for `STABLE_FRAMES` consecutive animation frames.
  //
  // Compared frame to frame rather than sampled twice with a delay: an element
  // that is moving smoothly is caught on the very next frame, and one that is
  // already at rest costs two frames rather than a fixed wait.
  function checkElementIsStable(node) {
    return new Promise((resolve) => {
      let lastRect = null;
      let stableFrames = 0;
      let lastTime = 0;

      const check = () => {
        const element = retarget(node, "none");
        if (!element || !element.isConnected) return "error:notconnected";

        const time = performance.now();
        if (STABLE_FRAMES > 1 && time - lastTime < 15) return CONTINUE_POLLING;
        lastTime = time;

        const box = element.getBoundingClientRect();
        const rect = { x: box.left, y: box.top, width: box.width, height: box.height };
        if (lastRect) {
          const still =
            rect.x === lastRect.x && rect.y === lastRect.y &&
            rect.width === lastRect.width && rect.height === lastRect.height;
          if (!still) return false;
          if (++stableFrames >= STABLE_FRAMES) return true;
        }
        lastRect = rect;
        return CONTINUE_POLLING;
      };

      const frame = () => {
        const result = check();
        if (result === CONTINUE_POLLING) requestAnimationFrame(frame);
        else resolve(result);
      };
      requestAnimationFrame(frame);
    });
  }

  // Stability first, because it is the one that takes time: an element that is
  // still moving is not worth asking anything else about yet.
  async function checkElementStates(node, states) {
    if (states.indexOf("stable") !== -1) {
      const stable = await checkElementIsStable(node);
      if (stable === "error:notconnected") return { notConnected: true };
      if (stable === false) return { missingState: "stable" };
    }
    for (let i = 0; i < states.length; i++) {
      if (states[i] === "stable") continue;
      const result = elementState(node, states[i]);
      if (result.received === "error:notconnected") return { notConnected: true };
      if (!result.matches) return { missingState: states[i] };
    }
    return { done: true };
  }

  const enclosingShadowRootOrDocument = (element) => {
    let node = element;
    while (node.parentNode) node = node.parentNode;
    return node.nodeType === 11 || node.nodeType === 9 ? node : null;
  };

  const parentElementOrShadowHost = (element) => {
    if (element.parentElement) return element.parentElement;
    if (!element.parentNode) return undefined;
    if (element.parentNode.nodeType === 11 && element.parentNode.host) return element.parentNode.host;
    return undefined;
  };

  // Whether a click at this point would reach the element we mean.
  //
  // Not "is the element visible": a transparent overlay is perfectly visible
  // and still eats the click. The walk descends one shadow root at a time,
  // because `elementFromPoint` stops at each boundary, and the answer names the
  // element that got in the way — which is the whole value of it, since
  // "element is not clickable" without saying what covered it is a message that
  // sends you to the browser's own devtools anyway.
  function expectHitTarget(hitPoint, targetElement) {
    const roots = [];
    let parentElement = targetElement;
    while (parentElement) {
      const root = enclosingShadowRootOrDocument(parentElement);
      if (!root) break;
      roots.push(root);
      if (root.nodeType === 9) break;
      parentElement = root.host;
    }

    let hitElement;
    for (let index = roots.length - 1; index >= 0; index--) {
      const root = roots[index];
      const elements = root.elementsFromPoint(hitPoint.x, hitPoint.y);
      const single = root.elementFromPoint(hitPoint.x, hitPoint.y);

      if (single && elements[0] && parentElementOrShadowHost(single) === elements[0]) {
        const style = computedStyle(single);
        if (style && style.display === "contents") elements.unshift(single);
      }
      if (elements[0] && elements[0].shadowRoot === root && elements[1] === single) elements.shift();

      const inner = elements[0];
      if (!inner) break;
      hitElement = inner;
      if (index && inner !== roots[index - 1].host) break;
    }

    const hitParents = [];
    while (hitElement && hitElement !== targetElement) {
      hitParents.push(hitElement);
      hitElement = hitElement.assignedSlot || parentElementOrShadowHost(hitElement);
    }
    if (hitElement === targetElement) return { done: true };

    const description = previewNode(hitParents[0] || document.documentElement);

    // The topmost thing in the way that is not also an ancestor of the target —
    // a dialog overlaying the page, rather than the particular <div> inside it
    // that happened to be under the cursor.
    let rootDescription;
    let element = targetElement;
    while (element) {
      const index = hitParents.indexOf(element);
      if (index !== -1) {
        if (index > 1) rootDescription = previewNode(hitParents[index - 1]);
        break;
      }
      element = parentElementOrShadowHost(element);
    }

    return {
      hitTargetDescription: rootDescription ? description + " from " + rootDescription + " subtree" : description,
    };
  }

  const MOUSE_EVENTS = ["mousedown", "mouseup", "pointerdown", "pointerup", "click", "auxclick", "dblclick", "contextmenu"];
  const HOVER_EVENTS = ["mousemove", "pointermove"];

  // Watches the events an action is about to produce and checks, for each one,
  // that the point it landed on still belongs to the element.
  //
  // The check before the click answers "is it clear now". This answers "was it
  // still clear when the event actually arrived", which is a different question
  // on a page whose layout is moving: there is a gap between aiming and firing,
  // and a banner sliding in during that gap is the classic way a passing suite
  // starts clicking the wrong thing once a week.
  function setupHitTargetInterceptor(node, action, hitPoint) {
    const element = retarget(node, "button-link");
    if (!element || !element.isConnected) return "error:notconnected";

    if (hitPoint) {
      const preliminary = expectHitTarget(hitPoint, element);
      if (!preliminary.done) return preliminary.hitTargetDescription;
    }

    const watched = action === "hover" ? HOVER_EVENTS : MOUSE_EVENTS;
    let outcome;

    const listener = (event) => {
      if (watched.indexOf(event.type) === -1) return;
      if (outcome === undefined && typeof event.clientX === "number") {
        outcome = expectHitTarget({ x: event.clientX, y: event.clientY }, element);
      }
      if (outcome && !outcome.done) {
        // Something got in the way between aiming and firing. The event is
        // stopped rather than allowed through, because a click that lands on
        // the wrong element is worse than one that does not land at all.
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
      }
    };

    const all = MOUSE_EVENTS.concat(HOVER_EVENTS);
    for (let i = 0; i < all.length; i++) window.addEventListener(all[i], listener, true);

    return {
      stop: () => {
        for (let i = 0; i < all.length; i++) window.removeEventListener(all[i], listener, true);
        if (!outcome || outcome.done) return { done: true };
        return outcome;
      },
    };
  }

  // Live interceptors, keyed by a token the caller made up.
  //
  // Not one slot: two fibers driving one page is an ordinary thing to do, and a
  // single slot would have the second action tear down the first one's
  // interceptor and then read its answer.
  const interceptors = new Map();

  // Clears an input and puts a value in it, the way a person would rather than
  // by assignment: `value = x` sets the property without any of the events a
  // framework listens for, so React and friends never learn the field changed.
  function fillNode(node, value) {
    const element = retarget(node, "follow-label");
    if (!element || !element.isConnected) return "error:notconnected";

    const state = elementState(element, "editable");
    if (!state.matches) return { missingState: "editable" };

    if (element.tagName === "INPUT" || element.tagName === "TEXTAREA") {
      const type = (element.getAttribute("type") || "text").toLowerCase();
      element.focus();
      element.selectionStart = 0;
      element.selectionEnd = element.value.length;
      // Reported as an empty field first, so that a listener sees the clear and
      // the fill as separate events, which is what typing looks like.
      if (element.value !== "") {
        element.value = "";
        element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
      }
      return { needsTyping: true, type: type };
    }

    if (element.isContentEditable) {
      element.focus();
      const selection = document.getSelection();
      const range = document.createRange();
      range.selectNodeContents(element);
      selection.removeAllRanges();
      selection.addRange(range);
      return { needsTyping: true, type: "contenteditable" };
    }

    if (element.tagName === "SELECT") {
      return { missingState: "editable" };
    }

    return { missingState: "editable" };
  }

  function scrollNodeIntoView(node, options) {
    const element = retarget(node, "none");
    if (!element || !element.isConnected) return "error:notconnected";
    if (options) element.scrollIntoView(options);
    return { done: true };
  }

  function nodeValue(node) {
    const element = retarget(node, "follow-label");
    if (!element) return null;
    if (element.tagName === "INPUT" || element.tagName === "TEXTAREA" || element.tagName === "SELECT") {
      return element.value;
    }
    return element.isContentEditable ? element.textContent : null;
  }

  // What Crystal can ask for by name. Arguments arrive through the same tagged
  // format `evaluate` uses, so an element is a handle and a selector is a
  // string that is never compiled as code.
  const api = {
    querySelector: (selector, root) => query(selector, root, false)[0] || null,
    querySelectorAll: (selector, root) => query(selector, root, true),
    visible: (element) => isVisible(element),
    textContent: (element) => element.textContent,
    innerText: (element) => element.innerText,
    getAttribute: (element, name) => element.getAttribute(name),
    previewNode: (node) => previewNode(node),

    // One round trip per poll answers "is it there yet" for every state,
    // including the two that are about absence.
    selectorState: (selector, root, state) => {
      const element = query(selector, root, false)[0] || null;
      if (state === "attached") return element ? { found: true } : { found: false };
      if (state === "detached") return { found: !element };
      if (state === "visible") return element && isVisible(element) ? { found: true } : { found: false };
      if (state === "hidden") return { found: !element || !isVisible(element) };
      throw new Error("Unknown selector state: " + state);
    },

    checkStates: (element, states) => checkElementStates(element, states),
    elementState: (element, state) => elementState(element, state),
    expectHitTarget: (element, x, y) => expectHitTarget({ x: x, y: y }, retarget(element, "button-link")),

    interceptHitTarget: (element, action, x, y, token) => {
      const installed = setupHitTargetInterceptor(element, action, { x: x, y: y });
      if (installed === "error:notconnected") return { notConnected: true };
      if (typeof installed === "string") return { hitTargetDescription: installed };
      interceptors.set(token, installed);
      return { done: true };
    },

    stopInterception: (token) => {
      const installed = interceptors.get(token);
      if (!installed) return { done: true };
      interceptors.delete(token);
      return installed.stop();
    },
    scrollIntoView: (element, options) => scrollNodeIntoView(element, options),
    prepareFill: (element, value) => fillNode(element, value),
    value: (element) => nodeValue(element),
    focus: (element) => {
      const target = retarget(element, "follow-label");
      if (!target || !target.isConnected) return "error:notconnected";
      target.focus();
      return { done: true };
    },
    viewport: () => ({ width: window.innerWidth, height: window.innerHeight }),
  };


  return {
    // Called through Runtime.callFunctionOn with this object as the receiver.
    //
    // `target` is the caller's source, already compiled by Chrome as part of the
    // function declaration — there is no eval here, which is what lets this work
    // under a page's Content-Security-Policy. A source that evaluates to a
    // function is called with the arguments; anything else is the result.
    evaluate(payload, handles, target) {
      const refs = new Map();
      const args = [];
      const tagged = payload.a || [];
      for (let i = 0; i < tagged.length; i++) args.push(parse(tagged[i], handles, refs));

      if (typeof target !== "function") {
        if (args.length) {
          throw new Error(
            "Arguments were passed but the source is not a function, so there is " +
              "nowhere for them to go. Write it as \"(a, b) => ...\"."
          );
        }
        return finish(target, payload.r);
      }

      const result = target.apply(null, args);
      if (result && typeof result.then === "function") {
        return result.then((resolved) => finish(resolved, payload.r));
      }
      return finish(result, payload.r);
    },

    // Calls one of this script's own functions by name.
    //
    // Separate from `evaluate` because the caller's source is not involved:
    // there is nothing to compile, and a selector travels as a string argument
    // rather than as code, which is what keeps `text="'); alert(1); //"` a
    // piece of text.
    invoke(name, payload, handles) {
      const refs = new Map();
      const args = [];
      const tagged = payload.a || [];
      for (let i = 0; i < tagged.length; i++) args.push(parse(tagged[i], handles, refs));

      const fn = api[name];
      if (!fn) throw new Error("No such utility function: " + name);

      // Some of these wait for the page — stability is measured across
      // animation frames — so a promise is a normal answer here, not an
      // accident of one function.
      const result = fn.apply(null, args);
      if (result && typeof result.then === "function") {
        return result.then((resolved) => finish(resolved, payload.r));
      }
      return finish(result, payload.r);
    },
  };
})()
