import type { Account, Observation, Overview } from "./reports";

export type Section = "overview" | "users" | "subscriptions";
export interface Access { analyst: boolean; support: boolean }

function escape(value: string | number) {
  return String(value).replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!);
}

const number = (value: number) => value.toLocaleString("en-US");
const date = (ms: number, year = true) => new Intl.DateTimeFormat("en-US", {
  timeZone: "UTC", month: "short", day: "numeric", ...(year ? { year: "numeric" } : {}),
}).format(ms);
const storeName = (store: Observation["store"]) => store === "apple" ? "App Store" : "Google Play";
const labels: Record<Section, string> = { overview: "Overview", users: "Users", subscriptions: "Subscriptions" };

function page(section: Section, access: Access, content: string) {
  const links = (Object.keys(labels) as Section[]).filter(k => k === "overview" ? access.analyst : access.support)
    .map(k => `<a href="/${k}"${section === k ? ' aria-current="page"' : ""}>${labels[k]}</a>`).join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${labels[section]} · Lively staff</title><link rel="stylesheet" href="/console.css"></head>
<body><header><div class="top"><a class="brand" href="/" aria-label="Lively staff home"><span class="mark" aria-hidden="true"><b>A</b><i>文</i></span>Lively</a>
<span class="division">Staff console</span><a class="logout" href="/cdn-cgi/access/logout">Sign out</a></div>
<nav aria-label="Staff console">${links}</nav></header><main><h1>${labels[section]}</h1>${content}</main></body></html>`;
}

function metric(label: string, value: number, caption: string) {
  return `<div><span class="metric-label">${label}</span><strong>${number(value)}</strong><small>${caption}</small></div>`;
}

function chart(days: Overview["days"]) {
  const max = Math.max(1, ...days.map(d => d.count));
  const bars = days.map((d, i) => {
    const height = 98 * d.count / max;
    const x = 14 + i * 51;
    const label = date(Date.parse(d.day), false);
    return `<g><title>${label} · ${number(d.count)} registrations</title>
      <rect x="${x}" y="${123 - height}" width="30" height="${height}" rx="4"></rect>
      <text class="value" x="${x + 15}" y="${115 - height}">${number(d.count)}</text>
      <text class="day" x="${x + 15}" y="146">${Number(d.day.slice(-2))}</text></g>`;
  }).join("");
  return `<svg role="img" aria-label="Registrations by UTC day. ${days.map(d => `${d.day}, ${d.count}`).join(". ")}" viewBox="0 0 720 154">
    <path d="M4 25H716 M4 74H716 M4 123H716" class="grid"/>${bars}</svg>`;
}

export function overviewPage(access: Access, data: Overview) {
  const total = data.stores.reduce((n, s) => n + s.count, 0);
  const recent = data.days.reduce((n, d) => n + d.count, 0);
  const stores = (["apple", "play"] as const).map(store => `<div class="entry"><span>${storeName(store)}</span>
    <b>${number(data.stores.find(s => s.store === store)?.count ?? 0)}</b></div>`).join("");
  const ads = data.ads.length ? `<table><thead><tr><th>Keyword</th><th class="num">Attributed installs</th>
    <th class="num">Paid subscriptions</th></tr></thead><tbody>${data.ads.map(a => `<tr><td>${escape(a.keyword)}</td>
    <td class="num">${number(a.installs)}</td><td class="num">${number(a.paid)}</td></tr>`).join("")}</tbody></table>`
    : '<p class="empty">No attributed installs in this period.</p>';
  return page("overview", access, `<p class="intro">Account growth and store activity <span>·</span> ${date(data.now)} UTC</p>
    <section class="metrics" aria-label="Summary">
    ${metric("Registered users", data.accounts, "Current Lively accounts")}
    ${metric("Recorded subscriptions", total, "Production store records on file")}
    ${metric("Complimentary Pro", data.grants, "Accounts with a Pro grant")}</section>
    <div class="split"><section class="panel"><div class="heading"><h2>Account registrations</h2><span>14 days</span></div>
    <div class="chart-total"><strong>${number(recent)}</strong> registrations</div>${chart(data.days)}
    <small>${date(Date.parse(data.days[0].day), false)} – ${date(data.now, false)} UTC · Current accounts by creation date</small></section>
    <section class="panel"><h2>Subscriptions by store</h2><p class="sub">Latest production record per subscription.</p>
    <div class="stores">${stores}</div><small>Includes ended subscriptions on file.</small></section></div>
    <section class="panel"><h2>Apple Ads keywords</h2><p class="sub">Top five by attributed installs in the last 14 UTC days, with subsequent first payments.</p>${ads}</section>`);
}

function lookup(action: string, label: string, placeholder: string, hint: string) {
  return `<section class="panel search"><form method="post" action="/${action}" autocomplete="off"><label for="q">${label}</label>
    <div class="field"><input id="q" name="q" placeholder="${placeholder}" required maxlength="254" spellcheck="false" autocapitalize="none" aria-describedby="hint"><button>Look up</button></div>
    <small id="hint">${hint}</small></form></section>`;
}
function row(label: string, value: string) {
  return `<div class="entry"><dt>${label}</dt><dd>${escape(value)}</dd></div>`;
}

export function accountPage(access: Access, account?: Account | null) {
  const form = lookup("users", "Email address or user ID", "name@example.com", "Use the exact email or Lively user ID from the support request.");
  let result = "";
  if (account === null) result = '<section class="panel"><h2>No matching user</h2><p class="sub">Check the email or user ID and try again.</p></section>';
  if (account) {
    const methods = ["Email code", ...(account.apple ? ["Apple"] : []), ...(account.google ? ["Google"] : [])];
    result = `<section class="panel detail"><h2>${escape(account.email)}</h2><dl>
      ${row("User ID", account.id)}${row("Created", date(account.created_at * 1000) + " UTC")}
      ${row("Sign-in methods", methods.join(", "))}${row("Unexpired sessions", number(account.sessions))}
      ${row("Complimentary Pro", account.free_pro ? "Granted" : "No grant")}
      ${account.apple_email_disabled ? row("Apple email forwarding", "Disabled") : ""}</dl>
      <small>Store purchases are separate. Look up a store reference under Subscriptions.</small></section>`;
  }
  return page("users", access, `<p class="intro">Find an account for a customer support request.</p>${form}${result}`);
}

function productName(product: string | null) {
  if (!product) return "Lively Pro";
  if (product.endsWith(".pro.monthly")) return "Pro monthly";
  if (product.endsWith(".pro.yearly")) return "Pro yearly";
  return product;
}
function observations(records: Observation[]) {
  return `<div class="scroll"><table><thead><tr><th>Store</th><th>Plan</th><th>Last store update</th><th>Period end</th><th>Record date <small>UTC</small></th></tr></thead>
    <tbody>${records.map(r => `<tr><td>${storeName(r.store)}</td><td>${escape(productName(r.product))}</td><td>${escape(r.event)}</td>
    <td>${r.period_end_ms == null ? "Unavailable" : date(r.period_end_ms)}</td><td>${date(r.observed_ms)}</td></tr>`).join("")}</tbody></table></div>`;
}

export function subscriptionsPage(access: Access, recent: Observation[], match?: Observation | null) {
  const search = lookup("subscriptions", "Store reference", "Original transaction ID or GPA order ID",
    "Use the App Store original transaction ID or the latest recorded Google Play order ID.");
  const heading = match === undefined ? "Recent store records" : match ? "Matching subscription" : "No matching subscription";
  const body = match === null ? '<p class="sub">Check the reference. This console only includes production records received by Lively.</p>'
    : match ? observations([match]) : recent.length ? observations(recent)
    : '<p class="empty">No production store records received yet.</p>';
  return page("subscriptions", access, `<p class="intro">Review the latest store information Lively has received for a purchase.</p>${search}
    <section class="panel"><h2>${heading}</h2>${match === undefined ? '<p class="sub">Up to 20 recent production records from the App Store and Google Play, one per subscription.</p>' : ""}
    ${body}${match !== undefined ? '<a class="back" href="/subscriptions">View recent store records</a>' : ""}</section>`);
}
