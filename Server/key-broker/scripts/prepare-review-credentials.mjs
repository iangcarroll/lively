import { writeFileSync, rmSync } from "node:fs";

// Run before any production mutation. Never include credentials in errors or
// stdout; Wrangler receives the normalized pair from a private temporary file.
const output = process.argv[2];
if (!output) throw new Error("A private output file is required.");
const email = (process.env.APP_REVIEW_EMAIL ?? "").trim().toLowerCase();
const hash = (process.env.APP_REVIEW_CODE_HASH ?? "").trim();
rmSync(output, { force: true });
if (email || hash) {
  if (!email || !hash) throw new Error("Both reviewer secrets must be configured together.");
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("The reviewer email is invalid.");
  }
  if (!/^[a-f0-9]{32}$/.test(hash)) throw new Error("The reviewer code hash is invalid.");
  writeFileSync(output, JSON.stringify({ APP_REVIEW_EMAIL: email, APP_REVIEW_CODE_HASH: hash }), { mode: 0o600 });
}
