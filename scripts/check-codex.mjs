import { execFileSync, spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { once, EventEmitter } from 'node:events';
import { readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const [mode, codex, optionsFile] = process.argv.slice(2);
const options = JSON.parse(readFileSync(optionsFile, 'utf8'));
const environment = { ...process.env, CODEX_HOME: options.codexHome };
const router = options.routerFile && JSON.parse(readFileSync(options.routerFile, 'utf8'));
const baseUrl = router && 'http://127.0.0.1:' + router.port + router.pathPrefix + '/v1';

if (mode === 'bundled') {
  try {
    const output = execFileSync(codex, ['debug', 'models', '--bundled'], {
      env: environment, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 30_000,
    });
    writeFileSync(options.bundledFile, JSON.stringify(JSON.parse(output)) + '\n');
  } catch {
    throw new Error('Could not read the bundled Codex model catalog');
  }
} else {
  await check();
}

async function check() {
  const args = [];
  if (mode === 'trial') {
    args.push('-c', 'openai_base_url=' + JSON.stringify(baseUrl));
    if (options.mergedFile) args.push('-c', 'model_catalog_json=' + JSON.stringify(options.mergedFile));
  }
  const server = spawn(codex, [...args, 'app-server'], {
    cwd: options.cwd, env: environment, windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'],
  });
  const lines = createInterface({ input: server.stdout });
  const notifications = new EventEmitter();
  const pending = new Map();
  let requestId = 0;

  server.on('error', () => notifications.emit('serverClosed'));
  server.on('exit', () => notifications.emit('serverClosed'));
  server.stdin.on('error', () => notifications.emit('serverClosed'));
  function send(message) {
    server.stdin.write(JSON.stringify(message) + '\n');
  }
  lines.on('line', line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.method) {
      if (message.id === undefined) notifications.emit('rpc/' + message.method, message.params);
      else send({ id: message.id, error: { code: -32601, message: 'Unexpected request during smoke test' } });
    } else {
      pending.get(message.id)?.(message);
    }
  });

  function request(method, params) {
    return new Promise((resolve, reject) => {
      const id = ++requestId;
      const disconnected = () => finish(new Error('Codex exited during ' + method));
      const timer = setTimeout(() => finish(new Error('Timed out during ' + method)), 60_000);
      function finish(error, result) {
        clearTimeout(timer);
        pending.delete(id);
        notifications.off('serverClosed', disconnected);
        if (error) reject(error);
        else resolve(result);
      }
      notifications.once('serverClosed', disconnected);
      pending.set(id, message => finish(message.error && new Error('Codex rejected ' + method), message.result));
      send({ id, method, params });
    });
  }

  try {
    await request('initialize', { clientInfo: { name: 'codex-model-router-test', version: '1' } });
    send({ method: 'initialized' });
    const { config } = await request('config/read', { cwd: options.cwd, includeLayers: false });
    if (config.model_provider && config.model_provider !== 'openai') {
      throw new Error('The target configuration uses a custom model provider');
    }
    if (mode === 'preflight') {
      const chatgptBase = config.chatgpt_base_url?.replace(/\/+$/, '');
      const conflicts = [
        config.openai_base_url && 'openai_base_url',
        config.model_catalog_json && 'model_catalog_json',
        chatgptBase && chatgptBase !== 'https://chatgpt.com/backend-api' && 'chatgpt_base_url',
      ].filter(Boolean);
      if (conflicts.length) throw new Error('Existing Codex routing or catalog settings: ' + conflicts.join(', '));
    }

    const entries = [];
    let cursor;
    do {
      const page = await request('model/list', { cursor, includeHidden: false });
      entries.push(...page.data);
      cursor = page.nextCursor;
    } while (cursor);
    const gptId = options.gptModel || config.model || entries.find(entry => entry.isDefault)?.model;
    const gpt = entries.find(entry => entry.model === gptId);
    if (!gpt || !gpt.model.startsWith('gpt-')) throw new Error('Select an available GPT model with -GptModel');
    if (mode === 'preflight') {
      console.log(JSON.stringify({ gptModel: gpt.model }));
      return;
    }

    const external = entries.find(entry => entry.model === options.providerModel);
    if (!external) throw new Error('The configured provider model is missing from the picker catalog');
    if (mode === 'catalog') {
      console.log('Verified picker catalog: ' + gpt.model + ', ' + external.model);
      return;
    }
    await checkTurns(request, notifications, gpt, external);
  } finally {
    lines.close();
    server.stdin.end();
    server.kill();
  }
}

async function checkTurns(request, notifications, gpt, external) {
  const { thread } = await request('thread/start', {
    cwd: options.cwd, model: mode === 'tool' ? external.model : gpt.model,
    ephemeral: true, approvalPolicy: 'never', sandbox: 'read-only',
  });
  const marker = 'ROUTER-' + randomBytes(5).toString('hex');

  async function turn(model, prompt, expected, expectedToolOutput) {
    const completed = new AbortController();
    const messages = new Map();
    const commands = [];
    const receive = ({ threadId, turnId, item }) => {
      if (threadId !== thread.id) return;
      if (item.type === 'agentMessage') messages.set(turnId, item.text);
      if (expectedToolOutput && item.type === 'commandExecution') {
        commands.push({ turnId, exitCode: item.exitCode, matched: item.aggregatedOutput?.includes(expectedToolOutput) });
      }
    };
    notifications.on('rpc/item/completed', receive);
    const timer = setTimeout(() => completed.abort(), 150_000);
    try {
      const [{ turn: started }, [event]] = await Promise.all([
        request('turn/start', {
          threadId: thread.id, model: model.model, effort: model.defaultReasoningEffort,
          input: [{ type: 'text', text: prompt }],
        }),
        once(notifications, 'rpc/turn/completed', { signal: completed.signal }),
      ]);
      if (event.threadId !== thread.id || event.turn.id !== started.id || event.turn.status !== 'completed') {
        const info = event.turn.error?.codexErrorInfo;
        const errorType = typeof info === 'string' ? info : Object.keys(info ?? {}).join(', ');
        throw new Error('The turn ended with status ' + event.turn.status + (errorType ? ' (' + errorType + ')' : ''));
      }
      if (expectedToolOutput) {
        const executed = commands.filter(command => command.turnId === started.id);
        if (!executed.some(command => command.exitCode === 0 && command.matched)) {
          const status = executed.length ? 'exit codes ' + executed.map(command => command.exitCode ?? 'none').join(', ') : 'no shell tool call';
          throw new Error('The shell tool did not print the marker (' + status + ')');
        }
      } else if (messages.get(started.id)?.trim() !== expected) {
        throw new Error('The reply did not match the test marker');
      }
      console.log('Verified streamed turn: ' + model.model);
      if (expectedToolOutput) console.log('Verified shell tool execution: ' + model.model);
    } catch (error) {
      throw new Error('Smoke test for ' + model.model + ': ' + error.message + '. Check the router status log.');
    } finally {
      clearTimeout(timer);
      completed.abort();
      notifications.off('rpc/item/completed', receive);
    }
  }

  if (mode === 'tool') {
    await turn(external, "Use the shell tool to run the PowerShell command Write-Output '" + marker +
      "'. After the command succeeds, reply exactly TOOL_READY.", 'TOOL_READY', marker);
    return;
  }
  await turn(gpt, 'Remember the marker ' + marker + '. Reply exactly GPT_READY.', 'GPT_READY');
  const recall = 'What marker did I give you? Reply with just the marker.';
  await turn(external, recall, marker);
  await turn(gpt, recall, marker);
}
