#!/usr/bin/env node
// Gives an uploaded TestFlight build to an external tester group, using the
// App Store Connect API and only Node's standard library.
//
//   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8="$(cat AuthKey_….p8)" \
//   node Tools/release/testflight-distribute.mjs <build number> [bundle id]
//
// It waits for Apple to finish processing the build, sets its "What to Test"
// text (TESTFLIGHT_NOTES), adds it to the group and submits it for beta
// review, which external groups need. TESTFLIGHT_GROUP names the group; without
// it, the app's only group with a public link is used.
import { createSign } from "node:crypto";

const [buildNumber, bundleID = "hk.cautela.lively"] = process.argv.slice(2);
const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 } = process.env;
if (!buildNumber || !ASC_KEY_ID || !ASC_ISSUER_ID || !ASC_KEY_P8) {
  console.error("Usage: ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8=… testflight-distribute.mjs <build number> [bundle id]");
  process.exit(2);
}
const groupName = process.env.TESTFLIGHT_GROUP || "";
const notes = (process.env.TESTFLIGHT_NOTES || "Latest changes.").slice(0, 4000);
const WAIT_MINUTES = Number(process.env.TESTFLIGHT_WAIT_MINUTES || 40);
const API = "https://api.appstoreconnect.apple.com";

const base64url = (value) => Buffer.from(value).toString("base64url");

/** Tokens last 20 minutes at most, so each request signs a fresh one. */
function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: ASC_KEY_ID, typ: "JWT" };
  const claims = { iss: ASC_ISSUER_ID, iat: now, exp: now + 600, aud: "appstoreconnect-v1" };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
  const signature = createSign("SHA256").update(unsigned).sign({ key: ASC_KEY_P8, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${unsigned}.${signature}`;
}

async function call(method, path, body, accept = []) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok && !accept.includes(response.status)) {
    throw new Error(`${method} ${path}: HTTP ${response.status} ${text}`);
  }
  return { status: response.status, body: text ? JSON.parse(text) : {} };
}

const sleep = (seconds) => new Promise((resolve) => setTimeout(resolve, seconds * 1000));

const apps = await call("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleID)}`);
const app = apps.body.data.find((entry) => entry.attributes.bundleId === bundleID);
if (!app) throw new Error(`No App Store Connect app has the bundle ID ${bundleID}.`);

const groups = (await call("GET", `/v1/betaGroups?filter[app]=${app.id}&limit=200`)).body.data;
const candidates = groupName
  ? groups.filter((group) => group.attributes.name === groupName)
  : groups.filter((group) => !group.attributes.isInternalGroup && group.attributes.publicLinkEnabled);
if (candidates.length !== 1) {
  const names = groups.map((group) => `"${group.attributes.name}"`).join(", ") || "none";
  throw new Error(
    groupName
      ? `Expected one TestFlight group named "${groupName}"; the app's groups are ${names}.`
      : `Expected one group with a public link but found ${candidates.length}; set TESTFLIGHT_GROUP to one of ${names}.`,
  );
}
const group = candidates[0];

// The build appears a little after the upload, then takes a while to process.
const deadline = Date.now() + WAIT_MINUTES * 60_000;
let build;
for (;;) {
  const found = await call("GET", `/v1/builds?filter[app]=${app.id}&filter[version]=${encodeURIComponent(buildNumber)}&limit=1`);
  build = found.body.data[0];
  const state = build?.attributes.processingState ?? "not listed yet";
  if (state === "VALID") break;
  if (state === "FAILED" || state === "INVALID") throw new Error(`Apple rejected build ${buildNumber} while processing it (${state}).`);
  if (Date.now() > deadline) throw new Error(`Build ${buildNumber} was still ${state} after ${WAIT_MINUTES} minutes.`);
  console.log(`Build ${buildNumber}: ${state}. Waiting…`);
  await sleep(30);
}

// External testers must be told what to test.
const localizations = (await call("GET", `/v1/builds/${build.id}/betaBuildLocalizations`)).body.data;
if (localizations.length) {
  for (const localization of localizations) {
    await call("PATCH", `/v1/betaBuildLocalizations/${localization.id}`, {
      data: { type: "betaBuildLocalizations", id: localization.id, attributes: { whatsNew: notes } },
    });
  }
} else {
  await call("POST", "/v1/betaBuildLocalizations", {
    data: {
      type: "betaBuildLocalizations",
      attributes: { locale: "en-US", whatsNew: notes },
      relationships: { build: { data: { type: "builds", id: build.id } } },
    },
  });
}

await call("POST", `/v1/betaGroups/${group.id}/relationships/builds`, { data: [{ type: "builds", id: build.id }] });

// A build of an already approved version is usually approved at once. 409 and
// 422 mean it has been submitted or approved already.
const review = await call(
  "POST",
  "/v1/betaAppReviewSubmissions",
  { data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: build.id } } } } },
  [409, 422],
);
const outcome = review.status === 201
  ? `submitted for beta review (${review.body.data.attributes.betaReviewState})`
  : `beta review not needed or already requested: ${review.body.errors?.[0]?.detail ?? `HTTP ${review.status}`}`;
console.log(`Build ${buildNumber} added to "${group.attributes.name}"; ${outcome}.`);
