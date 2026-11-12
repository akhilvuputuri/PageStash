import { lookup } from "node:dns/promises";
import { pipeline, type Readable } from "node:stream";
import { createBrotliDecompress, createGunzip } from "node:zlib";
import ipaddr from "ipaddr.js";
import { Agent, request } from "undici";
import { ImportFailure, timed, type ImportTrace } from "./import-error.js";

export function publicAddress(address: string): boolean {
  try {
    let value = ipaddr.parse(address);
    if (value.kind() === "ipv6" && (value as ipaddr.IPv6).isIPv4MappedAddress())
      value = (value as ipaddr.IPv6).toIPv4Address();
    return value.range() === "unicast";
  } catch {
    return false;
  }
}

export function normalizedURL(raw: string): string {
  const u = new URL(raw);
  if (!["https:", "http:"].includes(u.protocol) || u.username || u.password)
    throw new Error(
      "Only public HTTP(S) URLs without credentials are accepted.",
    );
  if (u.port && !["80", "443"].includes(u.port))
    throw new Error("Nonstandard ports are not supported.");
  u.hash = "";
  for (const key of [...u.searchParams.keys()])
    if (/^utm_/i.test(key) || ["fbclid", "gclid"].includes(key))
      u.searchParams.delete(key);
  return u.toString();
}

/** Stops reading a response body without crashing the process. Undici reports an abandoned body
 * as an 'error' event; with no listener, Node treats that as an uncaught exception. */
export function discard(body: { on(event: "error", listener: () => void): unknown; destroy(): unknown }) {
  body.on("error", () => {});
  body.destroy();
}

/** An honest product name in the conventional "compatible" form; it impersonates no browser build. */
export const USER_AGENT = "Mozilla/5.0 (compatible; PageStash/1.0; personal read-later)";
export const PAGE_ACCEPT =
  "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5";
export const IMAGE_ACCEPT =
  "image/avif,image/webp,image/png,image/jpeg,image/gif;q=0.9,*/*;q=0.5";

export interface Fetched {
  bytes: Buffer;
  mime: string;
  url: string;
  /** The `charset` parameter of the response's Content-Type, lower-cased, when present. */
  charset?: string;
}
export interface FetchOptions {
  accept?: string;
  /** Time allowed for each hop: DNS, connection, headers and body. */
  hopMs?: number;
  /** Time allowed for the whole fetch, across redirects. */
  totalMs?: number;
  trace?: ImportTrace;
}

const sizeFailure = () =>
  new ImportFailure("Source exceeds the download size limit.", true, "too_large");
const timeoutFailure = () =>
  new ImportFailure("The site took too long to respond.", false, "timeout");

/** A short, neutral explanation of a non-200 response. Nothing here claims a paywall. */
export function statusFailure(status: number): ImportFailure {
  const retryable = status >= 500 || status === 408 || status === 429;
  const code = `http_${status}`;
  if (status === 401)
    return new ImportFailure(`The site requires signing in (HTTP 401). Sign-in pages are not bypassed.`, true, code);
  if (status === 403)
    return new ImportFailure(`The site refused access (HTTP 403). It may require signing in or block automated readers.`, true, code);
  if (status === 404 || status === 410)
    return new ImportFailure(`The page wasn't found (HTTP ${status}).`, true, code);
  if (status === 408)
    return new ImportFailure(`The site took too long to respond (HTTP 408).`, false, code);
  if (status === 429)
    return new ImportFailure(`The site is limiting requests (HTTP 429). It will be tried again later.`, false, code);
  if (status >= 500)
    return new ImportFailure(`The site had a server error (HTTP ${status}). It will be tried again later.`, false, code);
  return new ImportFailure(`The site returned HTTP ${status}.`, !retryable, code);
}

/**
 * Reads a response body, decompressing gzip or Brotli, and stops as soon as either the bytes on
 * the wire or the decompressed bytes exceed `limit`. The decompressed cap is what makes a small
 * compression bomb safe: decompression is streamed and abandoned at the cap.
 */
export async function readBody(
  body: Readable,
  encoding: string | undefined,
  limit: number,
  trace?: ImportTrace,
): Promise<Buffer> {
  const name = (encoding ?? "identity").trim().toLowerCase();
  const decoder =
    name === "gzip" || name === "x-gzip"
      ? createGunzip()
      : name === "br"
        ? createBrotliDecompress()
        : null;
  if (!decoder && name !== "identity" && name !== "") {
    discard(body);
    throw new ImportFailure("The site sent an unsupported compressed response.", true, "bad_encoding");
  }
  if (trace) trace.encoding = decoder ? name : "identity";
  let wire = 0;
  let exceeded = false;
  const counter = async function* (source: AsyncIterable<Buffer>) {
    for await (const chunk of source) {
      wire += chunk.length;
      if (wire > limit) {
        exceeded = true;
        throw sizeFailure();
      }
      yield chunk;
    }
  };
  // pipeline() destroys every stage on the first error, including the response body.
  const output: AsyncIterable<Buffer> & { destroy?: () => void } = decoder
    ? pipeline(body, counter, decoder, () => {})
    : counter(body);
  const chunks: Buffer[] = [];
  let size = 0;
  try {
    for await (const chunk of output) {
      size += chunk.length;
      if (size > limit) {
        exceeded = true;
        throw sizeFailure();
      }
      chunks.push(Buffer.from(chunk));
    }
  } catch (error) {
    output.destroy?.();
    discard(body);
    if (exceeded) throw sizeFailure();
    throw error;
  } finally {
    if (trace) {
      trace.wireBytes = wire;
      trace.bytes = size;
    }
  }
  return Buffer.concat(chunks);
}

/** The lower-cased `charset` parameter of a Content-Type value. */
export function contentTypeCharset(value: unknown): string | undefined {
  const match = /;\s*charset\s*=\s*"?([^";\s]+)"?/i.exec(String(value ?? ""));
  return match?.[1].toLowerCase();
}

export async function safeFetch(
  raw: string,
  limit: number,
  options: FetchOptions = {},
): Promise<Fetched> {
  const { trace } = options;
  const hopMs = options.hopMs ?? 15_000;
  const overall = AbortSignal.timeout(options.totalMs ?? 30_000);
  let url = normalizedURL(raw);
  for (let hop = 0; hop <= 4; hop++) {
    const signal = AbortSignal.any([overall, AbortSignal.timeout(hopMs)]);
    try {
      const target = new URL(url);
      const hostname = target.hostname.replace(/^\[|\]$/g, "");
      const addresses = await timed(trace, "dns", async () =>
        ipaddr.isValid(hostname)
          ? [
              {
                address: hostname,
                family: ipaddr.parse(hostname).kind() === "ipv4" ? 4 : 6,
              },
            ]
          : await abortable(lookup(hostname, { all: true }), signal),
      );
      if (!addresses.length || addresses.some((a) => !publicAddress(a.address)))
        throw new ImportFailure(
          "Destination is not a public internet address.",
          true,
          "not_public",
        );
      // Pin the socket to the address we validated. Re-resolve and re-check every redirect.
      const selected = addresses.find((a) => a.family === 4) ?? addresses[0];
      const dispatcher = new Agent({
        connect: {
          lookup: (_host, options, callback) => {
            if (options.all) callback(null, [selected]);
            else callback(null, selected.address, selected.family);
          },
        },
      });
      try {
        const result = await timed(trace, "fetch", async () => {
          const response = await request(url, {
            dispatcher,
            signal,
            headersTimeout: 10_000,
            bodyTimeout: 10_000,
            headers: {
              "user-agent": USER_AGENT,
              accept: options.accept ?? PAGE_ACCEPT,
              "accept-language": "en-US,en;q=0.9,*;q=0.5",
              "accept-encoding": "gzip, br",
            },
          });
          if (trace) trace.status = response.statusCode;
          if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
            discard(response.body);
            return { redirect: response.headers.location };
          }
          if (response.statusCode !== 200) {
            discard(response.body);
            throw statusFailure(response.statusCode);
          }
          const encoding = response.headers["content-encoding"];
          if (Array.isArray(encoding)) {
            discard(response.body);
            throw new ImportFailure("The site sent an unsupported compressed response.", true, "bad_encoding");
          }
          if (Number(response.headers["content-length"]) > limit) {
            discard(response.body);
            throw sizeFailure();
          }
          const bytes = await readBody(response.body, encoding, limit, trace);
          const contentType = response.headers["content-type"];
          return {
            fetched: {
              bytes,
              mime: String(contentType ?? "")
                .split(";")[0]
                .trim()
                .toLowerCase(),
              charset: contentTypeCharset(contentType),
              url,
            } satisfies Fetched,
          };
        });
        if (result.fetched) return result.fetched;
        url = await timed(trace, "redirect", async () => {
          const location = result.redirect;
          if (!location || Array.isArray(location))
            throw new ImportFailure("The site sent an invalid redirect.", true, "redirect_invalid");
          if (trace) trace.redirects = (trace.redirects ?? 0) + 1;
          try {
            return normalizedURL(new URL(location, url).toString());
          } catch {
            throw new ImportFailure(
              "The site redirected to an address that isn't a public web page.",
              true,
              "redirect_invalid",
            );
          }
        });
      } finally {
        await dispatcher.destroy();
      }
    } catch (error) {
      if (signal.aborted && !(error instanceof ImportFailure && error.code !== "timeout"))
        throw timeoutFailure();
      throw error;
    }
  }
  throw new ImportFailure("The site redirected too many times.", true, "too_many_redirects");
}

/** DNS lookups take no signal; this stops waiting for one when the hop's time is up. */
function abortable<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(timeoutFailure());
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(timeoutFailure());
    signal.addEventListener("abort", onAbort, { once: true });
    work.then(
      (value) => {
        signal.removeEventListener("abort", onAbort);
        resolve(value);
      },
      (error) => {
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}
