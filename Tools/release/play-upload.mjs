#!/usr/bin/env node
// Uploads an Android App Bundle to a Google Play track with the Play Developer
// API, using only Node's standard library.
//
//   PLAY_SERVICE_ACCOUNT='<service account JSON>' \
//   node Tools/release/play-upload.mjs app-release.aab [package] [track]
//
// The service account needs "Release to testing tracks" on the app in Play
// Console › Users and permissions. The package defaults to sh.ian.lively and
// the track to internal. PLAY_RELEASE_STATUS (default "completed") must be
// "draft" until the app's first release has been reviewed.
import { createSign } from "node:crypto";
import { readFile } from "node:fs/promises";

const [bundlePath, packageName = "sh.ian.lively", track = "internal"] = process.argv.slice(2);
const status = process.env.PLAY_RELEASE_STATUS || "completed";
if (!bundlePath || !process.env.PLAY_SERVICE_ACCOUNT) {
  console.error("Usage: PLAY_SERVICE_ACCOUNT='<json>' play-upload.mjs <bundle.aab> [package] [track]");
  process.exit(2);
}
const account = JSON.parse(process.env.PLAY_SERVICE_ACCOUNT);
const API = "https://androidpublisher.googleapis.com";

const base64url = (value) => Buffer.from(value).toString("base64url");

async function accessToken() {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 600,
  };
  const unsigned = `${base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${base64url(JSON.stringify(claims))}`;
  const signature = createSign("RSA-SHA256").update(unsigned).sign(account.private_key).toString("base64url");
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${unsigned}.${signature}` }),
  });
  if (!response.ok) throw new Error(`Google sign-in failed: HTTP ${response.status} ${await response.text()}`);
  return (await response.json()).access_token;
}

const token = await accessToken();

async function call(method, path, body, contentType = "application/json") {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": contentType } : {}) },
    body: body && contentType === "application/json" ? JSON.stringify(body) : body,
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status} ${text}`);
  return text ? JSON.parse(text) : {};
}

// One edit holds the upload and the track change, and is committed as a whole.
const app = `/androidpublisher/v3/applications/${encodeURIComponent(packageName)}`;
const edit = await call("POST", `${app}/edits`);
const bundle = await call(
  "POST",
  `/upload${app}/edits/${edit.id}/bundles?uploadType=media`,
  await readFile(bundlePath),
  "application/octet-stream",
);
await call("PUT", `${app}/edits/${edit.id}/tracks/${encodeURIComponent(track)}`, {
  track,
  releases: [{ versionCodes: [String(bundle.versionCode)], status }],
});
await call("POST", `${app}/edits/${edit.id}:commit`);
console.log(`Uploaded version code ${bundle.versionCode} of ${packageName} to the ${track} track (${status}).`);
