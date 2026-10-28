import Fastify from "fastify";
import rateLimit from "@fastify/rate-limit";
import { z, ZodError } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { Service, HTTPError } from "./service.js";
import { oauthRoutes } from "./oauth.js";
import { normalizedURL } from "./fetch.js";

const id = z.string().uuid();
export const linkInput = z.object({
  url: z.string().url().max(2048),
  idempotency_key: z.string().min(1).max(200),
});
export const savedArticlesInput = z.object({
  limit: z.number().int().min(1).max(200).default(100),
  before: z.string().min(1).max(200).optional(),
  since: z.string().datetime({ offset: true }).optional(),
});
export const documentInput = z
  .object({
    title: z.string().min(1).max(300),
    markdown: z.string().min(1).max(200_000),
    sources: z.array(z.string().url().max(2048)).max(30).default([]),
    idempotency_key: z.string().min(1).max(200),
  })
  .superRefine((value, ctx) => {
    for (const source of value.sources)
      try {
        normalizedURL(source);
      } catch {
        ctx.addIssue({
          code: "custom",
          message: "Source references must be HTTP(S) URLs.",
        });
      }
  });

export async function buildServer(service: Service) {
  const app = Fastify({ logger: false, bodyLimit: 220_000, trustProxy: false });
  await app.register(rateLimit, {
    max: 120,
    timeWindow: "1 minute",
    keyGenerator: (r) =>
      r.headers.authorization
        ? String(r.headers.authorization).slice(-24)
        : r.ip,
  });
  app.addContentTypeParser(
    "application/x-www-form-urlencoded",
    { parseAs: "string" },
    (_request, body, done) =>
      done(null, Object.fromEntries(new URLSearchParams(body as string))),
  );
  app.addHook("onSend", async (_req, reply) => {
    reply
      .header("Cache-Control", "no-store")
      .header("X-Content-Type-Options", "nosniff")
      .header("Referrer-Policy", "no-referrer")
      .header("X-Frame-Options", "DENY")
      .header(
        "Content-Security-Policy",
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
      );
  });
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof HTTPError) {
      if (error.status === 401)
        reply.header(
          "WWW-Authenticate",
          `Bearer resource_metadata="${service.config.publicURL}/.well-known/oauth-protected-resource"`,
        );
      return reply.code(error.status).send({ error: error.message });
    }
    if (error instanceof ZodError)
      return reply.code(400).send({ error: "Invalid request fields." });
    if ((error as { statusCode?: number }).statusCode === 429)
      return reply.code(429).send({ error: "Too many requests. Try later." });
    const status = (error as { statusCode?: number }).statusCode;
    if (status && status >= 400 && status < 500)
      return reply.code(status).send({ error: "Invalid request." });
    return reply.code(500).send({ error: "Request could not complete." });
  });
  const auth = (request: { headers: { authorization?: string } }) =>
    service.authenticate(
      request.headers.authorization?.replace(/^Bearer /i, ""),
    );
  app.get("/health", async () => {
    await service.db.query("SELECT 1");
    return { ok: true };
  });
  app.post(
    "/v1/session",
    { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
    async (request) => {
      const input = z
        .object({
          email: z.string().email().max(200),
          password: z.string().min(1).max(1000),
        })
        .parse(request.body);
      return service.login(input.email, input.password);
    },
  );
  app.delete("/v1/session", async (request) => {
    const identity = await auth(request);
    service.app(identity);
    await service.db.query("DELETE FROM credentials WHERE id=$1", [
      identity.id,
    ]);
    return { ok: true };
  });
  app.post("/v1/saves/link", async (request) =>
    service.save(await auth(request), linkInput.parse(request.body)),
  );
  app.post("/v1/saves/document", async (request) =>
    service.save(await auth(request), documentInput.parse(request.body)),
  );
  app.get("/v1/saves/:id", async (request) =>
    service.status(
      await auth(request),
      id.parse((request.params as { id: string }).id),
    ),
  );
  app.get("/v1/library", async (request) =>
    service.library(
      await auth(request),
      z.coerce
        .number()
        .int()
        .min(0)
        .max(Number.MAX_SAFE_INTEGER)
        .parse((request.query as { cursor?: string }).cursor ?? 0),
    ),
  );
  app.get("/v1/interests/saved", async (request) => {
    const query = request.query as Record<string, string | undefined>;
    return service.savedArticles(
      await auth(request),
      savedArticlesInput.parse({
        ...query,
        limit: query.limit === undefined ? undefined : Number(query.limit),
      }),
    );
  });
  app.patch("/v1/items/:id", async (request) => {
    const patch = z
      .object({
        progress: z.number().min(0).max(1).optional(),
        archived: z.boolean().optional(),
        deleted: z.boolean().optional(),
        trashed: z.boolean().optional(),
        collections: z
          .array(z.string().trim().min(1).max(60))
          .max(20)
          .optional(),
      })
      .strict()
      .parse(request.body);
    await service.update(
      await auth(request),
      id.parse((request.params as { id: string }).id),
      patch,
    );
    return { ok: true };
  });
  app.post("/v1/items/:id/retry", async (request) => {
    const identity = await auth(request);
    service.app(identity);
    const itemID = id.parse((request.params as { id: string }).id);
    if (!(await service.retry(identity, itemID)))
      throw new HTTPError(404, "Retryable import not found.");
    return { ok: true };
  });
  app.get("/v1/features", async (request) =>
    service.features(await auth(request)),
  );
  app.get("/v1/items/:id/context", async (request) =>
    service.readingContext(
      await auth(request),
      id.parse((request.params as { id: string }).id),
    ),
  );
  app.post(
    "/v1/items/:id/context",
    { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
    async (request) => {
      const input = z
        .object({ regenerate: z.boolean().default(false) })
        .strict()
        .parse(request.body ?? {});
      return service.generateContext(
        await auth(request),
        id.parse((request.params as { id: string }).id),
        input.regenerate,
      );
    },
  );
  app.get("/v1/downloads/:token", async (request, reply) => {
    const { asset, bytes } = await service.download(
      z
        .string()
        .regex(/^[A-Za-z0-9_-]{43}$/)
        .parse((request.params as { token: string }).token),
    );
    return reply
      .header("Content-Length", bytes.length)
      .header("Content-Disposition", "attachment")
      .type(asset.mime)
      .send(bytes);
  });
  app.get("/v1/connections", async (request) => {
    const identity = await auth(request);
    service.app(identity);
    const result = await service.db.query(
      `SELECT c.connection_id AS id,min(c.label) AS label,min(c.kind) AS kind,max(c.expires_at) AS expires_at,
       COALESCE(bool_or(g.interests),false) AS interests
       FROM credentials c LEFT JOIN connection_grants g ON g.owner_id=c.owner_id AND g.connection_id=c.connection_id
       WHERE c.owner_id=$1 AND c.kind IN('api','oauth','refresh') GROUP BY c.connection_id ORDER BY max(c.created_at) DESC`,
      [identity.owner_id],
    );
    return { connections: result.rows };
  });
  app.post("/v1/connections", async (request) => {
    const identity = await auth(request);
    service.app(identity);
    const input = z
      .object({ label: z.string().min(1).max(100) })
      .parse(request.body);
    return service.credential(
      identity.owner_id,
      "api",
      input.label,
      undefined,
      365,
    );
  });
  app.patch("/v1/connections/:id", async (request) => {
    const identity = await auth(request);
    const input = z
      .object({ interests: z.boolean() })
      .strict()
      .parse(request.body);
    await service.setInterests(
      identity,
      id.parse((request.params as { id: string }).id),
      input.interests,
    );
    return { ok: true };
  });
  app.delete("/v1/connections/:id", async (request) => {
    const identity = await auth(request);
    service.app(identity);
    const connection = id.parse((request.params as { id: string }).id);
    await service.db.query(
      "DELETE FROM credentials WHERE connection_id=$1 AND owner_id=$2 AND kind<>$3",
      [connection, identity.owner_id, "app"],
    );
    // A revoked connection's opt-ins never carry over to a later credential.
    await service.db.query(
      "DELETE FROM connection_grants WHERE connection_id=$1 AND owner_id=$2",
      [connection, identity.owner_id],
    );
    return { ok: true };
  });
  app.delete("/v1/account", async (request) => {
    await service.deleteAccount(await auth(request));
    return { ok: true };
  });
  await oauthRoutes(app, service);
  app.post("/mcp", async (request, reply) => {
    const method = (request.body as { method?: string })?.method;
    const identity = request.headers.authorization
      ? await auth(request)
      : undefined;
    if (
      !identity &&
      ![
        "initialize",
        "notifications/initialized",
        "tools/list",
        "ping",
      ].includes(method ?? "")
    )
      throw new HTTPError(401, "Connect your account to use this tool.");
    if (identity && !["oauth", "api"].includes(identity.kind))
      throw new HTTPError(403, "An agent connection is required.");
    const caller = () => {
      if (!identity) throw new HTTPError(401, "Authentication required.");
      return identity;
    };
    const server = new McpServer({ name: "offline-reader", version: "0.1.0" });
    const schemes = [{ type: "oauth2", scopes: ["save", "status"] }];
    const result = async (action: () => Promise<unknown>) => {
      try {
        return {
          content: [
            { type: "text" as const, text: JSON.stringify(await action()) },
          ],
        };
      } catch (error) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text:
                error instanceof HTTPError
                  ? error.message
                  : "Submission could not complete.",
            },
          ],
        };
      }
    };
    server.registerTool(
      "save_link",
      {
        description:
          "Request article preparation for offline reading. Only ready confirms server preparation; failed imports are not saved articles. Does not mean downloaded on phone.",
        inputSchema: linkInput.shape,
        annotations: {
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: true,
        },
        _meta: { securitySchemes: schemes },
      },
      async (input) => result(() => service.save(caller(), input)),
    );
    server.registerTool(
      "save_document",
      {
        description:
          "Save an agent-created Markdown brief with its source references.",
        inputSchema: {
          title: z.string().min(1).max(300),
          markdown: z.string().min(1).max(200_000),
          sources: z.array(z.string().url().max(2048)).max(30).default([]),
          idempotency_key: z.string().min(1).max(200),
        },
        annotations: {
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        },
        _meta: { securitySchemes: schemes },
      },
      async (input) =>
        result(() => service.save(caller(), documentInput.parse(input))),
    );
    server.registerTool(
      "get_save_status",
      {
        description:
          "Check the server import status of this connection’s submission.",
        inputSchema: { submission_id: id },
        annotations: {
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        },
        _meta: { securitySchemes: schemes },
      },
      async (input) =>
        result(() => service.status(caller(), input.submission_id)),
    );
    server.registerTool(
      "list_saved_articles",
      {
        description:
          "List the owner's saved articles, newest first: title, link, site, domain and save time only. No content, briefs or reading state. Works only after the owner allows it for this connection in app Settings. Use `next` as `before` for the following page.",
        inputSchema: savedArticlesInput.shape,
        annotations: {
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        },
        _meta: { securitySchemes: schemes },
      },
      async (input) => result(() => service.savedArticles(caller(), input)),
    );
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
      allowedHosts: [new URL(service.config.publicURL).host],
      enableDnsRebindingProtection: true,
    });
    reply.hijack();
    reply.raw.on("close", () => {
      void transport.close();
      void server.close();
    });
    await server.connect(transport);
    await transport.handleRequest(request.raw, reply.raw, request.body);
  });
  app.get("/mcp", async (_request, reply) =>
    reply.code(405).send({ error: "Use Streamable HTTP POST." }),
  );
  return app;
}
