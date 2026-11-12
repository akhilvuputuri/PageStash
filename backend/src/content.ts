import { JSDOM } from "jsdom";
import createDOMPurify from "dompurify";
import { Readability } from "@mozilla/readability";
import sharp from "sharp";
import { randomUUID } from "node:crypto";
import { IMAGE_ACCEPT, safeFetch, type Fetched, type FetchOptions } from "./fetch.js";
import { ImportFailure, timed, type ImportTrace } from "./import-error.js";

const purifierWindow = new JSDOM("").window;
const purify = createDOMPurify(purifierWindow);
export function sanitize(html: string): string {
  const clean = purify.sanitize(html, {
    ALLOWED_TAGS: [
      "p",
      "div",
      "section",
      "article",
      "h1",
      "h2",
      "h3",
      "h4",
      "ul",
      "ol",
      "li",
      "blockquote",
      "pre",
      "code",
      "strong",
      "em",
      "b",
      "i",
      "a",
      "br",
      "hr",
      "figure",
      "figcaption",
      "img",
      "table",
      "thead",
      "tbody",
      "tr",
      "th",
      "td",
      "sup",
      "sub",
    ],
    ALLOWED_ATTR: ["href", "src", "alt", "title"],
    ALLOW_DATA_ATTR: false,
  });
  const dom = new JSDOM(clean);
  for (const a of dom.window.document.querySelectorAll("a"))
    if (!/^https?:\/\//i.test(a.getAttribute("href") ?? ""))
      a.removeAttribute("href");
  return dom.window.document.body.innerHTML;
}
export function escapeHTML(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
}

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
function rejectBarrier(document: Document, text: string) {
  const labels = [
    document.title,
    document.querySelector("main h1,article h1,h1")?.textContent ?? "",
  ].map((value) =>
    value
      .replace(/\s+/g, " ")
      .split(/\s+[|—–]\s+/)[0]
      .trim()
      .toLowerCase()
      .replace(/[.!?]+$/, ""),
  );
  const challenge = labels.some((label) =>
    /^(just a moment|checking your browser|verify (?:that )?you are human|security check|attention required)$/.test(
      label,
    ),
  );
  const failure = labels.some(
    (label) =>
      /^(?:error\s*)?(?:40[1348]|50[0234])(?:[ :–-]+(?:error|not found|page not found|forbidden|unauthorized|access denied|service unavailable|internal server error|bad gateway|gateway timeout|request timeout))?$/.test(
        label,
      ) ||
      /^(access denied|request blocked|forbidden|unauthorized|page not found|not found|something went wrong|service unavailable|internal server error|sign in|log in|login)$/.test(
        label,
      ),
  );
  const instruction =
    /verify (?:that )?you are human|enable javascript and cookies|checking your browser|you (?:do not|don't) have permission|sign in to (?:continue|read)|log in to (?:continue|read)|page (?:you requested |could )?(?:was |is )?not (?:be )?found|request (?:has been |was )?blocked|access (?:is |was )denied/i.test(
      text.slice(0, 1500),
    );
  let intro = text.toLowerCase().trim();
  for (const label of labels)
    if (label && intro.startsWith(label))
      intro = intro.slice(label.length).trim();
  const directed =
    /^(?:[.!?:–-]\s*)?(sorry|please|you\b|your\b|the page\b|this page\b|sign in\b|log in\b|verify\b|enable javascript\b|checking your browser\b)/.test(
      intro,
    );
  const challengeMarkup =
    document.querySelector(
      '#challenge-form, #cf-challenge-running, input[name="cf-turnstile-response"]',
    ) ||
    [...document.querySelectorAll("script[src]")].some((script) =>
      script.getAttribute("src")?.includes("/cdn-cgi/challenge-platform/"),
    );
  const password = document.querySelector('input[type="password"]');
  if (
    (challenge && (instruction || challengeMarkup)) ||
    (failure && ((instruction && directed) || text.length < 600 || password))
  ) {
    throw new ImportFailure(
      "The source returned an error, sign-in or access-check page instead of readable article text.",
      true,
      "barrier",
    );
  }
}

export type Fetcher = (
  url: string,
  limit: number,
  options?: FetchOptions,
) => Promise<Fetched>;

/** Readable elements allowed in a page, and SVG drawing elements, which Readability never keeps. */
export const ELEMENT_LIMIT = 20_000;
export const SVG_ELEMENT_LIMIT = 60_000;
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

/**
 * Counts opening tags in one pass without collecting matches. Script and style content is raw
 * text, not elements, so it is skipped; elements inside `<svg>` are counted separately.
 */
export function elementCounts(html: string): { elements: number; svg: number } {
  const lower = html.toLowerCase();
  const tag = /<(\/?)([a-z][a-z0-9-]*)\b[^>]*>/g;
  let elements = 0;
  let svg = 0;
  let svgDepth = 0;
  let match: RegExpExecArray | null;
  while ((match = tag.exec(lower))) {
    const [, closing, name] = match;
    if (closing) {
      if (name === "svg" && svgDepth > 0) svgDepth--;
      continue;
    }
    if (svgDepth > 0) svg++;
    else elements++;
    if (name === "svg" && !match[0].endsWith("/>")) svgDepth++;
    else if (name === "script" || name === "style") {
      const end = lower.indexOf(`</${name}`, tag.lastIndex);
      if (end < 0) break; // The rest of the page is that element's text.
      tag.lastIndex = end;
    }
    if (elements > ELEMENT_LIMIT || svg > SVG_ELEMENT_LIMIT) break;
  }
  return { elements, svg };
}

function direction(...values: (string | null | undefined)[]): "rtl" | "ltr" | undefined {
  for (const value of values) {
    const dir = value?.trim().toLowerCase();
    if (dir === "rtl" || dir === "ltr") return dir;
  }
  return undefined;
}

export async function extract(
  url: string,
  fetcher: Fetcher = safeFetch,
  trace?: ImportTrace,
): Promise<Prepared> {
  const page = await fetcher(url, 3 * 1024 * 1024, { trace });
  return timed(trace, "extract", async () => {
    if (!["text/html", "application/xhtml+xml"].includes(page.mime))
      throw new ImportFailure("This source is not an HTML article.", true, "not_html");
    const charset = pageCharset(page.bytes, page.charset);
    if (trace) trace.charset = charset;
    const html = decodePage(page.bytes, page.charset);
    const counts = elementCounts(html);
    if (trace) trace.elements = counts.elements;
    if (counts.elements > ELEMENT_LIMIT || counts.svg > SVG_ELEMENT_LIMIT)
      throw new ImportFailure("Source HTML exceeds the element limit.", true, "too_many_elements");
    const dom = new JSDOM(html, { url: page.url });
    const copy = dom.window.document.cloneNode(true) as Document;
    // Drawings are never article text; removing them keeps Readability's own count to real content.
    for (const drawing of copy.querySelectorAll("svg")) drawing.remove();
    const article = new Readability(copy, {
      // A little above our count, which excludes the implied html, head and body elements.
      maxElemsToParse: ELEMENT_LIMIT + 100,
    }).parse();
    const sourceText =
      dom.window.document.body.textContent?.replace(/\s+/g, " ").trim() ?? "";
    rejectBarrier(
      dom.window.document,
      article?.textContent?.replace(/\s+/g, " ").trim() || sourceText,
    );
    if (!article)
      throw new ImportFailure("Readable article text could not be extracted.", true, "no_article");
    const result = new JSDOM(sanitize(article.content ?? ""));
    const text =
      result.window.document.body.textContent?.replace(/\s+/g, " ").trim() ?? "";
    if (text.length < 100 || (text.match(/[\p{L}\p{N}]/gu)?.length ?? 0) < 40)
      throw new ImportFailure("Readable article text could not be extracted.", true, "no_article");
    return { dom, article, result };
  }).then(async ({ dom, article, result }) => {
    const images: Prepared["images"] = [];
    let missingImages = 0;
    const allImages = [...result.window.document.querySelectorAll("img")];
    await timed(trace, "images", async () => {
      let total = 0;
      const deadline = Date.now() + IMAGE_BUDGET_MS;
      for (const [index, img] of allImages.entries()) {
        try {
          if (index >= 20) throw new Error("Image count limit");
          if (Date.now() > deadline) throw new Error("Image time limit");
          const raw = img.getAttribute("src");
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
          img.setAttribute("src", `${id}.webp`);
        } catch {
          missingImages++;
          const placeholder = result.window.document.createElement("p");
          placeholder.textContent = `[Image unavailable${img.alt ? ": " + img.alt : ""}]`;
          img.replaceWith(placeholder);
        }
      }
    });
    if (trace)
      trace.images = { found: allImages.length, saved: images.length, missing: missingImages };
    const root = dom.window.document.documentElement;
    return {
      html: result.window.document.body.innerHTML,
      title: article.title || new URL(url).hostname,
      author: article.byline || undefined,
      siteName: article.siteName?.trim().slice(0, 120) || undefined,
      lang: languageTag(article.lang || root.lang),
      dir: direction(article.dir, root.getAttribute("dir"), dom.window.document.body?.getAttribute("dir")),
      images,
      missingImages,
    };
  });
}

// Deliberately small Markdown renderer: no raw HTML, embeds, or remote images.
export function markdownDocument(markdown: string): string {
  const lines = markdown.split(/\r?\n/);
  let inCode = false;
  const output: string[] = [];
  for (const line of lines) {
    if (line.startsWith("```")) {
      output.push(inCode ? "</code></pre>" : "<pre><code>");
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      output.push(escapeHTML(line) + "\n");
      continue;
    }
    const heading = /^(#{1,4})\s+(.*)$/.exec(line);
    const body = escapeHTML(heading?.[2] ?? line)
      .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>')
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    output.push(
      heading
        ? `<h${heading[1].length}>${body}</h${heading[1].length}>`
        : `<p>${body}</p>`,
    );
  }
  if (inCode) output.push("</code></pre>");
  return sanitize(output.join("\n"));
}
export function briefDocument(markdown: string): string {
  const html = markdownDocument(markdown);
  const text = new JSDOM(html).window.document.body.textContent ?? "";
  if (!/[\p{L}\p{N}]/u.test(text))
    throw new ImportFailure(
      "The brief contains no readable text. Submit a corrected brief as a new request.",
      true,
      "empty_brief",
    );
  return html;
}

/** A well-formed BCP 47 tag, or undefined; source pages sometimes carry junk in `lang`. */
export function languageTag(value: string | null | undefined): string | undefined {
  const tag = value?.trim();
  return tag && /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$/.test(tag) ? tag : undefined;
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
