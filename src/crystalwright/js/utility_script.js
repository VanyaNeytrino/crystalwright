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

  // Visible enough to be worth waiting for: it has a box, and it is not
  // `visibility: hidden`. The rest of what an element has to be before it can
  // be clicked — stable, enabled, actually on top at the point it will be
  // clicked — is a separate question and a later one.
  function isVisible(element) {
    if (!element || element.nodeType !== 1) return false;
    const view = element.ownerDocument && element.ownerDocument.defaultView;
    if (!view) return false;
    const style = view.getComputedStyle(element);
    if (!style || style.visibility === "hidden") return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
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
      return finish(fn.apply(null, args), payload.r);
    },
  };
})()
