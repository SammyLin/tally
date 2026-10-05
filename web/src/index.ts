import { verifyAccessJwt } from "./auth";
import {
  type Env, type Handler, HttpError, errorResponse, first, languages, parseParts, partNumber, readJSON, serveR2, splitFilename, templates,
} from "./http";
import { listRunners, runnerRoutes } from "./runner";
import { STT_LANGS, getSettings, parseSettings, putSettings } from "./settings";
import { enrol, isDefaultName, rematch, upsertPerson } from "./voice";

const PART_SIZE = 50 * 1024 * 1024;
const PROCESSING = `('converting','transcribing','cleaning')`;

const truthy = (v: string | null) => v !== null && v !== "" && v !== "0";
const id = (s: string) => Number(s);
const getRecording = (env: Env, rid: number) => first(env.DB.prepare(`SELECT * FROM recordings WHERE id=?`).bind(rid));
const getPerson = (env: Env, pid: number) => first<{ id: number; name: string }>(env.DB.prepare(`SELECT id, name FROM people WHERE id=?`).bind(pid), "person not found");

function recLanguage(v: unknown) {
  if (v == null) return null;
  if (!STT_LANGS.includes(v as string)) throw new HttpError(400, `language must be one of ${STT_LANGS.join("|")}`);
  return v as string;
}

async function listPersons(env: Env) {
  const { results } = await env.DB.prepare(`SELECT p.id, p.name,
      (SELECT count(*) FROM voiceprints v WHERE v.person_id=p.id) AS prints,
      (SELECT count(*) FROM speakers s WHERE s.person_id=p.id) AS speakers, p.last_used_at
    FROM people p ORDER BY p.last_used_at DESC, p.id DESC`).all();
  return results;
}

async function detail(env: Env, rid: number) {
  const recording = await getRecording(env, rid);
  const [speakers, segments, summaries] = await env.DB.batch([
    env.DB.prepare(`SELECT s.id, s.label, s.display_name, s.person_id, s.auto, s.embedding IS NOT NULL AS has_embedding, s.emb_model,
        CASE WHEN p.id IS NOT NULL THEN json_object('person_id', p.id, 'name', p.name, 'score', s.suggest_score) END AS suggest
      FROM speakers s LEFT JOIN people p ON p.id=s.suggest_person_id WHERE s.recording_id=? ORDER BY s.id`).bind(rid),
    env.DB.prepare(`SELECT id, start_ms, end_ms, speaker_id, text_raw, text_clean FROM segments WHERE recording_id=? ORDER BY start_ms, id`).bind(rid),
    env.DB.prepare(`SELECT * FROM summaries WHERE recording_id=? ORDER BY id DESC`).bind(rid),
  ]);
  return {
    recording, segments: segments.results, summaries: summaries.results,
    speakers: (speakers.results as { suggest: string | null }[]).map((s) => ({ ...s, suggest: s.suggest ? JSON.parse(s.suggest) : null })),
  };
}

async function folderExists(env: Env, fid: unknown) {
  if (fid === null || fid === undefined) return null;
  if (!Number.isInteger(fid)) throw new HttpError(400, "folder_id must be an integer or null");
  if (!(await env.DB.prepare(`SELECT 1 FROM folders WHERE id=?`).bind(fid).first())) throw new HttpError(400, "folder not found");
  return fid as number;
}

const folderRow = (env: Env, fid: number) =>
  first(env.DB.prepare(`SELECT f.id, f.parent_id, f.name,
    (SELECT count(*) FROM recordings r WHERE r.folder_id=f.id AND r.deleted_at IS NULL) AS count FROM folders f WHERE f.id=?`).bind(fid), "folder not found");

// D1 raises UNIQUE violations as plain errors.
async function uniqueName<T>(p: Promise<T>): Promise<T> {
  try {
    return await p;
  } catch (e) {
    if (String(e).includes("UNIQUE")) throw new HttpError(409, "a folder with that name already exists here");
    throw e;
  }
}

const routes: [string, RegExp, Handler][] = [
  ["GET", /^\/media\/(\d+)$/, async (req, env, [rid]) => {
    const rec = await env.DB.prepare(`SELECT play_key FROM recordings WHERE id=?`).bind(id(rid)).first<{ play_key: string | null }>();
    if (!rec?.play_key) return errorResponse(404, "media not ready");
    return serveR2(req, env.AUDIO, rec.play_key, "audio/mp4");
  }],

  ["GET", /^\/api\/recordings$/, async (_req, env, _p, url) => {
    const q = url.searchParams;
    const where = [`r.deleted_at IS ${truthy(q.get("trash")) ? "NOT NULL" : "NULL"}`];
    const args: unknown[] = [];
    const s = q.get("q");
    if (s) {
      where.push(`(r.title LIKE ? OR EXISTS(SELECT 1 FROM segments g WHERE g.recording_id=r.id AND (g.text_raw LIKE ? OR g.text_clean LIKE ?)))`);
      args.push(`%${s}%`, `%${s}%`, `%${s}%`);
    }
    const folder = q.get("folder");
    if (folder === "none") where.push(`r.folder_id IS NULL`);
    else if (folder) where.push(`r.folder_id=?`), args.push(Number(folder));
    if (q.has("filename")) where.push(`r.filename=?`), args.push(q.get("filename"));
    if (q.has("size")) where.push(`r.size=?`), args.push(Number(q.get("size")));
    const limit = q.get("view") === "recent" ? " LIMIT 50" : "";
    const { results } = await env.DB.prepare(`SELECT r.*, EXISTS(SELECT 1 FROM summaries s WHERE s.recording_id=r.id AND s.status='done') AS has_summary
      FROM recordings r WHERE ${where.join(" AND ")} ORDER BY r.created_at DESC, r.id DESC${limit}`).bind(...args).all();
    return results.map((r) => ({ ...r, has_summary: r.has_summary === 1 }));
  }],

  ["GET", /^\/api\/recordings\/(\d+)$/, (_req, env, [rid]) => detail(env, id(rid))],

  ["PATCH", /^\/api\/recordings\/(\d+)$/, async (req, env, [rid]) => {
    const body = await readJSON<{ title?: unknown; folder_id?: unknown }>(req);
    await getRecording(env, id(rid));
    const title = typeof body.title === "string" ? body.title.trim() : "";
    if (title) await env.DB.prepare(`UPDATE recordings SET title=? WHERE id=?`).bind(title, id(rid)).run();
    if ("folder_id" in body) {
      const fid = await folderExists(env, body.folder_id);
      await env.DB.prepare(`UPDATE recordings SET folder_id=? WHERE id=?`).bind(fid, id(rid)).run();
    }
    return getRecording(env, id(rid));
  }],

  ["DELETE", /^\/api\/recordings\/(\d+)$/, async (_req, env, [rid], url) => {
    await getRecording(env, id(rid));
    if (!truthy(url.searchParams.get("purge"))) {
      await env.DB.prepare(`UPDATE recordings SET deleted_at=datetime('now') WHERE id=?`).bind(id(rid)).run();
      return { ok: true };
    }
    // a runner holding a live lease would write into a deleted row; an expired lease is fair game
    const gone = await env.DB.prepare(`DELETE FROM recordings WHERE id=?
      AND NOT (status IN ${PROCESSING} AND lease_until >= datetime('now'))
      RETURNING status, source_key, play_key, upload_id`).bind(id(rid)).first<{ status: string; source_key: string | null; play_key: string | null; upload_id: string | null }>();
    if (!gone) throw new HttpError(409, "recording is being processed");
    if (gone.status === "uploading" && gone.source_key && gone.upload_id)
      await env.AUDIO.resumeMultipartUpload(gone.source_key, gone.upload_id).abort().catch(() => {});
    const keys = [gone.source_key, gone.play_key].filter((k): k is string => !!k);
    if (keys.length) await env.AUDIO.delete(keys);
    return { ok: true };
  }],

  ["POST", /^\/api\/recordings\/(\d+)\/restore$/, async (_req, env, [rid]) => {
    await getRecording(env, id(rid));
    await env.DB.prepare(`UPDATE recordings SET deleted_at=NULL WHERE id=?`).bind(id(rid)).run();
    return getRecording(env, id(rid));
  }],

  ["POST", /^\/api\/recordings\/(\d+)\/retranscribe$/, async (req, env, [rid]) => {
    // body is optional: {language?}; language null = back to the settings default
    const json = req.headers.get("Content-Type")?.toLowerCase().startsWith("application/json") && (await req.clone().text()).trim();
    const body = json ? await readJSON<{ language?: unknown }>(req) : {};
    const lang = "language" in body ? [recLanguage(body.language)] : [];
    await getRecording(env, id(rid));
    const r = await env.DB.prepare(`UPDATE recordings SET status='queued', error=NULL${lang.length ? ", language=?2" : ""}
      WHERE id=?1 AND status IN ('done','error')`).bind(id(rid), ...lang).run();
    if (!r.meta.changes) throw new HttpError(409, "recording is being processed");
    return getRecording(env, id(rid));
  }],

  ["PATCH", /^\/api\/segments\/(\d+)$/, async (req, env, [sid]) => {
    const body = await readJSON<{ text?: unknown }>(req);
    if (body.text !== undefined && typeof body.text !== "string") throw new HttpError(400, "text must be a string");
    const r = await env.DB.prepare(`UPDATE segments SET text_clean=? WHERE id=?`).bind(body.text ?? "", id(sid)).run();
    if (!r.meta.changes) throw new HttpError(404, "segment not found");
    return first(env.DB.prepare(`SELECT * FROM segments WHERE id=?`).bind(id(sid)));
  }],

  ["POST", /^\/api\/segments\/(\d+)\/speaker$/, async (req, env, [sid]) => {
    const body = await readJSON<{ name?: unknown; scope?: unknown }>(req);
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (!name) throw new HttpError(400, "name required");
    const seg = await first<{ recording_id: number; speaker_id: number | null }>(
      env.DB.prepare(`SELECT recording_id, speaker_id FROM segments WHERE id=?`).bind(id(sid)), "segment not found");
    const person = !isDefaultName(name);
    const db = env.DB;
    // scope all: rename (= confirm) the speaker; a real name enrols it as a voiceprint, a default name drops its print
    const stmts = (body.scope || "all") === "all" && seg.speaker_id !== null
      ? person
        ? enrol(db, seg.speaker_id, name)
        : [db.prepare(`UPDATE speakers SET display_name=?2, person_id=NULL, auto=2 WHERE id=?1`).bind(seg.speaker_id, name),
           db.prepare(`DELETE FROM voiceprints WHERE speaker_id=?`).bind(seg.speaker_id)]
      : [ // reuse a speaker with that name in this recording, else create one; then repoint the segment
          db.prepare(`INSERT INTO speakers(recording_id, label, display_name) SELECT ?1, 'custom', ?2
            WHERE NOT EXISTS(SELECT 1 FROM speakers WHERE recording_id=?1 AND display_name=?2)`).bind(seg.recording_id, name),
          db.prepare(`UPDATE segments SET speaker_id=(SELECT id FROM speakers WHERE recording_id=?1 AND display_name=?2 ORDER BY id LIMIT 1)
            WHERE id=?3`).bind(seg.recording_id, name, id(sid)),
          ...(person ? [upsertPerson(db, name),
            db.prepare(`UPDATE speakers SET person_id=(SELECT id FROM people WHERE name=?2), auto=0 WHERE recording_id=?1 AND display_name=?2`).bind(seg.recording_id, name)] : []),
        ];
    await env.DB.batch(stmts);
    // a new voiceprint can re-score every recording; otherwise only this one changed
    await rematch(env, person && (body.scope || "all") === "all" ? undefined : seg.recording_id);
    return detail(env, seg.recording_id);
  }],

  ["GET", /^\/api\/people$/, async (_req, env) => {
    const { results } = await env.DB.prepare(`SELECT name FROM people ORDER BY last_used_at DESC, id DESC LIMIT 20`).all<{ name: string }>();
    return results.map((r) => r.name);
  }],

  // ---- persons (speaker management); every change re-matches all recordings
  ["GET", /^\/api\/persons$/, (_req, env) => listPersons(env)],

  ["PATCH", /^\/api\/persons\/(\d+)$/, async (req, env, [ps]) => {
    const pid = id(ps);
    const body = await readJSON<{ name?: unknown; merge?: unknown }>(req);
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (!name || [...name].length > 100) throw new HttpError(400, "name must be 1-100 characters");
    if (isDefaultName(name)) throw new HttpError(400, "name cannot be a default speaker name");
    const person = await getPerson(env, pid);
    if (name === person.name) return listPersons(env);
    const other = await env.DB.prepare(`SELECT id FROM people WHERE name=?`).bind(name).first<{ id: number }>();
    const db = env.DB;
    if (!other) {
      await db.batch([
        db.prepare(`UPDATE people SET name=?2 WHERE id=?1`).bind(pid, name),
        db.prepare(`UPDATE speakers SET display_name=?2 WHERE person_id=?1`).bind(pid, name),
      ]);
    } else if (body.merge !== true) {
      return Response.json({ detail: `${name} already exists`, existing_id: other.id }, { status: 409 });
    } else {
      await db.batch([
        db.prepare(`UPDATE voiceprints SET person_id=?2 WHERE person_id=?1`).bind(pid, other.id),
        db.prepare(`UPDATE speakers SET person_id=?2, display_name=?3 WHERE person_id=?1`).bind(pid, other.id, name),
        db.prepare(`UPDATE speakers SET suggest_person_id=?2 WHERE suggest_person_id=?1`).bind(pid, other.id),
        db.prepare(`UPDATE settings SET value=?2 WHERE key='me' AND value=?1`).bind(JSON.stringify(pid), JSON.stringify(other.id)),
        db.prepare(`DELETE FROM people WHERE id=?`).bind(pid),
      ]);
    }
    await rematch(env);
    return listPersons(env);
  }],

  ["DELETE", /^\/api\/persons\/(\d+)$/, async (_req, env, [ps]) => {
    const pid = id(ps);
    await getPerson(env, pid);
    const db = env.DB;
    // auto labels revert to "Speaker k" (k = position among the recording's diarized speakers, as in rematch); confirmed names stay
    await db.batch([
      db.prepare(`UPDATE speakers SET display_name='Speaker ' || (SELECT count(*) FROM speakers s
          WHERE s.recording_id=speakers.recording_id AND s.label<>'custom' AND s.id<=speakers.id), person_id=NULL, auto=0
        WHERE person_id=?1 AND auto=1`).bind(pid),
      db.prepare(`UPDATE speakers SET person_id=NULL WHERE person_id=?1`).bind(pid),
      db.prepare(`UPDATE speakers SET suggest_person_id=NULL, suggest_score=NULL WHERE suggest_person_id=?1`).bind(pid),
      db.prepare(`DELETE FROM settings WHERE key='me' AND value=?`).bind(JSON.stringify(pid)),
      db.prepare(`DELETE FROM voiceprints WHERE person_id=?`).bind(pid),
      db.prepare(`DELETE FROM people WHERE id=?`).bind(pid),
    ]);
    await rematch(env);
    return { ok: true };
  }],

  // ---- settings
  ["GET", /^\/api\/settings$/, (_req, env) => getSettings(env)],

  ["PUT", /^\/api\/settings$/, async (req, env) => {
    const patch = parseSettings(await readJSON(req));
    if (typeof patch === "string") throw new HttpError(400, patch);
    if (patch.me != null && !(await env.DB.prepare(`SELECT 1 FROM people WHERE id=?`).bind(patch.me).first()))
      throw new HttpError(400, "me: person not found");
    return putSettings(env, patch);
  }],

  ["GET", /^\/api\/templates$/, async () => ({ templates, languages })],

  ["POST", /^\/api\/recordings\/(\d+)\/summaries$/, async (req, env, [rid]) => {
    const body = await readJSON<{ template_id?: unknown; language?: unknown }>(req);
    const lang = body.language || "zh-TW";
    if (!templates.some((t) => t.id === body.template_id) || !languages.some((l) => l.id === lang))
      throw new HttpError(400, "unknown template or language");
    await getRecording(env, id(rid));
    return first(env.DB.prepare(`INSERT INTO summaries(recording_id, template_id, language) VALUES(?, ?, ?) RETURNING *`).bind(id(rid), body.template_id, lang));
  }],

  ["DELETE", /^\/api\/summaries\/(\d+)$/, async (_req, env, [sid]) => {
    const r = await env.DB.prepare(`DELETE FROM summaries WHERE id=?`).bind(id(sid)).run();
    if (!r.meta.changes) throw new HttpError(404, "summary not found");
    return { ok: true };
  }],

  // ---- folders
  ["GET", /^\/api\/folders$/, async (_req, env) => {
    const { results } = await env.DB.prepare(`SELECT f.id, f.parent_id, f.name,
      (SELECT count(*) FROM recordings r WHERE r.folder_id=f.id AND r.deleted_at IS NULL) AS count FROM folders f ORDER BY f.name, f.id`).all();
    return results;
  }],

  ["POST", /^\/api\/folders$/, async (req, env) => {
    const body = await readJSON<{ name?: unknown; parent_id?: unknown }>(req);
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (!name) throw new HttpError(400, "name required");
    const parent = await folderExists(env, body.parent_id);
    const row = await uniqueName(first<{ id: number }>(env.DB.prepare(`INSERT INTO folders(parent_id, name) VALUES(?, ?) RETURNING id`).bind(parent, name)));
    return folderRow(env, row.id);
  }],

  ["PATCH", /^\/api\/folders\/(\d+)$/, async (req, env, [fs]) => {
    const fid = id(fs);
    const body = await readJSON<{ name?: unknown; parent_id?: unknown }>(req);
    await folderRow(env, fid);
    const sets: string[] = [];
    const args: unknown[] = [];
    if (typeof body.name === "string" && body.name.trim()) sets.push("name=?"), args.push(body.name.trim());
    if ("parent_id" in body) {
      const parent = await folderExists(env, body.parent_id);
      if (parent !== null) {
        const cycle = await env.DB.prepare(`WITH RECURSIVE anc(id) AS (
            SELECT ?1 UNION SELECT f.parent_id FROM folders f JOIN anc ON f.id=anc.id WHERE f.parent_id IS NOT NULL)
          SELECT 1 FROM anc WHERE id=?2`).bind(parent, fid).first();
        if (cycle) throw new HttpError(400, "cannot move a folder into itself or a subfolder");
      }
      sets.push("parent_id=?"), args.push(parent);
    }
    if (sets.length) await uniqueName(env.DB.prepare(`UPDATE folders SET ${sets.join(", ")} WHERE id=?`).bind(...args, fid).run());
    return folderRow(env, fid);
  }],

  ["DELETE", /^\/api\/folders\/(\d+)$/, async (_req, env, [fid]) => {
    // FK actions do the work: subfolders cascade, their recordings' folder_id → NULL (未分類)
    const r = await env.DB.prepare(`DELETE FROM folders WHERE id=?`).bind(id(fid)).run();
    if (!r.meta.changes) throw new HttpError(404, "folder not found");
    return { ok: true };
  }],

  // ---- uploads (R2 multipart through the Worker)
  ["POST", /^\/api\/uploads$/, async (req, env) => {
    const body = await readJSON<{ filename?: unknown; size?: unknown; folder_id?: unknown; language?: unknown }>(req);
    if (typeof body.filename !== "string" || !body.filename) throw new HttpError(400, "filename required");
    if (!Number.isInteger(body.size) || (body.size as number) < 0) throw new HttpError(400, "size required");
    const lang = recLanguage(body.language);
    const folder = await folderExists(env, body.folder_id);
    const { name, ext, stem } = splitFilename(body.filename);
    const { id: rid } = await first<{ id: number }>(env.DB.prepare(`INSERT INTO recordings(title, filename, status, size, folder_id, language)
      VALUES(?, ?, 'uploading', ?, ?, ?) RETURNING id`).bind(stem, name, body.size, folder, lang));
    const key = `rec/${rid}/source${ext}`;
    try {
      const up = await env.AUDIO.createMultipartUpload(key);
      await env.DB.prepare(`UPDATE recordings SET source_key=?, upload_id=? WHERE id=?`).bind(key, up.uploadId, rid).run();
    } catch (e) {
      await env.DB.prepare(`DELETE FROM recordings WHERE id=?`).bind(rid).run();
      throw e;
    }
    return { recording_id: rid, part_size: PART_SIZE };
  }],

  ["PUT", /^\/api\/uploads\/(\d+)\/(\d+)$/, async (req, env, [rid, part]) => {
    const rec = await uploading(env, id(rid));
    if (!req.body) throw new HttpError(400, "empty part");
    const p = await env.AUDIO.resumeMultipartUpload(rec.source_key, rec.upload_id).uploadPart(partNumber(part), req.body);
    return { etag: p.etag };
  }],

  ["POST", /^\/api\/uploads\/(\d+)\/complete$/, async (req, env, [rid]) => {
    const parts = parseParts(await readJSON(req));
    const rec = await uploading(env, id(rid));
    const obj = await env.AUDIO.resumeMultipartUpload(rec.source_key, rec.upload_id).complete(parts);
    await env.DB.prepare(`UPDATE recordings SET status='queued', upload_id=NULL, size=? WHERE id=?`).bind(obj.size, id(rid)).run();
    return getRecording(env, id(rid));
  }],

  ["DELETE", /^\/api\/uploads\/(\d+)$/, async (_req, env, [rid]) => {
    const rec = await uploading(env, id(rid));
    await env.AUDIO.resumeMultipartUpload(rec.source_key, rec.upload_id).abort().catch(() => {});
    await env.DB.prepare(`DELETE FROM recordings WHERE id=?`).bind(id(rid)).run();
    return { ok: true };
  }],

  ["GET", /^\/api\/runners$/, (_req, env) => listRunners(env)],

  ...runnerRoutes,
];

async function uploading(env: Env, rid: number) {
  const rec = await first<{ status: string; source_key: string; upload_id: string }>(
    env.DB.prepare(`SELECT status, source_key, upload_id FROM recordings WHERE id=?`).bind(rid));
  if (rec.status !== "uploading" || !rec.upload_id) throw new HttpError(409, "upload already completed");
  return rec;
}

async function denied(req: Request, env: Env): Promise<Response | null> {
  if (env.DEV_NO_AUTH === "1") return null;
  if (!env.ACCESS_TEAM || !env.ACCESS_AUD) return errorResponse(503, "Access not configured");
  const claims = await verifyAccessJwt(req.headers.get("Cf-Access-Jwt-Assertion"), env.ACCESS_TEAM, env.ACCESS_AUD);
  return claims ? null : errorResponse(403, "forbidden");
}

export default {
  async fetch(req, env): Promise<Response> {
    const url = new URL(req.url);
    const deny = await denied(req, env);
    if (deny) return deny;
    const method = req.method === "HEAD" ? "GET" : req.method;
    // CSRF: the Access cookie may ride along on cross-site requests; the runner sends no Sec-Fetch-* headers
    if (method !== "GET" && ["cross-site", "same-site"].includes(req.headers.get("Sec-Fetch-Site") ?? "")) return errorResponse(403, "cross-site request");
    let pathMatched = false;
    for (const [m, re, handler] of routes) {
      const match = re.exec(url.pathname);
      if (!match) continue;
      pathMatched = true;
      if (m !== method) continue;
      try {
        const v = await handler(req, env, match.slice(1), url);
        return v instanceof Response ? v : Response.json(v);
      } catch (e) {
        if (e instanceof HttpError) return errorResponse(e.status, e.message);
        console.error(req.method, url.pathname, e);
        return errorResponse(500, String((e as Error)?.message ?? e));
      }
    }
    return pathMatched ? errorResponse(405, "method not allowed") : errorResponse(404, "not found");
  },
} satisfies ExportedHandler<Env>;
