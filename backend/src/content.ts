import sharp from "sharp";
import { randomUUID } from "node:crypto";
import { IMAGE_ACCEPT, safeFetch, type Fetched, type FetchOptions } from "./fetch.js";
import { ImportFailure, timed, type ImportTrace } from "./import-error.js";
import {
  ELEMENT_LIMIT,
  briefDocument,
  elementFailure,
  escapeHTML,
  languageTag,
  markdownDocument,
  sanitize,
} from "./extract-dom.js";
import { parseInSandbox, type SandboxOptions } from "./extract-sandbox.js";

// The DOM helpers moved to extract-dom.ts (safe to load in the extraction child); these names stay importable from here.
export { ELEMENT_LIMIT, briefDocument, escapeHTML, languageTag, markdownDocument, sanitize };
export interface Prepared {
  html: string;
  title: string;
  author?: string;
  siteName?: string;
  /** BCP 47 language of the source page, so the reader can hyphenate correctly. */
  lang?: string;
  /** Text direction from the source page, so right-to-left articles render correctly. */
  dir?: "rtl" | "ltr";
  missingImages: number;
  images: { id: string; bytes: Buffer }[];
}
export type Fetcher = (
  url: string,
  limit: number,
  options?: FetchOptions,
) => Promise<Fetched>;

/**
 * Every `<` followed by a letter, counted without any context, so no comment, attribute or raw-text
 * trick can hide markup from it. It bounds tag tokens, not parsed nodes: the parser can build far
 * more elements than tags (adoption-agency re-creation of formatting elements builds about N×M
 * from N+3M tags). It is a cheap early rejection of large pages, not the memory bound; the
 * extraction child process's heap limit and deadline (extract-sandbox.ts) are. Measured on 13 November
 * 2026, a parsed page plus Readability's copy cost about 4.5 KB of RSS per element (20,000 elements
 * +93 MB, 50,000 +229 MB, 100,000 +460 MB).
 */
export const TAG_LIMIT = 40_000;
/** Time for all of an article's images; any left over are marked unavailable. */
const IMAGE_BUDGET_MS = 120_000;

/** WHATWG labels for UTF-16 can't describe an ASCII-compatible `<meta>`; browsers use UTF-8. */
function usableCharset(label: string | undefined): string | undefined {
  if (!label) return undefined;
  try {
    const encoding = new TextDecoder(label.trim()).encoding;
    return encoding.startsWith("utf-16") ? "utf-8" : encoding;
  } catch {
    return undefined;
  }
}

/**
 * Picks the page's character encoding the way a browser would, in order: a byte-order mark, the
 * Content-Type charset, a `<meta charset>` or `http-equiv` declaration in the first 4 KB, else UTF-8.
 */
export function pageCharset(bytes: Buffer, headerCharset?: string): string {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return "utf-8";
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return "utf-16be";
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return "utf-16le";
  const declared = usableCharset(headerCharset);
  if (declared) return declared;
  const head = bytes.subarray(0, 4096).toString("latin1");
  for (const tag of head.match(/<meta\b[^>]*>/gi) ?? []) {
    const value = /charset\s*=\s*["']?\s*([A-Za-z0-9._:-]+)/i.exec(tag)?.[1];
    const meta = usableCharset(value);
    if (meta) return meta;
  }
  return "utf-8";
}

/** Decodes page bytes without throwing; invalid sequences become U+FFFD. */
export function decodePage(bytes: Buffer, headerCharset?: string): string {
  const charset = pageCharset(bytes, headerCharset);
  // The decoder strips a byte-order mark that matches its encoding.
  return new TextDecoder(charset, { fatal: false }).decode(bytes);
}

const isLetter = (code: number) =>
  (code >= 97 && code <= 122) || (code >= 65 && code <= 90);
const isNameChar = (code: number) =>
  isLetter(code) || (code >= 48 && code <= 57) || code === 45 || code === 58;

/**
 * Counts tags with a linear hand scanner (no regular expression can backtrack on input without
 * `>`). `tags` counts every `<letter` anywhere, context-free. `elements` approximates the elements
 * a parser would build outside `<svg>`: it skips comments, quoted attribute values, and the text of
 * `<script>` and `<style>` outside SVG (inside SVG they are ordinary elements).
 */
export function elementCounts(html: string): { elements: number; tags: number } {
  let tags = 0;
  for (let i = html.indexOf("<"); i >= 0; i = html.indexOf("<", i + 1))
    if (isLetter(html.charCodeAt(i + 1)) && ++tags > TAG_LIMIT) break;
  const lower = html.toLowerCase();
  let elements = 0;
  let svgDepth = 0;
  let i = 0;
  scan: while (elements <= ELEMENT_LIMIT) {
    const open = lower.indexOf("<", i);
    if (open < 0) break;
    if (lower.startsWith("<!--", open)) {
      // "<!-->" and "<!--->" are complete (empty) comments to an HTML parser.
      const abrupt = lower.startsWith("<!-->", open) ? 5 : lower.startsWith("<!--->", open) ? 6 : 0;
      if (abrupt) {
        i = open + abrupt;
        continue;
      }
      const close = lower.indexOf("-->", open + 4);
      if (close < 0) break;
      i = close + 3;
      continue;
    }
    const closing = lower.charCodeAt(open + 1) === 47; // "/"
    let j = open + (closing ? 2 : 1);
    if (!isLetter(lower.charCodeAt(j))) {
      i = open + 1;
      continue;
    }
    const nameStart = j;
    while (j < lower.length && isNameChar(lower.charCodeAt(j))) j++;
    const name = lower.slice(nameStart, j);
    // Find the end of the tag, skipping quoted attribute values; every character is read once.
    let previous = 0;
    for (;;) {
      if (j >= lower.length) break scan;
      const code = lower.charCodeAt(j);
      if (code === 62) break; // ">"
      if ((code === 34 || code === 39) && previous === 61) {
        const quote = lower.indexOf(code === 34 ? '"' : "'", j + 1);
        if (quote < 0) break scan;
        j = quote + 1;
        previous = 0;
        continue;
      }
      if (code !== 32 && code !== 9 && code !== 10 && code !== 12 && code !== 13) previous = code;
      j++;
    }
    const selfClosing = lower.charCodeAt(j - 1) === 47;
    i = j + 1;
    if (closing) {
      if (name === "svg" && svgDepth > 0) svgDepth--;
      continue;
    }
    if (svgDepth > 0) {
      if (name === "svg" && !selfClosing) svgDepth++;
      continue;
    }
    elements++;
    if (name === "svg" && !selfClosing) svgDepth++;
    else if (name === "script" || name === "style") {
      const end = lower.indexOf(`</${name}`, i);
      if (end < 0) break; // The rest of the page is that element's text.
      i = end;
    }
  }
  return { elements, tags };
}

export async function extract(
  url: string,
  fetcher: Fetcher = safeFetch,
  trace?: ImportTrace,
  sandbox?: SandboxOptions,
): Promise<Prepared> {
  // Fetching stays on this thread, behind safeFetch's address checks; only the decoded HTML string
  // goes to the extraction child process, and only plain data comes back.
  const page = await fetcher(url, 3 * 1024 * 1024, { trace });
  const article = await timed(trace, "extract", async () => {
    if (!["text/html", "application/xhtml+xml"].includes(page.mime))
      throw new ImportFailure("This source is not an HTML article.", true, "not_html");
    const charset = pageCharset(page.bytes, page.charset);
    if (trace) trace.charset = charset;
    const html = decodePage(page.bytes, page.charset);
    // Cheap linear pre-checks here, so obviously oversized pages never start a child process.
    const counts = elementCounts(html);
    if (trace) trace.elements = counts.elements;
    if (counts.elements > ELEMENT_LIMIT || counts.tags > TAG_LIMIT) throw elementFailure();
    return parseInSandbox(html, page.url, sandbox);
  });
  const images: Prepared["images"] = [];
  let missingImages = 0;
  const pieces: string[] = [];
  await timed(trace, "images", async () => {
    let total = 0;
    const deadline = Date.now() + IMAGE_BUDGET_MS;
    for (const [index, img] of article.images.entries()) {
      try {
        if (index >= 20) throw new Error("Image count limit");
        if (Date.now() > deadline) throw new Error("Image time limit");
        const raw = img.src;
        if (!raw) throw new Error("Image unavailable");
        const image = await fetcher(
          new URL(raw, page.url).toString(),
          5 * 1024 * 1024,
          { accept: IMAGE_ACCEPT, hopMs: 10_000, totalMs: 15_000 },
        );
        if (
          ![
            "image/jpeg",
            "image/png",
            "image/webp",
            "image/gif",
            "image/avif",
          ].includes(image.mime)
        )
          throw new Error("Unsupported image");
        total += image.bytes.length;
        if (total > 25 * 1024 * 1024) throw new Error("Image byte limit");
        const bytes = await sharp(image.bytes, { limitInputPixels: 20_000_000 })
          .resize({ width: 1800, withoutEnlargement: true })
          .webp({ quality: 82 })
          .toBuffer();
        const id = randomUUID();
        images.push({ id, bytes });
        pieces.push(img.saved.split(article.slot).join(`${id}.webp`));
      } catch {
        missingImages++;
        pieces.push(img.missing);
      }
    }
  });
  if (trace)
    trace.images = { found: article.images.length, saved: images.length, missing: missingImages };
  return {
    html: article.parts.map((part, i) => (i ? pieces[i - 1] + part : part)).join(""),
    title: article.title || new URL(url).hostname,
    author: article.byline,
    siteName: article.siteName,
    lang: article.lang,
    dir: article.dir,
    images,
    missingImages,
  };
}

export function readerHTML(
  content: string,
  title: string,
  lang?: string,
  dir?: string,
): string {
  const language = languageTag(lang);
  const textDirection = dir === "rtl" || dir === "ltr" ? dir : undefined;
  return `<!doctype html><html${language ? ` lang="${language}"` : ""}${textDirection ? ` dir="${textDirection}"` : ""}><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><title>${escapeHTML(title)}</title><style>:root{color-scheme:light dark}body{font:20px/1.65 Georgia,serif;padding:18px;max-width:720px;margin:auto;overflow-wrap:anywhere}img{max-width:100%;height:auto}pre{overflow:auto}a{color:#4685c5}h1,h2,h3{line-height:1.25}table{display:block;overflow:auto}blockquote{border-inline-start:3px solid #888;padding-inline-start:16px;margin-inline-start:0}</style></head><body>${content}</body></html>`;
}
