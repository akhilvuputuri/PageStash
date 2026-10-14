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
  sources: string[];
  captured_at: Date;
  content_version: number;
  progress: number;
  collections: string[];
  archived: boolean;
  deleted: boolean;
  revision: string | number;
}

export class Service {
  onQueued?: () => void;
  constructor(
    public db: Database,
    public config: Config,
    public files: Storage,
    private prepareArticle: (url: string) => Promise<Prepared> = extract,
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
       WHERE owner_id=$1 AND kind='article' AND deleted=false AND source_url IS NOT NULL
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
      const { owner_id, connection_id, ...safe } = row;
      items.push({
        ...safe,
        revision: Number(row.revision),
        captured_at: new Date(row.captured_at).toISOString(),
        assets: manifest,
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
    },
  ) {
    this.app(identity);
    const result = await this.db.query(
      `UPDATE items SET progress=COALESCE($3,progress),archived=COALESCE($4,archived),collections=COALESCE($5::jsonb,collections),deleted=COALESCE($6,deleted),revision=nextval('library_revision') WHERE id=$1 AND owner_id=$2 AND deleted=false RETURNING id`,
      [
        id,
        identity.owner_id,
        patch.progress ?? null,
        patch.archived ?? null,
        patch.collections ? JSON.stringify(patch.collections) : null,
        patch.deleted ?? null,
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
    if (patch.deleted) {
      const keys = await this.db.query<{ storage_key: string }>(
        "SELECT storage_key FROM assets WHERE item_id=$1",
        [id],
      );
      await this.files.remove(keys.rows.map((r) => r.storage_key));
      await this.db.query("DELETE FROM assets WHERE item_id=$1", [id]);
      await this.db.query("DELETE FROM jobs WHERE id=$1", [id]);
    }
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
    UPDATE items SET status='ready',title=$4,author=$5,error=$6,site_name=$7,content_version=content_version+1,revision=nextval('library_revision') WHERE id IN(SELECT id FROM claimed) RETURNING id`,
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
    } catch (error) {
      await this.files.remove(uploaded);
      const message =
        error instanceof ImportFailure
          ? error.message.slice(0, 240)
          : "Import could not complete. Retry from Imports.";
      const terminal =
        row.attempts >= 3 || (error instanceof ImportFailure && error.terminal);
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
