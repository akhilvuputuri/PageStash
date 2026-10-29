import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { openDatabase, migrate, type Database } from "../src/db.js";
import { configuration } from "../src/config.js";
import { Service, type Identity } from "../src/service.js";
import { readerHTML } from "../src/content.js";
import {
  ContextProviderError,
  readUsage,
  requestBody,
  type ContextMessage,
  type ContextModel,
} from "../src/reading-context.js";

let db: Database, service: Service, owner: Identity, other: Identity;
const files = new Map<string, Buffer>();
const calls: ContextMessage[][] = [];
let failure: Error | undefined;
const model: ContextModel = {
  model: "test/model",
  async complete(messages) {
    calls.push(messages);
    if (failure) throw failure;
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
  failure = undefined;
  (service as any).contextPausedUntil = 0;
  (service as any).contextPauseMs = 0;
  (service as any).contextWideFailure = undefined;
  await db.query("DELETE FROM context_usage");
  await db.query("DELETE FROM context_failures");
  await db.query("DELETE FROM reading_contexts");
  await db.query("DELETE FROM items");
});

test("the request keeps reasoning low, uses the configured cap and asks for usage", () => {
  const body = requestBody("google/gemini-3.8-flash", [], 16_000);
  assert.deepEqual(body.reasoning, { effort: "low", exclude: true });
  assert.equal(body.max_tokens, 16_000);
  assert.deepEqual(body.usage, { include: true });
  assert.deepEqual(body.provider, { data_collection: "deny" });
  assert.equal(config().contextMaxTokens, 16_000);
  assert.equal(
    configuration({ DEV_AUTH: "true", DEV_PASSWORD: "x", READING_CONTEXT_MAX_TOKENS: "6000" }).contextMaxTokens,
    6000,
  );
  assert.throws(() => configuration({ DEV_AUTH: "true", DEV_PASSWORD: "x", READING_CONTEXT_MAX_TOKENS: "50" }));
});

test("usage is read as plain numbers, saved with the note, and anything malformed is dropped", async () => {
  assert.deepEqual(
    readUsage(
      { prompt_tokens: 9000, completion_tokens: 900, cost: 0.0042, completion_tokens_details: { reasoning_tokens: 600 } },
      "stop",
    ),
    { prompt_tokens: 9000, completion_tokens: 900, reasoning_tokens: 600, cost: 0.0042, finish_reason: "stop" },
  );
  assert.deepEqual(readUsage({ prompt_tokens: "lots", cost: -1 }), {
    prompt_tokens: undefined,
    completion_tokens: undefined,
    reasoning_tokens: undefined,
    cost: undefined,
    finish_reason: undefined,
  });
  assert.deepEqual(readUsage(undefined, "x".repeat(100)), { finish_reason: "x".repeat(40) });
  assert.equal(readUsage(null, { a: 1 }), undefined, "a non-string finish reason is dropped");
  const id = await item(owner, "Measured article");
  const measured: ContextModel = {
    model: "test/measured",
    async complete() {
      return {
        text: JSON.stringify({ summary: "Measured.", builds_on: [], covered: [], new_ideas: [] }),
        usage: { prompt_tokens: 8000, completion_tokens: 700, reasoning_tokens: 400, cost: 0.003, finish_reason: "stop" },
      };
    },
  };
  const svc = new Service(db, config(), storage, undefined, measured);
  await svc.generateContext(owner, id);
  const saved = await db.query<{ usage: Record<string, unknown> }>("SELECT usage FROM reading_contexts WHERE item_id=$1", [id]);
  assert.deepEqual(saved.rows[0].usage, {
    prompt_tokens: 8000,
    completion_tokens: 700,
    reasoning_tokens: 400,
    cost: 0.003,
    finish_reason: "stop",
  });
});

test("generates missing notes newest first, for the owner's articles only, and syncs them", async () => {
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

test("an item whose answers fail backs off, then stops after three attempts, and keeps billed reservations", async () => {
  const id = await item(owner, "Failing article");
  // Room for three billed attempts under the background cap.
  const roomy = new Service(db, config("10"), storage, undefined, model);
  failure = new ContextProviderError("empty_answer", true, false, 200, "length");
  assert.equal(await roomy.runContextJob(), true);
  const first = await db.query<{ attempts: number }>("SELECT attempts FROM context_failures WHERE item_id=$1", [id]);
  assert.equal(first.rows[0].attempts, 1);
  assert.equal(await roomy.runContextJob(), false, "it waits out the backoff");
  await db.query("UPDATE context_failures SET next_at=now()-interval '1 second'");
  assert.equal(await roomy.runContextJob(), true);
  await db.query("UPDATE context_failures SET next_at=now()-interval '1 second'");
  assert.equal(await roomy.runContextJob(), true);
  await db.query("UPDATE context_failures SET next_at=now()-interval '1 second'");
  assert.equal(await roomy.runContextJob(), false, "three attempts, then the owner can still ask");
  const usage = await db.query<{ background: number }>("SELECT background FROM context_usage");
  assert.equal(usage.rows[0]?.background, 3, "billed empty answers keep their reservation");
  failure = undefined;
  assert.equal((await roomy.generateContext(owner, id)).summary, "Background note.");
  await roomy.runContextJob();
  assert.equal((await db.query("SELECT 1 FROM context_failures WHERE item_id=$1", [id])).rows.length, 1);
});

test("does nothing without a model", async () => {
  await item(owner, "No key");
  const unconfigured = new Service(db, config(), storage);
  assert.equal(await unconfigured.runContextJob(), false);
  const page = await unconfigured.library(owner, 0);
  assert.ok(page.items.every((i: any) => !("reading_context" in i)));
});

test("a provider-wide failure pauses all background work without using up any item's attempts", async () => {
  const id = await item(owner, "Outage article");
  await item(owner, "Another article");
  failure = new ContextProviderError("provider_error", false, true, 401, "");
  assert.equal(await service.runContextJob(), false);
  assert.equal(calls.length, 1);
  assert.equal(await service.runContextJob(), false, "paused");
  assert.equal(calls.length, 1, "no requests while paused");
  assert.equal((await db.query("SELECT 1 FROM context_failures")).rows.length, 0);
  const usage = await db.query<{ background: number }>("SELECT background FROM context_usage");
  assert.equal(usage.rows[0]?.background ?? 0, 0, "an unbilled refusal is refunded");
  assert.ok((service as any).contextPauseMs >= 15 * 60_000);
  failure = undefined;
  (service as any).contextPausedUntil = 0;
  assert.equal(await service.runContextJob(), true);
  assert.equal((service as any).contextPauseMs, 0, "a success resets the pause");
  assert.ok(id);
});

test("saving a note doesn't reorder the finished-article history", async () => {
  const older = await item(owner, "Finished long ago", { capturedAt: "2026-01-01T00:00:00Z" });
  const recent = await item(owner, "Finished just now", { capturedAt: "2026-10-01T00:00:00Z" });
  await service.update(owner, older, { progress: 1, archived: true });
  await service.update(owner, recent, { progress: 1, archived: true });
  const current = await item(owner, "New save");
  const order = async () => {
    calls.length = 0;
    await service.generateContext(owner, current, true);
    return [...calls[0][1].content.matchAll(/^R\d+ \| ([^|\n]+)/gm)].map((m) => m[1].trim());
  };
  assert.deepEqual(await order(), ["Finished just now", "Finished long ago"]);
  // Background notes for both finished articles bump their sync revisions, oldest capture last.
  await db.query("DELETE FROM context_usage");
  while (await service.runContextJob()) {}
  assert.deepEqual(await order(), ["Finished just now", "Finished long ago"]);
  const note = await service.readingContext(owner, current);
  assert.equal(note.stale, false, "unchanged history isn't reported as stale");
});

test("an article that keeps failing provider-wide stops blocking older articles", async () => {
  const roomy = new Service(db, config("20"), storage, undefined, model);
  const unpause = () => ((roomy as any).contextPausedUntil = 0);
  await item(owner, "Older article", { capturedAt: "2026-01-01T00:00:00Z" });
  const stuck = await item(owner, "Stuck article", { capturedAt: "2026-10-01T00:00:00Z" });
  const real = model.complete;
  (model as any).complete = async (messages: ContextMessage[]) => {
    calls.push(messages);
    if (/Title: Stuck article/.test(messages[1].content))
      throw new ContextProviderError("timeout", true, true);
    return JSON.stringify({ summary: "Fine.", builds_on: [], covered: [], new_ideas: [] });
  };
  try {
    for (let round = 0; round < 12; round++) {
      await roomy.runContextJob();
      unpause();
      await db.query("UPDATE context_failures SET next_at=now()-interval '1 second'");
    }
    const notes = await db.query<{ title: string }>(
      "SELECT i.title FROM reading_contexts c JOIN items i ON i.id=c.item_id",
    );
    assert.deepEqual(notes.rows.map((r) => r.title), ["Older article"]);
    const failures = await db.query<{ attempts: number }>("SELECT attempts FROM context_failures WHERE item_id=$1", [stuck]);
    assert.equal(failures.rows[0].attempts, 3, "the stuck article stops after three of its own attempts");
    const stuckCalls = calls.filter((m) => /Title: Stuck article/.test(m[1].content)).length;
    assert.ok(stuckCalls <= 6, `bounded retries (${stuckCalls})`);
  } finally {
    (model as any).complete = real;
  }
});
