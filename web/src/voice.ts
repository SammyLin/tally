// Voiceprints: a user-named speaker's embedding enrols it as a print of that person; unconfirmed speakers
// (default "Speaker N" name, or auto-labelled) are matched against all prints. auto: 0 runner/user, 1 matched,
// 2 user renamed to a default name (a rejected match; never auto-labelled again).
import type { Env } from "./http";

export const MARGIN = 0.05; // best person must beat the runner-up person by this much
export const isDefaultName = (n: string) => /^Speaker \d+$/.test(n);
export const isEmbedding = (v: unknown): v is number[] =>
  Array.isArray(v) && v.length > 0 && v.length <= 4096 && v.every(Number.isFinite);

function cosine(a: number[], b: number[]) {
  let d = 0, na = 0, nb = 0;
  for (let i = 0; i < Math.min(a.length, b.length); i++) d += a[i] * b[i], na += a[i] * a[i], nb += b[i] * b[i];
  return na && nb ? d / Math.sqrt(na * nb) : 0;
}

export type Candidate = { id: number; recording_id: number; embedding: number[] };
export type Print = { person_id: number; embedding: number[] };

// speaker id → person id. A speaker only gets its best person (≥ threshold, ≥ MARGIN over the runner-up);
// conflicts go to the higher score, and a person is used at most once per recording (`taken` = persons
// already confirmed in that recording).
export function matchSpeakers(cands: Candidate[], prints: Print[], threshold: number, taken = new Map<number, Set<number>>()) {
  const scored = cands.flatMap((c) => {
    const best = new Map<number, number>();
    for (const p of prints) best.set(p.person_id, Math.max(best.get(p.person_id) ?? -1, cosine(c.embedding, p.embedding)));
    const [top, second] = [...best].sort((a, b) => b[1] - a[1]);
    if (!top || top[1] < threshold || top[1] - (second?.[1] ?? -1) < MARGIN) return [];
    return [{ c, person: top[0], score: top[1] }];
  }).sort((a, b) => b.score - a.score);
  const used = new Map([...taken].map(([r, s]) => [r, new Set(s)]));
  const out = new Map<number, number>();
  for (const { c, person } of scored) {
    const u = used.get(c.recording_id) ?? used.set(c.recording_id, new Set()).get(c.recording_id)!;
    if (u.has(person)) continue;
    u.add(person), out.set(c.id, person);
  }
  return out;
}

// people ids must stay stable (voiceprints hang off them), so no REPLACE; last_used_at = recency for the UI
export const upsertPerson = (db: D1Database, name: string) =>
  db.prepare(`INSERT INTO people(name) VALUES(?) ON CONFLICT(name) DO UPDATE SET last_used_at=datetime('now')`).bind(name);

// Names speaker `sid` as person `name` (confirmed) and upserts its voiceprint if it has an embedding.
export const enrol = (db: D1Database, sid: number, name: string) => [
  upsertPerson(db, name),
  db.prepare(`UPDATE speakers SET display_name=?2, person_id=(SELECT id FROM people WHERE name=?2), auto=0 WHERE id=?1`).bind(sid, name),
  db.prepare(`INSERT INTO voiceprints(person_id, speaker_id, embedding) SELECT person_id, id, embedding FROM speakers WHERE id=?1 AND embedding IS NOT NULL
    ON CONFLICT(speaker_id) DO UPDATE SET person_id=excluded.person_id, embedding=excluded.embedding`).bind(sid),
];

type Row = { id: number; recording_id: number; label: string; display_name: string; person_id: number | null; auto: number; embedding: string | null };

// Re-labels unconfirmed speakers (of one recording, or all) from the current voiceprints; an auto label
// that no longer matches goes back to its default "Speaker N". Returns the number of speakers changed.
// ponytail: loads every print (and every speaker when rid is omitted) into memory; fine for a few thousand.
export async function rematch(env: Env, rid?: number) {
  const db = env.DB;
  const [sp, vp] = await db.batch([
    rid === undefined
      ? db.prepare(`SELECT id, recording_id, label, display_name, person_id, auto, embedding FROM speakers ORDER BY id`)
      : db.prepare(`SELECT id, recording_id, label, display_name, person_id, auto, embedding FROM speakers WHERE recording_id=? ORDER BY id`).bind(rid),
    db.prepare(`SELECT v.person_id, v.embedding, p.name FROM voiceprints v JOIN people p ON p.id=v.person_id`),
  ]);
  const rows = sp.results as Row[];
  const prints = (vp.results as { person_id: number; embedding: string; name: string }[]);
  const names = new Map(prints.map((p) => [p.person_id, p.name]));
  const open = (s: Row) => s.auto === 1 || (s.auto === 0 && isDefaultName(s.display_name)); // auto=2: user chose a default name
  const taken = new Map<number, Set<number>>();
  for (const s of rows) if (!open(s) && s.person_id !== null) (taken.get(s.recording_id) ?? taken.set(s.recording_id, new Set()).get(s.recording_id)!).add(s.person_id);
  const matches = matchSpeakers(
    rows.filter((s) => open(s) && s.embedding).map((s) => ({ id: s.id, recording_id: s.recording_id, embedding: JSON.parse(s.embedding!) })),
    prints.map((p) => ({ person_id: p.person_id, embedding: JSON.parse(p.embedding) })),
    Number(env.VOICE_MATCH_THRESHOLD) || 0.75, taken);
  const nth = new Map<number, number>(); // runner names diarized speakers "Speaker k" in id order
  const stmts: D1PreparedStatement[] = [];
  // guarded by the values read, so a concurrent user rename wins
  const set = (s: Row, name: string, pid: number | null, auto: number) => stmts.push(db.prepare(
    `UPDATE speakers SET display_name=?4, person_id=?5, auto=?6 WHERE id=?1 AND display_name=?2 AND auto=?3`).bind(s.id, s.display_name, s.auto, name, pid, auto));
  for (const s of rows) {
    const k = s.label === "custom" ? 0 : nth.set(s.recording_id, (nth.get(s.recording_id) ?? 0) + 1).get(s.recording_id)!;
    if (!open(s)) continue;
    const pid = matches.get(s.id);
    if (pid !== undefined) {
      const name = names.get(pid)!;
      if (s.auto !== 1 || s.person_id !== pid || s.display_name !== name) set(s, name, pid, 1);
    } else if (s.auto === 1) set(s, `Speaker ${k}`, null, 0);
  }
  if (stmts.length) await db.batch(stmts);
  return stmts.length;
}
