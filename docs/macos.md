# Set up the model router on macOS

Use the Bash installer to add GLM 5.3 Flash to Codex's `/model` picker and run the router as a per-user LaunchAgent. Tested on Apple silicon with macOS 27.2.1, Codex CLI 0.171.0, Node.js 22.23.2, and ChatGPT sign-in.

## 1. Choose the launch environment

Run the installer from the macOS desktop session for the Codex account you want to use. The installer requires file-backed sign-in and the built-in OpenAI provider. The Codex home supplies the credentials for the installation test and holds the private `model-router` directory.

| Launch environment | Codex home | Configuration source |
| --- | --- | --- |
| Standalone CLI | `$CODEX_HOME` when set, otherwise `~/.codex` | `config.toml` in that home |
| Orca-managed account | `$CODEX_HOME` matching the managed `$ORCA_CODEX_HOME` | `~/.codex/config.toml` |

Orca copies the configuration source into the managed home when it launches Codex. Open a new Orca session after installation to pick up the settings. Sessions that share these settings use the OpenAI sign-in mode selected during setup. [Orca config syncing](https://orca.dev/docs/agents/codex-hot-swap#when-config-edits-seem-ignored)

```bash
codex --version
codex login status
node --version
```

## 2. Install

Save the BigModel Coding Plan API key on its own in a regular file outside the repository. Use a file you own with mode `0600` or `0400`. The default provider base is `https://open.bigmodel.cn/api/v1`. [BigModel Codex integration](https://docs.bigmodel.cn/cn/coding-plan/tool/codex)

Run the installer from the repository root with the path to your key file. [Installer source](../scripts/install-macos.sh)

```bash
bash scripts/install-macos.sh --provider-key-file "$HOME/.config/codex-provider-keys/zai.key"
```

| Option | Use |
| --- | --- |
| `--codex-exe` | Supply the absolute path to the Codex executable if discovery picks the wrong one or cannot find it. |
| `--gpt-model` | Choose an available GPT model for the test if the configured default is unavailable. |
| `--port` | Choose a free loopback port when `60069` is in use. |
| `--provider-base` and `--provider-catalog` | Use another provider's trusted HTTPS Responses base and a JSON catalog containing one visible model. |

The installer runs an offline test and verifies both same-session model switching and native GLM delegation before changing `config.toml`. It saves the routing settings in `model-router/codex-routing.toml` and backs up any existing configuration source to `model-router/config.before.toml`. For OpenAI API-key sign-in it also adds `model_catalog_json` for the merged catalog. [Codex routing configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)

The LaunchAgent starts the router at sign-in and restarts it if it exits.

## 3. Verify from your usual launcher

Use the service target printed after `Installed` and the port you selected during setup.

```bash
service_target='gui/<uid>/local.codex-model-router.<suffix>'
launchctl print "$service_target"
curl --fail --silent --show-error --noproxy 127.0.0.1 http://127.0.0.1:60069/health
```

The service should show `state = running`, and health should return `"ok":true` and `glm-5.3-flash`. Open a fresh Codex session, confirm both models appear in `/model`, and ask GPT to delegate a task to GLM. [Same-session check](reference-router.md#check-same-session-switching) · [Native delegation check](reference-router.md#check-native-delegation)

## 4. Troubleshoot

| Symptom | Check |
| --- | --- |
| `/model` warns about an overridden OpenAI base URL | Check the router's health endpoint. |
| The router is offline and the LaunchAgent is loaded | Run `launchctl kickstart "$service_target"` and check `service-error.log` if it still fails. |
| Health succeeds, but GLM is missing | Check the settings in `codex-routing.toml` against the configuration source in step 1, then open a fresh session. |
| GLM appears, but a turn fails | Check the `third-party` route and HTTP status in `service.jsonl`. Confirm the key has access to the model. |

Look for the logs in `model-router/` under the Codex home. For a failed installation, check the `model-router.failed.*` directory printed by the installer. If Codex uses an HTTP proxy, bypass it for `127.0.0.1`.

After rotating the provider key, update the file passed to `--provider-key-file` and keep its private permissions. The router reads it for every third-party request.

## 5. Roll back

1. Remove the top-level settings shown in `model-router/codex-routing.toml` from the configuration source. Use `config.before.toml` for comparison and preserve later edits.
2. Open a new session from the same launcher and confirm a GPT turn succeeds directly.
3. Run `launchctl bootout "$service_target"` with the service target from step 3. Move the plist printed by the installer out of `~/Library/LaunchAgents` and move the private `model-router` directory aside before reinstalling.
