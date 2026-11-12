import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { extract, type Fetcher } from "../src/content.js";
import {
  EXTRACT_DEADLINE_MS,
  ExtractProcessError,
  childFlags,
  parseInSandbox,
  runningExtractions,
} from "../src/extract-sandbox.js";
import { runRequest } from "../src/extract-dom.js";
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

/**
 * The independent reviewer's reproducer: nine `<b>` with 8,000-character titles re-opened in 1,900
 * paragraphs. 110 KB and 1,914 tags; as a worker thread it ended the whole process (exit 134).
 */
const amplifiedAttributes = `<html><body><article><p>${Array.from(
  { length: 9 },
  (_, k) => `<b title="${String.fromCharCode(97 + k).repeat(8_000)}">`,
).join("")}</p><p>${prose.slice(0, 330)}</p>${"<p>word word word</p>".repeat(1_900)}</article></body></html>`;

/** Readability is slow on many empty paragraphs (19,900 took 211 s on the main thread before). */
const emptyParagraphs = `<html><body><article><h1>Empty</h1><p>${prose.slice(0, 150)}</p>${"<p></p>".repeat(11_900)}</article></body></html>`;

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

/** The child is killed asynchronously after a failure; wait until none is left. */
async function noChildrenLeft() {
  for (let i = 0; i < 100 && runningExtractions() > 0; i++)
    await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(runningExtractions(), 0, "no extraction child left running");
}

const assertTooComplex = (failure: unknown) => {
  assert.ok(failure instanceof ImportFailure, String(failure));
  assert.equal(failure.code, "too_complex");
  assert.equal(failure.terminal, true);
  assert.equal(importOutcome(failure, "extract").terminal, true);
  assert.match(importOutcome(failure, "extract").message, /too complex/);
};

test("amplified attributes fail as too_complex at production limits, and this process survives", async () => {
  assert.ok(amplifiedAttributes.length < 120_000);
  const run = await whileTicking(() =>
    extract("https://example.com/attributes", page(amplifiedAttributes)),
  );
  assertTooComplex(run.result);
  assert.ok(run.longestGap < 1_000, `event loop blocked for ${Math.round(run.longestGap)} ms`);
  assert.ok(run.ticks > 0);
  await noChildrenLeft();
});

test("a fatal V8 heap abort in the child (below the size check) is too_complex, and this process survives", async () => {
  // 400-character titles stay under the parsed-size check; a 48 MB test heap makes V8 abort the
  // child ("Reached heap limit", SIGABRT), the failure a worker thread could not contain.
  const html = amplifiedAttributes.replace(/"([a-i])\1{7999}"/g, (_, c: string) => `"${c.repeat(400)}"`);
  assert.ok(html.length < 50_000);
  const run = await whileTicking(() =>
    extract("https://example.com/abort", page(html), undefined, { heapMb: 48 }),
  );
  assertTooComplex(run.result);
  assert.ok(run.longestGap < 1_000, `event loop blocked for ${Math.round(run.longestGap)} ms`);
  await noChildrenLeft();
});

test("a tiny adoption-agency page runs out of child memory and fails permanently while this process keeps running", async () => {
  const html = adoptionPage(300, 300);
  assert.ok(html.length < 6_000, "about 5.3 KB of HTML");
  // Production limits: about 90,000 elements from 603 tags, which used 454 MB on the main thread.
  const run = await whileTicking(() =>
    extract("https://example.com/adoption", page(html)),
  );
  assertTooComplex(run.result);
  assert.ok(run.ms < EXTRACT_DEADLINE_MS, `stopped by memory in ${Math.round(run.ms)} ms, before the deadline`);
  assert.ok(run.longestGap < 1_000, `event loop blocked for ${Math.round(run.longestGap)} ms`);
  assert.ok(run.ticks > 0);
  await noChildrenLeft();
});

test("many empty paragraphs hit the extraction deadline, and the child is killed", async () => {
  const run = await whileTicking(() =>
    extract("https://example.com/empty", page(emptyParagraphs), undefined, { deadlineMs: 1_000 }),
  );
  const failure = run.result;
  assert.ok(failure instanceof ImportFailure, String(failure));
  assert.equal(failure.code, "extract_timeout");
  assert.equal(failure.terminal, true);
  assert.equal(importOutcome(failure, "extract").terminal, true);
  assert.ok(run.ms < 5_000, `gave up after ${Math.round(run.ms)} ms`);
  assert.ok(run.longestGap < 1_000, `event loop blocked for ${Math.round(run.longestGap)} ms`);
  await noChildrenLeft();
});

test("an abort signal stops the child early as a retryable failure", async () => {
  const controller = new AbortController();
  setTimeout(() => controller.abort(), 300);
  const failure = await extract("https://example.com/empty", page(emptyParagraphs), undefined, {
    signal: controller.signal,
  }).catch((error: unknown) => error);
  assert.ok(failure instanceof ExtractProcessError, String(failure));
  assert.equal(failure.code, "EXTRACT_ABORTED");
  assert.equal(importOutcome(failure, "extract").terminal, false);
  await noChildrenLeft();
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

test("a RangeError from the page's size or shape is too_complex, other errors stay retryable", async () => {
  const { Readability } = await import("@mozilla/readability");
  const parse = Readability.prototype.parse;
  const request = {
    kind: "article" as const,
    html: `<html><body><article><p>${prose}</p></article></body></html>`,
    url: "https://example.com/",
    deadlineMs: 1_000,
  };
  try {
    Readability.prototype.parse = function () {
      throw new RangeError("Invalid string length");
    };
    assert.deepEqual(await runRequest(request), {
      ok: false,
      failure: {
        message: "This content is too complex to process. It would need more memory than PageStash allows.",
        terminal: true,
        code: "too_complex",
      },
    });
    Readability.prototype.parse = function () {
      throw Object.assign(new TypeError("quoting https://example.com/secret"), { code: "SOME_CODE" });
    };
    assert.deepEqual(await runRequest(request), { ok: false, error: { name: "TypeError", code: "SOME_CODE" } });
  } finally {
    Readability.prototype.parse = parse;
  }
});

test("a child that cannot start is a retryable internal failure carrying no message", async () => {
  const missing = new URL("./no-such-extract-child.js", import.meta.url);
  const failure = await parseInSandbox("<p>x</p>", "https://example.com/", { childUrl: missing }).catch(
    (error: unknown) => error,
  );
  assert.ok(failure instanceof ExtractProcessError, String(failure));
  assert.equal(failure.code, "EXTRACT_CHILD_START");
  assert.doesNotMatch(failure.message, /no-such-extract-child/);
  const outcome = importOutcome(failure, "extract");
  assert.equal(outcome.terminal, false);
  assert.equal(outcome.code, "internal");
  // Through extract as well: the caller sees the same retryable error.
  const viaExtract = await extract(
    "https://example.com/story",
    page(`<html><body><article><p>${prose}</p></article></body></html>`),
    undefined,
    { childUrl: missing },
  ).catch((error: unknown) => error);
  assert.ok(viaExtract instanceof ExtractProcessError);
  await noChildrenLeft();
});

test("the child inherits only module-loader flags, plus its heap limit", () => {
  assert.deepEqual(childFlags([], 192), ["--max-old-space-size=192"]);
  assert.deepEqual(
    childFlags(
      ["--import", "tsx", "--input-type=module", "-e", "console.log(1)", "--max-old-space-size=4096", "--require=./x.cjs", "--inspect"],
      192,
    ),
    ["--import", "tsx", "--require=./x.cjs", "--max-old-space-size=192"],
  );
});

test("a normal article still extracts in the child, and its errors cross back with their codes", async () => {
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
      assert.equal(fields.elements, 11_905);
      assert.doesNotMatch(lines[0], /private-host|private-path/);
      const state = await service.status(owner, receipt.submission_id!);
      assert.equal(state.status, "bookmark");
      assert.equal(state.error, "This content took too long to process and was stopped.");
      assert.equal(await service.runOne(), false, "never retried");
    },
  );
});

test("a brief of 200,000 newlines fails permanently in the child instead of exhausting the process", async () => {
  await withService(
    async () => {
      throw new Error("articles are not used here");
    },
    async (service, owner, runLogged) => {
      // The API allows 200,000 characters; this renders as 200,000 empty paragraphs, which took
      // 1.9 GB and 14 s on the main thread before rendering moved into the child.
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
      // An ordinary brief still renders through the child.
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
