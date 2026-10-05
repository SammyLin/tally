// node test/voice.test.ts — voiceprint matching: threshold, margin, greedy, one person per recording, suggestions.
import assert from "node:assert/strict";
import { isDefaultName, isEmbedding, isEmbModel, matchSpeakers } from "../src/voice.ts";

const unit = (...v: number[]) => { const n = Math.hypot(...v); return v.map((x) => x / n); };
// nearA(c): unit vector at cosine c to A
const nearA = (c: number) => [c, Math.sqrt(1 - c * c), 0];
const A = { person_id: 1, embedding: [1, 0, 0] };
const B = { person_id: 2, embedding: [0, 0, 1] };
const sp = (id: number, embedding: number[], recording_id = 10) => ({ id, recording_id, embedding });
const m = (...a: Parameters<typeof matchSpeakers>) => Object.fromEntries(matchSpeakers(...a).auto);
const sg = (...a: Parameters<typeof matchSpeakers>) => Object.fromEntries(matchSpeakers(...a).suggest);

// threshold
assert.deepEqual(m([sp(1, nearA(0.7))], [A, B], 0.6), { 1: 1 });
assert.deepEqual(m([sp(1, nearA(0.55))], [A, B], 0.6), {});
assert.deepEqual(m([sp(1, nearA(0.6))], [A], 0.6), { 1: 1 }); // ≥ threshold
assert.deepEqual(m([sp(1, [1, 0, 0])], [], 0.6), {}); // no prints

// margin: best must beat the runner-up person by ≥ 0.05
const between = unit(1, 0, 0.98); // ~0.714 to A, ~0.700 to B
assert.deepEqual(m([sp(1, between)], [A, B], 0.6), {});
assert.deepEqual(m([sp(1, unit(1, 0, 0.8))], [A, B], 0.6), { 1: 1 }); // 0.78 vs 0.62
// several prints of the same person don't count as a runner-up; score = max over the person's prints
assert.deepEqual(m([sp(1, nearA(0.9))], [A, { person_id: 1, embedding: nearA(0.95) }], 0.6), { 1: 1 });

// greedy: one person per recording, higher score wins, loser does not fall back to its runner-up
assert.deepEqual(m([sp(1, nearA(0.8)), sp(2, nearA(0.95))], [A, B], 0.6), { 2: 1 });
// ...but in different recordings both get the person
assert.deepEqual(m([sp(1, nearA(0.8), 10), sp(2, nearA(0.95), 11)], [A, B], 0.6), { 1: 1, 2: 1 });
// two speakers, two persons
assert.deepEqual(m([sp(1, nearA(0.9)), sp(2, unit(0, 0.3, 1))], [A, B], 0.6), { 1: 1, 2: 2 });
// person already confirmed in this recording is not reused; taken map is not mutated
const taken = new Map([[10, new Set([1])]]);
assert.deepEqual(m([sp(1, nearA(0.9)), sp(2, nearA(0.9), 11)], [A, B], 0.6, taken), { 2: 1 });
assert.deepEqual([...taken.get(10)!], [1]);

assert.ok(isDefaultName("Speaker 1") && isDefaultName("Speaker 12"));
assert.ok(!isDefaultName("Tammy") && !isDefaultName("Speaker") && !isDefaultName("Speaker 1a"));
// suggestions: open speakers not auto-labelled whose best person ≥ suggestAt; score rounded to 2 decimals
const none = new Map<number, Set<number>>();
assert.deepEqual(sg([sp(1, nearA(0.55))], [A, B], 0.65, none, 0.5), { 1: { person_id: 1, score: 0.55 } }); // below threshold
assert.deepEqual(sg([sp(1, nearA(0.45))], [A, B], 0.65, none, 0.5), {}); // below suggest
assert.deepEqual(sg([sp(1, nearA(0.9))], [A, B], 0.65, none, 0.5), {}); // auto-labelled → no suggestion
assert.deepEqual(sg([sp(1, between)], [A, B], 0.65, none, 0.5), { 1: { person_id: 1, score: 0.71 } }); // held back by margin
// held back because the person is used in this recording (by a confirmed speaker or a better auto match)
assert.deepEqual(sg([sp(1, nearA(0.8)), sp(2, nearA(0.95))], [A, B], 0.65, none, 0.5), { 1: { person_id: 1, score: 0.8 } });
assert.deepEqual(sg([sp(1, nearA(0.9))], [A, B], 0.65, new Map([[10, new Set([1])]]), 0.5), { 1: { person_id: 1, score: 0.9 } });
assert.deepEqual(sg([sp(1, nearA(0.55))], [A, B], 0.65), {}); // no suggestAt → no suggestions

assert.ok(isEmbedding(Array(1024).fill(0.1)) && !isEmbedding(Array(1025).fill(0.1)) && !isEmbedding([1, NaN]) && !isEmbedding([]));
assert.ok(isEmbModel(undefined) && isEmbModel(null) && isEmbModel("eres2net-large-zh-cn") && !isEmbModel("x".repeat(65)) && !isEmbModel("") && !isEmbModel(3));
console.log("voice ok");
