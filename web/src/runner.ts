// Runner job API: jobs are claimed with a lease; a lease that expires makes the job claimable again.
import { type Env, type Handler, HttpError, first, parseParts, partNumber, readJSON, runnerName, serveR2, splitFilename } from "./http";
import { LEGACY_MODEL, VOICE_MODEL, enrol, isDefaultName, isEmbModel, isEmbedding, rematch } from "./voice";

const LEASE = `datetime('now','+10 minutes')`;
const ACTIVE = { recordings: `status IN ('converting','transcribing','cleaning')`, summaries: `status='running'` };
const CHUNK_CHARS = 300_000; // JSON chars per bound parameter; D1 caps a value at 2 MB (CJK = 3 bytes/char)

type Kind = keyof typeof ACTIVE;
const kindOf = (s: string): Kind => (s.startsWith("rec") ? "recordings" : "summaries");
const id = (s: string) => Number(s);

// Records that a runner is alive; stt is only known on claim.
const seen = (env: Env, runner: string, stt: unknown = null) =>
  env.DB.prepare(`INSERT INTO runners(name, stt) VALUES(?1, ?2)
    ON CONFLICT(name) DO UPDATE SET last_seen=datetime('now'), stt=coalesce(?2, stt)`).bind(runner, typeof stt === "string" ? stt : null);

// Extends the lease if this runner still holds the job; otherwise the runner must abort.
async function hold(env: Env, kind: Kind, jid: number, runner: string, status: string | null = null) {
  const [r] = await env.DB.batch([
    env.DB.prepare(`UPDATE ${kind} SET lease_until=${LEASE}, status=coalesce(?3, status)
      WHERE id=?1 AND runner=?2 AND ${ACTIVE[kind]}`).bind(jid, runner, status),
    seen(env, runner),
  ]);
  if (!r.meta.changes) throw new HttpError(409, "lease lost");
}

// Online = contacted within 3 min (idle runners poll every 10 s, busy ones heartbeat every 60 s).
export async function listRunners(env: Env) {
  const { results } = await env.DB.prepare(`SELECT r.name, r.last_seen, r.stt,
      CAST(strftime('%s','now') - strftime('%s', r.last_seen) AS INTEGER) AS ago_s,
      coalesce(
        (SELECT json_object('kind','recording','id',id,'status',status,'title',title) FROM recordings
          WHERE runner=r.name AND ${ACTIVE.recordings} AND lease_until > datetime('now') LIMIT 1),
        (SELECT json_object('kind','summary','id',s.id,'recording_id',s.recording_id,'status',s.status,'title',rc.title)
          FROM summaries s JOIN recordings rc ON rc.id=s.recording_id
          WHERE s.runner=r.name AND s.${ACTIVE.summaries} AND s.lease_until > datetime('now') LIMIT 1)) AS job
    FROM runners r ORDER BY r.last_seen DESC`).all<{ name: string; last_seen: string; stt: string | null; ago_s: number; job: string | null }>();
  const q = await env.DB.prepare(`SELECT
      (SELECT count(*) FROM recordings WHERE status='queued' AND deleted_at IS NULL) AS recordings,
      (SELECT count(*) FROM summaries WHERE status='queued') AS summaries`).first<{ recordings: number; summaries: number }>();
  return {
    runners: results.map((r) => ({ ...r, online: r.ago_s < 180, job: r.job ? JSON.parse(r.job) : null })),
    queued: q ?? { recordings: 0, summaries: 0 },
  };
}

// play.m4a uploads carry the runner in ?runner= (the PUT body is raw audio).
const holdQuery = (env: Env, rid: number, url: URL) => hold(env, "recordings", rid, runnerName({ runner: url.searchParams.get("runner") }));

function chunks<T>(items: T[]): T[][] {
  const out: T[][] = [];
  let cur: T[] = [];
  let n = 0;
  for (const it of items) {
    const len = JSON.stringify(it).length;
    if (cur.length && n + len > CHUNK_CHARS) out.push(cur), (cur = []), (n = 0);
    cur.push(it), (n += len);
  }
  if (cur.length) out.push(cur);
  return out;
}

async function transcriptText(env: Env, rid: number) {
  const { results } = await env.DB.prepare(`SELECT s.start_ms AS ms, coalesce(sp.display_name, 'Speaker') AS name, coalesce(s.text_clean, s.text_raw) AS text
    FROM segments s LEFT JOIN speakers sp ON sp.id = s.speaker_id WHERE s.recording_id=? ORDER BY s.start_ms, s.id`).bind(rid).all<{ ms: number; name: string; text: string }>();
  const pad = (n: number) => String(n).padStart(2, "0");
  return results.map((r) => `[${pad(Math.floor(r.ms / 60000))}:${pad(Math.floor(r.ms / 1000) % 60)}] ${r.name}: ${r.text}`).join("\n");
}

async function recording(env: Env, rid: number) {
  return first<{ filename: string; source_key: string | null; play_key: string | null; upload_id: string | null }>(
    env.DB.prepare(`SELECT filename, source_key, play_key, upload_id FROM recordings WHERE id=?`).bind(rid));
}

export const runnerRoutes: [string, RegExp, Handler][] = [
  ["POST", /^\/api\/runner\/claim$/, async (req, env) => {
    const body = await readJSON<{ runner?: unknown; stt?: unknown; skip_recordings?: unknown }>(req);
    const runner = runnerName(body);
    await seen(env, runner, body.stt).run();
    // a runner works one job at a time, so a job still leased to this runner is left over from its previous run
    // one UPDATE…RETURNING per table: D1 runs statements serially, so two runners can never get the same row
    // skip_recordings: the runner's STT is paused (Groq quota), so it only takes summaries for now
    const rec = body.skip_recordings === true ? null : await env.DB.prepare(`UPDATE recordings
      SET status='converting', runner=?1, lease_until=${LEASE}, error=NULL, not_before=NULL, note=NULL
      WHERE id=(SELECT id FROM recordings WHERE deleted_at IS NULL
        AND ((status='queued' AND (not_before IS NULL OR not_before <= datetime('now')))
          OR (${ACTIVE.recordings} AND (lease_until < datetime('now') OR runner=?1))) ORDER BY id LIMIT 1)
      RETURNING id, filename, size, source_key, play_key`).bind(runner)
      .first<{ id: number; filename: string; size: number | null; source_key: string | null; play_key: string | null }>();
    if (rec) {
      // retranscribe after the source was deleted: the runner gets play.m4a as its source
      const size = rec.source_key ? rec.size : rec.play_key ? ((await env.AUDIO.head(rec.play_key))?.size ?? null) : null;
      return { job: { kind: "recording", id: rec.id, filename: rec.filename, source_size: size } };
    }
    const sum = await env.DB.prepare(`UPDATE summaries SET status='running', runner=?1, lease_until=${LEASE}, error=NULL
      WHERE id=(SELECT id FROM summaries WHERE status='queued' OR (${ACTIVE.summaries} AND (lease_until < datetime('now') OR runner=?1)) ORDER BY id LIMIT 1)
      RETURNING id, recording_id, template_id, language`).bind(runner)
      .first<{ id: number; recording_id: number; template_id: string; language: string }>();
    if (!sum) return { job: null };
    return { job: { kind: "summary", ...sum, transcript: await transcriptText(env, sum.recording_id) } };
  }],

  ["POST", /^\/api\/runner\/(recordings?|summar(?:y|ies))\/(\d+)\/heartbeat$/, async (req, env, [k, jid]) => {
    const body = await readJSON<{ runner?: unknown; status?: unknown }>(req);
    const kind = kindOf(k);
    let status: string | null = null;
    if (kind === "recordings" && body.status !== undefined && body.status !== null) {
      if (!["converting", "transcribing", "cleaning"].includes(body.status as string)) throw new HttpError(400, "status must be converting|transcribing|cleaning");
      status = body.status as string;
    }
    await hold(env, kind, id(jid), runnerName(body), status);
    return { ok: true };
  }],

  ["GET", /^\/api\/runner\/recordings\/(\d+)\/source$/, async (req, env, [rid]) => {
    const rec = await recording(env, id(rid));
    const key = rec.source_key ?? rec.play_key;
    if (!key) throw new HttpError(404, "source not found");
    return serveR2(req, env.AUDIO, key);
  }],

  ["PUT", /^\/api\/runner\/recordings\/(\d+)\/play$/, async (req, env, [rid], url) => {
    await holdQuery(env, id(rid), url);
    const rec = await recording(env, id(rid));
    if (!req.body) throw new HttpError(400, "empty body");
    const key = `rec/${id(rid)}/play.m4a`;
    if (url.searchParams.has("part")) {
      if (!rec.upload_id) throw new HttpError(409, "no play upload started");
      const p = await env.AUDIO.resumeMultipartUpload(key, rec.upload_id).uploadPart(partNumber(url.searchParams.get("part")), req.body);
      return { etag: p.etag };
    }
    if (!req.headers.get("Content-Length")) throw new HttpError(411, "Content-Length required");
    await env.AUDIO.put(key, req.body, { httpMetadata: { contentType: "audio/mp4" } });
    await env.DB.prepare(`UPDATE recordings SET play_key=? WHERE id=?`).bind(key, id(rid)).run();
    return { ok: true };
  }],

  ["POST", /^\/api\/runner\/recordings\/(\d+)\/play\/start$/, async (_req, env, [rid], url) => {
    await holdQuery(env, id(rid), url);
    const up = await env.AUDIO.createMultipartUpload(`rec/${id(rid)}/play.m4a`, { httpMetadata: { contentType: "audio/mp4" } });
    await env.DB.prepare(`UPDATE recordings SET upload_id=? WHERE id=?`).bind(up.uploadId, id(rid)).run();
    return { ok: true };
  }],

  ["POST", /^\/api\/runner\/recordings\/(\d+)\/play\/complete$/, async (req, env, [rid], url) => {
    const parts = parseParts(await readJSON(req));
    await holdQuery(env, id(rid), url);
    const rec = await recording(env, id(rid));
    if (!rec.upload_id) throw new HttpError(409, "no play upload started");
    const key = `rec/${id(rid)}/play.m4a`;
    await env.AUDIO.resumeMultipartUpload(key, rec.upload_id).complete(parts);
    await env.DB.prepare(`UPDATE recordings SET play_key=?, upload_id=NULL WHERE id=?`).bind(key, id(rid)).run();
    return { ok: true };
  }],

  ["POST", /^\/api\/runner\/recordings\/(\d+)\/transcript$/, async (req, env, [rs]) => {
    const rid = id(rs);
    const body = await readJSON<{ runner?: unknown; duration_s?: unknown; speakers?: unknown; segments?: unknown }>(req);
    const speakers = body.speakers ?? [];
    const segments = body.segments ?? [];
    if (!Array.isArray(speakers) || !speakers.every((s) => typeof s?.label === "string" && typeof s?.display_name === "string"
      && (s.embedding == null || isEmbedding(s.embedding)) && isEmbModel(s.emb_model)))
      throw new HttpError(400, "speakers: [{label, display_name, embedding?: number[≤1024], emb_model?: string}] required");
    if (!Array.isArray(segments) || !segments.every((s) => Number.isFinite(s?.start_ms) && Number.isFinite(s?.end_ms) && typeof s?.text_raw === "string"))
      throw new HttpError(400, "segments: [{start_ms, end_ms, speaker, text_raw}] required");
    await hold(env, "recordings", rid, runnerName(body));
    const db = env.DB;
    // one batch = one transaction; segments go in as JSON chunks, speaker index → id via the speakers just inserted
    const results = await db.batch([
      db.prepare(`DELETE FROM segments WHERE recording_id=?`).bind(rid),
      db.prepare(`DELETE FROM speakers WHERE recording_id=?`).bind(rid),
      db.prepare(`UPDATE recordings SET duration_s=? WHERE id=?`).bind(typeof body.duration_s === "number" ? body.duration_s : null, rid),
      db.prepare(`INSERT INTO speakers(recording_id, label, display_name, embedding, emb_model)
        SELECT ?1, value->>'label', value->>'display_name', nullif(value->'embedding', 'null'), value->>'emb_model' FROM json_each(?2) ORDER BY key`)
        .bind(rid, JSON.stringify(speakers.map((s) => ({ label: s.label, display_name: s.display_name,
          embedding: s.embedding ?? null, emb_model: s.embedding == null ? null : s.emb_model ?? LEGACY_MODEL })))),
      ...chunks(segments.map((s) => [Math.round(s.start_ms), Math.round(s.end_ms), Number.isInteger(s.speaker) ? s.speaker : null, s.text_raw])).map((c) =>
        db.prepare(`WITH sp AS (SELECT id, row_number() OVER (ORDER BY id) - 1 AS idx FROM speakers WHERE recording_id=?1)
          INSERT INTO segments(recording_id, start_ms, end_ms, speaker_id, text_raw)
          SELECT ?1, value->>0, value->>1, (SELECT id FROM sp WHERE idx = value->>2), value->>3 FROM json_each(?2) ORDER BY key
          RETURNING id`).bind(rid, JSON.stringify(c))),
    ]);
    // AUTOINCREMENT ids ascend in insertion order, which is input order
    const ids = results.slice(4).flatMap((r) => (r.results as { id: number }[]).map((x) => x.id)).sort((a, b) => a - b);
    await rematch(env, rid);
    return { segment_ids: ids };
  }],

  // Voiceprint backfill (no lease): store embeddings, enrol this recording's named speakers, re-match everything.
  ["POST", /^\/api\/runner\/recordings\/(\d+)\/speaker-embeddings$/, async (req, env, [rs]) => {
    const rid = id(rs);
    const body = await readJSON<{ speakers?: unknown }>(req);
    const items = body.speakers;
    if (!Array.isArray(items) || !items.every((s) => Number.isInteger(s?.id) && isEmbedding(s.embedding) && isEmbModel(s.emb_model)))
      throw new HttpError(400, "speakers: [{id, embedding: number[≤1024], emb_model?: string}] required");
    await recording(env, rid);
    const db = env.DB;
    // never replace a VOICE_MODEL embedding with another model's (an old runner's backfill)
    const stored = items.length ? (await db.batch(items.map((s) =>
      db.prepare(`UPDATE speakers SET embedding=?1, emb_model=?2 WHERE id=?3 AND recording_id=?4 AND (emb_model IS NOT ?5 OR ?2 = ?5)`)
        .bind(JSON.stringify(s.embedding), s.emb_model ?? LEGACY_MODEL, s.id, rid, VOICE_MODEL))))
      .reduce((n, r) => n + r.meta.changes, 0) : 0;
    const { results } = await db.prepare(`SELECT id, display_name FROM speakers WHERE recording_id=? AND auto=0 AND label<>'custom' AND embedding IS NOT NULL`)
      .bind(rid).all<{ id: number; display_name: string }>();
    const named = results.filter((s) => !isDefaultName(s.display_name));
    if (named.length) await db.batch(named.flatMap((s) => enrol(db, s.id, s.display_name, true)));
    return { stored, enrolled: named.length, relabelled: await rematch(env) };
  }],

  ["POST", /^\/api\/runner\/recordings\/(\d+)\/clean$/, async (req, env, [rs]) => {
    const rid = id(rs);
    const body = await readJSON<{ runner?: unknown; items?: unknown; title?: unknown }>(req);
    const items = body.items ?? [];
    if (!Array.isArray(items) || !items.every((i) => Number.isInteger(i?.id) && typeof i?.text_clean === "string"))
      throw new HttpError(400, "items: [{id, text_clean}] required");
    await hold(env, "recordings", rid, runnerName(body));
    const stmts = chunks(items.map((i) => ({ id: i.id, text_clean: i.text_clean }))).map((c) =>
      env.DB.prepare(`UPDATE segments SET text_clean = j.value->>'text_clean' FROM json_each(?2) j
        WHERE +segments.recording_id=?1 AND segments.id = j.value->>'id'`).bind(rid, JSON.stringify(c)));
    const title = typeof body.title === "string" ? body.title.trim() : "";
    if (title) {
      const { stem } = splitFilename((await recording(env, rid)).filename);
      stmts.push(env.DB.prepare(`UPDATE recordings SET title=? WHERE id=? AND title=?`).bind(title, rid, stem));
    }
    if (stmts.length) await env.DB.batch(stmts);
    return { ok: true };
  }],

  ["POST", /^\/api\/runner\/recordings\/(\d+)\/done$/, async (req, env, [rs]) => {
    const rid = id(rs);
    const runner = runnerName(await readJSON(req));
    const { source_key } = await recording(env, rid);
    const r = await env.DB.prepare(`UPDATE recordings SET status='done', error=NULL, lease_until=NULL, source_key=NULL
      WHERE id=?1 AND runner=?2 AND ${ACTIVE.recordings}`).bind(rid, runner).run();
    if (!r.meta.changes) throw new HttpError(409, "lease lost");
    if (source_key) await env.AUDIO.delete(source_key);
    return { ok: true };
  }],

  // Puts a claimed recording back in the queue until `seconds` from now (e.g. Groq quota), with a note for the UI.
  ["POST", /^\/api\/runner\/recordings?\/(\d+)\/defer$/, async (req, env, [rid]) => {
    const body = await readJSON<{ runner?: unknown; seconds?: unknown; note?: unknown }>(req);
    const secs = Math.min(Math.max(Math.round(Number(body.seconds) || 0), 0), 86_400);
    const r = await env.DB.prepare(`UPDATE recordings SET status='queued', runner=NULL, lease_until=NULL,
        not_before=datetime('now', '+' || ?3 || ' seconds'), note=?4
      WHERE id=?1 AND runner=?2 AND ${ACTIVE.recordings}`).bind(id(rid), runnerName(body), secs, String(body.note ?? "").slice(0, 200) || null).run();
    if (!r.meta.changes) throw new HttpError(409, "lease lost");
    return { ok: true };
  }],

  // Puts a claimed summary straight back in the queue (runner shutting down).
  ["POST", /^\/api\/runner\/summar(?:y|ies)\/(\d+)\/defer$/, async (req, env, [sid]) => {
    const r = await env.DB.prepare(`UPDATE summaries SET status='queued', runner=NULL, lease_until=NULL
      WHERE id=?1 AND runner=?2 AND ${ACTIVE.summaries}`).bind(id(sid), runnerName(await readJSON(req))).run();
    if (!r.meta.changes) throw new HttpError(409, "lease lost");
    return { ok: true };
  }],

  ["POST", /^\/api\/runner\/(recordings?|summar(?:y|ies))\/(\d+)\/fail$/, async (req, env, [k, jid]) => {
    const kind = kindOf(k);
    const body = await readJSON<{ runner?: unknown; error?: unknown }>(req);
    const r = await env.DB.prepare(`UPDATE ${kind} SET status='error', error=?3, lease_until=NULL WHERE id=?1 AND runner=?2 AND ${ACTIVE[kind]}`)
      .bind(id(jid), runnerName(body), String(body.error ?? "failed")).run();
    if (!r.meta.changes) throw new HttpError(409, "lease lost");
    return { ok: true };
  }],

  ["POST", /^\/api\/runner\/summar(?:y|ies)\/(\d+)\/result$/, async (req, env, [sid]) => {
    const body = await readJSON<{ runner?: unknown; content_md?: unknown }>(req);
    if (typeof body.content_md !== "string") throw new HttpError(400, "content_md required");
    const r = await env.DB.prepare(`UPDATE summaries SET status='done', content_md=?3, error=NULL, lease_until=NULL
      WHERE id=?1 AND runner=?2 AND ${ACTIVE.summaries}`).bind(id(sid), runnerName(body), body.content_md).run();
    if (!r.meta.changes) throw new HttpError(409, "lease lost");
    return { ok: true };
  }],
];
