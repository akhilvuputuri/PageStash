import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { Readable } from "node:stream";
import { brotliCompressSync, gzipSync } from "node:zlib";
import { request } from "undici";
import {
  contentTypeCharset,
  readBody,
  statusFailure,
  USER_AGENT,
} from "../src/fetch.js";
import {
  decodePage,
  elementCounts,
  extract,
  TAG_LIMIT,
  pageCharset,
  readerHTML,
  type Prepared,
} from "../src/content.js";
import {
  ImportFailure,
  importOutcome,
  newTrace,
} from "../src/import-error.js";
import {
  LIBRARY_LIMIT,
  MAX_ATTEMPTS,
  QUEUE_LIMIT,
  Service,
  retryDelaySeconds,
} from "../src/service.js";
import { configuration } from "../src/config.js";
import { migrate, openDatabase } from "../src/db.js";
import { buildServer } from "../src/server.js";

const prose =
  "The reporting explains the history and context of this event, with detailed observations and clear evidence for readers. ".repeat(
    12,
  );
const MB = 1024 * 1024;

/** Collects console lines while `work` runs. */
async function captureLogs(work: () => Promise<void>): Promise<string[]> {
  const lines: string[] = [];
  const { log, error } = console;
  console.log = (...args: unknown[]) => void lines.push(args.join(" "));
  console.error = (...args: unknown[]) => void lines.push(args.join(" "));
  try {
    await work();
  } finally {
    console.log = log;
    console.error = error;
  }
  return lines;
}

// --- Decompression ---------------------------------------------------------------------------

test("gzip and Brotli bodies decode, and the cap applies to decompressed bytes", async () => {
  const text = Buffer.from(`<p>${prose}</p>`);
  assert.deepEqual(await readBody(Readable.from([gzipSync(text)]), "gzip", MB), text);
  assert.deepEqual(await readBody(Readable.from([brotliCompressSync(text)]), "br", MB), text);
  assert.deepEqual(await readBody(Readable.from([text]), undefined, MB), text);
  // A compression bomb: 16 MB of zeros is about 16 KB gzipped and far smaller in Brotli.
  const zeros = Buffer.alloc(16 * MB);
  for (const [encoding, bomb] of [
    ["gzip", gzipSync(zeros)],
    ["br", brotliCompressSync(zeros)],
  ] as const) {
    assert.ok(bomb.length < MB, `${encoding} bomb is small on the wire`);
    const trace = newTrace();
    await assert.rejects(
      () => readBody(Readable.from([bomb]), encoding, MB, trace),
      (error: unknown) => error instanceof ImportFailure && error.code === "too_large",
    );
    // Reading stopped within one decompressed chunk of the cap rather than inflating everything.
    assert.ok((trace.bytes ?? 0) <= MB + 128 * 1024, `${encoding} stopped at the cap`);
  }
  // The wire cap still applies to uncompressed and compressed bodies.
  await assert.rejects(
    () => readBody(Readable.from([Buffer.alloc(2 * MB)]), "identity", MB),
    /download size limit/,
  );
  await assert.rejects(
    () => readBody(Readable.from([Buffer.from("x")]), "compress", MB),
    /unsupported compressed/,
  );
  // A corrupt gzip body maps to a short decode message.
  const corrupt = await readBody(Readable.from([Buffer.from("not gzip at all")]), "gzip", MB).catch(
    (error) => error,
  );
  assert.equal(importOutcome(corrupt, "fetch").code, "bad_encoding");
  const corruptBrotli = await readBody(
    Readable.from([Buffer.from("not brotli at all, definitely")]),
    "br",
    MB,
  ).catch((error) => error);
  assert.match(String(corruptBrotli.code), /^ERR__ERROR_/);
  assert.deepEqual(importOutcome(corruptBrotli, "fetch"), {
    message: "The site sent a response that couldn't be decoded.",
    code: "bad_encoding",
    terminal: false,
  });
});

test("a gzip bomb streamed over HTTP is abandoned at the cap without unhandled errors", async () => {
  const bomb = gzipSync(Buffer.alloc(32 * MB));
  const server = createServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/html", "content-encoding": "gzip" });
    response.end(bomb);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    const response = await request(`http://127.0.0.1:${port}/`, {
      headers: { "accept-encoding": "gzip, br" },
    });
    await assert.rejects(
      () => readBody(response.body, String(response.headers["content-encoding"]), MB),
      /download size limit/,
    );
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(response.body.destroyed, true);
  } finally {
    server.closeAllConnections();
    server.close();
  }
});

test("requests identify the product honestly and name the Content-Type charset", () => {
  assert.match(USER_AGENT, /PageStash/);
  assert.doesNotMatch(USER_AGENT, /Chrome|Safari|Firefox|Gecko\//);
  assert.equal(contentTypeCharset("text/html; charset=Shift_JIS"), "shift_jis");
  assert.equal(contentTypeCharset('text/html;charset="windows-1252"'), "windows-1252");
  assert.equal(contentTypeCharset("text/html"), undefined);
});

// --- Charset ---------------------------------------------------------------------------------

test("pages decode from a BOM, then the Content-Type charset, then a meta declaration", () => {
  const japanese = "日本語の記事です。";
  const shiftJIS = Buffer.from(new TextEncoderShiftJIS(japanese).bytes);
  // 日本 in Shift_JIS, checked by hand.
  assert.deepEqual([...shiftJIS.subarray(0, 4)], [0x93, 0xfa, 0x96, 0x7b]);
  assert.notEqual(shiftJIS.toString("utf8"), japanese);
  assert.equal(decodePage(shiftJIS, "shift_jis"), japanese);
  assert.equal(pageCharset(shiftJIS, "Shift_JIS"), "shift_jis");
  // windows-1252: curly quotes, an em dash and é, which UTF-8 decoding would mangle.
  const latin = Buffer.from([0x93, 0x43, 0x61, 0x66, 0xe9, 0x94, 0x20, 0x97, 0x20, 0x6f, 0x6b]);
  assert.equal(decodePage(latin, "windows-1252"), "“Café” — ok");
  // ISO-8859-1 is treated as windows-1252, as browsers do.
  assert.equal(pageCharset(latin, "iso-8859-1"), "windows-1252");
  // A <meta charset> in the page when the header has none.
  const meta = Buffer.concat([
    Buffer.from('<!doctype html><html><head><meta charset="Shift_JIS"><title>t</title></head><body><p>'),
    shiftJIS,
    Buffer.from("</p></body></html>"),
  ]);
  assert.equal(pageCharset(meta), "shift_jis");
  assert.match(decodePage(meta), /日本語の記事です/);
  // An http-equiv declaration.
  const equiv = Buffer.concat([
    Buffer.from('<html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head><body>'),
    latin,
  ]);
  assert.equal(pageCharset(equiv), "windows-1252");
  // The header wins over the meta; a BOM wins over both.
  assert.equal(pageCharset(meta, "utf-8"), "utf-8");
  const bom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("café")]);
  assert.equal(pageCharset(bom, "windows-1252"), "utf-8");
  assert.equal(decodePage(bom, "windows-1252"), "café");
  // Unknown labels and a UTF-16 meta fall back to UTF-8; invalid bytes never throw.
  assert.equal(pageCharset(Buffer.from("<meta charset=bogus>"), "x-unknown"), "utf-8");
  assert.equal(pageCharset(Buffer.from('<meta charset="utf-16">')), "utf-8");
  assert.equal(decodePage(Buffer.from([0x61, 0xff, 0x62])), "a�b");
});

test("extraction decodes a meta-declared Shift_JIS article and a windows-1252 header", async () => {
  const japanese = "これは日本語で書かれた長い記事の本文です。読みやすい段落が続きます。";
  const body = `<html><head><meta charset="shift_jis"><title>記事</title></head><body><article><h1>記事</h1>${`<p>${japanese.repeat(4)}</p>`.repeat(6)}</article></body></html>`;
  const encoded = Buffer.from(new TextEncoderShiftJIS(body).bytes);
  const article = await extract("https://example.com/jp", async (url) => ({
    url,
    mime: "text/html",
    bytes: encoded,
  }));
  assert.ok(article.html.includes(japanese), "Japanese text survives");
  const latin = Buffer.from(
    `<html><head><title>Caf\xe9</title></head><body><article><h1>Caf\xe9</h1><p>\x93Quoted\x94 ${prose}</p></article></body></html>`,
    "latin1",
  );
  const western = await extract("https://example.com/fr", async (url) => ({
    url,
    mime: "text/html",
    charset: "windows-1252",
    bytes: latin,
  }));
  assert.match(western.html, /“Quoted”/);
});

/**
 * Node has no Shift_JIS encoder, so this test fixture maps the few characters it uses from a
 * decoder-built table. It covers ASCII and every character in the fixture strings.
 */
class TextEncoderShiftJIS {
  bytes: number[] = [];
  private static table?: Map<string, number[]>;
  constructor(text: string) {
    const table = TextEncoderShiftJIS.build();
    for (const char of text) {
      const code = char.codePointAt(0)!;
      if (code < 0x80) this.bytes.push(code);
      else {
        const bytes = table.get(char);
        assert.ok(bytes, `fixture character ${char} is encodable`);
        this.bytes.push(...bytes);
      }
    }
  }
  private static build() {
    if (this.table) return this.table;
    const decoder = new TextDecoder("shift_jis");
    const table = new Map<string, number[]>();
    for (let lead = 0x81; lead <= 0xfc; lead++) {
      if (lead >= 0xa0 && lead <= 0xdf) continue;
      for (let trail = 0x40; trail <= 0xfc; trail++) {
        if (trail === 0x7f) continue;
        const char = decoder.decode(Uint8Array.from([lead, trail]));
        if (char.length === 1 && char !== "�" && !table.has(char)) table.set(char, [lead, trail]);
      }
    }
    this.table = table;
    return table;
  }
}

// --- Element counting ------------------------------------------------------------------------

test("element counting skips script and style text and does not count SVG as readable", async () => {
  const script = `<script>${"if (a<b && c<d) x = '<div>';".repeat(500)}</script>`;
  const style = `<style>${"a>b{}".repeat(1000)}</style>`;
  const plain = elementCounts(`<html><body>${script}${style}<p>x</p></body></html>`);
  assert.equal(plain.elements, 5);
  // The context-free count includes the script's "<b", "<d" and "<div>" text: it is deliberately
  // conservative.
  assert.equal(plain.tags, 5 + 3 * 500);
  const icons = `<svg viewBox="0 0 1 1">${"<path d='M0 0'/>".repeat(30_000)}</svg>`;
  assert.deepEqual(elementCounts(`<div>${icons}</div>`), { elements: 2, tags: 30_002 });
  // An unclosed script swallows the rest of the page for the readable count, as a parser would,
  // but every tag still counts toward the hard cap.
  const unclosed = elementCounts(`<p></p><script>${"<div>".repeat(30_000)}`);
  assert.equal(unclosed.elements, 2);
  assert.equal(unclosed.tags, 30_002);
  // Too many real elements is still rejected.
  await assert.rejects(
    () =>
      extract("https://example.com/huge", async (url) => ({
        url,
        mime: "text/html",
        bytes: Buffer.from(`<html><body>${"<div>x</div>".repeat(20_001)}</body></html>`),
      })),
    /element limit/,
  );
  // A page with an inline icon sprite and a long script still extracts.
  const sprite = `<svg viewBox="0 0 1 1">${"<path d='M0 0'/>".repeat(10_000)}</svg>`;
  const article = await extract("https://example.com/icons", async (url) => ({
    url,
    mime: "text/html",
    bytes: Buffer.from(
      `<html><head><title>Story</title>${script}</head><body>${sprite}<article><h1>Story</h1><p>${prose}</p></article></body></html>`,
    ),
  }));
  assert.match(article.html, /reporting explains/);
});

test("markup hidden from the readable count still hits the hard tag cap", async () => {
  const many = "<p>".repeat(TAG_LIMIT + 10);
  const bypasses = {
    // A script opened inside a comment: the comment is skipped, so the paragraphs are counted.
    comment: `<!--<script>-->${many}<!--</script>-->`,
    // A script tag inside a quoted attribute value is not a script.
    attribute: `<a title="><script>">x</a>${many}<a title="</script>">y</a>`,
    // Inside SVG, style and script are ordinary elements, not raw text.
    svgStyle: `<svg><style>${many}</style></svg>`,
    svgScript: `<svg><script>${many}</script></svg>`,
    // An unclosed SVG doesn't hide the rest of the page.
    unclosedSvg: `<svg>${many}`,
  };
  for (const [name, body] of Object.entries(bypasses)) {
    const counts = elementCounts(body);
    assert.ok(counts.tags > TAG_LIMIT, `${name}: hard cap counts every tag`);
    const failure = await extract("https://example.com/bypass", async (url) => ({
      url,
      mime: "text/html",
      bytes: Buffer.from(`<html><body>${body}</body></html>`),
    })).catch((error) => error);
    assert.ok(failure instanceof ImportFailure, name);
    assert.equal(failure.code, "too_many_elements", name);
    assert.equal(failure.terminal, true, name);
  }
  // The comment and attribute cases are also caught by the readable count itself.
  assert.ok(elementCounts(`<!--<script>-->${"<p>".repeat(20_001)}<!--</script>-->`).elements > 20_000);
  assert.ok(elementCounts(`<a title="><script>">x</a>${"<p>".repeat(20_001)}`).elements > 20_000);
  // Abrupt comments end immediately, as in a browser.
  assert.equal(elementCounts(`<!--><p><!---><p>`).elements, 2);
});

test("element counting is linear on input with no closing bracket", () => {
  for (const input of ["<a".repeat(1_500_000), "<a-" + "a-".repeat(1_500_000), `<a title="${"x".repeat(3_000_000)}`]) {
    const start = performance.now();
    elementCounts(input);
    const ms = performance.now() - start;
    assert.ok(ms < 2000, `scanned ${input.length} characters in ${Math.round(ms)} ms`);
  }
});

test("Readability's own element limit is a permanent failure", async () => {
  // A crafted count mismatch: elements our scanner can't see but the parser builds. Simulated by
  // injecting a fetcher whose page passes our scan and then a Readability that throws.
  const { Readability } = await import("@mozilla/readability");
  const parse = Readability.prototype.parse;
  Readability.prototype.parse = function () {
    throw new Error("Aborting parsing document; 20200 elements found");
  };
  try {
    const failure = await extract("https://example.com/many", async (url) => ({
      url,
      mime: "text/html",
      bytes: Buffer.from(`<html><body><article><p>${prose}</p></article></body></html>`),
    })).catch((error) => error);
    assert.ok(failure instanceof ImportFailure);
    assert.equal(failure.code, "too_many_elements");
    assert.equal(failure.terminal, true);
    assert.equal(importOutcome(failure, "extract").terminal, true);
  } finally {
    Readability.prototype.parse = parse;
  }
});

// --- Direction -------------------------------------------------------------------------------

test("reader HTML carries the article's text direction", async () => {
  const arabic = "هذا نص عربي طويل يشرح تاريخ الحدث وسياقه بملاحظات مفصلة وأدلة واضحة للقراء. ".repeat(6);
  const article = await extract("https://example.com/ar", async (url) => ({
    url,
    mime: "text/html",
    bytes: Buffer.from(
      `<html lang="ar" dir="rtl"><head><title>قصة</title></head><body><article><h1>قصة</h1><p>${arabic}</p></article></body></html>`,
    ),
  }));
  assert.equal(article.dir, "rtl");
  assert.equal(article.lang, "ar");
  const html = readerHTML(article.html, article.title, article.lang, article.dir);
  assert.match(html, /^<!doctype html><html lang="ar" dir="rtl">/);
  assert.match(readerHTML("<p>x</p>", "t", "en"), /^<!doctype html><html lang="en"><head>/);
  assert.doesNotMatch(readerHTML("<p>x</p>", "t", undefined, '"><script>'), /script>/);
});

// --- Error mapping and retry schedule --------------------------------------------------------

test("network errors map to short messages without quoting hosts", () => {
  const coded = (code: string, message = "getaddrinfo ENOTFOUND private-host.example") =>
    Object.assign(new Error(message), { code });
  const cases: [unknown, string, string, boolean][] = [
    [coded("ENOTFOUND"), "That domain couldn't be found.", "dns_not_found", false],
    [coded("EAI_AGAIN"), "That domain couldn't be looked up right now.", "dns_failed", false],
    [coded("UND_ERR_HEADERS_TIMEOUT"), "The site took too long to respond.", "timeout", false],
    [Object.assign(new Error("x"), { name: "TimeoutError" }), "The site took too long to respond.", "timeout", false],
    [coded("CERT_HAS_EXPIRED"), "The site's security certificate couldn't be verified.", "tls", true],
    [coded("ERR_TLS_CERT_ALTNAME_INVALID"), "The site's security certificate couldn't be verified.", "tls", true],
    [coded("ECONNRESET"), "The connection to the site failed.", "connection", false],
    // Undici wraps socket errors; the code is found on the cause.
    [new TypeError("fetch failed", { cause: coded("ECONNREFUSED") }), "The connection to the site failed.", "connection", false],
    [new Error("anything private-host.example"), "Import could not complete. Retry from Imports.", "internal", false],
  ];
  for (const [error, message, code, terminal] of cases) {
    const outcome = importOutcome(error, "fetch");
    assert.deepEqual(outcome, { message, code, terminal });
    assert.doesNotMatch(outcome.message, /private-host/);
  }
  // Storage errors never blame the site.
  assert.deepEqual(importOutcome(coded("ECONNRESET"), "upload"), {
    message: "Import could not complete. Retry from Imports.",
    code: "storage",
    terminal: false,
  });
  // Controlled failures keep their message and policy.
  assert.deepEqual(importOutcome(new ImportFailure("Readable article text could not be extracted.", true, "no_article")), {
    message: "Readable article text could not be extracted.",
    code: "no_article",
    terminal: true,
  });
});

test("HTTP statuses are worded neutrally and only transient ones retry", () => {
  for (const status of [401, 403, 404, 410, 451])
    assert.equal(statusFailure(status).terminal, true, String(status));
  for (const status of [408, 429, 500, 502, 503])
    assert.equal(statusFailure(status).terminal, false, String(status));
  for (const status of [401, 403, 404, 429, 503])
    assert.doesNotMatch(statusFailure(status).message, /paywall/i);
  assert.match(statusFailure(403).message, /refused access \(HTTP 403\)/);
  assert.match(statusFailure(401).message, /requires signing in \(HTTP 401\)/);
  assert.equal(statusFailure(503).code, "http_503");
});

test("retry backoff is about 30 seconds, 5 minutes, then 30 minutes", () => {
  assert.equal(MAX_ATTEMPTS, 4);
  assert.deepEqual(
    [1, 2, 3, 4, 5].map(retryDelaySeconds),
    [30, 300, 1800, null, null],
  );
});

// --- Service: logging, mapping and the library cap -------------------------------------------

async function withService(
  prepare: (url: string) => Promise<Prepared>,
  run: (service: Service, owner: Awaited<ReturnType<Service["authenticate"]>>) => Promise<void>,
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
  const owner = await service.authenticate(
    (await service.login("reader@example.test", "test-password")).token,
  );
  try {
    await run(service, owner);
  } finally {
    await db.close();
  }
}

test("each import outcome logs one structured line with no URL, host or message", async () => {
  const failure = Object.assign(new Error("getaddrinfo ENOTFOUND private-host.example"), {
    code: "ENOTFOUND",
  });
  let fail = true;
  await withService(
    async () => {
      if (fail) throw failure;
      return { html: `<p>${prose}</p>`, title: "Story", images: [], missingImages: 0 };
    },
    async (service, owner) => {
      const receipt = await service.save(owner, {
        url: "https://private-host.example/private-path?token=secret-value",
        idempotency_key: randomUUID(),
      });
      const lines = await captureLogs(async () => {
        await service.runOne();
      });
      assert.equal(lines.length, 1);
      assert.match(lines[0], /^Import failed /);
      const fields = JSON.parse(lines[0].slice("Import failed ".length));
      assert.equal(fields.item, receipt.submission_id);
      assert.equal(fields.outcome, "retry");
      assert.equal(fields.code, "dns_not_found");
      assert.equal(fields.errno, "ENOTFOUND");
      assert.equal(fields.error, "Error");
      assert.equal(fields.retry_in_s, 30);
      assert.equal(typeof fields.total_ms, "number");
      assert.doesNotMatch(lines[0], /private-host|private-path|secret-value|getaddrinfo/);
      const state = await service.status(owner, receipt.submission_id!);
      assert.equal(state.status, "queued");
      assert.equal(state.error, "That domain couldn't be found.");
      fail = false;
      await service.db.query("UPDATE jobs SET available_at=now()");
      const success = await captureLogs(async () => {
        await service.runOne();
      });
      assert.equal(success.length, 1);
      assert.match(success[0], /^Import finished /);
      const done = JSON.parse(success[0].slice("Import finished ".length));
      assert.equal(done.outcome, "ready");
      assert.equal(done.attempt, 2);
      assert.equal(typeof done.ms.upload, "number");
      assert.equal(typeof done.ms.publish, "number");
      assert.doesNotMatch(success[0], /private-host|Story/);
    },
  );
});

test("a TLS failure ends the import at once with a short message", async () => {
  await withService(
    async () => {
      throw Object.assign(new Error("certificate has expired"), { code: "CERT_HAS_EXPIRED" });
    },
    async (service, owner) => {
      const receipt = await service.save(owner, {
        url: "https://example.com/expired",
        idempotency_key: randomUUID(),
      });
      await captureLogs(async () => {
        await service.runOne();
      });
      const state = await service.status(owner, receipt.submission_id!);
      assert.equal(state.status, "bookmark");
      assert.equal(state.error, "The site's security certificate couldn't be verified.");
      assert.equal(await service.runOne(), false);
    },
  );
});

test("the library cap ignores archived and trashed items but the queue cap still applies", async () => {
  await withService(
    async () => ({ html: `<p>${prose}</p>`, title: "Story", images: [], missingImages: 0 }),
    async (service, owner) => {
      const fill = (count: number, status: string, extra = "") =>
        service.db.query(
          `INSERT INTO items(id,owner_id,connection_id,idempotency_key,kind,status,title${extra ? ",archived,trashed_at" : ""})
           SELECT gen_random_uuid(),$1,$2,gen_random_uuid()::text,'article',$3,'Filler'${extra}
           FROM generate_series(1,$4::integer)`,
          [owner.owner_id, owner.connection_id, status, count],
        );
      const save = () =>
        service.save(owner, { url: `https://example.com/${randomUUID()}`, idempotency_key: randomUUID() });
      await fill(LIBRARY_LIMIT - 1, "ready");
      // Archived and trashed items don't count.
      await fill(20, "ready", ",true,NULL");
      await fill(20, "ready", ",false,now()");
      assert.equal((await save()).status, "queued");
      await assert.rejects(save, /library or import queue limit/);
      await service.db.query(
        "UPDATE items SET archived=true WHERE id=(SELECT id FROM items WHERE owner_id=$1 AND title='Filler' AND archived=false AND trashed_at IS NULL LIMIT 1)",
        [owner.owner_id],
      );
      assert.equal((await save()).status, "queued");
      await assert.rejects(save, /library or import queue limit/);
      await service.db.query(
        "UPDATE items SET trashed_at=now() WHERE id=(SELECT id FROM items WHERE owner_id=$1 AND title='Filler' AND archived=false AND trashed_at IS NULL LIMIT 1)",
        [owner.owner_id],
      );
      assert.equal((await save()).status, "queued");
      // The queue cap counts every pending import.
      await service.db.query("UPDATE items SET archived=true WHERE owner_id=$1 AND title='Filler'", [
        owner.owner_id,
      ]);
      await fill(QUEUE_LIMIT, "queued", ",true,NULL");
      await assert.rejects(save, /library or import queue limit/);
    },
  );
});

test("unexpected request errors log only the route pattern, error class and code", async () => {
  const db = await openDatabase();
  await migrate(db);
  const service = new Service(db, configuration({ DEV_AUTH: "true", DEV_PASSWORD: "p" }), {
    put: async () => {},
    get: async () => Buffer.alloc(0),
    remove: async () => {},
    purgeOwner: async () => {},
  });
  const app = await buildServer(service);
  app.get("/boom/:token", async () => {
    throw Object.assign(new Error("private detail token=abc"), { code: "EPRIVATE" });
  });
  try {
    let status = 0;
    const lines = await captureLogs(async () => {
      status = (await app.inject({ method: "GET", url: "/boom/capability-value?code=secret" })).statusCode;
    });
    assert.equal(status, 500);
    assert.equal(lines.length, 1);
    assert.deepEqual(JSON.parse(lines[0].slice("Request failed ".length)), {
      method: "GET",
      route: "/boom/:token",
      error: "Error",
      code: "EPRIVATE",
    });
  } finally {
    await app.close();
    await db.close();
  }
});
