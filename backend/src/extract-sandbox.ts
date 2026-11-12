/**
 * Runs the DOM half of extraction (extract-dom.ts) in a child Node process with a heap limit and a
 * wall-clock deadline, so a hostile or pathological page can neither exhaust this process's memory
 * nor block its event loop (health checks, API requests).
 *
 * Why the tag cap is not enough: TAG_LIMIT counts `<` tokens, not parsed nodes. The HTML parser's
 * adoption-agency algorithm re-creates open formatting elements, so `<p>` + N distinct `<b>` +
 * `</p>` followed by M `<p>x</p>` builds about N×M elements from N+3M tags (measured on main: 5.3 KB
 * of HTML, 90,604 elements, 454 MB RSS). And Readability is roughly quadratic on many empty
 * paragraphs (19,900 took 211 s). The child's limits below are the real bound on both.
 *
 * Why a process, not a worker thread: V8 does not always turn running out of heap in a worker
 * thread into a worker error. A 110 KB page of amplified attributes ended the whole process with
 * "FATAL ERROR: Reached heap limit" (exit 134) from inside a worker; a child process dying cannot.
 */
import { fork, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { tooComplex, type ParsedArticle } from "./extract-dom.js";
import { ImportFailure, errorCode } from "./import-error.js";

export { tooComplex };

/**
 * V8 old-generation heap for the child, in MB (`--max-old-space-size`). See EXTRACT_HEAP_MB's
 * measurements in docs/VALIDATION.md (13 November 2026, review follow-up).
 */
export const EXTRACT_HEAP_MB = 192;
/**
 * Wall-clock time for one page's parse, Readability and sanitising, including starting the child
 * and loading jsdom in it (about 0.5 s locally). Ordinary articles finish in under a second and the
 * largest legitimate pages measured took a few seconds, so this leaves about ten-fold headroom for
 * a smaller CPU, well inside the 10-minute job lease next to the 30 s fetch and 120 s image budgets.
 */
export const EXTRACT_DEADLINE_MS = 30_000;
/**
 * Largest reply the child sends, in JSON characters. Replies are bounded by the parsed-size check
 * (8 M characters) and are normally far smaller than the page; anything bigger fails as too_complex.
 */
export const REPLY_LIMIT = 16 * 1024 * 1024;

export interface SandboxOptions {
  deadlineMs?: number;
  heapMb?: number;
  /** Stops the child early, for example at shutdown. The import is then retried later. */
  signal?: AbortSignal;
  /** Tests only: a different child script, for example one that does not exist. */
  childUrl?: URL;
}

export type SandboxRequest = { deadlineMs: number } & (
  | { kind: "article"; html: string; url: string }
  /** An agent's Markdown brief (up to 200,000 characters), rendered and sanitised. */
  | { kind: "brief"; markdown: string }
);
export type SandboxReply =
  | { ok: true; article?: ParsedArticle; html?: string }
  | { ok: false; failure: { message: string; terminal: boolean; code: string } }
  | { ok: false; error: { name?: string; code?: string } };

/** Under the test runner and `npm run dev` this module is TypeScript source; in production, `dist/*.js`. */
const defaultChildUrl = new URL(
  import.meta.url.endsWith(".ts") ? "./extract-child.ts" : "./extract-child.js",
  import.meta.url,
);

/** Our own failure to run the child, not the page's fault: retryable like any internal error. */
export class ExtractProcessError extends Error {
  constructor(public code: string, name?: string) {
    super("The extraction process failed.");
    this.name = name ?? "ExtractProcessError";
  }
}

export const extractTimeout = () =>
  new ImportFailure(
    "This content took too long to process and was stopped.",
    true,
    "extract_timeout",
  );

/**
 * Node flags the child inherits: only module loaders (how it gets tsx's loader under the test
 * runner, tsx's CLI and `npm run dev`). Never `-e`/`--eval`, `--input-type` or heap flags of the
 * parent. Production starts with `node dist/main.js`, so the list is empty there.
 */
export function childFlags(parent: string[], heapMb: number): string[] {
  const kept: string[] = [];
  const loader = /^(?:--import|--require|-r|--loader|--experimental-loader|--conditions|-C)(=|$)/;
  for (let i = 0; i < parent.length; i++) {
    const match = loader.exec(parent[i]);
    if (!match) continue;
    kept.push(parent[i]);
    if (!match[1] && i + 1 < parent.length) kept.push(parent[++i]);
  }
  return [...kept, `--max-old-space-size=${heapMb}`];
}

/**
 * The child's whole environment. It needs no database, storage, provider or OAuth settings, so
 * none of the parent's secrets are passed: only NODE_ENV, and TMPDIR for tsx's transform cache.
 */
function childEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const name of ["NODE_ENV", "TMPDIR"])
    if (process.env[name] !== undefined) env[name] = process.env[name];
  return env;
}

/** Extraction children still running; tests use it to check that none are left behind. */
export const runningExtractions = () => live.size;

/** Children still running, killed if this process exits first. */
const live = new Set<ChildProcess>();
let exitHook = false;
function track(child: ChildProcess) {
  if (!exitHook) {
    exitHook = true;
    process.once("exit", () => {
      for (const running of live) running.kill("SIGKILL");
    });
  }
  live.add(child);
  child.once("exit", () => live.delete(child));
}

/** The page's readable article, parsed in a fresh child process. */
export async function parseInSandbox(
  html: string,
  url: string,
  options: SandboxOptions = {},
): Promise<ParsedArticle> {
  const deadlineMs = options.deadlineMs ?? EXTRACT_DEADLINE_MS;
  return (await runInChild({ kind: "article", html, url, deadlineMs }, options)).article!;
}

/**
 * A brief's sanitised HTML, rendered in a fresh child process. Measured on the main thread before this:
 * 200,000 newlines (allowed by the API) took 14 s and 1.9 GB of RSS.
 */
export async function briefInSandbox(
  markdown: string,
  options: SandboxOptions = {},
): Promise<string> {
  const deadlineMs = options.deadlineMs ?? EXTRACT_DEADLINE_MS;
  return (await runInChild({ kind: "brief", markdown, deadlineMs }, options)).html!;
}

function runInChild(
  request: SandboxRequest,
  options: SandboxOptions,
): Promise<Extract<SandboxReply, { ok: true }>> {
  return new Promise((resolve, reject) => {
    if (options.signal?.aborted) {
      reject(new ExtractProcessError("EXTRACT_ABORTED"));
      return;
    }
    let child: ChildProcess;
    try {
      child = fork(fileURLToPath(options.childUrl ?? defaultChildUrl), [], {
        execArgv: childFlags(process.execArgv, options.heapMb ?? EXTRACT_HEAP_MB),
        env: childEnv(),
        // No stdout or stderr: nothing the page causes can reach the logs. Results come over IPC.
        stdio: ["ignore", "ignore", "ignore", "ipc"],
        serialization: "json",
      });
    } catch (error) {
      reject(new ExtractProcessError(errorCode(error) ?? "EXTRACT_CHILD_START"));
      return;
    }
    track(child);
    let ready = false;
    let settled = false;
    const finish = (outcome: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      options.signal?.removeEventListener("abort", abort);
      outcome();
      // Always: a no-op once it has exited; otherwise it stops a child still running.
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    };
    const abort = () => finish(() => reject(new ExtractProcessError("EXTRACT_ABORTED")));
    options.signal?.addEventListener("abort", abort, { once: true });
    // A child that never became ready says nothing about the page (a slow or overloaded host), so
    // that is a retryable start failure, not a timeout of the page's own work.
    const timer = setTimeout(
      () =>
        finish(() =>
          reject(ready ? extractTimeout() : new ExtractProcessError("EXTRACT_CHILD_START")),
        ),
      request.deadlineMs,
    );
    child.on("message", (message: { ready?: true } | SandboxReply) => {
      if (!ready) {
        if (!(message as { ready?: true }).ready) return;
        ready = true;
        child.send(request, (error) => {
          if (error) finish(() => reject(new ExtractProcessError(errorCode(error) ?? "EXTRACT_SEND")));
        });
        return;
      }
      const reply = message as SandboxReply;
      finish(() => {
        if (reply.ok) resolve(reply);
        else if ("failure" in reply)
          reject(new ImportFailure(reply.failure.message, reply.failure.terminal, reply.failure.code));
        else reject(new ExtractProcessError(reply.error.code ?? "EXTRACT_ERROR", reply.error.name));
      });
    });
    // Spawn failures (for example a missing Node binary). Errors after the child is running end in
    // "exit", which decides the outcome.
    child.on("error", (error) => {
      if (!ready) finish(() => reject(new ExtractProcessError(errorCode(error) ?? "EXTRACT_CHILD_START")));
    });
    child.once("exit", (code, signal) =>
      finish(() =>
        reject(
          !ready
            ? // It never loaded its modules: our deployment, not the page. Retryable.
              new ExtractProcessError("EXTRACT_CHILD_START")
            : code !== 0 || signal
              ? // Killed by V8's heap limit (exit 134), a signal or any crash while on this page.
                tooComplex()
              : new ExtractProcessError("EXTRACT_CHILD_EXIT"),
        ),
      ),
    );
  });
}
