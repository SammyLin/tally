// Ask (問問看): questions across all recordings, answered by a runner (claim/result live in runner.ts).
import { type Env, type Handler, HttpError, first, readJSON } from "./http";

const id = (s: string) => Number(s);
const CITE = /\[\[([^\]]+)\]\]/g;

// recording ids cited as [[id@mm:ss]] (several may share one bracket: [[3@01:00, 4@02:00]])
const citedIds = (md: string) => [...md.matchAll(CITE)].flatMap((m) => [...m[1].matchAll(/(\d+)@/g)].map((x) => Number(x[1])));
const preview = (md: string | null) => md ? md.replace(CITE, "").replace(/[#*_>`|]+/g, "").replace(/\s+/g, " ").trim().slice(0, 120) : null;

const getAsk = (env: Env, aid: number) =>
  first<{ id: number; answer_md: string | null; sources: string | null }>(env.DB.prepare(`SELECT * FROM asks WHERE id=?`).bind(aid), "ask not found");

export const askRoutes: [string, RegExp, Handler][] = [
  ["POST", /^\/api\/asks$/, async (req, env) => {
    const body = await readJSON<{ question?: unknown }>(req);
    const q = typeof body.question === "string" ? body.question.trim() : "";
    if (!q || [...q].length > 1000) throw new HttpError(400, "question must be 1-1000 characters");
    return first(env.DB.prepare(`INSERT INTO asks(question) VALUES(?) RETURNING id`).bind(q));
  }],

  ["GET", /^\/api\/asks$/, async (_req, env) => {
    const { results } = await env.DB.prepare(`SELECT id, question, status, created_at, substr(answer_md, 1, 400) AS answer
      FROM asks ORDER BY id DESC LIMIT 50`).all<{ answer: string | null }>();
    return results.map(({ answer, ...a }) => ({ ...a, preview: preview(answer) }));
  }],

  // full row + titles of the recordings it used or cites (deleted ones are flagged, purged ones absent)
  ["GET", /^\/api\/asks\/(\d+)$/, async (_req, env, [aid]) => {
    const a = await getAsk(env, id(aid));
    const sources: number[] = a.sources ? JSON.parse(a.sources) : [];
    const ids = [...new Set([...sources, ...citedIds(a.answer_md ?? "")])];
    const { results } = await env.DB.prepare(`SELECT id, title, deleted_at IS NOT NULL AS deleted FROM recordings
      WHERE id IN (SELECT value FROM json_each(?))`).bind(JSON.stringify(ids)).all();
    return { ...a, sources, recordings: results };
  }],

  ["DELETE", /^\/api\/asks\/(\d+)$/, async (_req, env, [aid]) => {
    const r = await env.DB.prepare(`DELETE FROM asks WHERE id=?`).bind(id(aid)).run();
    if (!r.meta.changes) throw new HttpError(404, "ask not found");
    return { ok: true };
  }],

  ["POST", /^\/api\/asks\/(\d+)\/retry$/, async (_req, env, [aid]) => {
    await getAsk(env, id(aid));
    const r = await env.DB.prepare(`UPDATE asks SET status='queued', error=NULL, answer_md=NULL, sources=NULL, runner=NULL, lease_until=NULL
      WHERE id=? AND status='error'`).bind(id(aid)).run();
    if (!r.meta.changes) throw new HttpError(409, "only a failed ask can be retried");
    return { ok: true };
  }],
];
