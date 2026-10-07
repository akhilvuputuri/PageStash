import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { randomUUID, createHash } from "node:crypto";
import sharp from "sharp";
import { openDatabase, migrate, type Database } from "../src/db.js";
import { configuration } from "../src/config.js";
import { Service, type Identity } from "../src/service.js";
import { buildServer } from "../src/server.js";
import { normalizedURL, publicAddress, safeFetch } from "../src/fetch.js";
import { extract, sanitize, markdownDocument } from "../src/content.js";
let db: Database,
  service: Service,
  app: Awaited<ReturnType<typeof buildServer>>;
let owner: Identity, other: Identity, agent: Identity, otherAgent: Identity;
let ownerToken: string, agentToken: string;
const files = new Map<string, Buffer>();
before(async () => {
  db = await openDatabase();
  await migrate(db);
  service = new Service(
    db,
    configuration({ DEV_AUTH: "true", DEV_PASSWORD: "local-test-password" }),
    {
      put: async (k, b) => {
        files.set(k, b);
      },
      get: async (k) => {
        const b = files.get(k);
        assert.ok(b);
        return b;
      },
    remove: async (keys) => {
      keys.forEach((k) => files.delete(k));
    },
    purgeOwner: async owner => {for(const key of files.keys())if(key.startsWith(owner+'/'))files.delete(key);},
    },
  );
  const login = await service.login(
    "reader@example.test",
    "local-test-password",
  );
  ownerToken = login.token;
  owner = await service.authenticate(login.token);
  const otherID = randomUUID();
  await db.query("INSERT INTO accounts(id,email) VALUES($1,$2)", [
    otherID,
    "other@example.test",
  ]);
  other = await service.authenticate(
    (await service.credential(otherID, "app", "Other")).token,
  );
  const a = await service.credential(owner.owner_id, "api", "Telegram");
  agentToken = a.token;
  agent = await service.authenticate(a.token);
  otherAgent = await service.authenticate(
    (await service.credential(owner.owner_id, "api", "Another agent")).token,
  );
  app = await buildServer(service);
});
after(async () => {
  await app.close();
  await db.close();
});
test("blocks private, loopback, metadata and mapped IPs", async () => {
  for (const address of [
    "127.0.0.1",
    "10.0.0.1",
    "169.254.169.254",
    "172.16.0.2",
    "192.168.1.1",
    "::1",
    "fc00::1",
    "fe80::1",
    "::ffff:127.0.0.1",
    "0.0.0.0",
  ])
    assert.equal(publicAddress(address), false, address);
  assert.equal(publicAddress("1.1.1.1"), true);
  await assert.rejects(
    () => safeFetch("http://127.0.0.1/secret", 1000),
    /public internet/,
  );
  assert.equal(
    normalizedURL("https://example.com/read?id=5&utm_source=x#part"),
    "https://example.com/read?id=5",
  );
  assert.throws(() => normalizedURL("file:///secret"));
});
test("sanitizes scripts, remote embeds and unsafe Markdown", () => {
  const clean = sanitize(
    '<p>Text<script>alert(1)</script><img src="x" onerror="steal()"><iframe src="https://evil.test"></iframe><a href="javascript:bad()">bad</a></p>',
  );
  assert.doesNotMatch(clean, /script|onerror|iframe|javascript:/);
  assert.match(
    markdownDocument("# Brief\n<script>steal()</script>"),
    /&lt;script&gt;/,
  );
});
test("extraction captures images locally and flags unavailable ones", async () => {
  const png = await sharp({
    create: { width: 4, height: 4, channels: 3, background: "red" },
  })
    .png()
    .toBuffer();
  const page =
    "<html><head><title>Fixture article</title></head><body><article><h1>A test article</h1><p>" +
    "Readable article content with meaningful sentences. ".repeat(20) +
    '</p><img src="/photo.png"><img src="/missing.png"></article></body></html>';
  const result = await extract("https://example.com/article", async (url) => {
    if (url.endsWith("/missing.png")) throw Error("missing");
    return url.endsWith("/photo.png")
      ? { bytes: png, mime: "image/png", url }
      : { bytes: Buffer.from(page), mime: "text/html", url };
  });
  assert.equal(result.images.length, 1);
  assert.equal(result.missingImages, 1);
  assert.match(result.html, /\.webp/);
  assert.doesNotMatch(result.html, /src="https?:/);
});
test("durable Markdown import, safe duplicate saves and account isolation", async () => {
  const input = {
    title: "A reading brief",
    markdown: "# Brief\nPrepared text",
    sources: ["https://example.com/source"],
    idempotency_key: randomUUID(),
  };
  const saved = await service.save(agent, input);
  assert.ok(saved.submission_id);
  const duplicate = await service.save(agent, input);
  assert.equal(duplicate.submission_id, saved.submission_id);
  assert.equal(duplicate.duplicate, true);
  const hidden = await service.save(otherAgent, input);
  assert.equal(hidden.submission_id, null);
  assert.equal(await service.runOne(), true);
  const status = await service.status(agent, saved.submission_id!);
  assert.equal(status.status, "ready");
  await assert.rejects(
    () => service.status(other, saved.submission_id!),
    /not found/,
  );
  await assert.rejects(
    () => service.status(otherAgent, saved.submission_id!),
    /not found/,
  );
  const library = await service.library(owner, 0);
  const item = library.items.find((i) => i.id === saved.submission_id)!;
  assert.equal(item.kind, "brief");
  assert.equal(item.assets.length, 1);
  const token = item.assets[0].url.split("/").at(-1)!;
  const download = await service.download(token);
  assert.match(download.bytes.toString(), /Agent-created brief/);
  const ownLibrary = await service.library(other, 0);
  assert.equal(ownLibrary.items.length, 0);
  await assert.rejects(() => service.library(agent, 0), /app session/);
  await service.update(owner, saved.submission_id!, { deleted: true });
  await service.update(owner, saved.submission_id!, { deleted: true });
  await assert.rejects(() => service.download(token), /unavailable/);
  const changes = await service.library(owner, library.cursor);
  assert.equal(
    changes.items.find((i) => i.id === saved.submission_id)?.deleted,
    true,
  );
});
test("HTTP agent token cannot manage library or credentials", async () => {
  for (const url of ["/v1/library", "/v1/connections"])
    assert.equal(
      (
        await app.inject({
          method: "GET",
          url,
          headers: { authorization: `Bearer ${agentToken}` },
        })
      ).statusCode,
      403,
    );
  assert.equal(
    (
      await app.inject({
        method: "DELETE",
        url: "/v1/account",
        headers: { authorization: `Bearer ${agentToken}` },
      })
    ).statusCode,
    403,
  );
  const credential = await service.credential(
    owner.owner_id,
    "api",
    "Revocable",
  );
  await service.db.query("DELETE FROM credentials WHERE id=$1", [
    credential.id,
  ]);
  await assert.rejects(() => service.authenticate(credential.token), /invalid/);
});
test("HTTP revocation and logout invalidate credentials and download grants", async () => {
  const login = await service.login("reader@example.test", "local-test-password");
  const identity = await service.authenticate(login.token);
  const credential = await service.credential(identity.owner_id, "api", "HTTP revoke check");
  const agentIdentity = await service.authenticate(credential.token);
  const saved = await service.save(agentIdentity, {
    title: "Revocation check", markdown: "A private brief", sources: [],
    idempotency_key: randomUUID(),
  });
  await service.runOne();
  const page = await service.library(identity, 0);
  const asset = page.items.find(item => item.id === saved.submission_id)!.assets[0];
  const authHeader = { authorization: `Bearer ${login.token}` };
  const revoke = await app.inject({ method: "DELETE",
    url: `/v1/connections/${credential.connection_id}`, headers: authHeader });
  assert.equal(revoke.statusCode, 200);
  const denied = await app.inject({ method: "GET", url: `/v1/saves/${saved.submission_id}`,
    headers: {authorization: `Bearer ${credential.token}`} });
  assert.equal(denied.statusCode, 401);
  const logout = await app.inject({ method: "DELETE", url: "/v1/session", headers: authHeader });
  assert.equal(logout.statusCode, 200);
  assert.equal((await app.inject({ method: "GET", url: "/v1/library", headers: authHeader })).statusCode, 401);
  assert.equal((await app.inject({ method: "GET", url: new URL(asset.url).pathname })).statusCode, 404);
  // Logging out revokes capabilities but preserves the account's saved article.
  assert.equal((await service.status(owner, saved.submission_id!)).status, "ready");
  const malformed = await app.inject({ method: "DELETE", url: "/v1/session",
    headers: { ...authHeader, "content-type": "application/json" } });
  assert.equal(malformed.statusCode, 400);
});
test("OAuth consent, S256, one-time code, rotation and revocation", async () => {
  const registration = await app.inject({
    method: "POST",
    url: "/oauth/register",
    payload: {
      client_name: "Test host",
      redirect_uris: ["https://host.example/callback"],
    },
  });
  assert.equal(registration.statusCode, 201);
  const client = registration.json();
  const verifier = "a".repeat(43),
    challenge = createHash("sha256").update(verifier).digest("base64url");
  const query = new URLSearchParams({
    client_id: client.client_id,
    redirect_uri: "https://host.example/callback",
    response_type: "code",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state: "s".repeat(32),
  });
  const consent = await app.inject({
    method: "GET",
    url: "/oauth/authorize?" + query,
  });
  assert.equal(consent.statusCode, 200);
  const cookie = String(consent.headers["set-cookie"]).split(";")[0];
  const csrf = cookie.split("=")[1];
  const approve = await app.inject({
    method: "POST",
    url: "/oauth/approve",
    headers: { "content-type": "application/x-www-form-urlencoded", cookie },
    payload: new URLSearchParams({
      ...Object.fromEntries(query),
      csrf,
      email: "reader@example.test",
      password: "local-test-password",
    }).toString(),
  });
  assert.equal(approve.statusCode, 302);
  const code = new URL(approve.headers.location!).searchParams.get("code")!;
  const tokenBody = {
    grant_type: "authorization_code",
    client_id: client.client_id,
    redirect_uri: "https://host.example/callback",
    code,
    code_verifier: verifier,
  };
  const issued = await app.inject({
    method: "POST",
    url: "/oauth/token",
    payload: tokenBody,
  });
  assert.equal(issued.statusCode, 200);
  const tokens = issued.json();
  assert.equal((await service.authenticate(tokens.access_token)).kind, "oauth");
  assert.equal(
    (
      await app.inject({
        method: "POST",
        url: "/oauth/token",
        payload: tokenBody,
      })
    ).statusCode,
    400,
  );
  const refresh = {
    grant_type: "refresh_token",
    client_id: client.client_id,
    refresh_token: tokens.refresh_token,
  };
  const rotated = await app.inject({
    method: "POST",
    url: "/oauth/token",
    payload: refresh,
  });
  assert.equal(rotated.statusCode, 200);
  assert.equal(
    (
      await app.inject({
        method: "POST",
        url: "/oauth/token",
        payload: refresh,
      })
    ).statusCode,
    400,
  );
  await assert.rejects(() => service.authenticate(tokens.access_token));
  await app.inject({
    method: "POST",
    url: "/oauth/revoke",
    payload: {
      client_id: client.client_id,
      token: rotated.json().refresh_token,
    },
  });
  await assert.rejects(() => service.authenticate(rotated.json().access_token));
});
test("production cannot enable development login", () =>
  assert.throws(
    () =>
      configuration({
        NODE_ENV: "production",
        DEV_AUTH: "true",
        DEV_PASSWORD: "x",
      }),
    /restricted/,
  ));
test("MCP exposes discovery, saves briefs, and requires authentication for tool calls", async () => {
  const headers = {
    accept: "application/json, text/event-stream",
    host: "127.0.0.1:8787",
    "content-type": "application/json",
    "mcp-protocol-version": "2025-03-26",
  };
  const initialize = await app.inject({
    method: "POST",
    url: "/mcp",
    headers,
    payload: {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "Test", version: "1" },
      },
    },
  });
  assert.equal(initialize.statusCode, 200);
  const tools = await app.inject({
    method: "POST",
    url: "/mcp",
    headers,
    payload: { jsonrpc: "2.0", id: 2, method: "tools/list" },
  });
  assert.equal(tools.statusCode, 200);
  assert.deepEqual(
    tools
      .json()
      .result.tools.map((t: { name: string }) => t.name)
      .sort(),
    ["get_save_status", "save_document", "save_link"],
  );
  const payload = {
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: {
      name: "save_document",
      arguments: {
        title: "Agent brief",
        markdown: "# Prepared brief\nA sourced reading note.",
        sources: ["https://example.com/"],
        idempotency_key: randomUUID(),
      },
    },
  };
  const unauthenticated = await app.inject({
    method: "POST",
    url: "/mcp",
    headers,
    payload,
  });
  assert.equal(unauthenticated.statusCode, 401);
  assert.match(
    String(unauthenticated.headers["www-authenticate"]),
    /oauth-protected-resource/,
  );
  const saved = await app.inject({
    method: "POST",
    url: "/mcp",
    headers: { ...headers, authorization: `Bearer ${agentToken}` },
    payload,
  });
  assert.equal(saved.statusCode, 200);
  assert.ok(JSON.parse(saved.json().result.content[0].text).submission_id);
  assert.equal(await service.runOne(), true);
});
test("expired worker lease can be reclaimed after a crash", async () => {
  const input = {
    title: "Recovered brief",
    markdown: "A durable job",
    idempotency_key: randomUUID(),
  };
  const saved = await service.save(agent, input);
  await db.query(
    "UPDATE jobs SET lease_until=now()-interval '1 minute',lease_token=$2 WHERE id=$1",
    [saved.submission_id, randomUUID()],
  );
  assert.equal(await service.runOne(), true);
  assert.equal(
    (await service.status(agent, saved.submission_id!)).status,
    "ready",
  );
});
test("account deletion purges orphan files and invalidates credentials", async () => {
  const credential=await service.credential(other.owner_id,'app','Delete test');
  files.set(`${other.owner_id}/orphan`,Buffer.from('unreferenced upload'));
  const saved=await service.save(other,{title:'Disposable brief',markdown:'Test content',idempotency_key:randomUUID()});
  await service.runOne();
  await service.deleteAccount(other);
  assert.equal([...files.keys()].some(k=>k.startsWith(other.owner_id+'/')),false);
  await assert.rejects(()=>service.authenticate(credential.token));
  assert.equal((await db.query('SELECT id FROM items WHERE id=$1',[saved.submission_id])).rows.length,0);
});
