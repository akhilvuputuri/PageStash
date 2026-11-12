/**
 * Worker-thread entry for one extraction (started by extract-sandbox.ts, one worker per page).
 * Receives decoded page HTML and its URL (or a brief's Markdown) and posts back plain data. It never
 * fetches anything.
 */
import { parentPort, workerData } from "node:worker_threads";
import { briefDocument, parseArticle } from "./extract-dom.js";
import { ImportFailure, errorCode, errorName } from "./import-error.js";
import type { WorkerReply, WorkerRequest } from "./extract-sandbox.js";

const request = workerData as WorkerRequest;
let reply: WorkerReply;
try {
  reply =
    request.kind === "article"
      ? { ok: true, article: await parseArticle(request.html, request.url) }
      : { ok: true, html: briefDocument(request.markdown) };
} catch (error) {
  reply =
    error instanceof ImportFailure
      ? { ok: false, failure: { message: error.message, terminal: error.terminal, code: error.code } }
      : // Only the class name and code cross back: messages could quote the page.
        { ok: false, error: { name: errorName(error), code: errorCode(error) } };
}
parentPort!.postMessage(reply);
