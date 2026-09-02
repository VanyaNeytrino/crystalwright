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
  };
})()
