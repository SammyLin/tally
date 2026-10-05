// Voiceprints: a user-named speaker's embedding enrols it as a print of that person; unconfirmed speakers
// (default "Speaker N" name, or auto-labelled) are matched against all VOICE_MODEL prints. auto: 0 runner/user, 1 matched,
// 2 user renamed to a default name (a rejected match; never auto-labelled again).
import type { Env } from "./http";

export const MARGIN = 0.05; // best person must beat the runner-up person by this much
// Only embeddings of this model are matched; others (old runners, pre-v2 rows) are stored but ignored.
export const VOICE_MODEL = "eres2net-large-zh-cn";
export const LEGACY_MODEL = "campplus-zh-cn"; // what an embedding posted without emb_model is
export const isDefaultName = (n: string) => /^Speaker \d+$/.test(n);
export const isEmbedding = (v: unknown): v is number[] =>
  Array.isArray(v) && v.length > 0 && v.length <= 1024 && v.every(Number.isFinite);
export const isEmbModel = (v: unknown): v is string | undefined | null => v == null || (typeof v === "string" && v.length > 0 && v.length <= 64);

function cosine(a: number[], b: number[]) {
  let d = 0, na = 0, nb = 0;
  for (let i = 0; i < Math.min(a.length, b.length); i++) d += a[i] * b[i], na += a[i] * a[i], nb += b[i] * b[i];
  return na && nb ? d / Math.sqrt(na * nb) : 0;
}

export type Candidate = { id: number; recording_id: number; embedding: number[] };
export type Print = { person_id: number; embedding: number[] };
export type Suggestion = { person_id: number; score: number };

// auto: speaker id → person id. A speaker only gets its best person (≥ threshold, ≥ MARGIN over the runner-up);
// conflicts go to the higher score, and a person is used at most once per recording (`taken` = persons
// already confirmed in that recording). suggest: every other speaker whose best person scores ≥ suggestAt
// (held back by threshold, margin or a used person), score rounded to 2 decimals.
export function matchSpeakers(cands: Candidate[], prints: Print[], threshold: number, taken = new Map<number, Set<number>>(), suggestAt = Infinity) {
  const scored = cands.flatMap((c) => {
    const best = new Map<number, number>();
    for (const p of prints) best.set(p.person_id, Math.max(best.get(p.person_id) ?? -1, cosine(c.embedding, p.embedding)));
    const [top, second] = [...best].sort((a, b) => b[1] - a[1]);
    return top ? [{ c, person: top[0], score: top[1], sure: top[1] >= threshold && top[1] - (second?.[1] ?? -1) >= MARGIN }] : [];
  }).sort((a, b) => b.score - a.score);
  const used = new Map([...taken].map(([r, s]) => [r, new Set(s)]));
  const auto = new Map<number, number>();
  for (const { c, person, sure } of scored) {
    const u = used.get(c.recording_id) ?? used.set(c.recording_id, new Set()).get(c.recording_id)!;
    if (!sure || u.has(person)) continue;
    u.add(person), auto.set(c.id, person);
  }
  const suggest = new Map<number, Suggestion>();
  for (const { c, person, score } of scored)
    if (!auto.has(c.id) && score >= suggestAt) suggest.set(c.id, { person_id: person, score: Math.round(score * 100) / 100 });
  return { auto, suggest };
}

// people ids must stay stable (voiceprints hang off them), so no REPLACE; last_used_at = recency for the UI
export const upsertPerson = (db: D1Database, name: string) =>
  db.prepare(`INSERT INTO people(name) VALUES(?) ON CONFLICT(name) DO UPDATE SET last_used_at=datetime('now')`).bind(name);

// Names speaker `sid` as person `name` (confirmed) and upserts its voiceprint if it has an embedding.
// backfill: only if the speaker is still called `name` (a concurrent rename wins), and without bumping the
// person's last_used_at (the people list's recency order is for real use).
export const enrol = (db: D1Database, sid: number, name: string, backfill = false) => [
  backfill ? db.prepare(`INSERT OR IGNORE INTO people(name) VALUES(?)`).bind(name) : upsertPerson(db, name),
  db.prepare(`UPDATE speakers SET display_name=?2, person_id=(SELECT id FROM people WHERE name=?2), auto=0
    WHERE id=?1${backfill ? " AND display_name=?2" : ""}`).bind(sid, name),
  db.prepare(`INSERT INTO voiceprints(person_id, speaker_id, embedding, emb_model)
    SELECT person_id, id, embedding, coalesce(emb_model, '${LEGACY_MODEL}') FROM speakers
    WHERE id=?1 AND display_name=?2 AND person_id IS NOT NULL AND embedding IS NOT NULL
    ON CONFLICT(speaker_id) DO UPDATE SET person_id=excluded.person_id, embedding=excluded.embedding, emb_model=excluded.emb_model`).bind(sid, name),
];

type Row = { id: number; recording_id: number; label: string; display_name: string; person_id: number | null; auto: number;
  embedding: string | null; suggest_person_id: number | null; suggest_score: number | null };

// Re-labels unconfirmed speakers (of one recording, or all) from the current VOICE_MODEL voiceprints; an auto
// label that no longer matches goes back to its default "Speaker N". Also (re)sets every speaker's suggestion.
// Returns the number of speakers changed.
// ponytail: loads every print (and every speaker when rid is omitted) into memory; fine for a few thousand.
export async function rematch(env: Env, rid?: number) {
  const db = env.DB;
  const cols = `id, recording_id, label, display_name, person_id, auto, suggest_person_id, suggest_score,
    CASE WHEN emb_model=?1 THEN embedding END AS embedding`;
  const [sp, vp] = await db.batch([
    rid === undefined
      ? db.prepare(`SELECT ${cols} FROM speakers ORDER BY id`).bind(VOICE_MODEL)
      : db.prepare(`SELECT ${cols} FROM speakers WHERE recording_id=?2 ORDER BY id`).bind(VOICE_MODEL, rid),
    db.prepare(`SELECT v.person_id, v.embedding, p.name FROM voiceprints v JOIN people p ON p.id=v.person_id WHERE v.emb_model=?`).bind(VOICE_MODEL),
  ]);
  const rows = sp.results as Row[];
  const prints = (vp.results as { person_id: number; embedding: string; name: string }[]);
  const names = new Map(prints.map((p) => [p.person_id, p.name]));
  const open = (s: Row) => s.auto === 1 || (s.auto === 0 && isDefaultName(s.display_name)); // auto=2: user chose a default name
  const taken = new Map<number, Set<number>>();
  for (const s of rows) if (!open(s) && s.person_id !== null) (taken.get(s.recording_id) ?? taken.set(s.recording_id, new Set()).get(s.recording_id)!).add(s.person_id);
  const { auto, suggest } = matchSpeakers(
    rows.filter((s) => open(s) && s.embedding).map((s) => ({ id: s.id, recording_id: s.recording_id, embedding: JSON.parse(s.embedding!) })),
    prints.map((p) => ({ person_id: p.person_id, embedding: JSON.parse(p.embedding) })),
    Number(env.VOICE_MATCH_THRESHOLD) || 0.65, taken, Number(env.VOICE_SUGGEST_THRESHOLD) || 0.5);
  const nth = new Map<number, number>(); // runner names diarized speakers "Speaker k" in id order
  const stmts: D1PreparedStatement[] = [];
  for (const s of rows) {
    const k = s.label === "custom" ? 0 : nth.set(s.recording_id, (nth.get(s.recording_id) ?? 0) + 1).get(s.recording_id)!;
    let [name, pid, a] = [s.display_name, s.person_id, s.auto];
    let sug: Suggestion | undefined;
    if (open(s)) {
      const m = auto.get(s.id);
      if (m !== undefined) [name, pid, a] = [names.get(m)!, m, 1];
      else {
        if (s.auto === 1) [name, pid, a] = [`Speaker ${k}`, null, 0];
        sug = suggest.get(s.id);
      }
    }
    const [gp, gs] = [sug?.person_id ?? null, sug?.score ?? null];
    if (name === s.display_name && pid === s.person_id && a === s.auto && gp === s.suggest_person_id && gs === s.suggest_score) continue;
    // guarded by the values read, so a concurrent user rename wins
    stmts.push(db.prepare(`UPDATE speakers SET display_name=?4, person_id=?5, auto=?6, suggest_person_id=?7, suggest_score=?8
      WHERE id=?1 AND display_name=?2 AND auto=?3`).bind(s.id, s.display_name, s.auto, name, pid, a, gp, gs));
  }
  if (stmts.length) await db.batch(stmts);
  return stmts.length;
}
