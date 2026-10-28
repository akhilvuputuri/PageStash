import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { openDatabase, migrate, type Database } from "../src/db.js";
import { configuration } from "../src/config.js";
import { Service, type Identity } from "../src/service.js";
import { readerHTML } from "../src/content.js";
import { requestBody, type ContextMessage, type ContextModel } from "../src/reading-context.js";

let db: Database, service: Service, owner: Identity, other: Identity;
const files = new Map<string, Buffer>();
const calls: ContextMessage[][] = [];
let fail = false;
const model: ContextModel = {
  model: "test/model",
  async complete(messages) {
    calls.push(messages);
    if (fail) throw new Error("provider down");
    return JSON.stringify({ summary: "Background note.", builds_on: [], covered: [], new_ideas: [] });
  },
};
const storage = {
  put: async (k: string, b: Buffer) => void files.set(k, b),
  get: async (k: string) => files.get(k)!,
  remove: async (keys: string[]) => keys.forEach((k) => files.delete(k)),
  purgeOwner: async () => {},
};
const config = (background = "2") =>
  configuration({
    DEV_AUTH: "true",
    DEV_PASSWORD: "local-test-password",
    READING_CONTEXT_DAILY_LIMIT: "5",
    READING_CONTEXT_BACKGROUND_DAILY_LIMIT: background,
  });
async function item(who: Identity, title: string, options: { kind?: string; capturedAt?: string } = {}) {
  const id = randomUUID();
  const asset = randomUUID();
  const key = `${who.owner_id}/${id}/${asset}`;
  const html = Buffer.from(readerHTML(`<p>${title} body.</p>`, title));
  files.set(key, html);
  await db.query(
    `INSERT INTO items(id,owner_id,connection_id,idempotency_key,kind,status,title,content_version,captured_at)
     VALUES($1,$2,$3,$4,$5,'ready',$6,1,$7)`,
    [id, who.owner_id, who.connection_id, randomUUID(), options.kind ?? "article", title, options.capturedAt ?? new Date().toISOString()],
  );
  await db.query(
    "INSERT INTO assets(id,item_id,role,mime,size,sha256,filename,storage_key) VALUES($1,$2,'content','text/html',$3,'x','article.html',$4)",
    [asset, id, html.length, key],
  );
  return id;
}
const titleOf = (messages: ContextMessage[]) => /Title: (.*)/.exec(messages[1].content)?.[1];

before(async () => {
  db = await openDatabase();
  await migrate(db);
  service = new Service(db, config(), storage, undefined, model);
  owner = await service.authenticate(
    (await service.login("reader@example.test", "local-test-password")).token,
  );
  const otherID = randomUUID();
  await db.query("INSERT INTO accounts(id,email) VALUES($1,$2)", [otherID, "other@example.test"]);
  other = await service.authenticate((await service.credential(otherID, "app", "Other")).token);
});
after(async () => db.close());
beforeEach(async () => {
  calls.length = 0;
  fail = false;
  await db.query("DELETE FROM context_usage");
  await db.query("DELETE FROM context_failures");
  await db.query("DELETE FROM reading_contexts");
  await db.query("DELETE FROM items");
});

test("the request keeps reasoning low and leaves room for the answer", () => {
  const body = requestBody("google/gemini-3.8-flash", []);
  assert.deepEqual(body.reasoning, { effort: "low", exclude: true });
  assert.ok(body.max_tokens >= 4000);
  assert.deepEqual(body.provider, { data_collection: "deny" });
});

test("generates missing notes newest first, for entitled owners' articles only, and syncs them", async () => {
  const older = await item(owner, "Older article", { capturedAt: "2026-10-01T00:00:00Z" });
  const newer = await item(owner, "Newer article", { capturedAt: "2026-10-20T00:00:00Z" });
  await item(owner, "A brief", { kind: "brief" });
  await item(other, "Someone else's article");
  const { cursor } = await service.library(owner, 0);
  assert.equal(await service.runContextJob(), true);
  assert.equal(titleOf(calls[0]), "Newer article");
  assert.equal(await service.runContextJob(), true);
  assert.equal(titleOf(calls[1]), "Older article");
  assert.equal(await service.runContextJob(), false, "briefs and other accounts are skipped");
  assert.equal(calls.length, 2);
  const usage = await db.query<{ count: number; background: number }>("SELECT count,background FROM context_usage");
  assert.deepEqual(usage.rows[0], { count: 0, background: 2 }, "background work leaves the owner's taps alone");
  // Saving a note bumps the item, so the next sync carries it.
  const page = await service.library(owner, cursor);
  const synced = new Map(page.items.map((i: any) => [i.id, i.reading_context]));
  assert.equal(synced.get(newer)?.summary, "Background note.");
  assert.equal(synced.get(older)?.stale, false);
  const theirs = await service.library(other, 0);
  assert.ok(theirs.items.every((i: any) => !("reading_context" in i)));
});

test("stops at the background daily limit", async () => {
  for (const n of [1, 2, 3]) await item(owner, `Article ${n}`);
  assert.equal(await service.runContextJob(), true);
  assert.equal(await service.runContextJob(), true);
  assert.equal(await service.runContextJob(), false);
  assert.equal(calls.length, 2);
  // The owner's own taps still work after the background budget is used up.
  const left = (await db.query<{ id: string }>(
    "SELECT id FROM items i WHERE NOT EXISTS(SELECT 1 FROM reading_contexts c WHERE c.item_id=i.id)",
  )).rows[0].id;
  assert.equal((await service.generateContext(owner, left)).summary, "Background note.");
  const off = new Service(db, config("0"), storage, undefined, model);
  await item(owner, "Paused");
  assert.equal(await off.runContextJob(), false);
});

test("a failing item backs off, then stops after three attempts", async () => {
  const id = await item(owner, "Failing article");
  fail = true;
  assert.equal(await service.runContextJob(), true);
  const first = await db.query<{ attempts: number }>("SELECT attempts FROM context_failures WHERE item_id=$1", [id]);
  assert.equal(first.rows[0].attempts, 1);
  assert.equal(await service.runContextJob(), false, "it waits out the backoff");
  await db.query("UPDATE context_failures SET next_at=now()-interval '1 second'");
  assert.equal(await service.runContextJob(), true);
  await db.query("UPDATE context_failures SET next_at=now()-interval '1 second'");
  assert.equal(await service.runContextJob(), true);
  await db.query("UPDATE context_failures SET next_at=now()-interval '1 second'");
  assert.equal(await service.runContextJob(), false, "three attempts, then the owner can still ask");
  const usage = await db.query<{ background: number }>("SELECT background FROM context_usage");
  assert.equal(usage.rows[0]?.background ?? 0, 0, "calls with no completion are refunded");
  fail = false;
  assert.equal((await service.generateContext(owner, id)).summary, "Background note.");
  await service.runContextJob();
  assert.equal((await db.query("SELECT 1 FROM context_failures WHERE item_id=$1", [id])).rows.length, 1);
});

test("does nothing without a model", async () => {
  await item(owner, "No key");
  const unconfigured = new Service(db, config(), storage);
  assert.equal(await unconfigured.runContextJob(), false);
  const page = await unconfigured.library(owner, 0);
  assert.ok(page.items.every((i: any) => !("reading_context" in i)));
});
