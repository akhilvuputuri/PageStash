/**
 * Runs the DOM half of extraction (extract-dom.ts) in a `node:worker_threads` Worker with a heap
 * limit and a wall-clock deadline, so a hostile or pathological page can neither exhaust the
 * process's memory nor block its event loop (health checks, API requests).
 *
 * Why the tag cap is not enough: TAG_LIMIT counts `<` tokens, not parsed nodes. The HTML parser's
 * adoption-agency algorithm re-creates open formatting elements, so `<p>` + N distinct `<b>` +
 * `</p>` followed by M `<p>x</p>` builds about N×M elements from N+3M tags (measured on main: 5.3 KB
 * of HTML, 90,604 elements, 454 MB RSS). And Readability is roughly quadratic on many empty
 * paragraphs (19,900 took 211 s). The worker's limits below are the real bound on both.
 */
import { Worker } from "node:worker_threads";
import { ImportFailure, errorCode } from "./import-error.js";
import type { ParsedArticle } from "./extract-dom.js";

/**
 * V8 old-generation heap for the worker, in MB. Measured on 13 November 2026 (Node 22, macOS; see
 * docs/VALIDATION.md): the server modules idle near 131 MB RSS; with this limit the whole process
 * peaked at 326–375 MB while hostile pages were stopped, against 410–416 MB at 256 MB, which leaves
 * too little of a 512 MB container for requests and image transcoding. It admits synthetic articles
 * of 7,500 elements and 540 KB of text, far longer than real articles; bigger ones fail as
 * `too_complex` instead of risking the whole process.
 */
export const EXTRACT_HEAP_MB = 192;
/** Young-generation (scavenger) space for the worker, in MB; V8's default is larger than needed. */
const EXTRACT_YOUNG_MB = 16;
/**
 * Wall-clock time for one page's parse, Readability and sanitising, including worker start-up and
 * loading jsdom (about 400 ms locally). Ordinary articles finish in under a second and the largest
 * synthetic legitimate pages took 1–3 s locally, so this leaves about ten-fold headroom for a smaller
 * CPU, well inside the 10-minute job lease with the 30 s page fetch and 120 s image budgets.
 */
export const EXTRACT_DEADLINE_MS = 30_000;

export interface SandboxOptions {
  deadlineMs?: number;
  heapMb?: number;
  /** Tests only: a different worker script, for example one that does not exist. */
  workerUrl?: URL;
}

export type WorkerRequest =
  | { kind: "article"; html: string; url: string }
  /** An agent's Markdown brief (up to 200,000 characters), rendered and sanitised. */
  | { kind: "brief"; markdown: string };
export type WorkerReply =
  | { ok: true; article?: ParsedArticle; html?: string }
  | { ok: false; failure: { message: string; terminal: boolean; code: string } }
  | { ok: false; error: { name?: string; code?: string } };

/** Under the test runner and `npm run dev` this module is TypeScript source; in production, `dist/*.js`. */
const defaultWorkerUrl = new URL(
  import.meta.url.endsWith(".ts") ? "./extract-worker.ts" : "./extract-worker.js",
  import.meta.url,
);

/** Our own failure to run the worker, not the page's fault: retryable like any internal error. */
export class ExtractWorkerError extends Error {
  constructor(public code: string, name?: string) {
    super("The extraction worker failed.");
    this.name = name ?? "ExtractWorkerError";
  }
}

export const tooComplex = () =>
  new ImportFailure(
    "This content is too complex to process. It would need more memory than PageStash allows.",
    true,
    "too_complex",
  );
export const extractTimeout = () =>
  new ImportFailure(
    "This content took too long to process and was stopped.",
    true,
    "extract_timeout",
  );

/** The page's readable article, parsed in a fresh worker. */
export async function parseInWorker(
  html: string,
  url: string,
  options: SandboxOptions = {},
): Promise<ParsedArticle> {
  return (await runInWorker({ kind: "article", html, url }, options)).article!;
}

/**
 * A brief's sanitised HTML, rendered in a fresh worker. Measured on the main thread before this:
 * 200,000 newlines (allowed by the API) took 14 s and 1.9 GB of RSS.
 */
export async function briefInWorker(
  markdown: string,
  options: SandboxOptions = {},
): Promise<string> {
  return (await runInWorker({ kind: "brief", markdown }, options)).html!;
}

function runInWorker(
  request: WorkerRequest,
  options: SandboxOptions,
): Promise<Extract<WorkerReply, { ok: true }>> {
  const deadlineMs = options.deadlineMs ?? EXTRACT_DEADLINE_MS;
  return new Promise((resolve, reject) => {
    let worker: Worker;
    try {
      worker = new Worker(options.workerUrl ?? defaultWorkerUrl, {
        workerData: request,
        // The worker inherits the parent's flags, which is how it gets tsx's loader under the test
        // runner. `--input-type` (from `node -e`) is the one inherited flag that stops a worker
        // script from loading; production starts with `node dist/main.js` and has no flags.
        execArgv: process.execArgv.filter((flag) => !flag.startsWith("--input-type")),
        resourceLimits: {
          maxOldGenerationSizeMb: options.heapMb ?? EXTRACT_HEAP_MB,
          maxYoungGenerationSizeMb: EXTRACT_YOUNG_MB,
        },
      });
    } catch (error) {
      reject(new ExtractWorkerError(errorCode(error) ?? "EXTRACT_WORKER_START"));
      return;
    }
    let settled = false;
    const finish = (outcome: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      outcome();
      // Stops a worker still running (deadline) and frees its isolate; a no-op once it has exited.
      void worker.terminate().catch(() => {});
    };
    const timer = setTimeout(() => finish(() => reject(extractTimeout())), deadlineMs);
    worker.once("message", (reply: WorkerReply) =>
      finish(() => {
        if (reply.ok) resolve(reply);
        else if ("failure" in reply)
          reject(new ImportFailure(reply.failure.message, reply.failure.terminal, reply.failure.code));
        else reject(new ExtractWorkerError(reply.error.code ?? "EXTRACT_ERROR", reply.error.name));
      }),
    );
    // Hitting `resourceLimits` ends the worker with ERR_WORKER_OUT_OF_MEMORY. Any other error here
    // (a script that fails to load, an uncaught error) is ours, so it carries only a code. `on`, not
    // `once`: an unhandled second "error" event would throw in this process.
    worker.on("error", (error) =>
      finish(() =>
        reject(
          errorCode(error) === "ERR_WORKER_OUT_OF_MEMORY"
            ? tooComplex()
            : new ExtractWorkerError(errorCode(error) ?? "EXTRACT_WORKER_ERROR"),
        ),
      ),
    );
    worker.once("exit", () => finish(() => reject(new ExtractWorkerError("EXTRACT_WORKER_EXIT"))));
  });
}
