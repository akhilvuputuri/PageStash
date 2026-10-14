# Reader adapter contract for any assistant

This is a handoff for an agent integrating an **existing** assistant. The reader server already runs independently. Implement one adapter in the assistant's tool layer; keep transport, credentials and retry handling out of the model's prompts. No changes to the Telegram bot transport are inherently required. Whether a particular assistant needs a configuration entry or a code adapter depends on its existing tool architecture.

This task has **not** modified or connected Chief Agent. This document does not assume that Chief Agent already supports MCP. A skill or plugin can wrap this contract later; neither is required to use the server.

## Connection settings

| Setting | Value |
| --- | --- |
| Production origin | `https://p01--reader-api--2sn8tjhm47hb.code.run` |
| MCP endpoint | `https://p01--reader-api--2sn8tjhm47hb.code.run/mcp` |
| Transport | MCP Streamable HTTP over HTTPS |
| Tools to expose | `save_link`, `save_document`, `get_save_status`; optionally `list_saved_articles` |
| Agent permissions | Save articles/briefs and inspect submissions made by that connection. With the owner's per-connection opt-in only: list saved-article metadata (title, link, site, save time) |
| Not permitted | Read article content, briefs or reading progress, read unrelated submissions' status, edit/delete articles, grant itself permissions, manage credentials or delete the account |

The server is stateless at the MCP transport layer. Use a normal MCP client handshake and `tools/list`; do not expect a durable `Mcp-Session-Id`. Imports are application jobs, **not MCP Tasks**. Poll `get_save_status` rather than a `tasks/get` endpoint. `GET /mcp` is not the integration API; tool calls use POST.

### Authentication options

**Headless/server-side assistant: API credential.** In the reader app, open Settings → Assistant connections, choose a descriptive label, then create an API credential. The owner supplies it to the assistant's existing secret manager or deployment environment. Send it as `Authorization: Bearer <credential>` on MCP requests. API credentials currently expire after 365 days and can be revoked earlier in app Settings. Never put the token in chat, prompts, a repository, a URL, or routine logs. Do not give an agent the app password, app session token, database password or Supabase service key.

Suggested adapter environment names (a convention for the implementer, not a universal host configuration format):

Bind credentials to the authorized owner/session. If an assistant serves multiple users, do not expose this personal owner's credential to every user through a global tool configuration. The current reader beta accepts one configured owner email.

```dotenv
READER_MCP_URL=https://p01--reader-api--2sn8tjhm47hb.code.run/mcp
READER_AGENT_TOKEN=<secret-manager-reference-or-runtime-secret>
```

**Interactive MCP host: OAuth.** Discover `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server` on the origin. The service supports public-client dynamic registration, authorization code flow with S256 PKCE, and `save status` scopes. Persist the client registration instead of registering on every request or restart. The owner signs in and approves the reader consent page.

Important interoperability details:

- Production redirect URIs must be HTTPS and match the registered URI exactly. Localhost HTTP callbacks are currently rejected in production; use an API credential for a headless/local host that cannot provide an HTTPS callback.
- Authorization codes expire after five minutes and are single-use. Access tokens last one hour; refresh tokens last 30 days and rotate on refresh.
- Serialize refresh attempts, and atomically save the new access/refresh pair. Refresh invalidates the previous access token for that connection.
- Request `save status`. Revocation is available at `/oauth/revoke` and in app Settings.
- Use the host's secure OAuth handling. Do not automate collection of the owner's app password inside the assistant.

OAuth refresh preserves the connection identity and access to its earlier submissions. Creating a replacement API credential or completing a new OAuth connection creates a new connection identity; it cannot inspect an older connection's submissions. The owner can still inspect those items in the phone app.

## Framework-neutral interface

Expose these operations to the assistant's existing tool registry:

```ts
interface ReaderAdapter {
  saveLink(input: {
    url: string;
    idempotencyKey: string;
  }): Promise<SaveReceipt>;

  saveDocument(input: {
    title: string;
    markdown: string;
    sources: string[];
    idempotencyKey: string;
  }): Promise<SaveReceipt>;

  getSaveStatus(submissionId: string): Promise<SubmissionStatus>;
}

type SaveReceipt = {
  submissionId: string | null;
  status: "queued" | "processing" | "ready" | "bookmark" | "already_saved";
  duplicate: boolean;
};

type SubmissionStatus = {
  submissionId: string;
  status: "queued" | "processing" | "ready" | "bookmark";
  error: string | null;
};
```

### Saved-article metadata (opt-in)

`list_saved_articles({ limit?: 1–200 (default 100), before?: cursor, since?: ISO datetime })` returns `{"articles":[{"url","title","site","domain","saved_at","prepared"}],"next":cursor|null}`, newest first. `prepared` is false while an import is queued or after it failed, when the title may still be just the host name. Pass `next` as `before` for the following page. Only articles are listed (never briefs, and not items in Trash), whichever connection or app saved them, including Safari shares. It returns no content, collections, archive or reading state. Until the owner turns on **Share saved-article titles** for that connection in Settings → Assistant connections, the call returns `isError` explaining how. An agent cannot turn it on itself. Revoking the connection (in the app or through `/oauth/revoke`) or letting its last credential expire removes the choice. Links are returned as saved, including any query string. OAuth scopes are unchanged (`save status`); the app toggle is the authorization. HTTP fallback: `GET /v1/interests/saved?limit=&before=&since=`.

Map the interface to MCP calls as follows. Wire field names are snake_case:

| Adapter operation | MCP tool | Arguments |
| --- | --- | --- |
| `saveLink` | `save_link` | `{ "url": "https://example.org/article", "idempotency_key": "<stable-operation-id>" }` |
| `saveDocument` | `save_document` | `{ "title": "Reading brief", "markdown": "# Brief\nPrepared text", "sources": ["https://example.org/source"], "idempotency_key": "<stable-operation-id>" }` |
| `getSaveStatus` | `get_save_status` | `{ "submission_id": "<UUID>" }` |

Use MCP discovery as the authoritative input schema. Current limits: title 300 characters, Markdown 200,000 characters, up to 30 source URLs, URLs up to 2,048 characters, and idempotency keys 1–200 characters. The total HTTP body is capped at 220,000 bytes, so multibyte Markdown may hit that limit first.

### Result decoding

Successful MCP calls currently return JSON serialized in a text content block, rather than `structuredContent`:

```json
{
  "content": [
    {"type":"text","text":"{\"submission_id\":\"<UUID>\",\"status\":\"queued\",\"duplicate\":false}"}
  ]
}
```

Check JSON-RPC errors and `result.isError` **before** decoding success. On `isError: true`, the text is an error message and is not necessarily JSON. On success, parse the text block as JSON and validate its shape. Save responses use `submission_id`; status responses use `id`, `status`, and `error`. Normalize `id` to the adapter's `submissionId` field.

Illustrative call logic with a host-provided MCP client:

```ts
async function callReader(client, name, args) {
  const result = await client.callTool({name, arguments: args});
  if (result.isError) throw new Error("Reader rejected the operation");
  const block = result.content.find(part => part.type === "text");
  if (!block) throw new Error("Reader returned no result");
  return JSON.parse(block.text); // Validate fields before returning to the model.
}

// The caller creates and persists operationId once, before its first attempt.
const receipt = await callReader(client, "save_link", {
  url: articleUrl,
  idempotency_key: operationId
});
```

The assistant framework chooses its MCP SDK/client and resolves secrets. Do not assume a particular `mcpServers` JSON format or environment interpolation syntax works across hosts.

## Durable operation and user-facing behavior

1. Persist one opaque operation ID before submitting a new user intent. Reuse that exact ID and payload on retries, including after an uncertain timeout or process restart. Do not generate a fresh ID for every attempt.
2. Store the returned submission ID in the assistant's normal durable work state. Repeated normalized URLs are also deduplicated within the user's library.
3. Poll queued/processing submissions with backoff, for example 2, 5, 10, then 20 seconds. Use a bounded interactive wait (about one minute), then return a pending receipt and continue later through the assistant's existing job system if it has one. Do not poll every second indefinitely.
4. `ready` means prepared on the server. Only the phone can confirm **Available offline**. The adapter must not claim that a tool call has downloaded content to the phone.
5. `bookmark` means preparation failed and only submission/URL metadata was retained. It is not a saved readable article. Report the bounded explanation; do not invent a replacement summary. The phone shows it in Imports with Retry. An intentional fresh save of the same owned URL with a new operation key requeues that submission; all known keys, including recovery keys, remain idempotent. Keep the original key for uncertain network retries.
6. `already_saved` with a null submission ID means another connection already owns the existing save. Report that a matching submission already exists; its preparation/download state is unverified. The owner can review or retry it in app Imports. Do not poll a null ID or seek broader library permissions.
7. Honour cancellation in the assistant's task system. Cancellation after a successful save does not undo the saved article; agents have no delete tool.

Suggested assistant instructions:

> When asked to save an external article, use `save_link`. When asked to save a reading brief you prepared, use `save_document` with a clear title and source references. Preserve one idempotency key across retries. Report server preparation separately from phone download status. Never request library-wide credentials or include secrets in saved content.

## Failure handling

- Network timeout or transient 5xx: retry with backoff and the original idempotency key; the write may already have succeeded.
- HTTP 401: refresh OAuth once if supported, otherwise ask the owner to reconnect or replace a revoked/expired API credential. Never fall back to the app session or Supabase service key.
- HTTP 403: surface a permissions error; do not attempt broader operations.
- HTTP 400/413 or schema errors: correct the input or ask the user to shorten it; do not repeat an unchanged invalid payload.
- HTTP 429: honour `Retry-After` when present. Capacity/quota errors may require owner action rather than timed retry.
- MCP `isError`: surface a bounded, safe explanation. Business errors currently have text messages rather than a stable structured error-code contract; do not depend on fragile message parsing.

Log tool names, durations and success/error categories. Redact authorization headers, OAuth codes/tokens, content, article URLs and download capability URLs.

## HTTP fallback for assistants without an MCP client

The same adapter interface can call these endpoints with the same API credential:

| Method | Path | Body |
| --- | --- | --- |
| POST | `/v1/saves/link` | Same fields as `save_link` |
| POST | `/v1/saves/document` | Same fields as `save_document` |
| GET | `/v1/saves/<submission UUID>` | No body |

HTTP success responses are direct JSON, without the MCP text envelope. Set `Content-Type: application/json` only when sending a JSON body. The existing [command adapter](../scripts/assistant-save.mjs) supports `link`, `document`, and `status` using runtime environment secrets. Do not invoke it with unescaped model-supplied shell strings; use a process argument array or call HTTP directly.

## Acceptance checklist for the integrating agent

- Register only the three allowlisted tools in the existing assistant. Confirm the MCP handshake and tool schemas against the deployed endpoint.
- Test a public article and a clearly labelled brief; record returned IDs and terminal server status.
- Retry an identical operation and an uncertain response without creating another brief.
- Confirm the phone separately reaches Available offline and displays the content.
- Revoke the connection in app Settings; verify the adapter reports authentication failure and stops retrying until reconnected.
- For OAuth hosts, test callback matching, refresh rotation, reconnect, and revoked-token rejection.
- Document where the credential is stored and what configuration/code changed in the assistant. Keep credentials and private traces out of that report.

## Readiness as of 8 October 2026

The deployed MCP endpoint's public handshake and exact three-tool discovery have been checked. Authenticated MCP saving, duplicate retries, downloads and revocation passed against an isolated local account. Production phone sign-in and article/image offline reading were confirmed by the owner. **A production authenticated MCP connection from Chief Agent, ChatGPT or Claude has not yet been verified.** This document is an integration contract, not an installed skill, plugin or universal one-click installer.
