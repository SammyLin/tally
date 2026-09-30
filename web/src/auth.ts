// Cloudflare Access JWT verification (RS256, WebCrypto). No imports so node can run test/auth.test.ts directly.

type Jwk = JsonWebKey & { kid?: string };
type Claims = { aud?: string | string[]; exp?: number; nbf?: number; iss?: string; email?: string; common_name?: string };

const CERT_TTL_MS = 3600_000;
let certs: { team: string; at: number; keys: Jwk[] } | null = null;

async function jwks(team: string, force: boolean): Promise<Jwk[]> {
  if (!force && certs?.team === team && Date.now() - certs.at < CERT_TTL_MS) return certs.keys;
  const res = await fetch(`https://${team}.cloudflareaccess.com/cdn-cgi/access/certs`);
  if (!res.ok) throw new Error(`access certs: HTTP ${res.status}`);
  const { keys } = (await res.json()) as { keys: Jwk[] };
  certs = { team, at: Date.now(), keys };
  return keys;
}

function b64url(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** Returns the token's claims, or null when it is missing, malformed, badly signed, expired or for another audience. */
export async function verifyAccessJwt(token: string | null, team: string, aud: string, now = Date.now() / 1000): Promise<Claims | null> {
  const parts = token?.split(".");
  if (!parts || parts.length !== 3) return null;
  try {
    const header = JSON.parse(new TextDecoder().decode(b64url(parts[0]))) as { alg?: string; kid?: string };
    const claims = JSON.parse(new TextDecoder().decode(b64url(parts[1]))) as Claims;
    if (header.alg !== "RS256") return null;
    let jwk = (await jwks(team, false)).find((k) => k.kid === header.kid);
    jwk ??= (await jwks(team, true)).find((k) => k.kid === header.kid); // key rotation
    if (!jwk) return null;
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    if (!ok) return null;
    const auds = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!auds.includes(aud)) return null;
    if (typeof claims.exp !== "number" || claims.exp <= now) return null;
    if (typeof claims.nbf === "number" && claims.nbf > now + 60) return null;
    if (claims.iss !== undefined && claims.iss !== `https://${team}.cloudflareaccess.com`) return null;
    return claims;
  } catch {
    return null;
  }
}
