import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { extract, type Fetcher } from "../src/content.js";
import {
  EXTRACT_DEADLINE_MS,
  ExtractWorkerError,
  parseInWorker,
} from "../src/extract-sandbox.js";
import { ImportFailure, importOutcome } from "../src/import-error.js";
import { Service } from "../src/service.js";
import { configuration } from "../src/config.js";
import { migrate, openDatabase } from "../src/db.js";

const prose =
  "The reporting explains the history and context of this event, with detailed observations and clear evidence for readers. ".repeat(
    12,
  );

const page = (html: string): Fetcher => async (url) => ({
  url,
  mime: "text/html",
  bytes: Buffer.from(html),
});

/** `<p>`, N distinct `<b>`, `</p>`, then M paragraphs: the parser re-opens every `<b>` in each. */
const adoptionPage = (n: number, m: number) =>
  `<html><body><p>${Array.from({ length: n }, (_, k) => `<b id=${k}>`).join("")}</p>${"<p>x</p>".repeat(m)}</body></html>`;

/** Readability is roughly quadratic here: 211 s on the main thread before this change. */
const emptyParagraphs = `<html><body><article><h1>Empty</h1>${"<p></p>".repeat(19_900)}</article></body></html>`;

/** Runs `work` while a 20 ms timer measures the longest gap between its ticks on this thread. */
async function whileTicking<T>(work: () => Promise<T>) {
  let ticks = 0;
  let longestGap = 0;
  let last = performance.now();
  const timer = setInterval(() => {
    const now = performance.now();
    longestGap = Math.max(longestGap, now - last);
    last = now;
    ticks++;
  }, 20);
  const start = performance.now();
  try {
    const result = await work().catch((error: unknown) => error);
    return { result, ms: performance.now() - start, ticks, longestGap };
  } finally {
    clearInterval(timer);
  }
}

test("a tiny adoption-agency page runs out of worker memory and fails permanently while this thread keeps running", async () => {
  const html = adoptionPage(300, 300);
  assert.ok(html.length < 6_000, "about 5.3 KB of HTML");
  // Production limits: about 90,000 elements from 603 tags, which used 454 MB on the main thread.
  const run = await whileTicking(() =>
    extract("https://example.com/adoption", page(html)),
  );
  const failure = run.result;
  assert.ok(failure instanceof ImportFailure, String(failure));
  assert.equal(failure.code, "too_complex");
  assert.equal(failure.terminal, true);
  assert.equal(importOutcome(failure, "extract").terminal, true);
  assert.match(importOutcome(failure, "extract").message, /too complex/);
  assert.ok(run.ms < EXTRACT_DEADLINE_MS, `stopped by memory in ${Math.round(run.ms)} ms, before the deadline`);
  assert.ok(run.longestGap < 1_000, `event loop blocked for ${Math.round(run.longestGap)} ms`);
  assert.ok(run.ticks >= Math.floor(run.ms / 20 / 4), `timer fired ${run.ticks} times in ${Math.round(run.ms)} ms`);
});

test("many empty paragraphs hit the extraction deadline, and the worker is stopped", async () => {
  const run = await whileTicking(() =>
    extract("https://example.com/empty", page(emptyParagraphs), undefined, { deadlineMs: 1_000 }),
  );
  const failure = run.result;
  assert.ok(failure instanceof ImportFailure, String(failure));
  assert.equal(failure.code, "extract_timeout");
  assert.equal(failure.terminal, true);
  assert.equal(importOutcome(failure, "extract").terminal, true);
  assert.ok(run.ms < 3_000, `gave up after ${Math.round(run.ms)} ms`);
  assert.ok(run.longestGap < 1_000, `event loop blocked for ${Math.round(run.longestGap)} ms`);
});

test("Readability's own element limit, reached through parser-built elements, is a permanent failure", async () => {
  // 2,113 tags pass our count; the parser builds about 23,000 elements, over Readability's limit.
  const failure = await extract("https://example.com/many", page(adoptionPage(10, 2_100))).catch(
    (error: unknown) => error,
  );
  assert.ok(failure instanceof ImportFailure, String(failure));
  assert.equal(failure.code, "too_many_elements");
  assert.equal(failure.terminal, true);
});

test("a worker that cannot start is a retryable internal failure carrying no message", async () => {
  const missing = new URL("./no-such-extract-worker.js", import.meta.url);
  const failure = await parseInWorker("<p>x</p>", "https://example.com/", { workerUrl: missing }).catch(
    (error: unknown) => error,
  );
  assert.ok(failure instanceof ExtractWorkerError, String(failure));
  assert.equal(failure.code, "ERR_MODULE_NOT_FOUND");
  assert.doesNotMatch(failure.message, /no-such-extract-worker/);
  const outcome = importOutcome(failure, "extract");
  assert.equal(outcome.terminal, false);
  assert.equal(outcome.code, "internal");
  // Through extract as well: the caller sees the same retryable error.
  const viaExtract = await extract(
    "https://example.com/story",
    page(`<html><body><article><p>${prose}</p></article></body></html>`),
    undefined,
    { workerUrl: missing },
  ).catch((error: unknown) => error);
  assert.ok(viaExtract instanceof ExtractWorkerError);
});

test("a normal article still extracts in the worker, and its errors cross back with their codes", async () => {
  const article = await extract(
    "https://example.com/story",
    page(`<html lang="en"><head><title>Story</title></head><body><article><h1>Story</h1><p>${prose}</p><p><a href="javascript:alert(1)">bad</a> <a href="https://example.org/">good</a></p></article></body></html>`),
  );
  assert.match(article.html, new RegExp(prose.slice(0, 60)));
  assert.doesNotMatch(article.html, /javascript/);
  assert.match(article.html, /<a href="https:\/\/example.org\/">good<\/a>/);
  assert.equal(article.lang, "en");
  const barrier = await extract(
    "https://example.com/blocked",
    page("<html><head><title>Access denied</title></head><body><h1>Access denied</h1><p>You don't have permission to access this page.</p></body></html>"),
  ).catch((error: unknown) => error);
  assert.ok(barrier instanceof ImportFailure);
  assert.equal(barrier.code, "barrier");
});

/** A service with in-memory storage whose `runOne` returns the console lines it wrote. */
async function withService(
  prepare: ConstructorParameters<typeof Service>[3],
  run: (
    service: Service,
    owner: Awaited<ReturnType<Service["authenticate"]>>,
    runLogged: () => Promise<string[]>,
  ) => Promise<void>,
) {
  const db = await openDatabase();
  await migrate(db);
  const service = new Service(
    db,
    configuration({ DEV_AUTH: "true", DEV_PASSWORD: "test-password" }),
    {
      put: async () => {},
      get: async () => Buffer.alloc(0),
      remove: async () => {},
      purgeOwner: async () => {},
    },
    prepare,
  );
  const runLogged = async () => {
    const lines: string[] = [];
    const { log, error } = console;
    console.log = (...args: unknown[]) => void lines.push(args.join(" "));
    console.error = (...args: unknown[]) => void lines.push(args.join(" "));
    try {
      await service.runOne();
    } finally {
      console.log = log;
      console.error = error;
    }
    return lines;
  };
  try {
    const owner = await service.authenticate(
      (await service.login("reader@example.test", "test-password")).token,
    );
    await run(service, owner, runLogged);
  } finally {
    await db.close();
  }
}

test("a page stopped at the deadline ends the import at once and logs its code without the URL", async () => {
  await withService(
    (url, trace) => extract(url, page(emptyParagraphs), trace, { deadlineMs: 500 }),
    async (service, owner, runLogged) => {
      const receipt = await service.save(owner, {
        url: "https://private-host.example/private-path",
        idempotency_key: randomUUID(),
      });
      const lines = await runLogged();
      assert.equal(lines.length, 1);
      assert.match(lines[0], /^Import failed /);
      const fields = JSON.parse(lines[0].slice("Import failed ".length));
      assert.equal(fields.outcome, "failed");
      assert.equal(fields.code, "extract_timeout");
      assert.equal(fields.stage, "extract");
      assert.equal(fields.elements, 19_904);
      assert.doesNotMatch(lines[0], /private-host|private-path/);
      const state = await service.status(owner, receipt.submission_id!);
      assert.equal(state.status, "bookmark");
      assert.equal(state.error, "This content took too long to process and was stopped.");
      assert.equal(await service.runOne(), false, "never retried");
    },
  );
});

test("a brief of 200,000 newlines fails permanently in the worker instead of exhausting the process", async () => {
  await withService(
    async () => {
      throw new Error("articles are not used here");
    },
    async (service, owner, runLogged) => {
      // The API allows 200,000 characters; this renders as 200,000 empty paragraphs, which took
      // 1.9 GB and 14 s on the main thread before rendering moved into the worker.
      const receipt = await service.save(owner, {
        title: "Long brief",
        markdown: "\n".repeat(199_999) + "x",
        idempotency_key: randomUUID(),
      });
      const lines = await runLogged();
      assert.equal(lines.length, 1);
      const fields = JSON.parse(lines[0].slice("Import failed ".length));
      assert.equal(fields.kind, "brief");
      assert.equal(fields.outcome, "failed");
      assert.equal(fields.code, "too_complex");
      const state = await service.status(owner, receipt.submission_id!);
      assert.equal(state.status, "bookmark");
      // An ordinary brief still renders through the worker.
      const ok = await service.save(owner, {
        title: "Short brief",
        markdown: "# Heading\nA **sourced** note with [a link](https://example.org/).",
        idempotency_key: randomUUID(),
      });
      const done = await runLogged();
      assert.match(done[0], /^Import finished /);
      assert.equal((await service.status(owner, ok.submission_id!)).status, "ready");
    },
  );
});
