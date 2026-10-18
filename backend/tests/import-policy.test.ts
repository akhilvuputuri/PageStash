import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { extract, briefDocument } from "../src/content.js";
import { ImportFailure } from "../src/import-error.js";
import { Service } from "../src/service.js";
import { configuration } from "../src/config.js";
import { openDatabase, migrate } from "../src/db.js";
import { buildServer } from "../src/server.js";

const prose =
  "The reporting explains the history and context of this event, with detailed observations and clear evidence for readers. ".repeat(
    12,
  );
const page = (title: string, body: string) =>
  `<html><head><title>${title}</title></head><body>${body}</body></html>`;
const capture = (html: string, mime = "text/html") =>
  extract("https://example.com/story", async (url) => ({
    url,
    mime,
    bytes: Buffer.from(html),
  }));

test("rejects HTML-200 challenges, sign-in and diagnostic pages before storing content", async () => {
  for (const html of [
    page(
      "Just a moment...",
      `<main><h1>Checking your browser</h1><p>Enable JavaScript and cookies to continue.</p><form id="challenge-form"></form>${prose}</main>`,
    ),
    page(
      "Sign in | Publisher",
      `<main><h1>Sign in</h1><form><input type="password"></form><p>Sign in to read this article.</p>${prose}</main>`,
    ),
    page(
      "Access denied",
      `<main><h1>Access denied</h1><p>You don't have permission to access this page. Your request was blocked.</p>${prose}</main>`,
    ),
    page(
      "404 Page not found",
      `<h1>404</h1><p>The page you requested was not found.</p>${prose}`,
    ),
    page(
      "Service unavailable",
      `<h1>Service unavailable</h1><p>Please try later.</p>`,
    ),
  ])
    await assert.rejects(() => capture(html), ImportFailure);
  await assert.rejects(
    () => capture("unsupported", "application/pdf"),
    /not an HTML article/,
  );
  await assert.rejects(
    () => capture(page("Empty", "<p>   </p>")),
    /could not be extracted/,
  );
});

test("keeps legitimate reporting about errors, including an ambiguous headline", async () => {
  const article = await capture(
    page(
      "Access denied",
      `<article><h1>Access denied</h1><p>Our reporter investigated the effect of permission errors on public records access. Access was denied to researchers, and their request was blocked. This story discusses HTTP 403 and login pages as subjects, rather than asking the reader to authenticate.</p><p>${prose}</p></article>`,
    ),
  );
  assert.ok(article.html.includes("Our reporter"));
  const ordinary = await capture(
    page(
      "How HTTP errors work",
      `<article><h1>How HTTP errors work</h1><p>Examples include access denied, page not found and internal server error.</p><p>${prose}</p></article>`,
    ),
  );
  assert.ok(ordinary.html.includes("Examples include"));
});

test("missing images retain readable text with an explicit warning", async () => {
  const html = page(
    "Readable story",
    `<article><h1>Readable story</h1><p>${prose}</p><img src='/missing.jpg' alt='Source photo'></article>`,
  );
  const result = await extract("https://example.com/story", async (url) => {
    if (url.endsWith(".jpg"))
      throw new ImportFailure("Source returned HTTP 404.");
    return { url, mime: "text/html", bytes: Buffer.from(html) };
  });
  assert.equal(result.missingImages, 1);
  assert.match(result.html, /Image unavailable: Source photo/);
  assert.match(result.html, /reporting explains/);
});

async function fixture(
  run: (
    service: Service,
    owner: Awaited<ReturnType<Service["authenticate"]>>,
    agent: Awaited<ReturnType<Service["authenticate"]>>,
    other: Awaited<ReturnType<Service["authenticate"]>>,
    setFailure: (failure: Error | null) => void,
  ) => Promise<void>,
) {
  const db = await openDatabase();
  await migrate(db);
  let failure: Error | null = new ImportFailure(
    "Source returned HTTP 403; authentication and paywalls are not bypassed.",
  );
  const files = new Map<string, Buffer>();
  const service = new Service(
    db,
    configuration({ DEV_AUTH: "true", DEV_PASSWORD: "test-password" }),
    {
      put: async (key, bytes) => {
        files.set(key, bytes);
      },
      get: async (key) => files.get(key)!,
      remove: async (keys) => {
        keys.forEach((key) => files.delete(key));
      },
      purgeOwner: async () => {
        files.clear();
      },
    },
    async () => {
      if (failure) throw failure;
      return {
        html: `<p>${prose}</p>`,
        title: "Usable story",
        images: [],
        missingImages: 1,
      };
    },
  );
  const owner = await service.authenticate(
    (await service.login("reader@example.test", "test-password")).token,
  );
  const agent = await service.authenticate(
    (await service.credential(owner.owner_id, "api", "Synthetic agent")).token,
  );
  const other = await service.authenticate(
    (await service.credential(owner.owner_id, "api", "Other connection")).token,
  );
  try {
    await run(service, owner, agent, other, (value) => {
      failure = value;
    });
  } finally {
    await db.close();
  }
}

test("failed submissions keep safe status, retry receipts and ownership without duplicate articles", async () =>
  fixture(async (service, owner, agent, other, setFailure) => {
    const input = {
      url: "https://example.com/story",
      idempotency_key: randomUUID(),
    };
    const initial = await service.save(agent, input);
    await service.runOne();
    assert.equal(
      (await service.status(agent, initial.submission_id!)).status,
      "bookmark",
    );
    assert.equal((await service.library(owner, 0)).items[0].assets.length, 0);
    assert.equal(await service.runOne(), false);
    const replay = await service.save(agent, input);
    assert.equal(replay.status, "bookmark");
    assert.equal(
      await service.runOne(),
      false,
      "network replay must not restart a terminal failure",
    );
    const opaque = await service.save(other, {
      ...input,
      idempotency_key: randomUUID(),
    });
    assert.equal(opaque.submission_id, null);
    assert.equal(opaque.status, "already_saved");
    assert.equal(await service.retry(other, initial.submission_id!), false);
    await assert.rejects(
      () => service.status(other, initial.submission_id!),
      /not found/,
    );
    const recovery = { ...input, idempotency_key: randomUUID() };
    const retried = await service.save(agent, recovery);
    assert.equal(retried.submission_id, initial.submission_id);
    assert.equal(retried.status, "queued");
    await service.runOne();
    assert.equal((await service.save(agent, recovery)).status, "bookmark");
    assert.equal(
      await service.runOne(),
      false,
      "the recovery request itself must also be idempotent",
    );
    setFailure(null);
    assert.equal(await service.retry(owner, initial.submission_id!), true);
    assert.equal(await service.retry(owner, initial.submission_id!), false);
    await service.runOne();
    const library = await service.library(owner, 0);
    assert.equal(library.items.length, 1);
    assert.equal(library.items[0].status, "ready");
    assert.match(library.items[0].error!, /source images unavailable/);
    assert.equal(library.items[0].assets.length, 1);
  }));

test("transient failures stop after bounded retries and hide provider details", async () =>
  fixture(async (service, _owner, agent, _other, setFailure) => {
    setFailure(
      new Error(
        "Private provider response with article token should never appear",
      ),
    );
    const receipt = await service.save(agent, {
      url: "https://example.com/retry",
      idempotency_key: randomUUID(),
    });
    for (let attempt = 0; attempt < 3; attempt++) {
      await service.db.query("UPDATE jobs SET available_at=now() WHERE id=$1", [
        receipt.submission_id,
      ]);
      await service.runOne();
    }
    const state = await service.status(agent, receipt.submission_id!);
    assert.equal(state.status, "bookmark");
    assert.equal(state.error, "Import could not complete. Retry from Imports.");
    assert.equal(await service.runOne(), false);
  }));

test("a job whose attempts ended the process is kept as a retryable bookmark", async () =>
  fixture(async (service, owner, agent, _other, setFailure) => {
    // Preparing would now succeed, so only the attempt guard can make this a bookmark.
    setFailure(null);
    const receipt = await service.save(agent, {
      url: "https://example.com/crashes",
      idempotency_key: randomUUID(),
    });
    // Three claims whose processes exited before recording a failure: each counted an attempt
    // and left an expired lease.
    await service.db.query(
      "UPDATE jobs SET attempts=3,lease_token=gen_random_uuid(),lease_until=now()-interval '1 second',available_at=now() WHERE id=$1",
      [receipt.submission_id],
    );
    assert.equal(await service.runOne(), true);
    const state = await service.status(agent, receipt.submission_id!);
    assert.equal(state.status, "bookmark");
    assert.equal(state.error, "Import could not complete. Retry from Imports.");
    assert.equal(await service.runOne(), false, "the job is not claimed again");
    assert.equal(await service.retry(owner, receipt.submission_id!), true);
    await service.runOne();
    assert.equal((await service.status(agent, receipt.submission_id!)).status, "ready");
    // Two crashed claims leave one real attempt: the third claim still prepares the article.
    const second = await service.save(agent, {
      url: "https://example.com/crashed-twice",
      idempotency_key: randomUUID(),
    });
    await service.db.query(
      "UPDATE jobs SET attempts=2,lease_token=gen_random_uuid(),lease_until=now()-interval '1 second',available_at=now() WHERE id=$1",
      [second.submission_id],
    );
    await service.runOne();
    assert.equal((await service.status(agent, second.submission_id!)).status, "ready");
  }));

test("retry route remains app-only and same-key concurrent saves have one durable queue entry", async () =>
  fixture(async (service, owner, agent, _other) => {
    const input = {
      url: "https://example.com/concurrent",
      idempotency_key: randomUUID(),
    };
    const receipts = await Promise.all([
      service.save(agent, input),
      service.save(agent, input),
    ]);
    assert.equal(receipts[0].submission_id, receipts[1].submission_id);
    await service.runOne();
    const app = await buildServer(service);
    try {
      const token = (await service.credential(owner.owner_id, "api", "Limited"))
        .token;
      const denied = await app.inject({
        method: "POST",
        url: `/v1/items/${receipts[0].submission_id}/retry`,
        headers: { authorization: `Bearer ${token}` },
      });
      assert.equal(denied.statusCode, 403);
    } finally {
      await app.close();
    }
  }));

test("concurrent fresh retry intents register both receipts but enqueue only one job", async () =>
  fixture(async (service, owner, agent) => {
    const input = {
      url: "https://example.com/parallel-retry",
      idempotency_key: randomUUID(),
    };
    const initial = await service.save(agent, input);
    await service.runOne();
    const keys = [randomUUID(), randomUUID()];
    const receipts = await Promise.all(
      keys.map((idempotency_key) =>
        service.save(agent, { ...input, idempotency_key }),
      ),
    );
    assert.ok(
      receipts.every((row) => row.submission_id === initial.submission_id),
    );
    const jobs = await service.db.query<{ count: string }>(
      "SELECT count(*) AS count FROM jobs",
    );
    assert.equal(Number(jobs.rows[0].count), 1);
    await service.runOne();
    for (const idempotency_key of keys)
      assert.equal(
        (await service.save(agent, { ...input, idempotency_key })).status,
        "bookmark",
      );
    assert.equal(await service.runOne(), false);
    assert.equal((await service.library(owner, 0)).items.length, 1);
    // Simulate a legacy item missing its original receipt, preserving newer aliases.
    await service.db.query(
      "DELETE FROM save_requests WHERE owner_id=$1 AND idempotency_key=$2",
      [owner.owner_id, input.idempotency_key],
    );
    await migrate(service.db);
    const aliases = await service.db.query<{ count: string }>(
      "SELECT count(*) AS count FROM save_requests WHERE submission_id=$1",
      [initial.submission_id],
    );
    assert.equal(Number(aliases.rows[0].count), 3);
  }));

test("brief validation rejects empty rendered content, not just empty input strings", () => {
  for (const value of ["   ", "```\n```", "# ", "***"])
    assert.throws(() => briefDocument(value), /no readable text/);
  assert.match(briefDocument("# Short note\nHello"), /Hello/);
});
