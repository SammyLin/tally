// Web Push "job finished" notifications, WebCrypto only: VAPID (RFC 8292) + aes128gcm payload encryption (RFC 8291 / RFC 8188).
// VAPID_PUBLIC_KEY = base64url uncompressed P-256 point (65 bytes); VAPID_PRIVATE_KEY = base64url raw private scalar d (32 bytes).
// Keys unset → notify is a no-op and /api/push/key answers {key:null} (the UI hides the toggle).
import type { Env } from "./http"; // type-only: node test imports this file

export type Sub = { endpoint: string; p256dh: string; auth: string };
export type Msg = { title: string; body: string; url: string; tag?: string };
type Vapid = { VAPID_PUBLIC_KEY: string; VAPID_PRIVATE_KEY: string; VAPID_SUBJECT?: string };

const te = new TextEncoder();
export const b64u = {
  enc: (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""),
  dec: (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)),
};
const cat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) out.set(p, i), (i += p.length);
  return out;
};
const P256 = { name: "ECDH", namedCurve: "P-256" };

// A raw d needs x/y for JWK import; they come from the matching public point (0x04 || x || y).
export function importPrivate(d: string, pub: Uint8Array, alg: "ECDSA" | "ECDH") {
  const jwk = { kty: "EC", crv: "P-256", d, x: b64u.enc(pub.slice(1, 33)), y: b64u.enc(pub.slice(33, 65)) };
  return crypto.subtle.importKey("jwk", jwk, { name: alg, namedCurve: "P-256" }, false, alg === "ECDSA" ? ["sign"] : ["deriveBits"]);
}

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number) {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, bytes * 8));
}

// One aes128gcm record (rs 4096, so the payload must stay < 4079 bytes). Salt and sender keys are random per message;
// the test injects RFC 8291 Appendix A's.
export async function encrypt(sub: { p256dh: string; auth: string }, plaintext: Uint8Array,
  salt = crypto.getRandomValues(new Uint8Array(16)), as?: { privateKey: CryptoKey; publicRaw: Uint8Array }) {
  if (!as) {
    const kp = (await crypto.subtle.generateKey(P256, true, ["deriveBits"])) as CryptoKeyPair;
    as = { privateKey: kp.privateKey, publicRaw: new Uint8Array((await crypto.subtle.exportKey("raw", kp.publicKey)) as ArrayBuffer) };
  }
  const ua = b64u.dec(sub.p256dh);
  const uaKey = await crypto.subtle.importKey("raw", ua, P256, false, []);
  // workers-types spell the param `$public`; the runtime (like WebCrypto everywhere) reads `public`
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey } as never, as.privateKey, 256));
  const ikm = await hkdf(b64u.dec(sub.auth), ecdh, cat(te.encode("WebPush: info\0"), ua, as.publicRaw), 32);
  const cek = await crypto.subtle.importKey("raw", await hkdf(salt, ikm, te.encode("Content-Encoding: aes128gcm\0"), 16), "AES-GCM", false, ["encrypt"]);
  const iv = await hkdf(salt, ikm, te.encode("Content-Encoding: nonce\0"), 12);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, cek, cat(plaintext, new Uint8Array([2])))); // 2 = last record
  const head = new Uint8Array(21); // salt(16) | rs(4) | idlen(1), then keyid = sender public key
  head.set(salt), new DataView(head.buffer).setUint32(16, 4096), (head[20] = as.publicRaw.length);
  return cat(head, as.publicRaw, ct);
}

export async function vapidAuth(endpoint: string, env: Vapid, now = Date.now()) {
  const key = await importPrivate(env.VAPID_PRIVATE_KEY, b64u.dec(env.VAPID_PUBLIC_KEY), "ECDSA");
  const part = (o: object) => b64u.enc(te.encode(JSON.stringify(o)));
  const claims = { aud: new URL(endpoint).origin, exp: Math.floor(now / 1000) + 12 * 3600, sub: env.VAPID_SUBJECT || "mailto:admin@example.com" };
  const input = `${part({ typ: "JWT", alg: "ES256" })}.${part(claims)}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, te.encode(input)); // raw r||s, as JWS wants
  return `vapid t=${input}.${b64u.enc(sig)}, k=${env.VAPID_PUBLIC_KEY}`;
}

export const pushEnabled = (env: Env): env is Env & Vapid => !!(env.VAPID_PUBLIC_KEY && env.VAPID_PRIVATE_KEY);

async function send(env: Env & Vapid, sub: Sub, payload: Uint8Array) {
  const r = await fetch(sub.endpoint, {
    method: "POST", body: await encrypt(sub, payload),
    headers: { Authorization: await vapidAuth(sub.endpoint, env), "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", TTL: "86400" },
  });
  const text = await r.text();
  if (r.status === 404 || r.status === 410) await env.DB.prepare(`DELETE FROM push_subscriptions WHERE endpoint=?`).bind(sub.endpoint).run();
  else if (!r.ok) throw new Error(`${r.status} ${text.slice(0, 200)}`);
}

// Sends to every subscription of user `uid` in parallel; never throws (a push failure must never fail the request that triggered it).
export async function notify(env: Env, uid: number, msg: Msg) {
  try {
    if (!pushEnabled(env)) return;
    const { results } = await env.DB.prepare(`SELECT endpoint, p256dh, auth FROM push_subscriptions WHERE user_id=?`).bind(uid).all<Sub>();
    const payload = te.encode(JSON.stringify({ ...msg, title: msg.title.slice(0, 100), body: msg.body.slice(0, 300) }));
    const out = await Promise.allSettled(results.map((s) => send(env, s, payload)));
    out.forEach((o, i) => o.status === "rejected" && console.error("push", new URL(results[i].endpoint).host, String(o.reason)));
  } catch (e) {
    console.error("push", e);
  }
}

// A finished/failed job → notification to the job's owner titled with its recording; clicking opens the recording (summary tab for summaries).
export async function notifyJob(env: Env, kind: "recordings" | "summaries" | "asks", jid: number, body: string) {
  try {
    if (!pushEnabled(env)) return;
    if (kind === "asks") {
      const a = await env.DB.prepare(`SELECT question, user_id FROM asks WHERE id=?`).bind(jid).first<{ question: string; user_id: number }>();
      if (a) await notify(env, a.user_id, { title: a.question.slice(0, 60), body, url: `/#/ask/${jid}`, tag: `ask-${jid}` });
      return;
    }
    const rec = await env.DB.prepare(kind === "summaries"
      ? `SELECT r.id, r.title, r.user_id FROM summaries s JOIN recordings r ON r.id=s.recording_id WHERE s.id=?`
      : `SELECT id, title, user_id FROM recordings WHERE id=?`).bind(jid).first<{ id: number; title: string; user_id: number }>();
    if (rec) await notify(env, rec.user_id, { title: rec.title || "Tally", body, url: `/#/rec/${rec.id}${kind === "summaries" ? "/summary" : ""}`, tag: `rec-${rec.id}` });
  } catch (e) {
    console.error("push", e);
  }
}
