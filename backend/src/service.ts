import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import type { Database } from "./db.js";
import { supabaseHeaders, type Config } from "./config.js";
import type { Storage } from "./storage.js";
import { normalizedURL } from "./fetch.js";
import { ImportFailure } from "./import-error.js";
import {
  extract,
  briefDocument,
  readerHTML,
  escapeHTML,
  type Prepared,
} from "./content.js";
import {
  ARTICLE_CHARACTERS,
  EXCERPT_CHARACTERS,
  EXCERPT_LIMIT,
  HISTORY_LIMIT,
  READING_CONTEXT,
  contextPrompt,
  documentText,
  parseContext,
  ContextProviderError,
  type ContextModel,
  type ContextResult,
  type HistoryEntry,
} from "./reading-context.js";

/** Import attempts before an article is kept as a bookmark that can be retried from Imports. */
const MAX_ATTEMPTS = 3;

export const hash = (value: string | Buffer) =>
  createHash("sha256").update(value).digest("hex");
export const secret = () => randomBytes(32).toString("base64url");
export class HTTPError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}
export interface Identity {
  id: string;
  owner_id: string;
  connection_id: string;
  kind: string;
}
export interface Asset {
  id: string;
  role: string;
  mime: string;
  size: number;
  sha256: string;
  filename: string;
  storage_key: string;
}
export interface Item {
  id: string;
  owner_id: string;
  connection_id: string;
  title: string;
  kind: string;
  status: string;
  error: string | null;
  source_url: string | null;
  author: string | null;
  site_name?: string | null;
  trashed_at?: Date | string | null;
  sources: string[];
  captured_at: Date;
  content_version: number;
  progress: number;
  collections: string[];
  archived: boolean;
  deleted: boolean;
  revision: string | number;
}

export interface ReadingContext extends ContextResult {
  item_id: string;
  content_version: number;
  generated_at: string;
  model: string;
  history_count: number;
  /** The finished-article set changed since this was generated. */
  stale: boolean;
}

type Owner = Pick<Identity, "owner_id">;
interface SavedContextRow {
  item_id: string;
  content_version: number;
  history_digest: string;
  history_count: number;
  model: string;
  result: ContextResult;
  generated_at: Date | string;
}
/** Background attempts per content version before an item waits for the owner to ask. */
const BACKGROUND_ATTEMPTS = 3;

export class Service {
  onQueued?: () => void;
  /** Called when an import publishes readable content, so background reading context can start. */
  onPrepared?: () => void;
  /**
   * Generations in progress, so a repeated tap waits for the same answer instead of paying twice.
   * In memory, like the background pause below: the service runs as a single replica.
   */
  private contextRuns = new Map<string, Promise<ReadingContext>>();
  private contextPausedUntil = 0;
  private contextPauseMs = 0;
  /** The item whose provider-wide failure started the current pause, until a success. */
  private contextWideFailure?: string;
  constructor(
    public db: Database,
    public config: Config,
    public files: Storage,
    private prepareArticle: (url: string) => Promise<Prepared> = extract,
    private contextModel?: ContextModel,
  ) {}
  async credential(
    owner: string,
    kind: string,
    label: string,
    connection: string = randomUUID(),
    days = 30,
  ) {
    const token = secret();
    const id = randomUUID();
    await this.db.query(
      "INSERT INTO credentials(id,owner_id,connection_id,hash,kind,label,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
      [
        id,
        owner,
        connection,
        hash(token),
        kind,
        label,
        new Date(Date.now() + days * 86400000),
      ],
    );
    return { token, id, connection_id: connection };
  }
  async authenticate(token: string | undefined): Promise<Identity> {
    if (!token) throw new HTTPError(401, "Authentication required.");
    const result = await this.db.query<Identity>(
      "SELECT id,owner_id,connection_id,kind FROM credentials WHERE hash=$1 AND expires_at>now()",
      [hash(token)],
    );
    if (!result.rows[0] || result.rows[0].kind === "refresh")
      throw new HTTPError(401, "Credential is invalid or expired.");
    return result.rows[0];
  }
  app(identity: Identity) {
    if (identity.kind !== "app")
      throw new HTTPError(403, "An app session is required.");
  }
  async login(email: string, password: string) {
    let owner: string;
    if (this.config.devAuth) {
      const actual = Buffer.from(hash(password));
      const expected = Buffer.from(hash(this.config.devPassword));
      if (
        email.toLowerCase() !== this.config.devEmail.toLowerCase() ||
        !timingSafeEqual(actual, expected)
      )
        throw new HTTPError(401, "Sign-in failed.");
      owner = "00000000-0000-4000-8000-000000000001";
    } else {
      const response = await fetch(
        `${this.config.supabaseURL}/auth/v1/token?grant_type=password`,
        {
          method: "POST",
          headers: {
            apikey: this.config.anonKey!,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ email, password }),
          signal: AbortSignal.timeout(15_000),
        },
      );
      if (!response.ok) throw new HTTPError(401, "Sign-in failed.");
      const result = (await response.json()) as {
        user: { id: string; email: string; email_confirmed_at?: string };
      };
      if (
        result.user.email.toLowerCase() !== this.config.ownerEmail ||
        !result.user.email_confirmed_at
      )
        throw new HTTPError(
          403,
          "This personal beta is restricted to its owner.",
        );
      owner = result.user.id;
    }
    await this.db.query(
      "INSERT INTO accounts(id,email) VALUES($1,$2) ON CONFLICT(id) DO UPDATE SET email=excluded.email",
      [owner, email.toLowerCase()],
    );
    return {
      ...(await this.credential(owner, "app", "iPhone session")),
      owner_id: owner,
    };
  }
  async save(
    identity: Identity,
    input: {
      url?: string;
      markdown?: string;
      title?: string;
      sources?: string[];
      idempotency_key: string;
    },
  ) {
    let url: string | null;
    try {
      url = input.url ? normalizedURL(input.url) : null;
    } catch {
      throw new HTTPError(
        400,
        "Use a public HTTP(S) article URL without credentials or nonstandard ports.",
      );
    }
    const existing = await this.savedRequest(
      identity,
      input.idempotency_key,
      url,
    );
    if (existing)
      return this.existingSave(identity, existing, input.idempotency_key, url);
    await this.checkCapacity(identity, true);
    const kind = url ? "article" : "brief";
    const id = randomUUID();
    // The item and its queue entry are one database statement, so a crash cannot lose the import.
    let inserted;
    try {
      inserted = await this.db.query<{ id: string }>(
        `WITH item AS (
   INSERT INTO items(id,owner_id,connection_id,idempotency_key,normalized_url,kind,title,source_url,sources)
   VALUES($1,$2,$3,$4,$5,$6,$7,$5,$8::jsonb) ON CONFLICT DO NOTHING RETURNING id)
   , receipt AS (INSERT INTO save_requests(owner_id,idempotency_key,submission_id) SELECT $2,$4,id FROM item)
   INSERT INTO jobs(id,payload) SELECT id,$9::jsonb FROM item RETURNING id`,
        [
          id,
          identity.owner_id,
          identity.connection_id,
          input.idempotency_key,
          url,
          kind,
          input.title ?? (url ? new URL(url).hostname : "Reading brief"),
          JSON.stringify(input.sources ?? []),
          JSON.stringify(input),
        ],
      );
    } catch (error) {
      if ((error as { code?: string }).code !== "23505") throw error;
      // A concurrent alias won; the whole insert statement rolled back.
      inserted = { rows: [] };
    }
    if (inserted.rows.length) {
      this.onQueued?.();
      return { submission_id: id, status: "queued", duplicate: false };
    }
    const winner = await this.savedRequest(
      identity,
      input.idempotency_key,
      url,
    );
    if (!winner)
      throw new HTTPError(
        409,
        "Submission conflicted; try a new request identifier.",
      );
    return this.existingSave(identity, winner, input.idempotency_key, url);
  }
  private async checkCapacity(identity: Identity, newItem: boolean) {
    const capacity = await this.db.query<{ queued: string; total: string }>(
      "SELECT count(*) FILTER(WHERE status IN('queued','processing')) AS queued,count(*) AS total FROM items WHERE owner_id=$1 AND deleted=false",
      [identity.owner_id],
    );
    if (
      Number(capacity.rows[0].queued) >= 50 ||
      (newItem && Number(capacity.rows[0].total) >= 1000)
    )
      throw new HTTPError(
        429,
        "Personal beta library or import queue limit reached.",
      );
  }
  private async savedRequest(
    identity: Identity,
    key: string,
    url: string | null,
  ) {
    const result = await this.db.query<{
      id: string;
      status: string;
      connection_id: string;
      normalized_url: string | null;
      matched_key: boolean;
    }>(
      `SELECT i.id,i.status,i.connection_id,i.normalized_url,(r.idempotency_key IS NOT NULL OR i.idempotency_key=$2) AS matched_key
       FROM items i LEFT JOIN save_requests r ON r.submission_id=i.id AND r.owner_id=$1 AND r.idempotency_key=$2
       WHERE i.owner_id=$1 AND (r.idempotency_key IS NOT NULL OR i.idempotency_key=$2 OR (i.normalized_url=$3 AND i.deleted=false))
       ORDER BY (r.idempotency_key IS NOT NULL OR i.idempotency_key=$2) DESC,i.captured_at LIMIT 1`,
      [identity.owner_id, key, url],
    );
    return result.rows[0];
  }
  private async existingSave(
    identity: Identity,
    row: NonNullable<Awaited<ReturnType<Service["savedRequest"]>>>,
    key: string,
    url: string | null,
  ): Promise<{
    submission_id: string | null;
    status: string;
    duplicate: boolean;
  }> {
    const visible =
      identity.kind === "app" || row.connection_id === identity.connection_id;
    if (!row.matched_key) {
      if (visible && row.status === "bookmark" && url === row.normalized_url)
        await this.checkCapacity(identity, false);
      const shouldRetry =
        visible && row.status === "bookmark" && url === row.normalized_url;
      const claimed = await this.db.query<{
        submission_id: string;
        requeued: boolean;
      }>(
        `WITH receipt AS (INSERT INTO save_requests(owner_id,idempotency_key,submission_id) VALUES($1,$2,$3)
         ON CONFLICT DO NOTHING RETURNING submission_id),
         candidate AS (UPDATE items SET status='queued',error=NULL,revision=nextval('library_revision')
          WHERE id=$3 AND owner_id=$1 AND $4 AND status='bookmark' AND deleted=false AND source_url IS NOT NULL
          AND NOT EXISTS(SELECT 1 FROM jobs WHERE id=$3) AND EXISTS(SELECT 1 FROM receipt) RETURNING id,source_url),
         job AS (INSERT INTO jobs(id,payload) SELECT id,jsonb_build_object('url',source_url) FROM candidate RETURNING id)
         SELECT submission_id,EXISTS(SELECT 1 FROM job) AS requeued FROM receipt`,
        [identity.owner_id, key, row.id, shouldRetry],
      );
      if (!claimed.rows.length) {
        const winner = await this.savedRequest(identity, key, url);
        if (!winner)
          throw new HTTPError(
            409,
            "Submission conflicted; try a new request identifier.",
          );
        return this.existingSave(identity, winner, key, url);
      }
      if (claimed.rows[0].requeued) this.onQueued?.();
      if (visible) {
        const current = await this.status(identity, row.id);
        row.status = String(current.status);
      }
    }
    // A new save of the same link brings it back from Trash. A retry of an earlier request (same
    // idempotency key) is a replay and changes nothing.
    if (visible && !row.matched_key && url !== null && url === row.normalized_url)
      await this.db.query(
        "UPDATE items SET trashed_at=NULL,activity_revision=NULL,revision=nextval('library_revision') WHERE id=$1 AND owner_id=$2 AND trashed_at IS NOT NULL AND deleted=false",
        [row.id, identity.owner_id],
      );
    // A limited connection never gains access to another connection's receipt.
    if (!visible)
      return { submission_id: null, status: "already_saved", duplicate: true };
    return { submission_id: row.id, status: row.status, duplicate: true };
  }
  async retry(identity: Identity, id: string) {
    const result = await this.db.query(
      `WITH candidate AS (UPDATE items SET status='queued',error=NULL,revision=nextval('library_revision')
       WHERE id=$1 AND owner_id=$2 AND ($3 OR connection_id=$4) AND status='bookmark' AND source_url IS NOT NULL AND deleted=false
       AND NOT EXISTS(SELECT 1 FROM jobs WHERE id=$1) RETURNING id,source_url)
       INSERT INTO jobs(id,payload) SELECT id,jsonb_build_object('url',source_url) FROM candidate RETURNING id`,
      [id, identity.owner_id, identity.kind === "app", identity.connection_id],
    );
    if (result.rows.length) this.onQueued?.();
    return result.rows.length > 0;
  }
  async status(identity: Identity, id: string) {
    const result = await this.db.query(
      "SELECT id,status,error FROM items WHERE id=$1 AND owner_id=$2 AND deleted=false AND ($3 OR connection_id=$4)",
      [id, identity.owner_id, identity.kind === "app", identity.connection_id],
    );
    if (!result.rows[0]) throw new HTTPError(404, "Submission not found.");
    return result.rows[0];
  }
  async setInterests(identity: Identity, connection: string, on: boolean) {
    this.app(identity);
    const result = await this.db.query(
      `INSERT INTO connection_grants(owner_id,connection_id,interests)
       SELECT $1,$2,$3 WHERE EXISTS(SELECT 1 FROM credentials WHERE owner_id=$1 AND connection_id=$2 AND kind IN('api','oauth','refresh'))
       ON CONFLICT(owner_id,connection_id) DO UPDATE SET interests=excluded.interests,updated_at=now() RETURNING connection_id`,
      [identity.owner_id, connection, on],
    );
    if (!result.rows.length) throw new HTTPError(404, "Connection not found.");
  }
  /** Saved-article metadata for an agent connection the owner opted in.
   * Titles, links, sites and save times only: never content, briefs,
   * collections or reading state. Newest first, keyset-paged. */
  async savedArticles(
    identity: Identity,
    input: { limit: number; before?: string; since?: string },
  ) {
    if (identity.kind !== "app") {
      const grant = await this.db.query(
        "SELECT 1 FROM connection_grants WHERE owner_id=$1 AND connection_id=$2 AND interests",
        [identity.owner_id, identity.connection_id],
      );
      if (!grant.rows.length)
        throw new HTTPError(
          403,
          "This connection cannot read saved articles. The owner can allow it in Settings → Assistant connections.",
        );
    }
    let at: string | null = null;
    let after: string | null = null;
    if (input.before) {
      const [time, id] = Buffer.from(input.before, "base64url")
        .toString()
        .split("|");
      if (
        !time ||
        !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/.test(time) ||
        Number.isNaN(Date.parse(time)) ||
        !id ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)
      )
        throw new HTTPError(400, "Invalid cursor.");
      at = time;
      after = id;
    }
    type Row = {
      id: string;
      title: string;
      status: string;
      source_url: string;
      site_name: string | null;
      captured_at: Date;
      at: string;
    };
    let result: { rows: Row[] };
    try {
      result = await this.db.query<Row>(
      // The cursor keeps microseconds in a fixed UTC form, independent of the
      // session's DateStyle and time zone, so paging is exact.
      `SELECT id,title,status,source_url,site_name,captured_at,
       to_char(captured_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS at FROM items
       WHERE owner_id=$1 AND kind='article' AND deleted=false AND trashed_at IS NULL AND source_url IS NOT NULL
       AND ($2::timestamptz IS NULL OR (captured_at,id) < ($2::timestamptz,$3::uuid))
       AND ($4::timestamptz IS NULL OR captured_at >= $4::timestamptz)
       ORDER BY captured_at DESC,id DESC LIMIT $5`,
      [identity.owner_id, at, after, input.since ?? null, input.limit + 1],
      );
    } catch (error) {
      // An out-of-range time in a forged cursor or `since` is a bad request.
      if (String((error as { code?: string }).code ?? "").startsWith("22"))
        throw new HTTPError(400, "Invalid cursor or time.");
      throw error;
    }
    const rows = result.rows.slice(0, input.limit);
    const last = rows.at(-1);
    const domain = (url: string) => {
      try {
        return new URL(url).hostname.replace(/^www\./, "");
      } catch {
        return null;
      }
    };
    return {
      articles: rows.flatMap((r) => {
        const host = domain(r.source_url);
        // A stored link that cannot be parsed is skipped, not fatal for the page.
        if (!host) return [];
        return [
          {
            url: r.source_url,
            title: r.title,
            site: r.site_name ?? null,
            domain: host,
            saved_at: new Date(r.captured_at).toISOString(),
            // False while queued or after a failed import: the title may
            // still be just the site's host name.
            prepared: r.status === "ready",
          },
        ];
      }),
      next:
        result.rows.length > input.limit && last
          ? Buffer.from(`${last.at}|${last.id}`).toString("base64url")
          : null,
    };
  }
  async library(identity: Identity, cursor: number) {
    this.app(identity);
    const result = await this.db.query<Item>(
      "SELECT * FROM items WHERE owner_id=$1 AND revision>$2 ORDER BY revision LIMIT 100",
      [identity.owner_id, cursor],
    );
    // Saved notes travel with their items, so they are on the phone before anyone opens them.
    const contexts =
      this.contextModel && (await this.entitled(identity, READING_CONTEXT))
        ? await this.savedContexts(identity, result.rows)
        : new Map<string, ReadingContext>();
    const items = [];
    for (const row of result.rows) {
      const assets = row.deleted
        ? []
        : (
            await this.db.query<Asset>(
              "SELECT * FROM assets WHERE item_id=$1",
              [row.id],
            )
          ).rows;
      const manifest = [];
      for (const asset of assets) {
        const token = secret();
        await this.db.query(
          "INSERT INTO download_grants(hash,asset_id,credential_id,expires_at) VALUES($1,$2,$3,$4)",
          [hash(token), asset.id, identity.id, new Date(Date.now() + 86400000)],
        );
        const { storage_key, ...safe } = asset;
        manifest.push({
          ...safe,
          url: `${this.config.publicURL}/v1/downloads/${token}`,
        });
      }
      const { owner_id, connection_id, activity_revision, ...safe } = row as Item & {
        activity_revision?: unknown;
      };
      items.push({
        ...safe,
        revision: Number(row.revision),
        captured_at: new Date(row.captured_at).toISOString(),
        assets: manifest,
        ...(contexts.has(row.id) ? { reading_context: contexts.get(row.id) } : {}),
      });
    }
    return {
      items,
      cursor: result.rows.length
        ? Number(result.rows.at(-1)!.revision)
        : cursor,
      has_more: result.rows.length === 100,
    };
  }
  async update(
    identity: Identity,
    id: string,
    patch: {
      progress?: number;
      archived?: boolean;
      collections?: string[];
      deleted?: boolean;
      trashed?: boolean;
    },
  ) {
    this.app(identity);
    // Moving to Trash keeps the first time it was trashed; restoring clears it.
    const result = await this.db.query(
      `UPDATE items SET activity_revision=NULL,progress=COALESCE($3,progress),archived=COALESCE($4,archived),collections=COALESCE($5::jsonb,collections),deleted=COALESCE($6,deleted),trashed_at=CASE WHEN $7::boolean IS NULL THEN trashed_at WHEN $7 THEN COALESCE(trashed_at,now()) ELSE NULL END,revision=nextval('library_revision') WHERE id=$1 AND owner_id=$2 AND deleted=false RETURNING id`,
      [
        id,
        identity.owner_id,
        patch.progress ?? null,
        patch.archived ?? null,
        patch.collections ? JSON.stringify(patch.collections) : null,
        patch.deleted ?? null,
        patch.trashed ?? null,
      ],
    );
    if (!result.rows.length) {
      const tombstone = await this.db.query(
        "SELECT id FROM items WHERE id=$1 AND owner_id=$2 AND deleted=true",
        [id, identity.owner_id],
      );
      if (!tombstone.rows.length || patch.deleted !== true)
        throw new HTTPError(404, "Item not found.");
    }
    if (patch.deleted) await this.removeContent(id);
  }
  private async removeContent(id: string) {
    const keys = await this.db.query<{ storage_key: string }>(
      "SELECT storage_key FROM assets WHERE item_id=$1",
      [id],
    );
    await this.files.remove(keys.rows.map((r) => r.storage_key));
    await this.db.query("DELETE FROM assets WHERE item_id=$1", [id]);
    await this.db.query("DELETE FROM jobs WHERE id=$1", [id]);
    // Derived text goes with the content it came from.
    await this.db.query("DELETE FROM reading_contexts WHERE item_id=$1", [id]);
    await this.db.query("DELETE FROM item_excerpts WHERE item_id=$1", [id]);
    await this.db.query("DELETE FROM context_failures WHERE item_id=$1", [id]);
  }
  /** Permanently deletes items that have been in Trash longer than `days`. */
  async purgeTrash(days = 30) {
    const expired = await this.db.query<{ id: string }>(
      `UPDATE items SET deleted=true,revision=nextval('library_revision')
       WHERE deleted=false AND trashed_at IS NOT NULL AND trashed_at < now() - ($1::int * interval '1 day')
       RETURNING id`,
      [days],
    );
    for (const row of expired.rows) await this.removeContent(row.id);
    return expired.rows.length;
  }
  async download(token: string) {
    const result = await this.db.query<Asset>(
      `SELECT a.* FROM assets a JOIN download_grants g ON g.asset_id=a.id JOIN credentials c ON c.id=g.credential_id JOIN items i ON i.id=a.item_id WHERE g.hash=$1 AND g.expires_at>now() AND c.expires_at>now() AND i.deleted=false`,
      [hash(token)],
    );
    const asset = result.rows[0];
    if (!asset)
      throw new HTTPError(
        404,
        "Download expired or unavailable. Refresh to retry.",
      );
    return { asset, bytes: await this.files.get(asset.storage_key) };
  }
  async deleteAccount(identity: Identity) {
    this.app(identity);
    // Include files uploaded before a crash but not yet referenced by a committed asset row.
    await this.files.purgeOwner(identity.owner_id);
    if (!this.config.devAuth) {
      const r = await fetch(
        `${this.config.supabaseURL}/auth/v1/admin/users/${identity.owner_id}`,
        {
          method: "DELETE",
          headers: supabaseHeaders(this.config.serviceKey!),
          signal: AbortSignal.timeout(15_000),
        },
      );
      if (!r.ok)
        throw new HTTPError(
          503,
          "Account deletion could not complete. Please retry.",
        );
    }
    await this.db.query("DELETE FROM accounts WHERE id=$1", [
      identity.owner_id,
    ]);
  }
  /** Owner-only and entitled features this app session may use. */
  async features(identity: Identity) {
    this.app(identity);
    return {
      reading_context:
        Boolean(this.contextModel) &&
        (await this.entitled(identity, READING_CONTEXT)),
    };
  }
  private async entitled(identity: Identity, feature: string) {
    const result = await this.db.query<{ email: string; granted: boolean }>(
      "SELECT a.email, EXISTS(SELECT 1 FROM account_entitlements e WHERE e.owner_id=a.id AND e.feature=$2) AS granted FROM accounts a WHERE a.id=$1",
      [identity.owner_id, feature],
    );
    const row = result.rows[0];
    if (!row) return false;
    const owner = this.config.devAuth
      ? this.config.devEmail.toLowerCase()
      : this.config.ownerEmail;
    return row.granted || (owner !== "" && row.email.toLowerCase() === owner);
  }
  private async requireContext(identity: Identity) {
    this.app(identity);
    if (!(await this.entitled(identity, READING_CONTEXT)))
      throw new HTTPError(403, "Reading context isn't available on this account.");
    if (!this.contextModel)
      throw new HTTPError(503, "Reading context isn't configured on this server.");
    return this.contextModel;
  }
  /** The saved reading context for an item, without generating one. */
  async readingContext(identity: Identity, id: string): Promise<ReadingContext> {
    await this.requireContext(identity);
    const item = await this.contextItem(identity, id);
    const saved = await this.savedContext(identity, item);
    if (!saved) throw new HTTPError(404, "No reading context yet.");
    return saved;
  }
  /** Returns the saved context, or generates one when there is none, the content changed, or `regenerate` is set. */
  async generateContext(
    identity: Identity,
    id: string,
    regenerate = false,
  ): Promise<ReadingContext> {
    const model = await this.requireContext(identity);
    const item = await this.contextItem(identity, id);
    const key = `${identity.owner_id}/${id}`;
    const own = () => {
      const run = this.runContext(identity, item, model).finally(() => this.contextRuns.delete(key));
      this.contextRuns.set(key, run);
      return run;
    };
    // Joining a background run: if it only stopped at the background cap, the owner's own
    // budget still applies.
    const join = (run: Promise<ReadingContext>) =>
      run.catch((error) => {
        if (!(error instanceof HTTPError && error.status === 429)) throw error;
        // Another joiner may have started the owner's run already.
        const current = this.contextRuns.get(key);
        return current && current !== run ? current : own();
      });
    const running = this.contextRuns.get(key);
    if (running) return join(running);
    if (!regenerate) {
      const saved = await this.savedContext(identity, item);
      if (saved) return saved;
      // Another request may have started while the saved note was read.
      const started = this.contextRuns.get(key);
      if (started) return join(started);
    }
    return own();
  }
  private async contextItem(identity: Identity, id: string) {
    const result = await this.db.query<Item>(
      "SELECT * FROM items WHERE id=$1 AND owner_id=$2 AND deleted=false AND status='ready'",
      [id, identity.owner_id],
    );
    if (!result.rows[0]) throw new HTTPError(404, "Item not found.");
    return result.rows[0];
  }
  private async savedContext(
    owner: Owner,
    item: Item,
  ): Promise<ReadingContext | undefined> {
    return (await this.savedContexts(owner, [item])).get(item.id);
  }
  /**
   * Saved notes for these items' current content, in a few queries for a whole sync page.
   * Each note's stale flag compares its finished-article set with today's, and citations of
   * articles deleted since are dropped with their titles and AI text.
   */
  private async savedContexts(owner: Owner, items: Item[]) {
    const views = new Map<string, ReadingContext>();
    const ready = items.filter((i) => !i.deleted);
    if (!ready.length) return views;
    const rows = (
      await this.db.query<SavedContextRow>(
        "SELECT item_id,content_version,history_digest,history_count,model,result,generated_at FROM reading_contexts WHERE owner_id=$1 AND item_id = ANY($2::uuid[])",
        [owner.owner_id, ready.map((i) => i.id)],
      )
    ).rows.filter(
      (r) => ready.find((i) => i.id === r.item_id)?.content_version === r.content_version,
    );
    if (!rows.length) return views;
    // One more than the history limit, so excluding the item itself still leaves a full list.
    const finished = (
      await this.db.query<{ id: string }>(
        `SELECT id FROM items WHERE owner_id=$1 AND deleted=false AND trashed_at IS NULL AND status='ready' AND progress>=1 AND archived
         ORDER BY COALESCE(activity_revision,revision) DESC LIMIT ${HISTORY_LIMIT + 1}`,
        [owner.owner_id],
      )
    ).rows.map((r) => r.id);
    const cited = [
      ...new Set(rows.flatMap((r) => [...r.result.builds_on, ...r.result.covered].map((n) => n.item_id))),
    ];
    const live = new Set(
      cited.length
        ? (
            await this.db.query<{ id: string }>(
              "SELECT id FROM items WHERE owner_id=$1 AND deleted=false AND id = ANY($2::uuid[])",
              [owner.owner_id, cited],
            )
          ).rows.map((r) => r.id)
        : [],
    );
    for (const row of rows) {
      const history = finished.filter((id) => id !== row.item_id).slice(0, HISTORY_LIMIT);
      views.set(row.item_id, {
        ...row.result,
        builds_on: row.result.builds_on.filter((n) => live.has(n.item_id)),
        covered: row.result.covered.filter((n) => live.has(n.item_id)),
        item_id: row.item_id,
        content_version: row.content_version,
        generated_at: new Date(row.generated_at).toISOString(),
        model: row.model,
        history_count: row.history_count,
        stale: historyDigest(history.map((id) => ({ id }))) !== row.history_digest,
      });
    }
    return views;
  }
  /**
   * Articles the owner marked Done (read marker and archived together), newest activity first.
   * Scrolling to the end alone also syncs progress 1, so archived is what separates Done.
   * Trash and the item itself are excluded.
   */
  private async finishedArticles(owner: Owner, exclude: string) {
    return (
      await this.db.query<{
        id: string;
        title: string;
        site_name: string | null;
        content_version: number;
      }>(
        `SELECT id,title,site_name,content_version FROM items
         WHERE owner_id=$1 AND id<>$2 AND deleted=false AND trashed_at IS NULL AND status='ready' AND progress>=1 AND archived
         ORDER BY COALESCE(activity_revision,revision) DESC LIMIT ${HISTORY_LIMIT}`,
        [owner.owner_id, exclude],
      )
    ).rows;
  }
  private async contentText(itemID: string, limit: number) {
    const asset = await this.db.query<{ storage_key: string }>(
      "SELECT storage_key FROM assets WHERE item_id=$1 AND role='content' LIMIT 1",
      [itemID],
    );
    if (!asset.rows[0]) return undefined;
    return documentText(
      (await this.files.get(asset.rows[0].storage_key)).toString("utf8"),
      limit,
    );
  }
  private async excerpts(
    rows: { id: string; content_version: number }[],
  ): Promise<Map<string, string>> {
    const cached = new Map<string, string>();
    if (!rows.length) return cached;
    const saved = await this.db.query<{
      item_id: string;
      content_version: number;
      excerpt: string;
    }>(
      "SELECT item_id,content_version,excerpt FROM item_excerpts WHERE item_id = ANY($1::uuid[])",
      [rows.map((r) => r.id)],
    );
    for (const row of saved.rows) {
      const item = rows.find((r) => r.id === row.item_id);
      if (item && item.content_version === row.content_version)
        cached.set(row.item_id, row.excerpt);
    }
    const missing = rows.filter((r) => !cached.has(r.id));
    // A few stored files at a time. A file that can't be read just goes without an excerpt.
    for (let i = 0; i < missing.length; i += 4)
      await Promise.all(
        missing.slice(i, i + 4).map(async (row) => {
          try {
            const excerpt = await this.contentText(row.id, EXCERPT_CHARACTERS);
            if (!excerpt) return;
            cached.set(row.id, excerpt);
            await this.db.query(
              "INSERT INTO item_excerpts(item_id,content_version,excerpt) SELECT $1,$2,$3 WHERE EXISTS(SELECT 1 FROM items WHERE id=$1 AND deleted=false) ON CONFLICT(item_id) DO UPDATE SET content_version=excluded.content_version,excerpt=excluded.excerpt",
              [row.id, row.content_version, excerpt],
            );
          } catch {
            // Titles alone still give the model something to compare.
          }
        }),
      );
    return cached;
  }
  private async runContext(
    identity: Owner,
    item: Item,
    model: ContextModel,
    budget: "owner" | "background" = "owner",
  ): Promise<ReadingContext> {
    const text = await this.contentText(item.id, ARTICLE_CHARACTERS);
    if (!text) throw new HTTPError(409, "This item has no readable text yet.");
    const rows = await this.finishedArticles(identity, item.id);
    const excerpts = await this.excerpts(rows.slice(0, EXCERPT_LIMIT));
    const history: HistoryEntry[] = rows.map((r) => ({
      id: r.id,
      title: r.title,
      site: r.site_name,
      excerpt: excerpts.get(r.id),
    }));
    // Background generations count apart, so a backfill never uses up the owner's own taps.
    const column = budget === "background" ? "background" : "count";
    const limit =
      budget === "background"
        ? this.config.contextBackgroundDailyLimit
        : this.config.contextDailyLimit;
    const reserved = await this.db.query<{ day: string }>(
      `INSERT INTO context_usage(owner_id,day,${column}) SELECT $1,(now() AT TIME ZONE 'UTC')::date,1 WHERE $2::int > 0
       ON CONFLICT(owner_id,day) DO UPDATE SET ${column}=context_usage.${column}+1 WHERE context_usage.${column} < $2
       RETURNING day::text`,
      [identity.owner_id, limit],
    );
    const day = reserved.rows[0]?.day;
    if (!day)
      throw new HTTPError(
        429,
        "Today's reading-context limit is used up. Saved summaries still open.",
      );
    let answer: string;
    try {
      answer = await model.complete(
        contextPrompt({ title: item.title, site: item.site_name ?? null, text }, history),
        AbortSignal.timeout(60_000),
      );
    } catch (error) {
      const provider = error instanceof ContextProviderError ? error : undefined;
      // Only a call the provider can't have billed gives its reservation back. An empty or
      // cut-off answer, a 200 with an error, or a timeout keeps it, so the cap bounds spending.
      if (!provider?.billed)
        await this.db.query(
          `UPDATE context_usage SET ${column}=${column}-1 WHERE owner_id=$1 AND day=$2::date AND ${column}>0`,
          [identity.owner_id, day],
        );
      logContextFailure(error, budget, "provider_call");
      throw new ContextGenerationError(provider ? provider.providerWide : true);
    }
    let result: ContextResult;
    try {
      result = parseContext(answer, history);
    } catch (error) {
      // The provider answered and billed it, so an unusable answer keeps its reservation.
      logContextFailure(error, budget, "invalid_answer");
      throw new ContextGenerationError(false);
    }
    const digest = historyDigest(rows);
    // Saving bumps the item's revision, so the note reaches the phone with the next sync.
    const saved = await this.db.query<{ generated_at: Date | string }>(
      `WITH saved AS (
         INSERT INTO reading_contexts(owner_id,item_id,content_version,history_digest,history_count,model,result)
         SELECT $1,$2,$3,$4,$5,$6,$7::jsonb WHERE EXISTS(SELECT 1 FROM items WHERE id=$2 AND owner_id=$1 AND deleted=false AND content_version=$3)
         ON CONFLICT(owner_id,item_id) DO UPDATE SET content_version=excluded.content_version,history_digest=excluded.history_digest,
         history_count=excluded.history_count,model=excluded.model,result=excluded.result,generated_at=now()
         RETURNING generated_at),
       bumped AS (UPDATE items SET activity_revision=COALESCE(activity_revision,revision),revision=nextval('library_revision')
         WHERE id=$2 AND owner_id=$1 AND EXISTS(SELECT 1 FROM saved) RETURNING id)
       SELECT generated_at FROM saved`,
      [
        identity.owner_id,
        item.id,
        item.content_version,
        digest,
        rows.length,
        model.model,
        JSON.stringify(result),
      ],
    );
    if (!saved.rows[0]) throw new HTTPError(404, "Item not found.");
    return {
      ...result,
      item_id: item.id,
      content_version: item.content_version,
      generated_at: new Date(saved.rows[0].generated_at).toISOString(),
      model: model.model,
      history_count: rows.length,
      stale: false,
    };
  }
  /**
   * Generates one missing note in the background: newly prepared articles and the backfill of
   * older ones, newest first, for owners with the entitlement. Returns whether it did any work.
   */
  async runContextJob(): Promise<boolean> {
    const model = this.contextModel;
    if (!model || this.config.contextBackgroundDailyLimit < 1) return false;
    // A provider-wide failure (key, credit, rate limit, outage) pauses all background work.
    if (Date.now() < this.contextPausedUntil) return false;
    const owner = this.config.devAuth
      ? this.config.devEmail.toLowerCase()
      : this.config.ownerEmail;
    if (!owner) return false;
    // Only the owner's library is sent in the background. Accounts with only an entitlement row
    // get notes when they ask, until there is an explicit opt-in for automatic sending.
    const next = await this.db.query<Item>(
      `SELECT i.* FROM items i JOIN accounts a ON a.id=i.owner_id
       WHERE i.deleted=false AND i.trashed_at IS NULL AND i.status='ready' AND i.kind='article'
       AND lower(a.email)=$1
       AND NOT EXISTS(SELECT 1 FROM reading_contexts c WHERE c.owner_id=i.owner_id AND c.item_id=i.id AND c.content_version=i.content_version)
       AND NOT EXISTS(SELECT 1 FROM context_failures f WHERE f.item_id=i.id AND f.content_version=i.content_version AND (f.attempts>=$2 OR f.next_at>now()))
       AND COALESCE((SELECT u.background FROM context_usage u WHERE u.owner_id=i.owner_id AND u.day=(now() AT TIME ZONE 'UTC')::date),0) < $3
       ORDER BY i.captured_at DESC, i.id DESC LIMIT 1`,
      [owner, BACKGROUND_ATTEMPTS, this.config.contextBackgroundDailyLimit],
    );
    const item = next.rows[0];
    if (!item) return false;
    const key = `${item.owner_id}/${item.id}`;
    // The owner's own request for this item is running; check again shortly.
    if (this.contextRuns.has(key)) return true;
    const run = this.runContext({ owner_id: item.owner_id }, item, model, "background").finally(
      () => this.contextRuns.delete(key),
    );
    this.contextRuns.set(key, run);
    try {
      await run;
      this.contextPauseMs = 0;
      this.contextWideFailure = undefined;
      await this.db.query("DELETE FROM context_failures WHERE item_id=$1", [item.id]);
    } catch (error) {
      // The cap filled up between the pick and the reservation: nothing more to do today.
      if (error instanceof HTTPError && error.status === 429) return false;
      // Probably not this article's fault: pause everything (15 minutes, doubling to an hour)
      // and leave its attempts untouched, so an outage can't use up the backfill. If the same
      // article fails that way again after a pause with no success in between, it counts as
      // one of its own attempts too, so a stuck article can't hold the backfill forever.
      if (error instanceof ContextGenerationError && error.providerWide) {
        this.contextPauseMs = Math.min(Math.max(this.contextPauseMs * 2, 15 * 60_000), 60 * 60_000);
        this.contextPausedUntil = Date.now() + this.contextPauseMs;
        const repeated = this.contextWideFailure === item.id;
        this.contextWideFailure = item.id;
        if (!repeated) return false;
      }
      // Back off an hour per attempt, then leave it for the owner to ask.
      await this.db.query(
        `INSERT INTO context_failures(item_id,content_version,attempts,next_at)
         SELECT $1,$2,1,now()+interval '1 hour' WHERE EXISTS(SELECT 1 FROM items WHERE id=$1 AND deleted=false)
         ON CONFLICT(item_id) DO UPDATE SET
           attempts=CASE WHEN context_failures.content_version=excluded.content_version THEN context_failures.attempts+1 ELSE 1 END,
           content_version=excluded.content_version,
           next_at=now()+(CASE WHEN context_failures.content_version=excluded.content_version THEN context_failures.attempts+1 ELSE 1 END)*interval '1 hour'`,
        [item.id, item.content_version],
      );
    }
    return true;
  }
  async runOne(): Promise<boolean> {
    const lease = randomUUID();
    const job = await this.db.query<{
      id: string;
      payload: {
        url?: string;
        markdown?: string;
        title?: string;
        sources?: string[];
      };
      attempts: number;
      owner_id: string;
    }>(
      `WITH candidate AS (SELECT id FROM jobs WHERE available_at<=now() AND (lease_until IS NULL OR lease_until<now()) ORDER BY available_at FOR UPDATE SKIP LOCKED LIMIT 1)
   UPDATE jobs j SET lease_until=now()+interval '10 minutes',lease_token=$1,attempts=attempts+1 FROM candidate c WHERE j.id=c.id RETURNING j.*, (SELECT owner_id FROM items WHERE id=j.id) AS owner_id`,
      [lease],
    );
    const row = job.rows[0];
    if (!row) return false;
    // Each claim counts an attempt, but only a failure the worker catches can end a job. A job
    // whose attempts ended the process instead (its lease expired) must not be retried forever.
    if (row.attempts > MAX_ATTEMPTS) {
      await this.db.query(
        `WITH claimed AS (DELETE FROM jobs WHERE id=$1 AND lease_token=$2 RETURNING id)
         UPDATE items SET status='bookmark',error=$3,revision=nextval('library_revision') WHERE id IN(SELECT id FROM claimed) AND deleted=false`,
        [row.id, lease, "Import could not complete. Retry from Imports."],
      );
      return true;
    }
    const uploaded: string[] = [];
    try {
      const active = await this.db.query(
        "UPDATE items SET status=$2,error=NULL,revision=nextval('library_revision') WHERE id=$1 AND deleted=false RETURNING id",
        [row.id, "processing"],
      );
      if (!active.rows.length) {
        await this.db.query("DELETE FROM jobs WHERE id=$1 AND lease_token=$2", [
          row.id,
          lease,
        ]);
        return true;
      }
      let prepared: Prepared;
      if (row.payload.url)
        prepared = await this.prepareArticle(row.payload.url);
      else {
        if (!row.payload.markdown?.trim())
          throw new ImportFailure("The brief contains no readable text.");
        prepared = {
          html:
            briefDocument(row.payload.markdown ?? "") +
            "<hr><p>Agent-created brief</p>" +
            (row.payload.sources ?? [])
              .map(
                (s) => `<p><a href="${escapeHTML(s)}">${escapeHTML(s)}</a></p>`,
              )
              .join(""),
          title: row.payload.title ?? "Reading brief",
          images: [],
          missingImages: 0,
        };
      }
      const contentID = randomUUID();
      const assets: {
        id: string;
        role: string;
        mime: string;
        size: number;
        sha256: string;
        filename: string;
        storage_key: string;
      }[] = [];
      const blobs = [
        {
          id: contentID,
          role: "content",
          mime: "text/html",
          filename: "article.html",
          bytes: Buffer.from(readerHTML(prepared.html, prepared.title, prepared.lang)),
        },
        ...prepared.images.map((i) => ({
          ...i,
          role: "image",
          mime: "image/webp",
          filename: `${i.id}.webp`,
        })),
      ];
      for (const blob of blobs) {
        const key = `${row.owner_id}/${row.id}/${blob.id}`;
        await this.files.put(key, blob.bytes, blob.mime);
        uploaded.push(key);
        assets.push({
          id: blob.id,
          role: blob.role,
          mime: blob.mime,
          size: blob.bytes.length,
          sha256: hash(blob.bytes),
          filename: blob.filename,
          storage_key: key,
        });
      }
      const published = await this.db.query(
        `WITH claimed AS (DELETE FROM jobs j WHERE j.id=$1 AND lease_token=$2 AND EXISTS(SELECT 1 FROM items WHERE id=j.id AND deleted=false) RETURNING id), inserted AS (
    INSERT INTO assets(id,item_id,role,mime,size,sha256,filename,storage_key) SELECT a.id,c.id,a.role,a.mime,a.size,a.sha256,a.filename,a.storage_key FROM jsonb_to_recordset($3::jsonb) AS a(id uuid,role text,mime text,size integer,sha256 text,filename text,storage_key text) CROSS JOIN claimed c RETURNING id)
    UPDATE items SET status='ready',title=$4,author=$5,error=$6,site_name=$7,content_version=content_version+1,activity_revision=NULL,revision=nextval('library_revision') WHERE id IN(SELECT id FROM claimed) RETURNING id`,
        [
          row.id,
          lease,
          JSON.stringify(assets),
          prepared.title,
          prepared.author ?? null,
          prepared.missingImages
            ? `${prepared.missingImages} source images unavailable.`
            : null,
          prepared.siteName ?? null,
        ],
      );
      if (!published.rows.length) await this.files.remove(uploaded);
      else this.onPrepared?.();
    } catch (error) {
      await this.files.remove(uploaded);
      const message =
        error instanceof ImportFailure
          ? error.message.slice(0, 240)
          : "Import could not complete. Retry from Imports.";
      const terminal =
        row.attempts >= MAX_ATTEMPTS || (error instanceof ImportFailure && error.terminal);
      if (terminal) {
        await this.db.query(
          `WITH claimed AS (DELETE FROM jobs WHERE id=$1 AND lease_token=$2 RETURNING id)
           UPDATE items SET status='bookmark',error=$3,revision=nextval('library_revision') WHERE id IN(SELECT id FROM claimed) AND deleted=false`,
          [row.id, lease, message],
        );
      } else {
        await this.db.query(
          `WITH released AS (UPDATE jobs SET lease_until=NULL,lease_token=NULL,available_at=now()+interval '30 seconds' WHERE id=$1 AND lease_token=$2 RETURNING id)
           UPDATE items SET status='queued',error=$3,revision=nextval('library_revision') WHERE id IN(SELECT id FROM released) AND deleted=false`,
          [row.id, lease, message],
        );
      }
    }
    return true;
  }
}

/** Identifies the finished-article set a reading context was built from. */
function historyDigest(rows: { id: string }[]) {
  return hash(rows.map((r) => r.id).sort().join(","));
}

/** A failed generation. `providerWide` failures pause background work instead of counting against the item. */
class ContextGenerationError extends HTTPError {
  constructor(public providerWide: boolean) {
    super(502, "Reading context could not be generated. Try again.");
  }
}

/** One line per failure, with a fixed category and the provider's status and code. Never content. */
function logContextFailure(error: unknown, budget: string, fallback: string) {
  const detail =
    error instanceof ContextProviderError
      ? { category: error.category, status: error.status, detail: error.detail, billed: error.billed }
      : // Other messages can quote the answer, so only the error's kind is logged.
        { category: fallback, detail: (error as Error)?.name };
  console.error("Reading context failed", JSON.stringify({ budget, ...detail }));
}
