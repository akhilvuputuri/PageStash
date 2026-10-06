import { JSDOM } from "jsdom";
import createDOMPurify from "dompurify";
import { Readability } from "@mozilla/readability";
import sharp from "sharp";
import { randomUUID } from "node:crypto";
import { safeFetch } from "./fetch.js";

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
  missingImages: number;
  images: { id: string; bytes: Buffer }[];
}
export async function extract(
  url: string,
  fetcher = safeFetch,
): Promise<Prepared> {
  const page = await fetcher(url, 3 * 1024 * 1024);
  if (!["text/html", "application/xhtml+xml"].includes(page.mime))
    throw new Error("This source is not an HTML article.");
  const html = page.bytes.toString("utf8");
  if ((html.match(/<[A-Za-z][^>]*>/g)?.length ?? 0) > 20_000)
    throw new Error("Source HTML exceeds the element limit.");
  const dom = new JSDOM(html, { url: page.url });
  const article = new Readability(dom.window.document, {
    maxElemsToParse: 20_000,
  }).parse();
  if (!article || (article.textContent?.length ?? 0) < 100)
    throw new Error(
      "Readable article text could not be extracted. The bookmark has been retained.",
    );
  const result = new JSDOM(sanitize(article.content ?? ""));
  const images: Prepared["images"] = [];
  let missingImages = 0;
  let total = 0;
  const allImages = [...result.window.document.querySelectorAll("img")];
  for (const [index, img] of allImages.entries()) {
    try {
      if (index >= 20) throw new Error("Image count limit");
      const raw = img.getAttribute("src");
      if (!raw) throw new Error("Image unavailable");
      const image = await fetcher(
        new URL(raw, page.url).toString(),
        5 * 1024 * 1024,
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
  return {
    html: result.window.document.body.innerHTML,
    title: article.title || new URL(url).hostname,
    author: article.byline || undefined,
    images,
    missingImages,
  };
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
export function readerHTML(content: string, title: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><title>${escapeHTML(title)}</title><style>:root{color-scheme:light dark}body{font:20px/1.65 Georgia,serif;padding:18px;max-width:720px;margin:auto;overflow-wrap:anywhere}img{max-width:100%;height:auto}pre{overflow:auto}a{color:#4685c5}h1,h2,h3{line-height:1.25}table{display:block;overflow:auto}blockquote{border-left:3px solid #888;padding-left:16px;margin-left:0}</style></head><body>${content}</body></html>`;
}
