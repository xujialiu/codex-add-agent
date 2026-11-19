import http from 'node:http';
import https from 'node:https';
import { appendFileSync, closeSync, constants, fstatSync, lstatSync, openSync, readFileSync } from 'node:fs';
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
  const windows = process.platform === 'win32';
  // The Windows installer grants access to the current user on the containing directory.
  if (windows && !lstatSync(path).isFile()) throw new Error('Provider key must be a regular file');
  const flags = windows ? constants.O_RDONLY : constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK;
  const fd = openSync(path, flags);
  try {
    const file = fstatSync(fd);
    const privateFile = windows || (file.uid === process.getuid() && !(file.mode & 0o077));
    if (!file.isFile() || !privateFile || file.size > 8192) {
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
  const httpsAgent = config.proxyEnv ? new https.Agent({ proxyEnv: config.proxyEnv }) : undefined;
  const requestUpstream = (url, options, body) =>
    upstreamRequest(url, { ...options, agent: url.protocol === 'https:' ? httpsAgent : undefined }, body);
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
          const response = await requestUpstream(url, { method: 'GET', headers });
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
      const response = await requestUpstream(target, { method: 'POST', headers, signal: abort.signal }, raw);
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
  const log = entry => {
    const line = JSON.stringify({ time: new Date().toISOString(), ...entry }) + '\n';
    if (config.logFile) appendFileSync(config.logFile, line);
    else process.stdout.write(line);
  };
  const server = createRouter(config, { log });
  server.listen(config.port, '127.0.0.1', () => log({ event: 'listening', port: config.port }));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
}
