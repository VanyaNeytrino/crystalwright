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
      if (ENGINES[name] || FILTERS[name]) return { engine: name, body: step.slice(eq + 1).trim() };
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

  // `text=Sign in`    case-insensitive substring, whitespace collapsed
  // `text="Sign in"`  exact after collapsing, case sensitive
  // `text="Sign in"i` case-insensitive substring, same as the bare form
  // `text=/^Sign/i`   regular expression
  //
  // The quoted-with-`i` form exists so that a `Locator` can quote everything it
  // emits. An unquoted body is fine when a person writes it and dangerous when
  // a builder does: the first `>>` inside the text would be read as a step
  // separator, and the first quote as the start of one.
  function textMatcher(body) {
    if (body.length > 1 && body[0] === '"') {
      const end = body.lastIndexOf('"');
      if (end > 0) {
        const literal = normalizeText(JSON.parse(body.slice(0, end + 1)));
        if (body.slice(end + 1).indexOf("i") !== -1) {
          const needle = literal.toLowerCase();
          return (text) => text.toLowerCase().indexOf(needle) !== -1;
        }
        return (text) => text === literal;
      }
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

  // Elements carrying an attribute whose text matches — `placeholder=`, `alt=`,
  // `title=`. One shape covers all three, because the only thing that differs
  // is which attribute is read.
  const attributeEngine = (attribute) => (root, body, all) => {
    const matches = textMatcher(body);
    const found = [];
    const scopes = scopesUnder(root);
    for (let s = 0; s < scopes.length; s++) {
      const candidates = scopes[s].querySelectorAll("[" + attribute + "]");
      for (let i = 0; i < candidates.length; i++) {
        if (!matches(normalizeText(candidates[i].getAttribute(attribute)))) continue;
        found.push(candidates[i]);
        if (!all) return found;
      }
    }
    return found;
  };

  // The control a label names, not the label itself.
  //
  // `label.control` is the platform's own answer and covers both spellings —
  // `<label for=...>` and a control nested inside the label — which is not
  // something worth reimplementing from the HTML specification by hand.
  // `aria-label` is included because for a control with no visible label it is
  // the only name there is.
  function queryLabel(root, body, all) {
    const matches = textMatcher(body);
    const found = [];
    const scopes = scopesUnder(root);

    for (let s = 0; s < scopes.length; s++) {
      const labels = scopes[s].querySelectorAll("label");
      for (let i = 0; i < labels.length; i++) {
        if (!matches(normalizeText(labels[i].textContent))) continue;
        const control = labels[i].control;
        if (!control) continue;
        found.push(control);
        if (!all) return found;
      }

      const labelled = scopes[s].querySelectorAll("[aria-label]");
      for (let i = 0; i < labelled.length; i++) {
        if (!matches(normalizeText(labelled[i].getAttribute("aria-label")))) continue;
        if (found.indexOf(labelled[i]) !== -1) continue;
        found.push(labelled[i]);
        if (!all) return found;
      }
    }
    return found;
  }

  const ENGINES = {
    css: (root, body, all) => queryCSS(root, body, true, all),
    "css:light": (root, body, all) => queryCSS(root, body, false, all),
    text: (root, body, all) => queryText(root, body, all),
    xpath: (root, body, all) => queryXPath(root, body, all),
    id: (root, body, all) => queryCSS(root, "[id=" + cssQuote(body) + "]", true, all),
    label: queryLabel,
    placeholder: attributeEngine("placeholder"),
    alt: attributeEngine("alt"),
    title: attributeEngine("title"),
    "data-testid": (root, body, all) => queryCSS(root, "[data-testid=" + cssQuote(body) + "]", true, all),
    // The one engine that has to look at every element rather than ask the
    // browser: a role is computed, not stored, so there is nothing to select on.
    role: (root, body, all) => queryRole(root, body, all),
  };

  // Steps that narrow the set found so far instead of searching inside it.
  //
  // `div >> nth=1` is not "the second div inside each div" — it is the second
  // of the divs. The distinction is invisible until a selector has two steps,
  // and then it is the whole meaning.
  const FILTERS = {
    nth: (elements, body) => {
      const index = parseInt(body, 10);
      if (isNaN(index)) throw new Error("nth= needs a number, got " + JSON.stringify(body));
      const picked = index < 0 ? elements[elements.length + index] : elements[index];
      return picked ? [picked] : [];
    },

    // Contains the text anywhere inside it — unlike the `text` engine, which
    // takes the smallest element that has it. `filter(has_text:)` is about
    // picking one row out of a table by something inside the row.
    "internal:has-text": (elements, body) => {
      const matches = textMatcher(body);
      return elements.filter((element) => matches(normalizeText(element.textContent)));
    },

    // The body is a whole selector, and it arrives quoted, because a nested
    // selector is data at this level: `internal:has="span >> b"` is one step
    // carrying two, and unquoting it is what turns it back into two.
    "internal:has": (elements, body) => {
      const inner = body.length > 1 && body[0] === '"' ? JSON.parse(body) : body;
      return elements.filter((element) => query(inner, element, false, false).length > 0);
    },

    visible: (elements, body) => {
      const wanted = body !== "false";
      return elements.filter((element) => isVisible(element) === wanted);
    },
  };

  function strictViolation(selector, matches) {
    const shown = matches.slice(0, 5).map((element, index) => "\n  " + (index + 1) + ") " + previewNode(element));
    if (matches.length > shown.length) shown.push("\n  ...");
    return new Error(
      "strict mode violation: " + selector + " resolved to " + matches.length + " elements:" +
        shown.join("") +
        "\n\nUse .nth(), .first or .last to say which one, or narrow the selector."
    );
  }

  function query(selector, root, all, strict) {
    const steps = splitSteps(selector);
    if (!steps.length) throw new Error("The selector is empty.");

    let current = [root || document];
    let searched = false;

    for (let s = 0; s < steps.length; s++) {
      const step = parseStep(steps[s]);

      if (FILTERS[step.engine]) {
        if (!searched) {
          throw new Error(step.engine + "= has nothing to narrow: it has to follow a selector.");
        }
        current = FILTERS[step.engine](current, step.body);
      } else {
        const engine = ENGINES[step.engine];
        const next = [];
        const seen = new Set();

        // Every branch is explored even when the caller wants one element in
        // the end. The first match of step one need not be the one whose
        // subtree contains step two — and strict mode has to know how many
        // there were, which is a question that cannot be answered early.
        for (let c = 0; c < current.length; c++) {
          const hits = engine(current[c], step.body, true);
          for (let h = 0; h < hits.length; h++) {
            if (seen.has(hits[h])) continue;
            seen.add(hits[h]);
            next.push(hits[h]);
          }
        }
        current = next;
        searched = true;
      }

      if (!current.length) return [];
    }

    if (strict && current.length > 1) throw strictViolation(selector, current);
    return all ? current : current.slice(0, 1);
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

  const computedStyle = (element, pseudo) => {
    const view = element.ownerDocument && element.ownerDocument.defaultView;
    return view ? view.getComputedStyle(element, pseudo) : null;
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

  // Only the native half of the question. The ARIA half is added in
  // `elementState`, and it has to stay separate: role computation asks whether
  // an element is focusable, focusability asks whether it is disabled, and an
  // aria-aware answer there would make a `role="button" aria-disabled="true"`
  // change its own role.
  function isReadonly(element) {
    const tag = element.tagName.toUpperCase();
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return element.hasAttribute("readonly");
    if (element.isContentEditable) return false;
    return "error";
  }

  const READONLY_ROLES = ["checkbox", "combobox", "grid", "gridcell", "listbox", "radiogroup",
    "slider", "spinbutton", "textbox", "columnheader", "rowheader", "searchbox", "switch",
    "treegrid"];

  // The native answer, then the ARIA one. `aria-readonly` only means anything
  // on a role that could be read-only: on a `<div>` with no role it is a
  // decoration the page put there, and honouring it would make an ordinary
  // element uneditable for no reason a caller could see.
  function ariaReadonly(element) {
    const tag = elementSafeTagName(element);
    // Order matters and is not the obvious one: the ARIA answer comes before
    // `contenteditable`, so a `role="textbox" aria-readonly="true"` on an
    // editable element is honoured rather than overruled by the fact that the
    // browser would let you type in it.
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
      return element.hasAttribute("readonly");
    }
    if (READONLY_ROLES.includes(ariaRole(element) || "")) {
      return element.getAttribute("aria-readonly") === "true";
    }
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
    if (state === "checked" || state === "unchecked") {
      const checked = checkedState(element);
      if (checked === "error") {
        throw new Error(
          "Element is not a checkbox, a radio, or anything with a role that can be checked."
        );
      }
      const received = checked === "mixed" ? "mixed" : checked ? "checked" : "unchecked";
      return { matches: received === state, received: received };
    }
    if (state === "disabled" || state === "enabled") {
      const disabled = ariaDisabled(element);
      return { matches: state === "disabled" ? disabled : !disabled, received: disabled ? "disabled" : "enabled" };
    }
    if (state === "editable") {
      const disabled = ariaDisabled(element);
      const readonly = ariaReadonly(element);
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
  // ---------------------------------------------------------------- roles --
  //
  // What a screen reader would call this element, and what it would call it.
  //
  // Two computations, both defined by specifications rather than by taste:
  // HTML-AAM maps an element to a role, and accname maps it to a name. They are
  // written out in full here rather than approximated, because a `get_by_role`
  // that is nearly right is worse than none: it finds the element on the page
  // it was written against and quietly stops finding it on the next one, and
  // the failure looks like the page changed.
  //
  // Checked against Playwright's own implementation, element by element, on a
  // fixture built to disagree — see the differential spec.

  // The tag name, upper-cased, and safe on a form.
  //
  // `form.tagName` is not the tag name when the form contains a control named
  // "tagName": named controls shadow properties on the form element itself. The
  // guard is for that one case and costs nothing everywhere else.
  function elementSafeTagName(element) {
    const tagName = element.tagName;
    if (typeof tagName === "string") {
      const first = tagName.charCodeAt(0);
      // A lower-cased tag name means an XML or foreign-content element, whose
      // case is significant; anything already upper-case is HTML.
      if (first >= 97 && first <= 122) return tagName.toUpperCase();
      return tagName;
    }
    return String(Element.prototype.getAttribute.call(element, "tagName") || "").toUpperCase() ||
      element.nodeName;
  }

  // `closest`, but stepping out of shadow roots instead of stopping at them.
  function closestCrossShadow(element, selector) {
    let node = element;
    while (node) {
      const found = node.closest(selector);
      if (found) return found;
      node = parentElementOrShadowHost(node);
    }
    return undefined;
  }

  // The elements an IDREF list points at, within the same root.
  function getIdRefs(element, ref) {
    if (!ref) return [];
    const root = enclosingShadowRootOrDocument(element);
    if (!root) return [];
    try {
      const ids = ref.split(" ").filter((id) => !!id);
      const seen = new Set();
      for (const id of ids) {
        // `getElementById` is not on a shadow root's interface in every engine,
        // so the escape is done here and a plain query is used.
        const found = root.querySelectorAll("#" + CSS.escape(id));
        if (found.length) seen.add(found[0]);
      }
      return [...seen];
    } catch (e) {
      return [];
    }
  }

  const ARIA_GLOBAL_ATTRIBUTES = [
    ["aria-atomic", null],
    ["aria-busy", null],
    ["aria-controls", null],
    ["aria-current", null],
    ["aria-describedby", null],
    ["aria-details", null],
    ["aria-dropeffect", null],
    ["aria-flowto", null],
    ["aria-grabbed", null],
    ["aria-hidden", null],
    ["aria-keyshortcuts", null],
    // Prohibited on the roles that have no accessible name of their own.
    ["aria-label", ["caption", "code", "deletion", "emphasis", "generic", "insertion",
      "paragraph", "presentation", "strong", "subscript", "superscript"]],
    ["aria-labelledby", ["caption", "code", "deletion", "emphasis", "generic", "insertion",
      "paragraph", "presentation", "strong", "subscript", "superscript"]],
    ["aria-live", null],
    ["aria-owns", null],
    ["aria-relevant", null],
    ["aria-roledescription", ["generic"]],
  ];

  function hasGlobalAriaAttribute(element, forRole) {
    return ARIA_GLOBAL_ATTRIBUTES.some(([attr, prohibited]) =>
      !(prohibited && prohibited.includes(forRole || "")) && element.hasAttribute(attr));
  }

  const hasTabIndex = (element) =>
    !Number.isNaN(Number(String(element.getAttribute("tabindex"))));

  function isNativelyFocusable(element) {
    const tag = elementSafeTagName(element);
    if (["BUTTON", "DETAILS", "SELECT", "TEXTAREA"].includes(tag)) return true;
    if (tag === "A" || tag === "AREA") return element.hasAttribute("href");
    if (tag === "INPUT") return !element.hidden;
    return false;
  }

  const isFocusable = (element) =>
    !isDisabled(element) && (isNativelyFocusable(element) || hasTabIndex(element));

  const hasExplicitAccessibleName = (element) =>
    element.hasAttribute("aria-label") || element.hasAttribute("aria-labelledby");

  // A landmark inside one of these is not a landmark: `<header>` in an
  // `<article>` is not the page's banner.
  const ANCESTOR_PREVENTING_LANDMARK =
    "article:not([role]), aside:not([role]), main:not([role]), nav:not([role]), " +
    "section:not([role]), [role=article], [role=complementary], [role=main], " +
    "[role=navigation], [role=region]";

  const INPUT_TYPE_TO_ROLE = {
    button: "button",
    checkbox: "checkbox",
    image: "button",
    number: "spinbutton",
    radio: "radio",
    range: "slider",
    reset: "button",
    submit: "button",
  };

  const isHeaderCell = (element) => !!element && elementSafeTagName(element) === "TH";

  const isNonEmptyDataCell = (element) => {
    if (!element || elementSafeTagName(element) !== "TD") return false;
    return !!((element.textContent || "").trim() || element.childElementCount);
  };

  // HTML-AAM: the role an element has when it does not claim one.
  const IMPLICIT_ROLE_BY_TAG = {
    A: (e) => (e.hasAttribute("href") ? "link" : null),
    AREA: (e) => (e.hasAttribute("href") ? "link" : null),
    ARTICLE: () => "article",
    ASIDE: () => "complementary",
    BLOCKQUOTE: () => "blockquote",
    BUTTON: () => "button",
    CAPTION: () => "caption",
    CODE: () => "code",
    DATALIST: () => "listbox",
    DD: () => "definition",
    DEL: () => "deletion",
    DETAILS: () => "group",
    DFN: () => "term",
    DIALOG: () => "dialog",
    DT: () => "term",
    EM: () => "emphasis",
    FIELDSET: () => "group",
    FIGURE: () => "figure",
    FOOTER: (e) => (closestCrossShadow(e, ANCESTOR_PREVENTING_LANDMARK) ? null : "contentinfo"),
    FORM: (e) => (hasExplicitAccessibleName(e) ? "form" : null),
    H1: () => "heading",
    H2: () => "heading",
    H3: () => "heading",
    H4: () => "heading",
    H5: () => "heading",
    H6: () => "heading",
    HEADER: (e) => (closestCrossShadow(e, ANCESTOR_PREVENTING_LANDMARK) ? null : "banner"),
    HR: () => "separator",
    HTML: () => "document",
    // An image with an empty alt and nothing else to say is decoration.
    IMG: (e) =>
      e.getAttribute("alt") === "" && !e.getAttribute("title") &&
        !hasGlobalAriaAttribute(e) && !hasTabIndex(e)
        ? "presentation"
        : "img",
    INPUT: (e) => {
      const type = (e.type || "").toLowerCase();
      if (["email", "search", "tel", "text", "url", ""].includes(type)) {
        const list = getIdRefs(e, e.getAttribute("list"))[0];
        if (list && elementSafeTagName(list) === "DATALIST") return "combobox";
        return type === "search" ? "searchbox" : "textbox";
      }
      if (type === "hidden") return null;
      if (type === "file") return "button";
      return INPUT_TYPE_TO_ROLE[type] || "textbox";
    },
    INS: () => "insertion",
    LI: () => "listitem",
    MAIN: () => "main",
    MARK: () => "mark",
    MATH: () => "math",
    MENU: () => "list",
    METER: () => "meter",
    NAV: () => "navigation",
    OL: () => "list",
    OPTGROUP: () => "group",
    OPTION: () => "option",
    OUTPUT: () => "status",
    P: () => "paragraph",
    PROGRESS: () => "progressbar",
    SEARCH: () => "search",
    SECTION: (e) => (hasExplicitAccessibleName(e) ? "region" : null),
    SELECT: (e) => (e.hasAttribute("multiple") || e.size > 1 ? "listbox" : "combobox"),
    STRONG: () => "strong",
    SUB: () => "subscript",
    SUP: () => "superscript",
    // Chrome reports `img` for `<svg>`; Firefox says `diagram`, which is not in
    // the specification yet, and Safari reports none. Following the browser
    // this shard drives.
    SVG: () => "img",
    TABLE: () => "table",
    TBODY: () => "rowgroup",
    TD: (e) => {
      const table = closestCrossShadow(e, "table");
      const role = table ? getExplicitAriaRole(table) : "";
      return role === "grid" || role === "treegrid" ? "gridcell" : "cell";
    },
    TEXTAREA: () => "textbox",
    TFOOT: () => "rowgroup",
    // A header cell is a column header or a row header depending on where it
    // sits, and `scope` only sometimes says which. The rest is the algorithm
    // HTML-AAM spells out, and it is the reason this table cannot be a map.
    TH: (e) => {
      const scope = e.getAttribute("scope");
      if (scope === "col" || scope === "colgroup") return "columnheader";
      if (scope === "row" || scope === "rowgroup") return "rowheader";
      const next = e.nextElementSibling;
      const previous = e.previousElementSibling;
      const row = e.parentElement && elementSafeTagName(e.parentElement) === "TR"
        ? e.parentElement
        : undefined;
      if (!next && !previous) {
        if (row) {
          const table = closestCrossShadow(row, "table");
          if (table && table.rows.length <= 1) return null;
        }
        return "columnheader";
      }
      if (isHeaderCell(next) && isHeaderCell(previous)) return "columnheader";
      if (isNonEmptyDataCell(next) || isNonEmptyDataCell(previous)) return "rowheader";
      return "columnheader";
    },
    THEAD: () => "rowgroup",
    TIME: () => "time",
    TR: () => "row",
    UL: () => "list",
  };

  // A `role="presentation"` on one of these is inherited by the children that
  // only make sense inside it: a presentational list has presentational items.
  const PRESENTATION_INHERITANCE_PARENTS = {
    DD: ["DL", "DIV"],
    DIV: ["DL"],
    DT: ["DL", "DIV"],
    LI: ["OL", "UL"],
    TBODY: ["TABLE"],
    TD: ["TR"],
    TFOOT: ["TABLE"],
    TH: ["TR"],
    THEAD: ["TABLE"],
    TR: ["THEAD", "TBODY", "TFOOT", "TABLE"],
  };

  const VALID_ROLES = new Set([
    "alert", "alertdialog", "application", "article", "banner", "blockquote", "button",
    "caption", "cell", "checkbox", "code", "columnheader", "combobox", "complementary",
    "contentinfo", "definition", "deletion", "dialog", "directory", "document", "emphasis",
    "feed", "figure", "form", "generic", "grid", "gridcell", "group", "heading", "img",
    "insertion", "link", "list", "listbox", "listitem", "log", "main", "mark", "marquee",
    "math", "meter", "menu", "menubar", "menuitem", "menuitemcheckbox", "menuitemradio",
    "navigation", "none", "note", "option", "paragraph", "presentation", "progressbar",
    "radio", "radiogroup", "region", "row", "rowgroup", "rowheader", "scrollbar", "search",
    "searchbox", "separator", "slider", "spinbutton", "status", "strong", "subscript",
    "superscript", "switch", "tab", "table", "tablist", "tabpanel", "term", "textbox",
    "time", "timer", "toolbar", "tooltip", "tree", "treegrid", "treeitem",
  ]);

  // The first token of `role` that names a real role. A page that writes
  // `role="link button"` gets `link`, and one that writes nonsense gets its
  // implicit role rather than nothing.
  function getExplicitAriaRole(element) {
    const tokens = (element.getAttribute("role") || "").split(" ").map((t) => t.trim());
    return tokens.find((token) => VALID_ROLES.has(token)) || null;
  }

  const hasPresentationConflictResolution = (element, role) =>
    hasGlobalAriaAttribute(element, role) || isFocusable(element);

  function getImplicitAriaRole(element) {
    const compute = IMPLICIT_ROLE_BY_TAG[elementSafeTagName(element)];
    const implicit = (compute ? compute(element) : null) || "";
    if (!implicit) return null;

    let ancestor = element;
    while (ancestor) {
      const parent = parentElementOrShadowHost(ancestor);
      const parents = PRESENTATION_INHERITANCE_PARENTS[elementSafeTagName(ancestor)];
      if (!parents || !parent || !parents.includes(elementSafeTagName(parent))) break;
      const parentRole = getExplicitAriaRole(parent);
      if ((parentRole === "none" || parentRole === "presentation") &&
        !hasPresentationConflictResolution(parent, parentRole)) {
        return parentRole;
      }
      ancestor = parent;
    }
    return implicit;
  }

  // `role="presentation"` is a request, not a fact: an element that is focusable
  // or carries a global ARIA attribute keeps the role it really has, because
  // hiding it from assistive technology while leaving it operable is a
  // contradiction the specification resolves in favour of the user.
  function ariaRole(element) {
    const explicit = getExplicitAriaRole(element);
    if (!explicit) return getImplicitAriaRole(element);
    if (explicit === "none" || explicit === "presentation") {
      const implicit = getImplicitAriaRole(element);
      if (hasPresentationConflictResolution(element, implicit)) return implicit;
    }
    return explicit;
  }

  // ---------------------------------------------------- accessible names --
  //
  // What a screen reader would read out for this element. The algorithm is
  // accname, and it is longer than it looks: a name can come from a reference
  // to elsewhere on the page, from an attribute, from the element's own text,
  // or from CSS that inserted content the DOM never had — and the order those
  // are tried in is the whole specification.
  //
  // Reference traversal is why the visited set exists. `aria-labelledby`
  // pointing at an ancestor, or at the element itself, is not an error a page
  // will ever fix; it is something to survive.

  const IGNORED_FOR_ARIA = ["STYLE", "SCRIPT", "NOSCRIPT", "TEMPLATE"];
  const isElementIgnoredForAria = (element) =>
    IGNORED_FOR_ARIA.includes(elementSafeTagName(element));

  const ariaBoolean = (value) => (value === null ? undefined : value.toLowerCase() === "true");

  // Hidden as far as a name is concerned, which is not the same question the
  // pointer asks: an element scrolled off screen still has a name, and one that
  // is `display: none` does not.
  function belongsToHiddenSubtree(element) {
    let node = element;
    while (node) {
      if (node.parentElement && node.parentElement.shadowRoot && !node.assignedSlot) return true;
      const style = computedStyle(node);
      if (!style || style.display === "none") return true;
      if (ariaBoolean(node.getAttribute("aria-hidden")) === true) return true;
      node = parentElementOrShadowHost(node);
    }
    return false;
  }

  // Visible enough to have a name.
  //
  // `visibility` alone is not the whole question: the content of a closed
  // `<details>` reports `display: block` and is not rendered at all, and the
  // only thing that knows is the browser. `checkVisibility` is that answer,
  // and the fallback is the `<details>` case written out, because it is the
  // one that actually comes up.
  function isStyleVisibleForAria(element, style) {
    if (!style) return true;
    // Both, because they answer different questions: `checkVisibility` knows
    // about rendering — a closed `<details>` reports `display: block` for
    // content the browser never draws — and it deliberately says nothing about
    // `visibility: hidden` unless asked.
    if (Element.prototype.checkVisibility && !element.checkVisibility()) return false;
    if (!Element.prototype.checkVisibility) {
      const container = element.closest("details,summary");
      if (container !== element && container && container.nodeName === "DETAILS" && !container.open) {
        return false;
      }
    }
    return style.visibility === "visible";
  }

  function isElementHiddenForAria(element) {
    if (isElementIgnoredForAria(element)) return true;
    const style = computedStyle(element);
    const isSlot = element.nodeName === "SLOT";
    if (style && style.display === "contents" && !isSlot) {
      for (let child = element.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === 1 && !isElementHiddenForAria(child)) return false;
        if (child.nodeType === 3 && visibleTextNode(child)) return false;
      }
      return true;
    }
    // An `<option>` inside a `<select>` has no box of its own and is not
    // hidden for that reason; neither is a slot.
    const isOptionInsideSelect = element.nodeName === "OPTION" && !!element.closest("select");
    if (!isOptionInsideSelect && !isSlot && !isStyleVisibleForAria(element, style)) return true;
    return belongsToHiddenSubtree(element);
  }

  // Whitespace as accname flattens it: runs collapse, zero-width characters and
  // soft hyphens vanish, and a non-breaking space is left alone because it is a
  // character the page chose rather than formatting.
  function asFlatString(text) {
    // A non-breaking space is a character the page chose and survives; a
    // zero-width space and a soft hyphen are formatting and do not. Written as
    // escapes rather than as themselves, because an invisible character in
    // source is a trap for whoever edits the line next.
    const NBSP = "\u00a0";
    return text
      .split(NBSP)
      .map((chunk) => chunk
        .replace(/\r\n/g, "\n")
        .replace(/[\u200b\u00ad]/g, "")
        .replace(/\s\s*/g, " "))
      .join(NBSP)
      .trim();
  }

  // What CSS put in front of or behind the element's own content.
  //
  // Only string literals and `attr()` are honoured. Counters and images have no
  // text to contribute, and a page that names a button with a counter has a
  // problem this shard is not going to solve.
  function parseCSSContent(element, value, isPseudo) {
    if (!value || value === "none" || value === "normal") return undefined;
    const parts = [];
    const pattern = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|attr\(\s*([\w-]+)\s*\)|(\S+)/g;
    let match;
    while ((match = pattern.exec(value)) !== null) {
      if (match[1] !== undefined) parts.push(match[1].replace(/\\(.)/g, "$1"));
      else if (match[2] !== undefined) parts.push(match[2].replace(/\\(.)/g, "$1"));
      else if (match[3] !== undefined) parts.push(element.getAttribute(match[3]) || "");
      else if (!isPseudo) return undefined;
    }
    return parts.join("");
  }

  function getCSSContent(element, pseudo) {
    const style = computedStyle(element, pseudo);
    let content;
    if (style) {
      const value = style.content;
      if (value && value !== "none" && value !== "normal" &&
        style.display !== "none" && style.visibility !== "hidden") {
        content = parseCSSContent(element, value, !!pseudo);
      }
    }
    if (pseudo && content !== undefined) {
      const display = (style && style.display) || "inline";
      if (display !== "inline") content = " " + content + " ";
    }
    return content;
  }

  const ariaLabelledByElements = (element) => {
    const ref = element.getAttribute("aria-labelledby");
    if (ref === null) return null;
    const refs = getIdRefs(element, ref);
    return refs.length ? refs : null;
  };

  function queryInAriaOwned(element, selector) {
    const result = [...element.querySelectorAll(selector)];
    for (const owned of getIdRefs(element, element.getAttribute("aria-owns"))) {
      if (owned.matches(selector)) result.push(owned);
      result.push(...owned.querySelectorAll(selector));
    }
    return result;
  }

  // Roles whose own content is their name.
  const ALWAYS_NAME_FROM_CONTENT = ["button", "cell", "checkbox", "columnheader", "gridcell",
    "heading", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "row",
    "rowheader", "switch", "tab", "tooltip", "treeitem"];

  // And roles that contribute their content when they are inside one of those.
  const DESCENDANT_NAME_FROM_CONTENT = ["", "caption", "code", "contentinfo", "definition",
    "deletion", "emphasis", "insertion", "list", "listitem", "mark", "none", "paragraph",
    "presentation", "region", "row", "rowgroup", "section", "strong", "subscript", "superscript",
    "table", "term", "time"];

  const allowsNameFromContent = (role, isDescendant) =>
    ALWAYS_NAME_FROM_CONTENT.includes(role) ||
    (isDescendant && DESCENDANT_NAME_FROM_CONTENT.includes(role));

  // Roles that have no name of their own at all.
  const NAMING_PROHIBITED = ["caption", "code", "definition", "deletion", "emphasis", "generic",
    "insertion", "mark", "paragraph", "presentation", "strong", "subscript", "suggestion",
    "superscript", "term", "time"];

  function accumulatedElementText(element, options) {
    const tokens = [];
    const visit = (node, skipSlotted) => {
      if (skipSlotted && node.assignedSlot) return;
      if (node.nodeType === 1) {
        const style = computedStyle(node);
        const display = (style && style.display) || "inline";
        let token = textAlternative(node, options);
        // A block-level child is a word boundary; an inline one is not. This is
        // the difference between "SaveChanges" and "Save Changes".
        if (display !== "inline" || node.nodeName === "BR") token = " " + token + " ";
        tokens.push(token);
      } else if (node.nodeType === 3) {
        tokens.push(node.textContent || "");
      }
    };

    tokens.push(getCSSContent(element, "::before") || "");
    const content = getCSSContent(element);
    if (content !== undefined) {
      tokens.push(content);
    } else {
      const assigned = element.nodeName === "SLOT" ? element.assignedNodes() : [];
      if (assigned.length) {
        for (const child of assigned) visit(child, false);
      } else {
        for (let child = element.firstChild; child; child = child.nextSibling) visit(child, true);
        if (element.shadowRoot) {
          for (let child = element.shadowRoot.firstChild; child; child = child.nextSibling) {
            visit(child, true);
          }
        }
        for (const owned of getIdRefs(element, element.getAttribute("aria-owns"))) visit(owned, true);
      }
    }
    tokens.push(getCSSContent(element, "::after") || "");
    return tokens.join("");
  }

  function labelsOf(element) {
    try {
      return [...(element.labels || [])];
    } catch (e) {
      return [];
    }
  }

  function nameFromLabels(labels, options) {
    return labels
      .map((label) => textAlternative(label, {
        ...options,
        embeddedInLabel: { element: label, hidden: isElementHiddenForAria(label) },
        embeddedInNativeTextAlternative: undefined,
        embeddedInLabelledBy: undefined,
        embeddedInTargetElement: undefined,
      }))
      .filter((text) => !!text)
      .join(" ");
  }

  // The algorithm itself. `options.embeddedIn*` is how the specification's
  // "traversal context" is carried: the same element contributes different text
  // depending on why it is being asked.
  function textAlternative(element, options) {
    if (options.visitedElements.has(element)) return "";

    const childOptions = {
      ...options,
      embeddedInTargetElement:
        options.embeddedInTargetElement === "self" ? "descendant" : options.embeddedInTargetElement,
    };

    if (!options.includeHidden) {
      const insideHiddenReference =
        !!(options.embeddedInLabelledBy && options.embeddedInLabelledBy.hidden) ||
        !!(options.embeddedInNativeTextAlternative && options.embeddedInNativeTextAlternative.hidden) ||
        !!(options.embeddedInLabel && options.embeddedInLabel.hidden);
      if (isElementIgnoredForAria(element) ||
        (!insideHiddenReference && isElementHiddenForAria(element))) {
        options.visitedElements.add(element);
        return "";
      }
    }

    const labelledBy = ariaLabelledByElements(element);
    if (!options.embeddedInLabelledBy) {
      const referenced = (labelledBy || [])
        .map((ref) => textAlternative(ref, {
          ...options,
          embeddedInLabelledBy: { element: ref, hidden: isElementHiddenForAria(ref) },
          embeddedInTargetElement: undefined,
          embeddedInLabel: undefined,
          embeddedInNativeTextAlternative: undefined,
        }))
        .join(" ");
      if (referenced) return referenced;
    }

    const role = ariaRole(element) || "";
    const tag = elementSafeTagName(element);

    // A control being read as part of somebody else's name contributes its
    // value, not its label: a text box inside a label reads out what is typed
    // in it.
    if (options.embeddedInLabel || options.embeddedInLabelledBy ||
      options.embeddedInTargetElement === "descendant") {
      const isOwnLabel = labelsOf(element).includes(element);
      const isOwnLabelledBy = (labelledBy || []).includes(element);
      if (!isOwnLabel && !isOwnLabelledBy) {
        if (role === "textbox") {
          options.visitedElements.add(element);
          if (tag === "INPUT" || tag === "TEXTAREA") return element.value;
          return element.textContent || "";
        }
        if (role === "combobox" || role === "listbox") {
          options.visitedElements.add(element);
          let selected;
          if (tag === "SELECT") {
            selected = [...element.selectedOptions];
            if (!selected.length && element.options.length) selected.push(element.options[0]);
          } else {
            const listbox = role === "combobox"
              ? queryInAriaOwned(element, "*").find((e) => ariaRole(e) === "listbox")
              : element;
            selected = listbox
              ? queryInAriaOwned(listbox, '[aria-selected="true"]').filter((e) => ariaRole(e) === "option")
              : [];
          }
          if (!selected.length && tag === "INPUT") return element.value;
          return selected.map((option) => textAlternative(option, childOptions)).join(" ");
        }
        if (["progressbar", "scrollbar", "slider", "spinbutton", "meter"].includes(role)) {
          options.visitedElements.add(element);
          if (element.hasAttribute("aria-valuetext")) return element.getAttribute("aria-valuetext");
          if (element.hasAttribute("aria-valuenow")) return element.getAttribute("aria-valuenow");
          return element.getAttribute("value") || "";
        }
        if (role === "menu") {
          options.visitedElements.add(element);
          return "";
        }
      }
    }

    const ariaLabel = element.getAttribute("aria-label") || "";
    if (ariaLabel.trim()) {
      options.visitedElements.add(element);
      return ariaLabel;
    }

    if (!["presentation", "none"].includes(role)) {
      if (tag === "INPUT" && ["button", "submit", "reset"].includes(element.type)) {
        options.visitedElements.add(element);
        const value = element.value || "";
        if (value.trim()) return value;
        if (element.type === "submit") return "Submit";
        if (element.type === "reset") return "Reset";
        return element.getAttribute("title") || "";
      }
      if (tag === "INPUT" && element.type === "file") {
        options.visitedElements.add(element);
        const labels = labelsOf(element);
        if (labels.length && !options.embeddedInLabelledBy) return nameFromLabels(labels, options);
        return "Choose File";
      }
      if (tag === "INPUT" && element.type === "image") {
        options.visitedElements.add(element);
        const labels = labelsOf(element);
        if (labels.length && !options.embeddedInLabelledBy) return nameFromLabels(labels, options);
        const alt = element.getAttribute("alt") || "";
        if (alt.trim()) return alt;
        const title = element.getAttribute("title") || "";
        if (title.trim()) return title;
        return "Submit";
      }
      if (!labelledBy && tag === "BUTTON") {
        options.visitedElements.add(element);
        const labels = labelsOf(element);
        if (labels.length) return nameFromLabels(labels, options);
      }
      if (!labelledBy && tag === "OUTPUT") {
        options.visitedElements.add(element);
        const labels = labelsOf(element);
        if (labels.length) return nameFromLabels(labels, options);
        return element.getAttribute("title") || "";
      }
      if (!labelledBy && ["TEXTAREA", "SELECT", "INPUT", "METER", "PROGRESS"].includes(tag)) {
        options.visitedElements.add(element);
        const labels = labelsOf(element);
        if (labels.length) return nameFromLabels(labels, options);
        const usePlaceholder =
          (tag === "INPUT" &&
            ["text", "password", "number", "search", "tel", "email", "url"].includes(element.type)) ||
          tag === "TEXTAREA";
        const title = element.getAttribute("title") || "";
        if (!usePlaceholder || title) return title;
        return element.getAttribute("placeholder") || "";
      }
      if (!labelledBy && (tag === "FIELDSET" || tag === "FIGURE" || tag === "TABLE")) {
        const wanted = tag === "FIELDSET" ? "LEGEND" : tag === "FIGURE" ? "FIGCAPTION" : "CAPTION";
        options.visitedElements.add(element);
        for (let child = element.firstElementChild; child; child = child.nextElementSibling) {
          if (elementSafeTagName(child) === wanted) {
            return textAlternative(child, {
              ...childOptions,
              embeddedInNativeTextAlternative: { element: child, hidden: isElementHiddenForAria(child) },
            });
          }
        }
        if (tag === "TABLE") {
          const summary = element.getAttribute("summary") || "";
          if (summary) return summary;
        } else {
          return element.getAttribute("title") || "";
        }
      }
      if (tag === "IMG" || tag === "AREA") {
        options.visitedElements.add(element);
        const alt = element.getAttribute("alt") || "";
        if (alt.trim()) return alt;
        return element.getAttribute("title") || "";
      }
      if (tag === "SVG" || element.ownerSVGElement) {
        options.visitedElements.add(element);
        for (let child = element.firstElementChild; child; child = child.nextElementSibling) {
          if (elementSafeTagName(child) === "TITLE" && child.ownerSVGElement) {
            return textAlternative(child, {
              ...childOptions,
              embeddedInLabelledBy: { element: child, hidden: isElementHiddenForAria(child) },
            });
          }
        }
      }
      if (element.ownerSVGElement && tag === "A") {
        const title = element.getAttribute("xlink:title") || "";
        if (title.trim()) {
          options.visitedElements.add(element);
          return title;
        }
      }
    }

    // `<summary>` names itself from its content whatever its role says.
    const summaryNamesItself = tag === "SUMMARY" && !["presentation", "none"].includes(role);
    if (allowsNameFromContent(role, options.embeddedInTargetElement === "descendant") ||
      summaryNamesItself || options.embeddedInLabelledBy || options.embeddedInLabel ||
      options.embeddedInNativeTextAlternative) {
      options.visitedElements.add(element);
      const text = accumulatedElementText(element, childOptions);
      const trimmed = options.embeddedInTargetElement === "self" ? text.trim() : text;
      if (trimmed) return trimmed;
    }

    if (!["presentation", "none"].includes(role) || tag === "IFRAME" || tag === "FRAME") {
      options.visitedElements.add(element);
      const title = element.getAttribute("title") || "";
      if (title.trim()) return title;
    }

    options.visitedElements.add(element);
    return "";
  }

  function accessibleName(element, includeHidden) {
    if (NAMING_PROHIBITED.includes(ariaRole(element) || "")) return "";
    return asFlatString(textAlternative(element, {
      includeHidden: !!includeHidden,
      visitedElements: new Set(),
      embeddedInTargetElement: "self",
    }));
  }

  // ------------------------------------------------- states, and the query --
  //
  // The attributes `get_by_role` can filter on. Each is a small algorithm of
  // its own, and each is only meaningful for some roles: `aria-pressed` on a
  // `<div>` with no role means nothing, and a `<details>` is expanded or not
  // whatever it says.

  const CHECKED_ROLES = ["checkbox", "menuitemcheckbox", "option", "radio", "switch",
    "menuitemradio", "treeitem"];

  function ariaChecked(element) {
    const tag = elementSafeTagName(element);
    if (tag === "INPUT" && element.indeterminate) return "mixed";
    if (tag === "INPUT" && ["checkbox", "radio"].includes(element.type)) return element.checked;
    if (CHECKED_ROLES.includes(ariaRole(element) || "")) {
      const checked = element.getAttribute("aria-checked");
      if (checked === "true") return true;
      if (checked === "mixed") return "mixed";
      return false;
    }
    return false;
  }

  const PRESSED_ROLES = ["button"];

  function ariaPressed(element) {
    if (PRESSED_ROLES.includes(ariaRole(element) || "")) {
      const pressed = element.getAttribute("aria-pressed");
      if (pressed === "true") return true;
      if (pressed === "mixed") return "mixed";
    }
    return false;
  }

  const EXPANDED_ROLES = ["application", "button", "checkbox", "combobox", "gridcell", "link",
    "listbox", "menuitem", "row", "rowheader", "tab", "treeitem", "columnheader",
    "menuitemcheckbox", "menuitemradio", "switch"];

  function ariaExpanded(element) {
    if (elementSafeTagName(element) === "DETAILS") return element.open;
    if (EXPANDED_ROLES.includes(ariaRole(element) || "")) {
      const expanded = element.getAttribute("aria-expanded");
      if (expanded === null) return undefined;
      return expanded === "true";
    }
    return undefined;
  }

  const LEVEL_ROLES = ["heading", "listitem", "row", "treeitem"];
  const NATIVE_HEADING_LEVEL = { H1: 1, H2: 2, H3: 3, H4: 4, H5: 5, H6: 6 };

  function ariaLevel(element) {
    const native = NATIVE_HEADING_LEVEL[elementSafeTagName(element)];
    if (native) return native;
    if (LEVEL_ROLES.includes(ariaRole(element) || "")) {
      const attribute = element.getAttribute("aria-level");
      const value = attribute === null ? Number.NaN : Number(attribute);
      if (Number.isInteger(value) && value >= 1) return value;
    }
    return undefined;
  }

  const SELECTED_ROLES = ["gridcell", "option", "row", "tab", "rowheader", "columnheader",
    "treeitem"];

  function ariaSelected(element) {
    if (elementSafeTagName(element) === "OPTION") return element.selected;
    if (SELECTED_ROLES.includes(ariaRole(element) || "")) {
      return ariaBoolean(element.getAttribute("aria-selected")) === true;
    }
    return false;
  }

  const DISABLED_ROLES = ["application", "button", "composite", "gridcell", "group", "input",
    "link", "menuitem", "scrollbar", "separator", "tab", "checkbox", "columnheader", "combobox",
    "grid", "listbox", "menu", "menubar", "menuitemcheckbox", "menuitemradio", "option", "radio",
    "radiogroup", "row", "rowheader", "searchbox", "select", "slider", "spinbutton", "switch",
    "tablist", "textbox", "toolbar", "tree", "treegrid", "treeitem"];

  // `aria-disabled` is inherited until something says otherwise: a toolbar can
  // disable everything in it with one attribute, and a control inside can undo
  // that with `aria-disabled="false"`.
  function ariaDisabledInChain(element) {
    let node = element;
    while (node) {
      const attribute = (node.getAttribute("aria-disabled") || "").toLowerCase();
      if (attribute === "true") return true;
      if (attribute === "false") return false;
      node = parentElementOrShadowHost(node);
    }
    return false;
  }

  const ariaDisabled = (element) =>
    isDisabled(element) ||
    (DISABLED_ROLES.includes(ariaRole(element) || "") && ariaDisabledInChain(element));

  // `role=button[name="Save"i][checked][level=2]`
  //
  // Parsed rather than interpolated: the name arrives as a JSON string, so a
  // page whose button is called `"] [name="` is a button with an awkward name
  // rather than a way to write a different selector.
  function parseRoleSelector(body) {
    const match = /^([a-zA-Z]*)/.exec(body);
    const spec = { role: match[1], name: undefined, exact: false, includeHidden: false };
    let rest = body.slice(spec.role.length);
    const attribute = /^\[\s*([a-zA-Z-]+)\s*(?:=\s*("(?:[^"\\]|\\.)*"i?|[^\]]*?)\s*)?\]/;
    while (rest.length) {
      const found = attribute.exec(rest);
      if (!found) throw new Error("Unexpected input in role selector: " + rest);
      rest = rest.slice(found[0].length);
      const key = found[1];
      const raw = found[2];
      if (key === "name") {
        if (raw === undefined) throw new Error("role selector: name needs a value");
        if (raw.endsWith('"i')) {
          spec.name = JSON.parse(raw.slice(0, -1));
          spec.exact = false;
        } else {
          spec.name = JSON.parse(raw);
          spec.exact = true;
        }
      } else if (key === "level") {
        spec.level = Number(raw);
      } else if (key === "include-hidden") {
        spec.includeHidden = raw === undefined ? true : raw === "true";
      } else if (["checked", "pressed"].includes(key)) {
        spec[key] = raw === undefined ? true : raw === "mixed" ? "mixed" : raw === "true";
      } else if (["disabled", "expanded", "selected"].includes(key)) {
        spec[key] = raw === undefined ? true : raw === "true";
      } else {
        throw new Error("Unknown attribute in role selector: " + key);
      }
    }
    return spec;
  }

  function matchesRoleSpec(element, spec) {
    if (spec.role && ariaRole(element) !== spec.role) return false;
    // Hidden elements are out unless asked for. A name is computed as though
    // the element were shown, because "the button is hidden" is a thing a
    // caller wants told rather than a thing that should make it unfindable by
    // its own name.
    if (!spec.includeHidden && isElementHiddenForAria(element)) return false;

    if (spec.name !== undefined) {
      // Flattened twice today: `accessibleName` already does it, so removing
      // this turns nothing red. Kept because the two are separable — one
      // normalises a computed name, the other normalises before a comparison —
      // and labelled rather than trusted.
      const name = asFlatString(accessibleName(element, spec.includeHidden));
      const wanted = asFlatString(spec.name);
      if (spec.exact) {
        if (name !== wanted) return false;
      } else if (name.toLowerCase().indexOf(wanted.toLowerCase()) === -1) {
        return false;
      }
    }
    if (spec.checked !== undefined && ariaChecked(element) !== spec.checked) return false;
    if (spec.pressed !== undefined && ariaPressed(element) !== spec.pressed) return false;
    if (spec.selected !== undefined && ariaSelected(element) !== spec.selected) return false;
    if (spec.disabled !== undefined && ariaDisabled(element) !== spec.disabled) return false;
    if (spec.expanded !== undefined && ariaExpanded(element) !== spec.expanded) return false;
    if (spec.level !== undefined && ariaLevel(element) !== spec.level) return false;
    return true;
  }

  function queryRole(root, body, all) {
    const spec = parseRoleSelector(body);
    const found = [];
    for (const scope of scopesUnder(root)) {
      const candidates = scope.querySelectorAll("*");
      for (let i = 0; i < candidates.length; i++) {
        if (!matchesRoleSpec(candidates[i], spec)) continue;
        if (!all) return [candidates[i]];
        found.push(candidates[i]);
      }
    }
    return found;
  }

  // Whether a control is ticked, for the states a caller can wait on.
  //
  // Native first, then ARIA, the same order everything else here uses: an
  // `<input type=checkbox>` answers from its own property, and a `<div
  // role="checkbox">` from `aria-checked`. An element that is neither is not
  // "unchecked" — it is not the kind of thing that can be, and saying so is
  // what stops `check` from clicking a paragraph forever.
  function checkedState(element) {
    const tag = elementSafeTagName(element);
    if (tag === "INPUT" && ["checkbox", "radio"].includes(element.type)) {
      return element.indeterminate ? "mixed" : element.checked;
    }
    if (CHECKED_ROLES.includes(ariaRole(element) || "")) {
      const attribute = element.getAttribute("aria-checked");
      if (attribute === "true") return true;
      if (attribute === "mixed") return "mixed";
      return false;
    }
    return "error";
  }

  // Chooses among a `<select>`'s options.
  //
  // Matched by value, then by label, then by index — the three ways a person
  // names an option, tried in that order because a value and a label can
  // collide and the value is the one the form actually submits.
  //
  // The events are dispatched by hand because setting `selected` from script
  // fires nothing, and a page that only listens for `change` would never learn
  // that anything happened.
  function selectOptions(node, wanted) {
    const element = retarget(node, "follow-label");
    if (!element || !element.isConnected) return { notConnected: true };
    if (elementSafeTagName(element) !== "SELECT") {
      return { error: "not a <select>: " + previewNode(element) };
    }
    if (isDisabled(element)) return { missingState: "enabled" };

    const options = [...element.options];
    const chosen = [];
    for (const want of wanted) {
      const found = options.find((option) => {
        if (want.value !== undefined) return option.value === want.value;
        if (want.label !== undefined) return option.label === want.label;
        if (want.index !== undefined) return option.index === want.index;
        return false;
      });
      if (!found) return { missing: JSON.stringify(want) };
      if (found.disabled) return { missing: "a disabled option: " + JSON.stringify(want) };
      chosen.push(found);
    }
    if (chosen.length > 1 && !element.multiple) {
      return { error: "the <select> does not take more than one option" };
    }

    for (const option of options) option.selected = false;
    for (const option of chosen) option.selected = true;

    element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return { done: true, values: chosen.map((option) => option.value) };
  }

  const api = {
    // The role a screen reader would report, or null.
    ariaRole(node) {
      const element = retarget(node, "none");
      return element ? ariaRole(element) : null;
    },

    // Which options a `<select>` should be showing.
    selectOptions(node, wanted) {
      return selectOptions(node, wanted);
    },

    // What a screen reader would read out for this element.
    accessibleName(node, includeHidden) {
      const element = retarget(node, "none");
      return element ? accessibleName(element, includeHidden) : "";
    },

    querySelector: (selector, root, strict) => query(selector, root, false, !!strict)[0] || null,
    querySelectorAll: (selector, root) => query(selector, root, true, false),
    count: (selector, root) => query(selector, root, true, false).length,
    visible: (element) => isVisible(element),
    textContent: (element) => element.textContent,
    innerText: (element) => element.innerText,
    getAttribute: (element, name) => element.getAttribute(name),
    previewNode: (node) => previewNode(node),

    // One round trip per poll answers "is it there yet" for every state,
    // including the two that are about absence.
    selectorState: (selector, root, state) => {
      const element = query(selector, root, false, false)[0] || null;
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
    text: (element) => normalizeText(element.textContent),
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
