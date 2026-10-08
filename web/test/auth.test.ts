// node test/auth.test.ts — signs tokens with a local RSA key and checks verifyAccessJwt / verifyClerkJwt against stubbed JWKS endpoints.
import assert from "node:assert/strict";
import { clerkFrontendApi, verifyAccessJwt, verifyClerkJwt } from "../src/auth.ts";

const team = "myteam", aud = "aud-123";
const alg = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
const { privateKey, publicKey } = await crypto.subtle.generateKey(alg, true, ["sign", "verify"]);
const other = await crypto.subtle.generateKey(alg, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", publicKey)), kid: "k1" };

const fapi = "singular-anchovy-3844.clerk.accounts.dev";
let fetches = 0;
globalThis.fetch = async (url) => {
  fetches++;
  assert.ok([`https://${team}.cloudflareaccess.com/cdn-cgi/access/certs`, `https://${fapi}/.well-known/jwks.json`].includes(String(url)), String(url));
  return Response.json({ keys: [jwk] });
};

const enc = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
async function sign(claims: object, { kid = "k1", key = privateKey, alg = "RS256" } = {}) {
  const input = `${enc({ alg, kid, typ: "JWT" })}.${enc(claims)}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(input));
  return `${input}.${Buffer.from(sig).toString("base64url")}`;
}
const now = Math.floor(Date.now() / 1000);
const good = { aud: [aud], exp: now + 60, iat: now, iss: `https://${team}.cloudflareaccess.com`, email: "me@example.com" };

assert.equal((await verifyAccessJwt(await sign(good), team, aud))?.email, "me@example.com");
assert.equal((await verifyAccessJwt(await sign({ ...good, aud, common_name: "cid" }), team, aud))?.common_name, "cid"); // string aud
assert.equal(await verifyAccessJwt(await sign({ ...good, aud: ["other"] }), team, aud), null);
assert.equal(await verifyAccessJwt(await sign({ ...good, exp: now - 1 }), team, aud), null);
assert.equal(await verifyAccessJwt(await sign({ ...good, exp: undefined }), team, aud), null);
assert.equal(await verifyAccessJwt(await sign({ ...good, iss: "https://evil.cloudflareaccess.com" }), team, aud), null);
assert.equal(await verifyAccessJwt(await sign(good, { key: other.privateKey }), team, aud), null); // wrong signer
assert.equal(await verifyAccessJwt(await sign(good, { alg: "none" }), team, aud), null);
const t = await sign(good);
assert.equal(await verifyAccessJwt(t.slice(0, t.lastIndexOf(".")) + "." + enc({}) , team, aud), null); // tampered sig
const [h, , s] = t.split(".");
assert.equal(await verifyAccessJwt(`${h}.${enc({ ...good, email: "evil@x" })}.${s}`, team, aud), null); // tampered payload
assert.equal(await verifyAccessJwt(null, team, aud), null);
assert.equal(await verifyAccessJwt("garbage", team, aud), null);
const before = fetches;
assert.equal(await verifyAccessJwt(await sign(good, { kid: "unknown" }), team, aud), null);
assert.equal(fetches, before); // certs fetched <1 min ago: unknown kid does not refetch
const realNow = Date.now;
Date.now = () => realNow() + 61_000;
assert.equal(await verifyAccessJwt(await sign(good, { kid: "unknown" }), team, aud), null); // key rotation: one refetch
assert.equal(await verifyAccessJwt(await sign(good, { kid: "unknown" }), team, aud), null);
assert.equal(fetches, before + 1); // ...then throttled again
Date.now = realNow;
await verifyAccessJwt(await sign(good), team, aud);
assert.equal(fetches, before + 1); // certs cached

// Clerk
assert.equal(clerkFrontendApi("pk_test_c2luZ3VsYXItYW5jaG92eS0zODQ0LmNsZXJrLmFjY291bnRzLmRldiQ"), fapi);
assert.equal(clerkFrontendApi(undefined), null);
assert.equal(clerkFrontendApi("pk_test_" + Buffer.from("evil.example").toString("base64")), null); // no trailing $
assert.equal(clerkFrontendApi("sk_test_abc"), null);
const parties = ["https://kiroku.3mi.ai", "http://localhost:8800"];
const session = { sub: "user_123", iss: `https://${fapi}`, azp: "https://kiroku.3mi.ai", exp: now + 60, nbf: now - 5, iat: now };
const clerk = (t: string | null, p = parties) => verifyClerkJwt(t, fapi, p);
assert.equal((await clerk(await sign(session)))?.sub, "user_123");
assert.equal((await clerk(await sign({ ...session, azp: undefined })))?.sub, "user_123"); // native token, no azp
assert.equal(await clerk(await sign({ ...session, azp: "https://evil.example" })), null); // wrong azp
assert.equal(await clerk(await sign(session), []), null); // azp present but nothing authorized
assert.equal(await clerk(await sign({ ...session, exp: now - 1 })), null); // expired
assert.equal(await clerk(await sign({ ...session, nbf: now + 600 })), null); // not yet valid
assert.equal(await clerk(await sign({ ...session, iss: "https://other.clerk.accounts.dev" })), null); // another instance
assert.equal(await clerk(await sign({ ...session, iss: undefined })), null); // iss required
assert.equal(await clerk(await sign({ ...session, sub: undefined })), null); // no user
assert.equal(await clerk(await sign(session, { key: other.privateKey })), null); // wrong signer
assert.equal(await clerk(await sign(session, { alg: "HS256" })), null);
assert.equal(await clerk(await sign(good)), null); // an Access token is not a Clerk token
assert.equal(await clerk(null), null);
console.log("auth ok");
