#!/usr/bin/env node
// Exercise a real backend using an app login, never its database/service keys.
// Retains the demonstration article and brief in the user's library.
import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {createInterface} from 'node:readline/promises';
import {Writable} from 'node:stream';
import {pathToFileURL} from 'node:url';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function verifyBackend({origin, email, password, articleURL}) {
  const base = new URL(origin);
  assert.ok(base.protocol === 'https:' ||
    (base.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(base.hostname)),
    'Use HTTPS, except for a loopback development server.');
  assert.equal(base.pathname, '/', 'Use the backend origin without a path.');
  assert.ok(!base.username && !base.password && !base.search && !base.hash,
    'The origin must not contain credentials, a query, or a fragment.');
  let session, connection;
  const expectedAssets = [];
  async function request(path, {token, body, method = body ? 'POST' : 'GET'} = {}) {
    try {
      return await fetch(new URL(path, base), {
        method, signal: AbortSignal.timeout(30_000),
        headers: {...(body ? {'Content-Type': 'application/json'} : {}), Accept: 'application/json, text/event-stream',
          ...(token ? {Authorization: `Bearer ${token}`} : {})},
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch { throw new Error('Backend request failed or timed out.'); }
  }
  async function json(path, options) {
    const response = await request(path, options);
    assert.ok(response.ok, `Backend returned HTTP ${response.status}.`);
    return response.json();
  }
  async function tool(name, args) {
    const result = await json('/mcp', {token: connection.token, body: {
      jsonrpc: '2.0', id: randomUUID(), method: 'tools/call',
      params: {name, arguments: args},
    }});
    assert.ok(!result.error && !result.result?.isError, `MCP ${name} failed.`);
    return JSON.parse(result.result.content.find(c => c.type === 'text').text);
  }
  async function ready(id) {
    for (let attempt = 0; attempt < 90; attempt++) {
      const status = await tool('get_save_status', {submission_id: id});
      if (status.status === 'ready') return;
      assert.notEqual(status.status, 'bookmark', 'Extraction retained a bookmark; inspect the app.');
      await pause(2000);
    }
    throw new Error('Import did not finish within three minutes.');
  }
  async function library() {
    const items = [];
    let cursor = 0;
    while (true) {
      const page = await json(`/v1/library?cursor=${cursor}`, {token: session.token});
      items.push(...page.items);
      if (!page.has_more) return items;
      assert.ok(page.cursor > cursor, 'Library cursor did not advance.');
      cursor = page.cursor;
    }
  }
  try {
    assert.equal((await json('/health')).ok, true);
    assert.equal((await request('/v1/library')).status, 401);
    session = await json('/v1/session', {body: {email, password}});
    connection = await json('/v1/connections', {token: session.token,
      body: {label: 'Deployment verification (temporary)'}});
    const input = {title: 'Offline Reader verification brief',
      markdown: '# Ready for offline reading\n\nThis agent-created brief verifies private storage and file integrity.',
      sources: ['https://www.wikipedia.org/'], idempotency_key: randomUUID()};
    const saved = await tool('save_document', input);
    const duplicate = await tool('save_document', input);
    assert.equal(duplicate.submission_id, saved.submission_id);
    assert.equal(duplicate.duplicate, true);
    await ready(saved.submission_id);
    expectedAssets.push({id: saved.submission_id, brief: true});
    if (articleURL) {
      const articleInput = {url: articleURL, idempotency_key: randomUUID()};
      const article = await tool('save_link', articleInput);
      const repeated = await tool('save_link', articleInput);
      assert.equal(repeated.duplicate, true);
      // An article already saved by another connection is intentionally opaque to this agent.
      if (article.submission_id) {
        await ready(article.submission_id);
        expectedAssets.push({id: article.submission_id, brief: false});
      }
    }
    const items = await library();
    let verifiedFiles = 0, verifiedImages = 0;
    for (const expected of expectedAssets) {
      const item = items.find(i => i.id === expected.id);
      assert.ok(item && item.assets.length > 0, 'Ready item is missing its manifest.');
      if (expected.brief) assert.equal(item.kind, 'brief');
      for (const asset of item.assets) {
        assert.equal(new URL(asset.url).origin, base.origin, 'Unexpected download origin.');
        const response = await request(new URL(asset.url).pathname);
        assert.ok(response.ok, 'Private asset download failed.');
        const bytes = Buffer.from(await response.arrayBuffer());
        assert.equal(bytes.length, asset.size, 'Asset size mismatch.');
        assert.equal(createHash('sha256').update(bytes).digest('hex'), asset.sha256,
          'Asset hash mismatch.');
        if (expected.brief && asset.role === 'content')
          assert.match(bytes.toString(), /Agent-created brief/);
        verifiedFiles++;
        if (asset.role !== 'content') verifiedImages++;
      }
    }
    assert.equal((await request('/v1/library', {token: connection.token})).status, 403);
    await json(`/v1/connections/${connection.connection_id}`, {token: session.token, method: 'DELETE'});
    assert.equal((await request(`/v1/saves/${saved.submission_id}`, {token: connection.token})).status, 401);
    connection = undefined;
    console.log(`Backend verification passed: MCP brief, idempotent retry, ${verifiedFiles} hash-verified files (${verifiedImages} images), private library and revoked-agent rejection.`);
    return {verifiedFiles, verifiedImages};
  } finally {
    if (connection && session) await json(`/v1/connections/${connection.connection_id}`,
      {token: session.token, method: 'DELETE'}).catch(() => console.error('Temporary connection cleanup needs retry.'));
    if (session) await json('/v1/session', {token: session.token, method: 'DELETE'})
      .catch(() => console.error('Temporary session cleanup needs retry.'));
  }
}

async function passwordPrompt() {
  assert.ok(process.stdin.isTTY, 'Run interactively to enter your app password privately.');
  process.stdout.write('App password (hidden): ');
  const hidden = new Writable({write(_chunk, _encoding, callback) {callback();}});
  const prompt = createInterface({input: process.stdin, output: hidden, terminal: true});
  try { return await prompt.question(''); }
  finally { prompt.close(); process.stdout.write('\n'); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    console.log('This check saves a demonstration brief and article in your library; it revokes its temporary assistant credential afterward.');
    await verifyBackend({
      origin: process.env.READER_URL ?? 'https://p01--reader-api--2sn8tjhm47hb.code.run',
      email: process.env.READER_EMAIL ?? 'akhilvuputuri@gmail.com',
      password: await passwordPrompt(),
      articleURL: process.env.READER_ARTICLE_URL ?? 'https://en.wikipedia.org/wiki/Airplane_mode',
    });
  } catch (error) {
    console.error(error instanceof assert.AssertionError ? error.message :
      ['Backend request failed or timed out.', 'Import did not finish within three minutes.'].includes(error.message)
        ? error.message : 'Verification failed; check the app account and backend health.');
    process.exitCode = 1;
  }
}
