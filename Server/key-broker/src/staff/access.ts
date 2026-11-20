export interface StaffPolicy {
  STAFF_ACCESS_AUD?: string;
  STAFF_IDP_ID?: string;
  /** JSON object mapping lowercase SHA-256 leaf fingerprints to Access user UUIDs. */
  STAFF_CERT_OWNERS?: string;
  STAFF_SUPPORT_IDS?: string;
  STAFF_ANALYST_IDS?: string;
}

function includes(ids: string | undefined, id: string) {
  return ids?.split(",").some(item => item.trim() === id) ?? false;
}

// The browser supplies neither of these objects. Cloudflare authenticates the
// Access principal and the TLS connection separately. A permissive edge rule
// cannot register a client certificate, assign its owner, or grant a role.
export async function authorizeStaff(request: Request, policy: StaffPolicy, ctx: ExecutionContext) {
  if (!policy.STAFF_ACCESS_AUD || ctx.access?.aud !== policy.STAFF_ACCESS_AUD) return null;
  const tls = (request.cf as IncomingRequestCfProperties | undefined)?.tlsClientAuth;
  if (!tls || tls.certPresented !== "1" || tls.certVerified !== "SUCCESS" || tls.certRevoked !== "0") return null;
  const fingerprint = tls.certFingerprintSHA256?.toLowerCase();
  if (!fingerprint || !/^[0-9a-f]{64}$/.test(fingerprint) || !policy.STAFF_CERT_OWNERS || !policy.STAFF_IDP_ID) return null;
  let owners: unknown;
  try {
    owners = JSON.parse(policy.STAFF_CERT_OWNERS);
  } catch {
    return null;
  }
  if (!owners || typeof owners !== "object" || Array.isArray(owners) || !Object.hasOwn(owners, fingerprint)) return null;
  const owner = (owners as Record<string, unknown>)[fingerprint];
  if (typeof owner !== "string" || !owner) return null;

  const identity = await ctx.access.getIdentity();
  if (!identity?.email || identity.user_uuid !== owner || identity.idp?.id !== policy.STAFF_IDP_ID) return null;
  // Enforce the staff application's minimum sign-in strength and maximum
  // identity age even if somebody relaxes the Cloudflare Access policy.
  if (!Array.isArray(identity.amr) || !identity.amr.some(method => method === "hwk" || method === "swk")) return null;
  const now = Math.floor(Date.now() / 1000);
  if (typeof identity.iat !== "number" || !Number.isSafeInteger(identity.iat) || identity.iat > now || now - identity.iat >= 4 * 3600) return null;
  const access = { support: includes(policy.STAFF_SUPPORT_IDS, owner), analyst: includes(policy.STAFF_ANALYST_IDS, owner) };
  return access.support || access.analyst ? { operator: owner, access } : null;
}
