import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { zstdCompressSync, zstdDecompressSync, gzipSync } from 'node:zlib';
import { createRouter } from './router.mjs';

test('serves a merged catalog and streams turns using isolated credentials', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'codex-router-test-'));
  const calls = [];
  const servers = [];
  async function listen(server) {
    servers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    return 'http://127.0.0.1:' + server.address().port;
  }
  t.after(async () => {
    await Promise.all(servers.map(server => new Promise(resolve => {
      server.close(resolve);
      server.closeAllConnections();
    })));
    rmSync(dir, { recursive: true, force: true });
  });
  const upstream = await listen(http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const raw = Buffer.concat(chunks);
    const decoded = req.headers['content-encoding'] === 'zstd' ? zstdDecompressSync(raw) : raw;
    calls.push({ path: req.url, headers: req.headers, body: decoded.length ? JSON.parse(decoded) : null });
    if (req.url.startsWith('/chatgpt/models?')) {
      res.setHeader('content-type', 'application/json');
      return res.end(JSON.stringify({ models: [{ slug: 'gpt-live' }] }));
    }
    res.setHeader('content-type', 'text/event-stream');
    res.write('data: {"type":"response.output_text.delta","delta":"OK"}\n\n');
    setImmediate(() => res.end('data: {"type":"response.completed"}\n\n'));
  }));
  const files = {
    providerCatalogFile: { models: [{ slug: 'external-test' }] },
    fallbackCatalogFile: { models: [{ slug: 'gpt-bundled' }] },
  };
  const config = {
    pathPrefix: '/test-only-random-prefix-for-router',
    providerBase: upstream + '/external',
    providerKeyFile: join(dir, 'key'),
    openaiAuth: 'chatgpt',
  };
  for (const [name, value] of Object.entries(files)) {
    config[name] = join(dir, name + '.json');
    writeFileSync(config[name], JSON.stringify(value));
  }
  writeFileSync(config.providerKeyFile, 'example-provider-key\n', { mode: 0o600 });
  const openaiBases = { chatgpt: upstream + '/chatgpt', 'api-key': upstream + '/openai' };
  const root = await listen(createRouter(config, { openaiBases }));
  const base = root + config.pathPrefix + '/v1';
  const auth = { authorization: 'Bearer example-chatgpt-token', 'chatgpt-account-id': 'example-account' };
  const catalog = async () => {
    const response = await fetch(base + '/models?client_version=test', { headers: auth });
    return (await response.json()).models.map(model => model.slug);
  };
  assert.deepEqual(await catalog(), ['gpt-bundled', 'external-test']);
  let slugs;
  for (let attempt = 0; attempt < 50; attempt++) {
    slugs = await catalog();
    if (slugs[0] === 'gpt-live') break;
    await setTimeout(10);
  }
  assert.deepEqual(slugs, ['gpt-live', 'external-test']);
  assert.equal(calls[0].path, '/chatgpt/models?client_version=test');

  async function turn(url, body, authHeaders, encode, encoding) {
    const headers = { ...authHeaders, 'content-type': 'application/json' };
    if (encoding) headers['content-encoding'] = encoding;
    const response = await fetch(url + '/responses', {
      method: 'POST',
      headers,
      body: encode(Buffer.from(JSON.stringify(body))),
    });
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type'), /^text\/event-stream/);
    assert.match(await response.text(), /response.output_text.delta[\s\S]*response.completed/);
    return calls.at(-1);
  }
  const gpt = { model: 'gpt-live', input: [{ type: 'reasoning', encrypted_content: 'encrypted' }] };
  let call = await turn(base, gpt, auth, zstdCompressSync, 'zstd');
  assert.equal(call.path, '/chatgpt/responses');
  assert.equal(call.headers.authorization, auth.authorization);
  assert.equal(call.headers['chatgpt-account-id'], 'example-account');
  assert.deepEqual(call.body, gpt);

  const message = { type: 'message', role: 'user', content: 'a synthetic marker' };
  const external = {
    model: 'external-test',
    input: [...gpt.input, { ...message, encrypted_function_args: 'opaque' }],
    service_tier: 'priority',
    client_metadata: { upstream: 'openai' },
  };
  call = await turn(base, external, auth, gzipSync, 'gzip');
  assert.equal(call.path, '/external/responses');
  assert.equal(call.headers.authorization, 'Bearer example-provider-key');
  assert.equal(call.headers['chatgpt-account-id'], undefined);
  assert.equal(call.headers['content-encoding'], undefined);
  assert.deepEqual(call.body, { model: external.model, input: [message], store: false, stream: true });
  writeFileSync(config.providerKeyFile, 'example-rotated-key\n');
  call = await turn(base, external, auth, bytes => bytes);
  assert.equal(call.headers.authorization, 'Bearer example-rotated-key');

  call = await turn(base, { ...gpt, input: [...gpt.input, { type: 'reasoning' }] }, auth, bytes => bytes);
  assert.deepEqual(call.body, gpt);

  const apiKeyRoot = await listen(createRouter({ ...config, openaiAuth: 'api-key' }, { openaiBases }));
  const apiKey = { authorization: 'Bearer example-openai-api-key' };
  call = await turn(apiKeyRoot + config.pathPrefix + '/v1', gpt, apiKey, bytes => bytes);
  assert.equal(call.path, '/openai/responses');
  assert.equal(call.headers.authorization, apiKey.authorization);

  const before = calls.length;
  const denied = [
    [base + '/models', {}, 401],
    [base + '/models', { ...auth, origin: 'https://example.invalid' }, 403],
    [root + '/wrong/v1/models', auth, 404],
  ];
  for (const [url, headers, status] of denied) {
    const response = await fetch(url, { headers });
    assert.equal(response.status, status);
    await response.text();
  }
  assert.equal(calls.length, before);
  const upgradeStatus = await new Promise((resolve, reject) => {
    const request = http.get(base + '/responses', {
      headers: { connection: 'Upgrade', upgrade: 'websocket' },
    }, response => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on('error', reject);
  });
  assert.equal(upgradeStatus, 426);
});
