import { WorkerEntrypoint } from "cloudflare:workers";
import type { Env } from "../broker";
import { referenceHash, type Store } from "./observations";

export interface Observation {
  store: Store;
  product: string | null;
  event: string;
  observed_ms: number;
  period_end_ms: number | null;
}

export interface Account {
  id: string;
  email: string;
  created_at: number;
  free_pro: number;
  apple: number;
  google: number;
  apple_email_disabled: number;
  sessions: number;
}

export interface Overview {
  accounts: number;
  grants: number;
  stores: { store: Store; count: number }[];
  days: { day: string; count: number }[];
  ads: { keyword: string; installs: number; paid: number }[];
  now: number;
}

const fields = "store, product, event, observed_ms, period_end_ms";

// Only this named service binding can read these projections. The staff web
// Worker has neither a SQL binding nor any of the broker's provider secrets.
export class StaffReports extends WorkerEntrypoint<Env> {
  async overview(): Promise<Overview> {
    const now = Date.now();
    const dayMs = 86_400_000;
    const today = Math.floor(now / dayMs) * dayMs;
    const start = today - 13 * dayMs;
    const db = this.env.DB;
    const [accounts, stores, daily, ads] = await db.batch<Record<string, unknown>>([
      db.prepare("SELECT count(*) AS accounts, count(CASE WHEN free_pro = 1 THEN 1 END) AS grants FROM users"),
      db.prepare("SELECT store, count(*) AS count FROM subscription_observations GROUP BY store"),
      db.prepare(`SELECT date(created_at, 'unixepoch') AS day, count(*) AS count FROM users
        WHERE created_at BETWEEN ? AND ? GROUP BY day`).bind(start / 1000, Math.floor(now / 1000)),
      db.prepare(`SELECT coalesce(keyword, 'Unreported keyword') AS keyword, sum(installs) AS installs,
        sum(paid_subscriptions) AS paid FROM apple_ads_keyword_conversions
        WHERE install_cohort_utc >= ? AND install_cohort_utc <= ?
        GROUP BY coalesce(keyword, 'Unreported keyword') ORDER BY installs DESC, keyword LIMIT 5`)
        .bind(isoDay(start), isoDay(now)),
    ]);
    const counts = new Map(daily.results.map(row => [row.day, Number(row.count)]));
    const days = Array.from({ length: 14 }, (_, i) => {
      const day = isoDay(start + i * dayMs);
      return { day, count: counts.get(day) ?? 0 };
    });
    return {
      accounts: Number(accounts.results[0].accounts),
      grants: Number(accounts.results[0].grants),
      stores: stores.results.map(r => ({ store: r.store as Store, count: Number(r.count) })),
      ads: ads.results.map(r => ({ keyword: String(r.keyword), installs: Number(r.installs), paid: Number(r.paid) })),
      days,
      now,
    };
  }

  async account(query: string): Promise<Account | null> {
    const key = query.trim().toLowerCase();
    if (!key || key.length > 254) return null;
    return this.env.DB.prepare(`SELECT id, email, created_at, free_pro, apple_sub IS NOT NULL AS apple,
      google_sub IS NOT NULL AS google, apple_email_disabled,
      (SELECT count(*) FROM sessions WHERE user_id = users.id AND expires_at > unixepoch()) AS sessions
      FROM users WHERE id = ?1 OR email = ?1 LIMIT 1`).bind(key).first<Account>();
  }

  async recentSubscriptions(): Promise<Observation[]> {
    return (await this.env.DB.prepare(`SELECT ${fields} FROM subscription_observations
      ORDER BY observed_ms DESC, subscription_key LIMIT 20`).all<Observation>()).results;
  }

  async subscription(reference: string): Promise<Observation | null> {
    const value = reference.trim().toUpperCase();
    const store = /^\d{1,32}$/.test(value) ? "apple" : /^GPA\.[0-9-]+(?:\.\.\d+)?$/.test(value) ? "play" : null;
    if (!store || value.length > 64) return null;
    return this.env.DB.prepare(`SELECT ${fields} FROM subscription_observations WHERE lookup_hash = ?
      ORDER BY observed_ms DESC LIMIT 1`).bind(await referenceHash(store, value)).first<Observation>();
  }
}

function isoDay(time: number) {
  return new Date(time).toISOString().slice(0, 10);
}
