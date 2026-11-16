import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, statSync, existsSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./prepare-review-credentials.mjs", import.meta.url));
function prepare(t, email, hash) {
  const dir = mkdtempSync(join(tmpdir(), "lively-review-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const output = join(dir, "secrets.json");
  // A skipped or rejected configuration must not reuse a previous run's file.
  writeFileSync(output, "stale secret");
  const result = spawnSync(process.execPath, [script, output], {
    env: { ...process.env, APP_REVIEW_EMAIL: email, APP_REVIEW_CODE_HASH: hash }, encoding: "utf8",
  });
  assert.equal(result.stdout, "");
  return { ...result, output };
}

test("normalizes copied credentials and writes a private, round-trippable pair", t => {
  const email = `review-${randomBytes(12).toString("hex")}@example.com`;
  const hash = randomBytes(16).toString("hex");
  const result = prepare(t, ` ${email.toUpperCase()}\n`, `${hash}\n`);
  assert.equal(result.status, 0);
  assert.deepEqual(JSON.parse(readFileSync(result.output, "utf8")), { APP_REVIEW_EMAIL: email, APP_REVIEW_CODE_HASH: hash });
  assert.equal(statSync(result.output).mode & 0o777, 0o600);
});

test("no configuration removes stale input without creating a deployment file", t => {
  const result = prepare(t, " \n", "");
  assert.equal(result.status, 0);
  assert.equal(existsSync(result.output), false);
});

for (const kind of ["email only", "hash only", "invalid email", "invalid hash"]) {
  test(`rejects ${kind} before a deployment file can be consumed`, t => {
    const email = `review-${randomBytes(12).toString("hex")}@example.com`;
    const hash = randomBytes(16).toString("hex");
    const result = prepare(t, kind === "hash only" ? "" : kind === "invalid email" ? "bad address" : email,
      kind === "email only" ? "" : kind === "invalid hash" ? hash.slice(1) : hash);
    assert.notEqual(result.status, 0);
    assert.equal(existsSync(result.output), false);
    assert.ok(!result.stderr.includes(email));
    assert.ok(!result.stderr.includes(hash));
  });
}
