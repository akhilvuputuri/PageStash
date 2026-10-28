import { PGlite } from "@electric-sql/pglite";
import pg from "pg";

export interface Database {
  query<T = Record<string, unknown>>(
    sql: string,
    values?: unknown[],
  ): Promise<{ rows: T[] }>;
  close(): Promise<void>;
}

export async function openDatabase(
  url?: string,
  localPath?: string,
): Promise<Database> {
  if (url) {
    const pool = new pg.Pool({ connectionString: url });
    return {
      query: async <T>(sql: string, values?: unknown[]) => ({
        rows: (await pool.query(sql, values)).rows as T[],
      }),
      close: () => pool.end(),
    };
  }
  const db = new PGlite(localPath);
  await db.waitReady;
  return {
    query: <T>(sql: string, values?: unknown[]) => db.query<T>(sql, values),
    close: () => db.close(),
  };
}

export const schema = `
CREATE TABLE IF NOT EXISTS schema_version (version integer PRIMARY KEY);
CREATE SEQUENCE IF NOT EXISTS library_revision;
CREATE TABLE IF NOT EXISTS accounts (
 id uuid PRIMARY KEY, email text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS credentials (
 id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 connection_id uuid NOT NULL, hash text UNIQUE NOT NULL, kind text NOT NULL,
 label text NOT NULL, expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS items (
 id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 connection_id uuid NOT NULL, idempotency_key text NOT NULL, normalized_url text,
 kind text NOT NULL, status text NOT NULL DEFAULT 'queued', title text NOT NULL,
 author text, source_url text, sources jsonb NOT NULL DEFAULT '[]',
 captured_at timestamptz NOT NULL DEFAULT now(), error text,
 content_version integer NOT NULL DEFAULT 0, archived boolean NOT NULL DEFAULT false,
 collections jsonb NOT NULL DEFAULT '[]', progress double precision NOT NULL DEFAULT 0,
 deleted boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT nextval('library_revision'),
 UNIQUE(owner_id, idempotency_key)
);
CREATE TABLE IF NOT EXISTS save_requests (
 owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 idempotency_key text NOT NULL, submission_id uuid NOT NULL REFERENCES items(id) ON DELETE CASCADE,
 PRIMARY KEY(owner_id,idempotency_key)
);
INSERT INTO save_requests(owner_id,idempotency_key,submission_id)
 SELECT owner_id,idempotency_key,id FROM items ON CONFLICT DO NOTHING;
CREATE UNIQUE INDEX IF NOT EXISTS unique_saved_url ON items(owner_id, normalized_url)
 WHERE normalized_url IS NOT NULL AND deleted=false;
CREATE INDEX IF NOT EXISTS sync_owner ON items(owner_id, revision);
CREATE TABLE IF NOT EXISTS jobs (
 id uuid PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, payload jsonb NOT NULL,
 attempts integer NOT NULL DEFAULT 0, available_at timestamptz NOT NULL DEFAULT now(),
 lease_until timestamptz, lease_token uuid
);
CREATE TABLE IF NOT EXISTS assets (
 id uuid PRIMARY KEY, item_id uuid NOT NULL REFERENCES items(id) ON DELETE CASCADE,
 role text NOT NULL, mime text NOT NULL, size integer NOT NULL, sha256 text NOT NULL,
 filename text NOT NULL, storage_key text NOT NULL
);
CREATE TABLE IF NOT EXISTS download_grants (
 hash text PRIMARY KEY, asset_id uuid NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
 credential_id uuid NOT NULL REFERENCES credentials(id) ON DELETE CASCADE,
 expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS oauth_clients (
 id text PRIMARY KEY, name text NOT NULL, redirect_uris jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS oauth_codes (
 hash text PRIMARY KEY, owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 client_id text NOT NULL REFERENCES oauth_clients(id), redirect_uri text NOT NULL,
 challenge text NOT NULL, expires_at timestamptz NOT NULL
);
-- Additive: the publisher's site name for quiet Library metadata.
ALTER TABLE items ADD COLUMN IF NOT EXISTS site_name text;
-- Additive: when an item was moved to Trash, or null when it is not in Trash.
ALTER TABLE items ADD COLUMN IF NOT EXISTS trashed_at timestamptz;
INSERT INTO schema_version(version) VALUES(1) ON CONFLICT DO NOTHING;
-- Additive: per-connection opt-in grants beyond save/status. The owner turns
-- "interests" on in the app. It is keyed by connection so OAuth token refresh
-- keeps the same choice.
CREATE TABLE IF NOT EXISTS connection_grants (
 owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 connection_id uuid NOT NULL, interests boolean NOT NULL DEFAULT false,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(owner_id, connection_id)
);
CREATE INDEX IF NOT EXISTS saved_articles_owner ON items(owner_id, captured_at DESC, id DESC)
 WHERE kind='article' AND deleted=false;
INSERT INTO schema_version(version) VALUES(2) ON CONFLICT DO NOTHING;
-- Additive: paid features granted beyond the owner, for example a future premium tier.
CREATE TABLE IF NOT EXISTS account_entitlements (
 owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 feature text NOT NULL, granted_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(owner_id, feature)
);
-- Additive: the latest AI reading context per item, and the finished-article set it was built from.
CREATE TABLE IF NOT EXISTS reading_contexts (
 owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 item_id uuid NOT NULL REFERENCES items(id) ON DELETE CASCADE,
 content_version integer NOT NULL, history_digest text NOT NULL, history_count integer NOT NULL,
 model text NOT NULL, result jsonb NOT NULL, generated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(owner_id, item_id)
);
-- Additive: short opening text of finished articles, cached so a request reads few stored files.
CREATE TABLE IF NOT EXISTS item_excerpts (
 item_id uuid PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
 content_version integer NOT NULL, excerpt text NOT NULL
);
-- Additive: new reading-context generations per account and UTC day.
CREATE TABLE IF NOT EXISTS context_usage (
 owner_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 day date NOT NULL, count integer NOT NULL DEFAULT 0,
 PRIMARY KEY(owner_id, day)
);
INSERT INTO schema_version(version) VALUES(3) ON CONFLICT DO NOTHING;
`;

export async function migrate(db: Database) {
  // Execute individually for compatibility with parameterized PostgreSQL drivers.
  for (const statement of schema.split(";").filter((s) => s.trim()))
    await db.query(statement);
  // Supabase's public data APIs get no policies. Only the backend database role accesses these tables.
  for (const name of [
    "accounts",
    "credentials",
    "items",
    "save_requests",
    "jobs",
    "assets",
    "download_grants",
    "oauth_clients",
    "oauth_codes",
    "connection_grants",
    "account_entitlements",
    "reading_contexts",
    "item_excerpts",
    "context_usage",
    "schema_version",
  ])
    await db.query(`ALTER TABLE ${name} ENABLE ROW LEVEL SECURITY`);
}
