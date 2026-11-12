// Only controlled explanations from this class are exposed in import receipts.
export class ImportFailure extends Error {
  constructor(
    message: string,
    public terminal = true,
    /** A short fixed code for logs, never shown to the app. */
    public code = "rejected",
  ) {
    super(message);
    this.name = "ImportFailure";
  }
}

/** Where an import was when it finished or failed. */
export type ImportStage =
  | "dns"
  | "fetch"
  | "redirect"
  | "extract"
  | "images"
  | "upload"
  | "publish";

/**
 * Numbers about one import, filled in as it runs and logged once at the end. It holds no URL,
 * header, body text or error message, so the whole object is safe to log.
 */
export interface ImportTrace {
  stage: ImportStage;
  ms: Partial<Record<ImportStage, number>>;
  /** HTTP status of the last page response. */
  status?: number;
  /** Bytes received on the wire for the page, and after decompression. */
  wireBytes?: number;
  bytes?: number;
  encoding?: string;
  charset?: string;
  redirects?: number;
  elements?: number;
  images?: { found: number; saved: number; missing: number };
}

export const newTrace = (): ImportTrace => ({ stage: "fetch", ms: {} });

/** Runs `work` as `stage`, adding its elapsed milliseconds to the trace. */
export async function timed<T>(
  trace: ImportTrace | undefined,
  stage: ImportStage,
  work: () => Promise<T>,
): Promise<T> {
  if (!trace) return work();
  trace.stage = stage;
  const start = performance.now();
  try {
    return await work();
  } finally {
    trace.ms[stage] = Math.round(
      (trace.ms[stage] ?? 0) + performance.now() - start,
    );
  }
}

const generic = "Import could not complete. Retry from Imports.";

const timeoutCodes = new Set([
  "UND_ERR_HEADERS_TIMEOUT",
  "UND_ERR_BODY_TIMEOUT",
  "UND_ERR_CONNECT_TIMEOUT",
  "ETIMEDOUT",
  "ESOCKETTIMEDOUT",
]);
const missingDomainCodes = new Set(["ENOTFOUND", "EAI_NONAME", "ENODATA"]);
const lookupCodes = new Set(["EAI_AGAIN", "EAI_FAIL", "ESERVFAIL"]);
const connectionCodes = new Set([
  "ECONNRESET",
  "ECONNREFUSED",
  "ECONNABORTED",
  "EPIPE",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "EHOSTDOWN",
  "UND_ERR_SOCKET",
  "UND_ERR_CLOSED",
]);
const tlsCodes = new Set([
  "CERT_HAS_EXPIRED",
  "CERT_NOT_YET_VALID",
  "CERT_REVOKED",
  "CERT_UNTRUSTED",
  "DEPTH_ZERO_SELF_SIGNED_CERT",
  "SELF_SIGNED_CERT_IN_CHAIN",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
  "UNABLE_TO_GET_ISSUER_CERT",
  "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
  "ERR_TLS_CERT_ALTNAME_INVALID",
  "HOSTNAME_MISMATCH",
]);
const decodeCodes = new Set([
  "Z_DATA_ERROR",
  "Z_BUF_ERROR",
  "ERR_BROTLI_DECOMPRESSION_FAILED",
]);

/** The first well-formed `code` on the error or its causes, for example `ECONNRESET`. */
export function errorCode(error: unknown): string | undefined {
  let current = error as { code?: unknown; cause?: unknown } | undefined;
  for (let depth = 0; current && depth < 4; depth++) {
    if (typeof current.code === "string" && /^[A-Za-z0-9_]{1,48}$/.test(current.code))
      return current.code;
    current = current.cause as typeof current;
  }
  return undefined;
}

/** The error's class name, when it is a plain identifier. Never the message. */
export function errorName(error: unknown): string | undefined {
  const name = (error as { name?: unknown } | undefined)?.name;
  return typeof name === "string" && /^[A-Za-z0-9_]{1,48}$/.test(name)
    ? name
    : undefined;
}

export interface ImportOutcome {
  /** The text stored in the item's existing `error` field. */
  message: string;
  /** A fixed short category for logs. */
  code: string;
  /** False when trying again later could succeed. */
  terminal: boolean;
}

/**
 * Maps any import error to a short message the app can show and whether to retry. Messages of
 * arbitrary errors can quote the URL or host (`getaddrinfo ENOTFOUND host`), so they are never used.
 */
export function importOutcome(
  error: unknown,
  stage: ImportStage = "fetch",
): ImportOutcome {
  if (error instanceof ImportFailure)
    return {
      message: error.message.slice(0, 240),
      code: error.code,
      terminal: error.terminal,
    };
  // Storage and database errors happen after the source was read: they never blame the site.
  if (!["dns", "fetch", "redirect"].includes(stage))
    return {
      message: generic,
      code: stage === "upload" || stage === "publish" ? "storage" : "internal",
      terminal: false,
    };
  const code = errorCode(error) ?? "";
  const name = errorName(error) ?? "";
  if (timeoutCodes.has(code) || name === "TimeoutError" || name === "AbortError")
    return { message: "The site took too long to respond.", code: "timeout", terminal: false };
  if (missingDomainCodes.has(code))
    return { message: "That domain couldn't be found.", code: "dns_not_found", terminal: false };
  if (lookupCodes.has(code))
    return { message: "That domain couldn't be looked up right now.", code: "dns_failed", terminal: false };
  if (tlsCodes.has(code) || code.startsWith("ERR_SSL_") || code.startsWith("ERR_TLS_"))
    return {
      message: "The site's security certificate couldn't be verified.",
      code: "tls",
      terminal: true,
    };
  if (connectionCodes.has(code))
    return { message: "The connection to the site failed.", code: "connection", terminal: false };
  // Brotli reports decoder errors as ERR__ERROR_FORMAT_*, ERR__ERROR_DICTIONARY_* and so on.
  if (
    decodeCodes.has(code) ||
    code.startsWith("ERR_ZLIB") ||
    code.startsWith("ERR_BROTLI") ||
    code.startsWith("ERR__ERROR_")
  )
    return {
      message: "The site sent a response that couldn't be decoded.",
      code: "bad_encoding",
      terminal: false,
    };
  return { message: generic, code: "internal", terminal: false };
}
