/**
 * The DOM half of article extraction: JSDOM parsing, Readability, DOMPurify and building the
 * result. It does no network or file access and imports nothing native, so it can run inside the
 * extraction worker thread (extract-worker.ts) that bounds its memory and time.
 */
import { randomUUID } from "node:crypto";
import { JSDOM } from "jsdom";
import createDOMPurify from "dompurify";
import { Readability } from "@mozilla/readability";
import { ImportFailure } from "./import-error.js";

const purifierWindow = new JSDOM("").window;
const purify = createDOMPurify(purifierWindow);
/** DOMPurify's pass alone. Its `removed` list keeps the whole parsed fragment alive, so it is cleared. */
function purifyHTML(html: string): string {
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
  purify.removed = [];
  return clean;
}
/** Keeps only http(s) link targets. */
function dropUnsafeLinks(document: Document) {
  for (const a of document.querySelectorAll("a"))
    if (!/^https?:\/\//i.test(a.getAttribute("href") ?? ""))
      a.removeAttribute("href");
}
export function sanitize(html: string): string {
  const dom = new JSDOM(purifyHTML(html));
  dropUnsafeLinks(dom.window.document);
  const clean = dom.window.document.body.innerHTML;
  dom.window.close();
  return clean;
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
  const dom = new JSDOM(html);
  const text = dom.window.document.body.textContent ?? "";
  dom.window.close();
  if (!/[\p{L}\p{N}]/u.test(text))
    throw new ImportFailure(
      "The brief contains no readable text. Submit a corrected brief as a new request.",
      true,
      "empty_brief",
    );
  return html;
}


/** Readable elements allowed in a page: outside `<svg>`, not counting script or style text. */
export const ELEMENT_LIMIT = 20_000;

export const elementFailure = () =>
  new ImportFailure("Source HTML exceeds the element limit.", true, "too_many_elements");

/** What barrier detection needs from the source page, read before Readability changes it. */
interface BarrierFacts {
  labels: string[];
  challengeMarkup: boolean;
  password: boolean;
}
function barrierFacts(document: Document): BarrierFacts {
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
  const challengeMarkup =
    !!document.querySelector(
      '#challenge-form, #cf-challenge-running, input[name="cf-turnstile-response"]',
    ) ||
    [...document.querySelectorAll("script[src]")].some((script) =>
      script.getAttribute("src")?.includes("/cdn-cgi/challenge-platform/"),
    );
  const password = !!document.querySelector('input[type="password"]');
  return { labels, challengeMarkup, password };
}
function rejectBarrier({ labels, challengeMarkup, password }: BarrierFacts, text: string) {
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

function direction(...values: (string | null | undefined)[]): "rtl" | "ltr" | undefined {
  for (const value of values) {
    const dir = value?.trim().toLowerCase();
    if (dir === "rtl" || dir === "ltr") return dir;
  }
  return undefined;
}

/** A well-formed BCP 47 tag, or undefined; source pages sometimes carry junk in `lang`. */
export function languageTag(value: string | null | undefined): string | undefined {
  const tag = value?.trim();
  return tag && /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$/.test(tag) ? tag : undefined;
}

/** One `<img>` of the article, pre-rendered both ways so the caller needs no DOM to finish it. */
export interface ArticleImage {
  /** The raw `src` attribute, resolved by the caller against the page URL. */
  src: string | null;
  /** The `<img>` element's HTML with its `src` set to `slot`, to be replaced by the stored file name. */
  saved: string;
  /** The `[Image unavailable…]` paragraph that replaces the image when it can't be stored. */
  missing: string;
}

/** Plain data only, so it can cross from the worker thread by structured clone. */
export interface ParsedArticle {
  /** The sanitised article HTML, cut at each image: `parts.length === images.length + 1`. */
  parts: string[];
  images: ArticleImage[];
  /** Placeholder inside each `saved` image's `src`. */
  slot: string;
  title: string;
  byline?: string;
  siteName?: string;
  lang?: string;
  dir?: "rtl" | "ltr";
}

/**
 * Lets V8 collect documents from finished steps. Within one synchronous run their memory was not
 * reclaimed (measured: a dropped and closed JSDOM document stayed live until the next macrotask),
 * so without these yields every intermediate document is live at the peak.
 */
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

/**
 * Parses page HTML into the readable article. Throws `ImportFailure` for permanent rejections
 * (barrier pages, no article text, Readability's element limit). CPU and memory here grow with the
 * number of parsed nodes, which the caller's tag cap does not bound (see extract-sandbox.ts).
 */
export async function parseArticle(html: string, pageUrl: string): Promise<ParsedArticle> {
  const dom = new JSDOM(html, { url: pageUrl });
  const source = dom.window.document;
  // Everything later steps need from the source page, read before Readability rewrites it (in
  // place: there is no second copy of the page).
  const facts = barrierFacts(source);
  const sourceText = source.body.textContent?.replace(/\s+/g, " ").trim() ?? "";
  const root = source.documentElement;
  const rootLang = root.lang;
  const rootDir = root.getAttribute("dir");
  const bodyDir = source.body?.getAttribute("dir");
  // Drawings are never article text; removing them keeps Readability's own count to real content.
  for (const drawing of source.querySelectorAll("svg")) drawing.remove();
  let article: ReturnType<Readability["parse"]>;
  try {
    article = new Readability(source, {
      // A little above our count, which excludes the implied html, head and body elements.
      maxElemsToParse: ELEMENT_LIMIT + 100,
    }).parse();
  } catch (error) {
    // Readability's own element limit: as permanent as ours, so it must not be retried.
    if (/^Aborting parsing document/.test((error as Error)?.message ?? "")) throw elementFailure();
    throw error;
  } finally {
    dom.window.close();
  }
  rejectBarrier(facts, article?.textContent?.replace(/\s+/g, " ").trim() || sourceText);
  if (!article)
    throw new ImportFailure("Readable article text could not be extracted.", true, "no_article");
  await settle();
  const purified = purifyHTML(article.content ?? "");
  await settle();
  const result = new JSDOM(purified);
  const document = result.window.document;
  dropUnsafeLinks(document);
  const text = document.body.textContent?.replace(/\s+/g, " ").trim() ?? "";
  if (text.length < 100 || (text.match(/[\p{L}\p{N}]/gu)?.length ?? 0) < 40)
    throw new ImportFailure("Readable article text could not be extracted.", true, "no_article");

  // Each image becomes a random marker in the serialised HTML, so the caller can splice in the
  // stored image or its placeholder after fetching, outside this thread, without re-parsing.
  const cut = randomUUID();
  const slot = randomUUID();
  const images: ArticleImage[] = [];
  for (const img of [...document.querySelectorAll("img")]) {
    const src = img.getAttribute("src");
    const placeholder = document.createElement("p");
    placeholder.textContent = `[Image unavailable${img.alt ? ": " + img.alt : ""}]`;
    img.setAttribute("src", slot);
    images.push({ src, saved: img.outerHTML, missing: placeholder.outerHTML });
    img.replaceWith(document.createTextNode(cut));
  }
  const parts = document.body.innerHTML.split(cut);
  result.window.close();
  if (parts.length !== images.length + 1) throw new Error("Image markers did not split cleanly");
  return {
    parts,
    images,
    slot,
    title: article.title ?? "",
    byline: article.byline || undefined,
    siteName: article.siteName?.trim().slice(0, 120) || undefined,
    lang: languageTag(article.lang || rootLang),
    dir: direction(article.dir, rootDir, bodyDir),
  };
}
