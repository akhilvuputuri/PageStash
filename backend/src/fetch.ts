import { lookup } from "node:dns/promises";
import ipaddr from "ipaddr.js";
import { Agent, request } from "undici";
import { ImportFailure } from "./import-error.js";

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

export interface Fetched {
  bytes: Buffer;
  mime: string;
  url: string;
}
export async function safeFetch(raw: string, limit: number): Promise<Fetched> {
  let url = normalizedURL(raw);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15_000);
  try {
    for (let hop = 0; hop <= 4; hop++) {
      const target = new URL(url);
      const hostname = target.hostname.replace(/^\[|\]$/g, "");
      const addresses = ipaddr.isValid(hostname)
        ? [
            {
              address: hostname,
              family: ipaddr.parse(hostname).kind() === "ipv4" ? 4 : 6,
            },
          ]
        : await lookup(hostname, { all: true });
      if (!addresses.length || addresses.some((a) => !publicAddress(a.address)))
        throw new ImportFailure(
          "Destination is not a public internet address.",
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
        const response = await request(url, {
          dispatcher,
          signal: controller.signal,
          headersTimeout: 10_000,
          bodyTimeout: 10_000,
          headers: {
            "user-agent": "OfflineReader/0.1 (personal article capture)",
            "accept-encoding": "identity",
          },
        });
        if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
          const location = response.headers.location;
          discard(response.body);
          if (!location || Array.isArray(location))
            throw new ImportFailure("Invalid redirect.");
          url = normalizedURL(new URL(location, url).toString());
          continue;
        }
        if (response.statusCode !== 200) {
          discard(response.body);
          throw new ImportFailure(
            `Source returned HTTP ${response.statusCode}; authentication and paywalls are not bypassed.`,
            response.statusCode < 500 &&
              ![408, 429].includes(response.statusCode),
          );
        }
        if (
          response.headers["content-encoding"] &&
          response.headers["content-encoding"] !== "identity"
        ) {
          discard(response.body);
          throw new ImportFailure("Unsupported compressed response.");
        }
        if (Number(response.headers["content-length"]) > limit) {
          discard(response.body);
          throw new ImportFailure("Source exceeds the download size limit.");
        }
        const chunks: Buffer[] = [];
        let size = 0;
        for await (const chunk of response.body) {
          size += chunk.length;
          if (size > limit) {
            discard(response.body);
            throw new ImportFailure("Source exceeds the download size limit.");
          }
          chunks.push(Buffer.from(chunk));
        }
        return {
          bytes: Buffer.concat(chunks),
          mime: String(response.headers["content-type"] ?? "")
            .split(";")[0]
            .trim()
            .toLowerCase(),
          url,
        };
      } finally {
        await dispatcher.destroy();
      }
    }
    throw new ImportFailure("Too many redirects.");
  } finally {
    clearTimeout(timer);
  }
}
