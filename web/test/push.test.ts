// node test/push.test.ts — aes128gcm against RFC 8291 Appendix A; VAPID JWT verifies with the public key.
import assert from "node:assert/strict";
import { b64u, encrypt, importPrivate, vapidAuth } from "../src/push.ts";

// RFC 8291 Appendix A
const asPublic = b64u.dec("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8");
const as = { privateKey: await importPrivate("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw", asPublic, "ECDH"), publicRaw: asPublic };
const sub = { p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4", auth: "BTBZMqHH6r4Tts7J_aSIgg" };
const body = await encrypt(sub, new TextEncoder().encode("When I grow up, I want to be a watermelon"), b64u.dec("DGv6ra1nlYgDCS1FRnbzlw"), as);
assert.equal(b64u.enc(body), "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN");

// random salt + sender keys: same layout, different bytes each time
const a = await encrypt(sub, new Uint8Array(5)), b = await encrypt(sub, new Uint8Array(5));
assert.equal(a.length, 16 + 4 + 1 + 65 + 5 + 1 + 16);
assert.notEqual(b64u.enc(a), b64u.enc(b));

// VAPID: a fresh keypair in the env formats (public = raw point, private = d)
const kp = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
const pub = b64u.enc(await crypto.subtle.exportKey("raw", kp.publicKey));
const env = { VAPID_PUBLIC_KEY: pub, VAPID_PRIVATE_KEY: (await crypto.subtle.exportKey("jwk", kp.privateKey)).d!, VAPID_SUBJECT: "mailto:me@example.com" };
const now = Date.now();
const auth = await vapidAuth("https://fcm.googleapis.com/fcm/send/abc", env, now);
const m = /^vapid t=([^.]+)\.([^.]+)\.([^.]+), k=(.+)$/.exec(auth);
assert.ok(m, auth);
assert.equal(m[4], pub);
const verifyKey = await crypto.subtle.importKey("raw", b64u.dec(m[4]), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, verifyKey, b64u.dec(m[3]), new TextEncoder().encode(`${m[1]}.${m[2]}`)));
const json = (s: string) => JSON.parse(new TextDecoder().decode(b64u.dec(s)));
assert.deepEqual(json(m[1]), { typ: "JWT", alg: "ES256" });
assert.deepEqual(json(m[2]), { aud: "https://fcm.googleapis.com", exp: Math.floor(now / 1000) + 12 * 3600, sub: "mailto:me@example.com" });
console.log("push ok");
