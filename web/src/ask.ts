// Ask (問問看): questions across the user's recordings, answered by a runner (claim/result live in runner.ts).
import { type Env, type Handler, HttpError, first, readJSON } from "./http";

const id = (s: string) => Number(s);
const CITE = /\[\[([^\]]+)\]\]/g;

// recording ids cited as [[id@mm:ss]] (several may share one bracket: [[3@01:00, 4@02:00]])
const citedIds = (md: string) => [...md.matchAll(CITE)].flatMap((m) => [...m[1].matchAll(/(\d+)@/g)].map((x) => Number(x[1])));
const preview = (md: string | null) => md ? md.replace(CITE, "").replace(/[#*_>`|]+/g, "").replace(/\s+/g, " ").trim().slice(0, 120) : null;

const getAsk = (env: Env, aid: number, uid: number) =>
  first<{ id: number; answer_md: string | null; sources: string | null }>(env.DB.prepare(`SELECT * FROM asks WHERE id=? AND user_id=?`).bind(aid, uid), "ask not found");

export const askRoutes: [string, RegExp, Handler][] = [
  ["POST", /^\/api\/asks$/, async (req, env, _p, _u, _c, uid) => {
    const body = await readJSON<{ question?: unknown }>(req);
    const q = typeof body.question === "string" ? body.question.trim() : "";
    if (!q || [...q].length > 1000) throw new HttpError(400, "question must be 1-1000 characters");
    return first(env.DB.prepare(`INSERT INTO asks(question, user_id) VALUES(?, ?) RETURNING id`).bind(q, uid));
  }],

  ["GET", /^\/api\/asks$/, async (_req, env, _p, _u, _c, uid) => {
    const { results } = await env.DB.prepare(`SELECT id, question, status, created_at, substr(answer_md, 1, 400) AS answer
      FROM asks WHERE user_id=? ORDER BY id DESC LIMIT 50`).bind(uid).all<{ answer: string | null }>();
    return results.map(({ answer, ...a }) => ({ ...a, preview: preview(answer) }));
  }],

  // full row + titles of the recordings it used or cites (deleted ones are flagged, purged ones absent)
  ["GET", /^\/api\/asks\/(\d+)$/, async (_req, env, [aid], _u, _c, uid) => {
    const a = await getAsk(env, id(aid), uid);
    const sources: number[] = a.sources ? JSON.parse(a.sources) : [];
    const ids = [...new Set([...sources, ...citedIds(a.answer_md ?? "")])];
    const { results } = await env.DB.prepare(`SELECT id, title, deleted_at IS NOT NULL AS deleted FROM recordings
      WHERE id IN (SELECT value FROM json_each(?)) AND user_id=?`).bind(JSON.stringify(ids), uid).all();
    return { ...a, sources, recordings: results };
  }],

  ["DELETE", /^\/api\/asks\/(\d+)$/, async (_req, env, [aid], _u, _c, uid) => {
    const r = await env.DB.prepare(`DELETE FROM asks WHERE id=? AND user_id=?`).bind(id(aid), uid).run();
    if (!r.meta.changes) throw new HttpError(404, "ask not found");
    return { ok: true };
  }],

  ["POST", /^\/api\/asks\/(\d+)\/retry$/, async (_req, env, [aid], _u, _c, uid) => {
    await getAsk(env, id(aid), uid);
    const r = await env.DB.prepare(`UPDATE asks SET status='queued', error=NULL, answer_md=NULL, sources=NULL, runner=NULL, lease_until=NULL
      WHERE id=? AND user_id=? AND status='error'`).bind(id(aid), uid).run();
    if (!r.meta.changes) throw new HttpError(409, "only a failed ask can be retried");
    return { ok: true };
  }],
];
