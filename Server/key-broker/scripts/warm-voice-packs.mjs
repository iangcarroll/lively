// Requests every pinned voice file once, so the broker copies it into R2
// before a user's download has to wait for that. Usage:
//   node scripts/warm-voice-packs.mjs [https://lively.cautela.hk]
const origin = (process.argv[2] ?? "https://lively.cautela.hk").replace(/\/$/, "");
// Cloudflare's bot check turns away Node's default user agent.
const headers = { "User-Agent": "lively-voice-warm/1.0" };

const response = await fetch(`${origin}/v1/voices/manifest`, { headers });
if (!response.ok) throw new Error(`manifest: HTTP ${response.status}`);
const manifest = await response.json();

let failed = 0;
for (const file of manifest.files) {
  const path = file.path.split("/").map(encodeURIComponent).join("/");
  const result = await fetch(`${origin}/v1/voices/files/${manifest.revision}/${path}`, { headers });
  const bytes = result.ok ? (await result.arrayBuffer()).byteLength : 0;
  const ok = result.ok && bytes === file.size;
  if (!ok) failed += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${file.path} (${result.status}, ${bytes} of ${file.size} bytes)`);
}
if (failed) {
  console.error(`${failed} of ${manifest.files.length} files failed.`);
  process.exit(1);
}
console.log(`All ${manifest.files.length} files of ${manifest.revision} are stored.`);
