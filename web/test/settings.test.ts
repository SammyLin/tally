// node test/settings.test.ts — settings patch validation/normalisation.
import assert from "node:assert/strict";
import { DEFAULTS, parseSettings } from "../src/settings.ts";

assert.deepEqual(parseSettings({}), {});
assert.deepEqual(parseSettings({ about: "  hi  ", stt_lang: "auto", cleanup: false, auto_label: true, me: null }),
  { about: "hi", stt_lang: "auto", cleanup: false, auto_label: true, me: null });
assert.deepEqual(parseSettings({ instructions: "字".repeat(500) }), { instructions: "字".repeat(500) }); // chars, not bytes
assert.deepEqual(parseSettings({ content_focus: ` ${"x".repeat(500)} ` }), { content_focus: "x".repeat(500) }); // trimmed first
assert.equal(typeof parseSettings({ about: "x".repeat(501) }), "string");
assert.equal(typeof parseSettings({ about: 1 }), "string");
assert.equal(typeof parseSettings({ stt_lang: "de" }), "string");
assert.equal(typeof parseSettings({ cleanup: "false" }), "string");
assert.equal(typeof parseSettings({ me: 0 }), "string");
assert.equal(typeof parseSettings({ me: "3" }), "string");
assert.deepEqual(parseSettings({ me: 3 }), { me: 3 });
assert.equal(parseSettings({ nope: 1 }), "unknown setting: nope");
assert.equal(typeof parseSettings({ about: "ok", nope: 1 }), "string"); // one bad key fails the whole patch

// vocab: trimmed, empty dropped, deduped (first wins, case-sensitive), ≤ 50 chars each, ≤ 200 items
assert.deepEqual(parseSettings({ vocab: [" Delta ", "", "  ", "DEMP", "Delta", "delta"] }), { vocab: ["Delta", "DEMP", "delta"] });
assert.deepEqual(parseSettings({ vocab: ["德".repeat(50)] }), { vocab: ["德".repeat(50)] });
assert.equal(typeof parseSettings({ vocab: ["x".repeat(51)] }), "string");
assert.equal(typeof parseSettings({ vocab: "Delta" }), "string");
assert.equal(typeof parseSettings({ vocab: ["a", 1] }), "string");
const many = Array.from({ length: 200 }, (_, i) => `w${i}`);
assert.deepEqual(parseSettings({ vocab: [...many, "w0"] }), { vocab: many }); // dups don't count toward the cap
assert.equal(typeof parseSettings({ vocab: [...many, "w200"] }), "string");

// defaults themselves validate
assert.deepEqual(parseSettings(DEFAULTS), DEFAULTS);
console.log("settings ok");
