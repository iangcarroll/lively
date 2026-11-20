import { createRemoteJWKSet, jwtVerify } from "jose";

export interface StaffPolicy {
  STAFF_ACCESS_ISSUER?: string;
  STAFF_ACCESS_AUD?: string;
  STAFF_IDP_ID?: string;
  STAFF_SUPPORT_IDS?: string;
  STAFF_ANALYST_IDS?: string;
}

const maxAge = 4 * 3600;
const teamOrigin = /^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/;
let keys: { issuer: string; resolve: ReturnType<typeof createRemoteJWKSet> } | undefined;

function includes(ids: string | undefined, id: string) {
  return ids?.split(",").some(item => item.trim() === id) ?? false;
}

// Fetch keys only from the configured team. The resolver caches public keys
// and refreshes them for key rotation. Never use a URL supplied by the JWT.
function signingKeys(issuer: string) {
  if (keys?.issuer !== issuer) {
    keys = { issuer, resolve: createRemoteJWKSet(new URL("/cdn-cgi/access/certs", issuer)) };
  }
  return keys.resolve;
}

export async function authorizeStaff(request: Request, policy: StaffPolicy, ctx: ExecutionContext) {
  const issuer = policy.STAFF_ACCESS_ISSUER;
  const audience = policy.STAFF_ACCESS_AUD;
  if (!issuer || !teamOrigin.test(issuer) || !audience || ctx.access?.aud !== audience || !policy.STAFF_IDP_ID) return null;

  const assertion = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!assertion || assertion.length > 16384) return null;
  const verified = await jwtVerify(assertion, signingKeys(issuer), {
    issuer, audience, algorithms: ["RS256"], requiredClaims: ["sub", "email", "exp", "type"], maxTokenAge: maxAge,
  }).catch(() => null);
  const claims = verified?.payload;
  if (claims?.type !== "app" || typeof claims.sub !== "string" || !claims.sub ||
      typeof claims.email !== "string" || !claims.email) return null;

  const operator = claims.sub;
  const access = { support: includes(policy.STAFF_SUPPORT_IDS, operator), analyst: includes(policy.STAFF_ANALYST_IDS, operator) };
  if (!access.support && !access.analyst) return null;

  // Access application JWTs contain only part of the user's identity. Bind
  // the trusted runtime's IdP to the same verified subject.
  const identity = await ctx.access.getIdentity();
  if (identity?.user_uuid !== operator || identity.email !== claims.email || identity.idp?.id !== policy.STAFF_IDP_ID) return null;
  const now = Math.floor(Date.now() / 1000);
  if (typeof identity.iat !== "number" || !Number.isSafeInteger(identity.iat) ||
      identity.iat > now || now - identity.iat >= maxAge) return null;
  return { operator, access };
}
