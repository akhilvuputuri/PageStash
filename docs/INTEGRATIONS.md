# Assistant connections

The backend origin must be HTTPS and publicly reachable for hosted ChatGPT/Claude connections. Saving means captured/processing on the server, not necessarily downloaded to the iPhone.

## Existing Telegram assistant: HTTP

In app Settings create an API credential named `Telegram assistant`. It appears once; store it in the existing assistant's secret/environment configuration, not in messages, source code, or logs. Do not create another bot. The credential permits save/status only and can be revoked in Settings.

```http
POST /v1/saves/link
Authorization: Bearer YOUR_AGENT_CREDENTIAL
Content-Type: application/json

{"url":"https://example.org/article","idempotency_key":"stable-request-id"}
```

```http
POST /v1/saves/document
Authorization: Bearer YOUR_AGENT_CREDENTIAL
Content-Type: application/json

{"title":"Reading brief","markdown":"# Brief\nPrepared notes with references.","sources":["https://example.org/source"],"idempotency_key":"stable-brief-request-id"}
```

```http
GET /v1/saves/SUBMISSION_UUID
Authorization: Bearer YOUR_AGENT_CREDENTIAL
```

Typical save response: `{"submission_id":"UUID","status":"queued","duplicate":false}`. Poll with backoff; reuse the exact idempotency key when retrying a request whose outcome is unknown. Server status becomes `ready` or `bookmark` (failure retained). `already_saved` with a null ID means an existing item belongs to another connection; the agent cannot inspect it. Do not include secrets in Markdown, title or references.

An optional local command adapter for the existing assistant is `scripts/assistant-save.mjs`. It reads `READER_URL` and `READER_AGENT_TOKEN` from the environment, accepts `link URL REQUEST_ID`, `document FILE TITLE REQUEST_ID [SOURCE_URL...]`, or `status UUID`, and prints only the API result. Configure it as an existing assistant tool; no changes to the bot's messaging code are required.

## MCP tools

Endpoint: `https://YOUR_BACKEND/mcp` over Streamable HTTP.

- `save_link(url, idempotency_key)`
- `save_document(title, markdown, sources, idempotency_key)`
- `get_save_status(submission_id)`

OAuth metadata lives at `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource`. Public-client dynamic registration is at `/oauth/register`. Scopes are `save status`; consent explicitly excludes browsing/deleting the library. Only the owner application account may sign in during the personal beta.

## ChatGPT

Use the custom MCP/plugin developer connection workflow available in your ChatGPT account. Add the HTTPS MCP endpoint, choose OAuth, and complete the Offline Reader consent screen. If prompted for OAuth client configuration, use dynamic registration/public-client auth and S256 PKCE. Enable the connection in a conversation. Ask it to save a public article and then a Markdown brief; verify server status and the app separately.

Account feature availability and exact UI vary; consult the current [official custom MCP guide](https://developers.openai.com/api/docs/guides/custom-mcp-server). This implementation's protocol is tested locally; **the actual ChatGPT connection has not been tested**.

## Claude

Add a custom remote connector using the same MCP URL. Complete OAuth with your application account, then enable it in a conversation. Verify discovery, article save, brief save, status checks and revocation. See [Claude's custom connector instructions](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp). **The actual Claude connection has not been tested**.

## Host acceptance tests

For each host record: account/plan, test date, client registration method, successful consent, all three tools, token refresh, revoked connection rejection, duplicate request behavior, and confirmation that no browse/delete tools exist. Do not mark a host supported based only on a local MCP protocol test.
