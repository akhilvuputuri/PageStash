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
import {
  extract,
  markdownDocument,
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
    const capacity = await this.db.query<{ queued: string; total: string }>(
      "SELECT count(*) FILTER(WHERE status IN('queued','processing')) AS queued,count(*) AS total FROM items WHERE owner_id=$1 AND deleted=false",
      [identity.owner_id],
    );
    if (
      Number(capacity.rows[0].queued) >= 50 ||
      Number(capacity.rows[0].total) >= 1000
    )
      throw new HTTPError(
        429,
        "Personal beta library or import queue limit reached.",
      );
    const url = input.url ? normalizedURL(input.url) : null;
    const kind = url ? "article" : "brief";
    const id = randomUUID();
    // The item and its queue entry are one database statement, so a crash cannot lose the import.
    const inserted = await this.db.query<{ id: string }>(
      `WITH item AS (
   INSERT INTO items(id,owner_id,connection_id,idempotency_key,normalized_url,kind,title,source_url,sources)
   VALUES($1,$2,$3,$4,$5,$6,$7,$5,$8::jsonb) ON CONFLICT DO NOTHING RETURNING id)
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
    if (inserted.rows.length) {
      this.onQueued?.();
      return { submission_id: id, status: "queued", duplicate: false };
    }
    const existing = await this.db.query<{
      id: string;
      status: string;
      connection_id: string;
    }>(
      `SELECT id,status,connection_id FROM items WHERE owner_id=$1 AND (idempotency_key=$2 OR (normalized_url=$3 AND deleted=false)) ORDER BY captured_at LIMIT 1`,
      [identity.owner_id, input.idempotency_key, url],
    );
    const row = existing.rows[0];
    if (!row)
      throw new HTTPError(
        409,
        "Submission conflicted; try a new request identifier.",
      );
    // Do not disclose submissions created by another connection to a limited agent.
    if (identity.kind !== "app" && row.connection_id !== identity.connection_id)
      return { submission_id: null, status: "already_saved", duplicate: true };
    return { submission_id: row.id, status: row.status, duplicate: true };
  }
  async status(identity: Identity, id: string) {
    const result = await this.db.query(
      "SELECT id,status,error FROM items WHERE id=$1 AND owner_id=$2 AND deleted=false AND ($3 OR connection_id=$4)",
      [id, identity.owner_id, identity.kind === "app", identity.connection_id],
    );
    if (!result.rows[0]) throw new HTTPError(404, "Submission not found.");
    return result.rows[0];
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
      if (row.payload.url) prepared = await extract(row.payload.url);
      else
        prepared = {
          html:
            markdownDocument(row.payload.markdown ?? "") +
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
          bytes: Buffer.from(readerHTML(prepared.html, prepared.title)),
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
    UPDATE items SET status='ready',title=$4,author=$5,error=$6,content_version=content_version+1,revision=nextval('library_revision') WHERE id IN(SELECT id FROM claimed) RETURNING id`,
        [
          row.id,
          lease,
          JSON.stringify(assets),
          prepared.title,
          prepared.author ?? null,
          prepared.missingImages
            ? `${prepared.missingImages} source images unavailable.`
            : null,
        ],
      );
      if (!published.rows.length) await this.files.remove(uploaded);
    } catch (error) {
      await this.files.remove(uploaded);
      const message =
        error instanceof Error &&
        /Source|article|Destination|HTML|redirect|compressed/.test(
          error.message,
        )
          ? error.message.slice(0, 240)
          : "Import could not complete. The bookmark has been retained.";
      const terminal = row.attempts >= 3;
      await this.db.query(
        `UPDATE items SET status=$2,error=$3,revision=nextval('library_revision') WHERE id=$1 AND deleted=false AND EXISTS(SELECT 1 FROM jobs WHERE id=$1 AND lease_token=$4)`,
        [row.id, terminal ? "bookmark" : "queued", message, lease],
      );
      if (terminal)
        await this.db.query("DELETE FROM jobs WHERE id=$1 AND lease_token=$2", [
          row.id,
          lease,
        ]);
      else
        await this.db.query(
          "UPDATE jobs SET lease_until=NULL,lease_token=NULL,available_at=now()+interval '30 seconds' WHERE id=$1 AND lease_token=$2",
          [row.id, lease],
        );
    }
    return true;
  }
}
