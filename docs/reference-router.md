# Reference router

Save the two code blocks as `router.mjs` and `router.test.mjs` in the private install directory from the [runbook](../README.md). They use Node built-ins. Run the test before starting the service.

## router.mjs

The router binds to loopback and requires a random path prefix and a Bearer header for inference and discovery. Upstreams authenticate their own credentials. The third-party path creates fresh headers, keeps ordinary conversation and tool history, and removes OpenAI-specific metadata and opaque history items. Extend the request adapter only for fields the target provider documents and accepts.

The HTTP upgrade response triggers SSE fallback in Codex 0.170.0. GPT inference and compaction use the selected OpenAI upstream. Third-party compaction needs a provider-specific implementation and verification. [Codex 0.170.0 HTTP fallback](https://github.com/openai/codex/blob/rust-v0.170.0/codex-rs/core/src/client.rs#L1806)

```javascript
import http from 'node:http';
import https from 'node:https';
import { constants, fstatSync, openSync, readFileSync, closeSync } from 'node:fs';
import { createHash } from 'node:crypto';
import * as zlib from 'node:zlib';

const OPENAI_BASES = {
  chatgpt: 'https://chatgpt.com/backend-api/codex',
  'api-key': 'https://api.openai.com/v1',
};
const MAX_BODY = 128 * 1024 * 1024;
const HOP_HEADERS = new Set([
  'host', 'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade', 'content-length',
]);
const PROVIDER_FIELDS = [
  'model', 'input', 'instructions', 'tools', 'tool_choice', 'parallel_tool_calls',
  'reasoning', 'text', 'max_output_tokens', 'temperature', 'top_p',
];
const OPAQUE_ITEMS = new Set([
  'reasoning', 'configuration_update', 'compaction', 'context_compaction',
]);

function decodeBody(body, encoding = '') {
  const limit = { maxOutputLength: MAX_BODY };
  switch (encoding.toLowerCase()) {
    case '':
    case 'identity': return body;
    case 'zstd': return zlib.zstdDecompressSync(body, limit);
    case 'gzip': return zlib.gunzipSync(body, limit);
    case 'br': return zlib.brotliDecompressSync(body, limit);
    case 'deflate': return zlib.inflateSync(body, limit);
    default: throw new Error('Unsupported request encoding');
  }
}

async function collect(stream, limit = MAX_BODY) {
  const chunks = [];
  let length = 0;
  for await (const chunk of stream) {
    length += chunk.length;
    if (length > limit) throw new Error('Body exceeds the router limit');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function endToEndHeaders(headers) {
  const nominated = new Set((headers.connection ?? '').toLowerCase().split(',').map(name => name.trim()));
  return Object.fromEntries(Object.entries(headers).filter(([name]) =>
    !HOP_HEADERS.has(name) && !nominated.has(name)));
}

function readProviderKey(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const file = fstatSync(fd);
    if (!file.isFile() || file.uid !== process.getuid() || (file.mode & 0o077) || file.size > 8192) {
      throw new Error('Provider key file must be small and private to the current user');
    }
    const key = readFileSync(fd, 'utf8').trim();
    if (!/^[\x21-\x7e]+$/.test(key)) throw new Error('Provider key file needs one Bearer token');
    return key;
  } finally {
    closeSync(fd);
  }
}

function thirdPartyBody(body) {
  const result = Object.fromEntries(PROVIDER_FIELDS.filter(key => Object.hasOwn(body, key))
    .map(key => [key, body[key]]));
  if (Array.isArray(result.input)) {
    const history = result.input.filter(item => !OPAQUE_ITEMS.has(item?.type));
    result.input = JSON.parse(JSON.stringify(history, (key, value) =>
      key === 'encrypted_content' || key === 'encrypted_function_args' ? undefined : value));
  }
  return { ...result, stream: body.stream !== false, store: false };
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
}

function sendError(res, status, message) {
  sendJson(res, status, { error: { message } });
}

function upstreamRequest(url, options, body) {
  return new Promise((resolve, reject) => {
    const client = url.protocol === 'https:' ? https : http;
    const req = client.request(url, options, resolve);
    req.on('error', reject);
    req.setTimeout(300_000, () => req.destroy(new Error('Upstream timeout')));
    req.end(body);
  });
}

export function createRouter(config, { openaiBases = OPENAI_BASES, log = () => {} } = {}) {
  if (!Object.hasOwn(openaiBases, config.openaiAuth)) throw new Error('Unknown OpenAI auth mode');
  if (!/^\/[A-Za-z0-9_-]{24,}$/.test(config.pathPrefix)) throw new Error('Invalid local path prefix');
  const openaiBase = openaiBases[config.openaiAuth].replace(/\/$/, '');
  const providerBase = config.providerBase.replace(/\/$/, '');
  const basePath = config.pathPrefix + '/v1';
  const fallback = JSON.parse(readFileSync(config.fallbackCatalogFile, 'utf8'));
  const model = JSON.parse(readFileSync(config.providerCatalogFile, 'utf8')).models[0];
  const catalogs = new Map();
  const merge = catalog => ({ ...catalog, models: [...catalog.models.filter(item => item.slug !== model.slug), model] });

  function getCatalog(req, url) {
    const identity = createHash('sha256')
      .update(JSON.stringify([req.headers.authorization, req.headers['chatgpt-account-id']]))
      .digest('hex');
    if (!catalogs.has(identity)) {
      if (catalogs.size >= 16) catalogs.delete(catalogs.keys().next().value);
      catalogs.set(identity, { catalog: merge(fallback), checkedAt: 0, refreshing: false });
    }
    const cached = catalogs.get(identity);
    if (!cached.refreshing && Date.now() - cached.checkedAt >= 300_000) {
      cached.refreshing = true;
      void (async () => {
        try {
          const headers = endToEndHeaders(req.headers);
          delete headers['if-none-match'];
          const response = await upstreamRequest(url, { method: 'GET', headers });
          const bytes = await collect(response, 32 * 1024 * 1024);
          if (response.statusCode === 200) {
            const catalog = JSON.parse(decodeBody(bytes, response.headers['content-encoding']));
            if (Array.isArray(catalog.models) && catalog.models.length) cached.catalog = merge(catalog);
          }
        } catch {
          // Serve the last good catalog during an upstream failure.
        } finally {
          cached.checkedAt = Date.now();
          cached.refreshing = false;
        }
      })();
    }
    return cached.catalog;
  }

  const server = http.createServer(async (req, res) => {
    let route = 'openai';
    try {
      if (req.headers.origin !== undefined) return sendError(res, 403, 'Browser origin rejected');
      const url = new URL(req.url, 'http://127.0.0.1');
      if (req.method === 'GET' && url.pathname === '/health') {
        return sendJson(res, 200, { ok: true, model: model.slug });
      }
      if (!url.pathname.startsWith(basePath + '/')) return sendError(res, 404, 'Unknown router path');
      if (!/^Bearer \S+$/i.test(req.headers.authorization ?? '')) {
        return sendError(res, 401, 'Codex Bearer authentication is required');
      }
      const path = url.pathname.slice(basePath.length);
      const openaiUrl = new URL(openaiBase + path + url.search);
      if (req.method === 'GET' && path === '/models') {
        const catalog = getCatalog(req, openaiUrl);
        log({ route: 'catalog', status: 200 });
        return sendJson(res, 200, catalog);
      }
      if (req.method !== 'POST' || !['/responses', '/responses/compact'].includes(path)) {
        return sendError(res, 404, 'Unknown router path');
      }

      let raw = await collect(req);
      let body;
      try {
        body = JSON.parse(decodeBody(raw, req.headers['content-encoding']));
      } catch {
        return sendError(res, 400, 'Invalid Responses request body or encoding');
      }
      if (typeof body?.model !== 'string' || !body.model) return sendError(res, 400, 'Missing model');
      let target = openaiUrl;
      let headers = endToEndHeaders(req.headers);
      if (body.model === model.slug) {
        route = 'third-party';
        if (path !== '/responses') return sendError(res, 501, 'Third-party compaction is unavailable');
        target = new URL(providerBase + '/responses');
        headers = {
          authorization: 'Bearer ' + readProviderKey(config.providerKeyFile),
          'content-type': 'application/json',
          accept: 'text/event-stream',
        };
        raw = Buffer.from(JSON.stringify(thirdPartyBody(body)));
      } else if (Array.isArray(body.input)) {
        const input = body.input.filter(item => item?.type !== 'reasoning' || item.encrypted_content);
        if (input.length !== body.input.length) {
          raw = Buffer.from(JSON.stringify({ ...body, input }));
          delete headers['content-encoding'];
        }
      }
      headers['content-length'] = String(raw.length);
      const abort = new AbortController();
      res.on('close', () => { if (!res.writableEnded) abort.abort(); });
      const response = await upstreamRequest(target, { method: 'POST', headers, signal: abort.signal }, raw);
      log({ route, path, status: response.statusCode });
      response.on('error', () => res.destroy());
      res.writeHead(response.statusCode, endToEndHeaders(response.headers));
      response.pipe(res);
    } catch {
      log({ route, status: 502 });
      if (!res.destroyed && !res.headersSent) sendError(res, 502, 'Check the router and upstream availability');
      else res.destroy();
    }
  });
  server.on('upgrade', (_req, socket) => {
    socket.end('HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
  });
  return server;
}

if (import.meta.main) {
  const config = JSON.parse(readFileSync(process.argv[2], 'utf8'));
  const url = new URL(config.providerBase);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) {
    throw new Error('Provider base must be an HTTPS URL without embedded authentication, query, or fragment');
  }
  const log = entry => process.stdout.write(JSON.stringify({ time: new Date().toISOString(), ...entry }) + '\n');
  const server = createRouter(config, { log });
  server.listen(config.port, '127.0.0.1', () => log({ event: 'listening', port: config.port }));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
}
```

## router.test.mjs

The test uses synthetic keys and loopback upstreams. It exercises both OpenAI auth routes, fast catalog discovery and refresh, compression, credential isolation, key rotation, history filtering, SSE framing, and HTTP upgrade fallback.

```javascript
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
```
