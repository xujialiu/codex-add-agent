# Set up the model router on macOS

Use Bash to add a third-party model to Codex's `/model` picker and run the router as a per-user LaunchAgent.

The baseline is macOS, Codex CLI 0.170.0, Node.js 22.23.2, and GPT authenticated through ChatGPT sign-in. The source installation verified GPT → GLM 5.3 Flash → GPT with a short text conversation on November 19, 2026. This runbook adapts that setup to a private key file and includes a separate OpenAI API-key variant. Recheck discovery and transport with any other Codex version.

[Terminology](../GLOSSARY.md) · [Routing decision](adr/0001-use-a-local-model-router.md) · [Reference router and offline test](reference-router.md)

## 1. Identify the target and gather inputs

Work in the launch environment of the Codex account the user wants to configure. In an Orca-managed account, resolve the account's active `CODEX_HOME` from that environment. The default CLI uses `~/.codex`. Use one home and one third-party model per install. Run the shell snippets in Bash in the same terminal so values carry forward.

```bash
umask 077
target_codex_home="$(cd "${CODEX_HOME:-$HOME/.codex}" && pwd -P)"
codex_config="$target_codex_home/config.toml"
if [ -n "${ORCA_CODEX_HOME:-}" ] && [ "$(cd "$ORCA_CODEX_HOME" && pwd -P)" = "$target_codex_home" ]; then
  codex_config="$HOME/.codex/config.toml"
fi
router_dir="$target_codex_home/model-router"
node_bin="$(command -v node)"
codex --version
codex login status
"$node_bin" --input-type=module -e '
  import { zstdDecompressSync } from "node:zlib";
  if (!import.meta.main || typeof zstdDecompressSync !== "function") process.exit(1);
'
```

Confirm the active home, the built-in `openai` provider, and a GPT model the current credential can actually call. Inspect the selected user config and any active profile for existing provider, base URL, or model catalog overrides. If a router or custom catalog already controls this home, resolve that conflict before editing. For an Orca-managed account, persist routing to `~/.codex/config.toml` and open a new session from Orca to verify the mirrored settings. [Codex advanced configuration](https://learn.chatgpt.com/docs/config-file/config-advanced) · [Orca config syncing](https://orca.dev/docs/agents/codex-hot-swap#when-config-edits-seem-ignored)

Collect these inputs from the user and provider documentation.

| Input | Requirement | GLM 5.3 Flash example |
| --- | --- | --- |
| Responses base URL | Trusted HTTPS base to which the router appends `/responses` | `https://open.bigmodel.cn/api/v1` for the mainland BigModel Coding Plan |
| Model ID | Exact ID the provider accepts, distinct from every GPT catalog entry | `glm-5.3-flash` |
| Key file | Absolute path outside the repo to a regular file owned by the current user, with mode `0600` or `0400` | `~/.config/codex-provider-keys/zai.key`, resolved to an absolute path |
| OpenAI auth mode | `chatgpt` for ChatGPT sign-in or `api-key` for OpenAI API-key sign-in | `chatgpt` |

Have the user put the third-party key alone in the private file. Work with its path and permissions. Keep the key out of chat, shell history, logs, the repo, and Codex config. The router reads the file per third-party request, so key rotation takes effect when the user replaces it with the same ownership and permissions. The provider's official Codex setup confirms the BigModel Responses base URL. [BigModel Codex integration](https://docs.bigmodel.cn/cn/coding-plan/tool/codex)

For a new provider, confirm that the key enables the exact model and that the endpoint accepts Responses requests and streams Responses SSE events. A Chat Completions–only endpoint requires a protocol adapter. Verify advertised capabilities such as reasoning effort, image input, or tool calls before listing them. During switching, the selected provider receives the plaintext context and tool outputs included in its turn. Use a fresh conversation with synthetic data for verification.

## 2. Prepare the router and catalogs

Choose an unused loopback port. Replace the example key path and set the auth mode you confirmed above. Create the install directory for a fresh setup. If it already exists, inspect and reuse the existing install or resolve the conflict before writing files.

```bash
provider_base='https://open.bigmodel.cn/api/v1'
provider_model='glm-5.3-flash'
provider_key_file="$HOME/.config/codex-provider-keys/zai.key"
openai_auth='chatgpt'
router_port=60069

mkdir -m 700 "$router_dir"
codex debug models --bundled > "$router_dir/openai-models.json"
```

If the port is occupied, choose a different one. From the repository root, copy the router, offline test, and GLM catalog. For another provider, use a catalog containing one model entry with its verified capabilities. [Codex model catalog reference](https://learn.chatgpt.com/docs/enterprise/roll-out-a-gateway#model-catalog-reference)

```bash
cp router/router.mjs router/router.test.mjs "$router_dir/"
cp router/glm-5.3-flash.json "$router_dir/provider-model.json"
```

Generate the local config and, for the API-key variant, the merged picker catalog. The path prefix is a local access secret. Avoid printing it in reports.

```bash
"$node_bin" --input-type=module - "$router_dir" "$router_port" "$openai_auth" \
  "$provider_base" "$provider_model" "$provider_key_file" <<'NODE'
import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';

const [dir, portText, openaiAuth, providerBase, providerModel, providerKeyFile] = process.argv.slice(2);
const port = Number(portText);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Choose a valid local port');
if (!isAbsolute(dir) || !isAbsolute(providerKeyFile)) throw new Error('Use absolute paths');
if (!['chatgpt', 'api-key'].includes(openaiAuth)) throw new Error('Check the OpenAI auth mode');
const fallbackCatalogFile = join(dir, 'openai-models.json');
const providerCatalogFile = join(dir, 'provider-model.json');
const fallback = JSON.parse(readFileSync(fallbackCatalogFile, 'utf8'));
const { models } = JSON.parse(readFileSync(providerCatalogFile, 'utf8'));
if (models.length !== 1 || models[0].slug !== providerModel ||
    fallback.models.some(model => model.slug === providerModel)) {
  throw new Error('Use one provider entry with a unique slug matching the provider model ID');
}
if (models[0].visibility !== 'list' || (openaiAuth === 'api-key' && !models[0].supported_in_api)) {
  throw new Error('The provider entry must be visible in the active model picker');
}
const write = (name, data) => writeFileSync(join(dir, name), JSON.stringify(data, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
if (openaiAuth === 'api-key') {
  write('merged-models.json', { ...fallback, models: [...fallback.models, ...models] });
}
write('router.json', {
  port, pathPrefix: '/' + randomBytes(24).toString('base64url'), openaiAuth,
  providerBase, providerKeyFile, providerCatalogFile, fallbackCatalogFile,
});
NODE

"$node_bin" --test "$router_dir/router.test.mjs"
```

## 3. Prove same-session switching

Start the router in a separate terminal or PTY with the resolved absolute paths for `node_bin` and `router_dir`. Keep it running during the trial and confirm its listening event.

```bash
"$node_bin" "$router_dir/router.mjs" "$router_dir/router.json"
```

In the original terminal, check `/health` for `ok: true` and the provider model ID. Apply the routing settings as temporary CLI overrides.

```bash
curl --fail --silent --show-error "http://127.0.0.1:$router_port/health"
router_setting="$("$node_bin" -e '
  const c = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  console.log("openai_base_url = " + JSON.stringify("http://127.0.0.1:" + c.port + c.pathPrefix + "/v1"));
' "$router_dir/router.json")"
trial_args=(-c "$router_setting")
printf '%s\n' "$router_setting" > "$router_dir/codex-routing.toml"
if [ "$openai_auth" = 'api-key' ]; then
  catalog_setting="$("$node_bin" -p '"model_catalog_json = " + JSON.stringify(process.argv[1])' "$router_dir/merged-models.json")"
  trial_args+=(-c "$catalog_setting")
  printf '%s\n' "$catalog_setting" >> "$router_dir/codex-routing.toml"
fi
codex "${trial_args[@]}" debug models > "$router_dir/trial-models.json"
codex "${trial_args[@]}"
```

ChatGPT sign-in discovers the merged catalog through the router. The API-key variant uses `model_catalog_json` because Codex 0.170.0 skips remote discovery for the built-in OpenAI provider with both an API key and an explicit `openai_base_url`. The static catalog must include the available GPT entry and the third-party entry, with `supported_in_api: true` on models intended for that picker. This variant needs its own live trial before you persist it. [Codex 0.170.0 routing tests](https://github.com/openai/codex/blob/rust-v0.170.0/codex-rs/model-provider/src/models_endpoint_tests.rs#L134-L149)

Check that `trial-models.json` includes both models. In the trial Codex session, verify that both are selectable and that switching models preserves the conversation. [Same-session check](reference-router.md#check-same-session-switching)

## 4. Persist the verified setup

Exit the trial Codex session and stop its foreground router. Use a LaunchAgent unique to this Codex home. Generate the plist with absolute paths, then load it and check health before pointing Codex at it. For a retry, inspect existing service and config state first.

```bash
launch_label="local.codex-model-router.$(printf '%s' "$target_codex_home" | shasum -a 256 | cut -c 1-12)"
launch_domain="gui/$(id -u)"
launch_plist="$HOME/Library/LaunchAgents/$launch_label.plist"
mkdir -p "$HOME/Library/LaunchAgents"

"$node_bin" --input-type=module - "$launch_label" "$node_bin" "$router_dir" \
  <<'NODE' | plutil -convert xml1 -o "$router_dir/launch-agent.plist" -- -
import { join } from 'node:path';
const [Label, node, dir] = process.argv.slice(2);
console.log(JSON.stringify({
  Label,
  ProgramArguments: [node, join(dir, 'router.mjs'), join(dir, 'router.json')],
  WorkingDirectory: dir,
  RunAtLoad: true,
  KeepAlive: true,
  StandardOutPath: join(dir, 'service.log'),
  StandardErrorPath: join(dir, 'service-error.log'),
}));
NODE
plutil -lint "$router_dir/launch-agent.plist"
# Install only after confirming the label and destination are unused.
cp -n "$router_dir/launch-agent.plist" "$launch_plist"
launchctl bootstrap "$launch_domain" "$launch_plist"
launchctl print "$launch_domain/$launch_label"
curl --fail --silent --show-error "http://127.0.0.1:$router_port/health"
```

After the service is healthy, copy any existing `$codex_config` to `$router_dir/config.before.toml` with its permissions preserved. If the config was absent, record that in the install directory. Merge the values from `$router_dir/codex-routing.toml` into the top level of `$codex_config`, before any TOML table headers. Preserve the user's other settings, including the GPT default and OpenAI authentication. Check the resulting TOML for duplicate keys and install it atomically with mode `0600` to keep the path prefix private. Restart the intended Codex client and repeat the picker and same-session trial without the temporary CLI flags.

Use `launchctl print "$launch_domain/$launch_label"`, `/health`, and the two logs in the install directory to diagnose startup failures. If the model is missing, check the effective home and catalog source. If GPT or the third-party model fails, check the route and upstream HTTP status, then check that credential and model's access. Report the selected home, auth mode, tested model IDs, and observed result.

## Roll back

1. Compare the edited routing keys with `codex-routing.toml`. Remove the entries introduced by this install, or restore their previous values from the backup if the installation deliberately replaced any. Preserve later unrelated edits.
2. Restart Codex and confirm a direct GPT turn succeeds.
3. Unload the service with `launchctl bootout "$launch_domain/$launch_label"`. Move its plist out of `~/Library/LaunchAgents` to disable it on the next login. Keep the private installation files and config backup for inspection.
