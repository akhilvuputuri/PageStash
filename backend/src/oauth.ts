import { randomUUID, createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { Service, hash, secret, HTTPError } from "./service.js";
import { escapeHTML } from "./content.js";

const scopes = "save status";
const params = z.object({
  client_id: z.string().max(200),
  redirect_uri: z.string().url().max(2048),
  response_type: z.literal("code"),
  code_challenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  code_challenge_method: z.literal("S256"),
  state: z.string().min(16).max(1024),
  scope: z.string().default(scopes),
});
function allowedScope(value: string) {
  if (value.split(" ").some((s) => !["save", "status"].includes(s)))
    throw new HTTPError(400, "Unsupported OAuth scope.");
}

export async function oauthRoutes(app: FastifyInstance, service: Service) {
  const base = service.config.publicURL;
  app.get("/.well-known/oauth-protected-resource", async () => ({
    resource: `${base}/mcp`,
    authorization_servers: [base],
    scopes_supported: ["save", "status"],
    bearer_methods_supported: ["header"],
  }));
  app.get("/.well-known/oauth-authorization-server", async () => ({
    issuer: base,
    authorization_endpoint: `${base}/oauth/authorize`,
    token_endpoint: `${base}/oauth/token`,
    registration_endpoint: `${base}/oauth/register`,
    revocation_endpoint: `${base}/oauth/revoke`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    token_endpoint_auth_methods_supported: ["none"],
    code_challenge_methods_supported: ["S256"],
    scopes_supported: ["save", "status"],
  }));
  app.post("/oauth/register", async (request, reply) => {
    const input = z
      .object({
        client_name: z.string().max(100).default("Reading assistant"),
        redirect_uris: z.array(z.string().url().max(2048)).min(1).max(5),
        token_endpoint_auth_method: z.literal("none").optional(),
      })
      .parse(request.body);
    for (const value of input.redirect_uris) {
      const url = new URL(value);
      if (
        url.hash ||
        url.username ||
        url.password ||
        (url.protocol !== "https:" &&
          !(
            service.config.devAuth &&
            url.protocol === "http:" &&
            ["127.0.0.1", "localhost"].includes(url.hostname)
          ))
      )
        throw new HTTPError(400, "HTTPS redirect URIs are required.");
    }
    const count = await service.db.query<{ count: string }>(
      "SELECT count(*) FROM oauth_clients",
    );
    if (Number(count.rows[0].count) >= 100)
      throw new HTTPError(429, "Client registration capacity reached.");
    const client = secret();
    await service.db.query(
      "INSERT INTO oauth_clients(id,name,redirect_uris) VALUES($1,$2,$3::jsonb)",
      [client, input.client_name, JSON.stringify(input.redirect_uris)],
    );
    return reply
      .code(201)
      .send({
        client_id: client,
        client_name: input.client_name,
        redirect_uris: input.redirect_uris,
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
      });
  });
  async function validate(input: z.infer<typeof params>) {
    allowedScope(input.scope);
    const result = await service.db.query<{
      name: string;
      redirect_uris: string[];
    }>("SELECT name,redirect_uris FROM oauth_clients WHERE id=$1", [
      input.client_id,
    ]);
    if (
      !result.rows[0] ||
      !result.rows[0].redirect_uris.includes(input.redirect_uri)
    )
      throw new HTTPError(
        400,
        "OAuth client or redirect URI is not registered.",
      );
    return result.rows[0];
  }
  app.get("/oauth/authorize", async (request, reply) => {
    const input = params.parse(request.query);
    const client = await validate(input);
    const nonce = secret();
    // Double-submit cookie binds consent to this browser; no account credentials are in the URL.
    reply.header(
      "Set-Cookie",
      `oauth_csrf=${nonce}; HttpOnly; SameSite=Lax; Path=/oauth; Max-Age=600${service.config.devAuth ? "" : "; Secure"}`,
    );
    const hidden = Object.entries(input)
      .map(
        ([key, value]) =>
          `<input type="hidden" name="${escapeHTML(key)}" value="${escapeHTML(value)}">`,
      )
      .join("");
    return reply
      .type("text/html")
      .send(
        `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connect Offline Reader</title><style>body{font:18px system-ui;max-width:480px;margin:60px auto;padding:20px}input,button{display:block;width:100%;padding:12px;margin:12px 0;box-sizing:border-box}small{color:#555}</style><h1>Connect ${escapeHTML(client.name)}</h1><p>Allow this assistant to save articles and briefs and check its submissions. It cannot browse or delete your library.</p><form method="post" action="/oauth/approve">${hidden}<input type="hidden" name="csrf" value="${nonce}"><label>Email<input type="email" name="email" required autocomplete="username"></label><label>Password<input type="password" name="password" required autocomplete="current-password"></label><button type="submit">Sign in and allow saving</button></form><small>Only connect an assistant you trust. Revoke access in the iPhone app.</small>`,
      );
  });
  app.post("/oauth/approve", async (request, reply) => {
    const input = params
      .extend({
        email: z.string().email(),
        password: z.string().min(1).max(1000),
        csrf: z.string(),
      })
      .parse(request.body);
    const cookie = String(request.headers.cookie ?? "")
      .split(";")
      .map((s) => s.trim())
      .find((s) => s.startsWith("oauth_csrf="))
      ?.slice(11);
    if (!cookie || hash(cookie) !== hash(input.csrf))
      throw new HTTPError(403, "Consent session expired. Start again.");
    await validate(input);
    const session = await service.login(input.email, input.password);
    // The consent form creates no enduring full-library session.
    await service.db.query("DELETE FROM credentials WHERE id=$1", [session.id]);
    const code = secret();
    await service.db.query(
      "INSERT INTO oauth_codes(hash,owner_id,client_id,redirect_uri,challenge,expires_at) VALUES($1,$2,$3,$4,$5,$6)",
      [
        hash(code),
        session.owner_id,
        input.client_id,
        input.redirect_uri,
        input.code_challenge,
        new Date(Date.now() + 300_000),
      ],
    );
    const redirect = new URL(input.redirect_uri);
    redirect.searchParams.set("code", code);
    redirect.searchParams.set("state", input.state);
    reply.header(
      "Set-Cookie",
      "oauth_csrf=; HttpOnly; SameSite=Lax; Path=/oauth; Max-Age=0",
    );
    return reply.redirect(redirect.toString());
  });
  app.post("/oauth/token", async (request, reply) => {
    reply.header("Cache-Control", "no-store");
    const input = z
      .object({
        grant_type: z.enum(["authorization_code", "refresh_token"]),
        client_id: z.string(),
        code: z.string().optional(),
        redirect_uri: z.string().optional(),
        code_verifier: z
          .string()
          .min(43)
          .max(128)
          .regex(/^[A-Za-z0-9._~-]+$/)
          .optional(),
        refresh_token: z.string().optional(),
        resource: z.string().optional(),
      })
      .parse(request.body);
    if (input.resource && input.resource !== `${base}/mcp`)
      throw new HTTPError(400, "Invalid token audience.");
    let owner: string, connection: string;
    if (input.grant_type === "authorization_code") {
      if (!input.code || !input.redirect_uri || !input.code_verifier)
        throw new HTTPError(
          400,
          "Code, redirect URI and verifier are required.",
        );
      const challenge = createHash("sha256")
        .update(input.code_verifier)
        .digest("base64url");
      const result = await service.db.query<{ owner_id: string }>(
        `DELETE FROM oauth_codes WHERE hash=$1 AND client_id=$2 AND redirect_uri=$3 AND challenge=$4 AND expires_at>now() RETURNING owner_id`,
        [hash(input.code), input.client_id, input.redirect_uri, challenge],
      );
      if (!result.rows[0])
        throw new HTTPError(400, "Authorization code is invalid.");
      owner = result.rows[0].owner_id;
      connection = randomUUID();
    } else {
      if (!input.refresh_token)
        throw new HTTPError(400, "Refresh token required.");
      const result = await service.db.query<{
        owner_id: string;
        connection_id: string;
      }>(
        `DELETE FROM credentials WHERE hash=$1 AND kind='refresh' AND label=$2 AND expires_at>now() RETURNING owner_id,connection_id`,
        [hash(input.refresh_token), input.client_id],
      );
      if (!result.rows[0])
        throw new HTTPError(400, "Refresh token is invalid.");
      owner = result.rows[0].owner_id;
      connection = result.rows[0].connection_id;
      await service.db.query(
        "DELETE FROM credentials WHERE owner_id=$1 AND connection_id=$2 AND kind='oauth'",
        [owner, connection],
      );
    }
    const access = await service.credential(
      owner,
      "oauth",
      input.client_id,
      connection,
      1 / 24,
    );
    const refresh = await service.credential(
      owner,
      "refresh",
      input.client_id,
      connection,
      30,
    );
    return {
      access_token: access.token,
      token_type: "Bearer",
      expires_in: 3600,
      refresh_token: refresh.token,
      scope: scopes,
    };
  });
  app.post("/oauth/revoke", async (request, reply) => {
    const input = z
      .object({ token: z.string(), client_id: z.string() })
      .parse(request.body);
    await service.db.query(
      `DELETE FROM credentials WHERE connection_id IN(SELECT connection_id FROM credentials WHERE hash=$1 AND label=$2 AND kind IN('oauth','refresh'))`,
      [hash(input.token), input.client_id],
    );
    return reply.code(200).send({});
  });
}
