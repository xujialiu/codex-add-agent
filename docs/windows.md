# Set up the model router on Windows

Use the PowerShell installer to add GLM 5.3 Flash to Codex's `/model` picker and run the router as a per-user scheduled task. The tested versions are Codex CLI 0.170.0 and Node.js 22.23.2. The installer uses a signed-in Codex account with file-backed credentials and the built-in OpenAI provider.

## 1. Choose the launch environment

Run the installer in native Windows PowerShell from the launch environment of the Codex account you want to use. The Codex home supplies the credentials for the installation test and holds the private `model-router` directory. The configuration source is where the installer saves the routing settings.

| Launch environment | Codex home | Configuration source |
| --- | --- | --- |
| Standalone CLI, including Tabby | `$env:CODEX_HOME` when set, otherwise `%USERPROFILE%\.codex` | `config.toml` in that home |
| Orca-managed account | `$env:CODEX_HOME` matching the managed `$env:ORCA_CODEX_HOME` | `%USERPROFILE%\.codex\config.toml` |

Orca copies the configuration source into the managed home when it launches Codex. Launch a new session through Orca after installation to pick up the settings. The router uses the OpenAI sign-in mode selected during setup for sessions that share those settings. [Orca config syncing](https://orca.dev/docs/agents/codex-hot-swap#when-config-edits-seem-ignored)

Check the versions and sign-in in that environment.

```powershell
codex --version
codex login status
node --version
```

## 2. Install

Run the installer from the repository root. [Installer source](../scripts/install-windows.ps1)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

The default setup reads Pi's stored `zai-coding-cn` API key from `auth.json` and uses `https://open.bigmodel.cn/api/v1` as the BigModel Coding Plan Responses base. It chooses the first set directory from `PI_CODING_AGENT_DIR` and `ORCA_PI_SOURCE_AGENT_DIR`, with `%USERPROFILE%\.pi\agent` as the fallback. The installer copies the key to `model-router\provider.key` and restricts access to the current user. [BigModel Codex integration](https://docs.bigmodel.cn/cn/coding-plan/tool/codex)

| Option | Use |
| --- | --- |
| `-CodexExe` | Supply the absolute path to the native Codex executable if discovery picks the wrong one or cannot find it. |
| `-PiAuthFile` | Point to a specific Pi `auth.json`. |
| `-ProviderKeyFile` | Use a private file containing the provider API key. Choose this or `-PiAuthFile`. |
| `-ProviderBase` and `-ProviderCatalog` | With `-ProviderKeyFile`, use another provider's trusted HTTPS Responses base and a JSON catalog containing one visible model. |
| `-GptModel` | Choose an available GPT model for the test if the configured default is unavailable. |
| `-Port` | Choose a free loopback port when `60069` is in use. |

The installer runs the offline test and an isolated trial that switches from GPT to the third-party model and back. It backs up an existing configuration source to `model-router\config.before.toml` and writes the top-level `openai_base_url` setting. For OpenAI API-key sign-in it also adds `model_catalog_json` for a merged GPT and third-party catalog. The exact settings are saved in `model-router\codex-routing.toml`. [Codex routing configuration](https://learn.chatgpt.com/docs/config-file/config-advanced) · [Model catalog settings](https://learn.chatgpt.com/docs/enterprise/roll-out-a-gateway#model-catalog-reference)

Task Scheduler starts the router at sign-in. A three-minute trigger starts it again when the previous instance has exited. The installer builds a Windows launcher that starts Node.js without a console window. [Launcher source](../scripts/windows-router-launcher.cs)

## 3. Verify from your usual launcher

Check the scheduled task and the router's health. Use your selected port if you passed `-Port`.

```powershell
Get-ScheduledTask -TaskName 'Codex model router *' | Select-Object TaskName, State
curl.exe --fail --silent --show-error --noproxy 127.0.0.1 http://127.0.0.1:60069/health
```

The task should be `Running` and health should return `"ok":true` and the selected model ID. The default ID is `glm-5.3-flash`. The router should start without opening a Windows Terminal window or tab, even briefly, at sign-in, during automatic recovery, and when started with `Start-ScheduledTask`.

Open a fresh Codex session in your usual launcher, check that both models are selectable in `/model`, and ask GPT to delegate a task to GLM. [Same-session check](reference-router.md#check-same-session-switching) · [Native delegation check](reference-router.md#check-native-delegation)

## 4. Troubleshoot

| Symptom | Check |
| --- | --- |
| `/model` displays a warning about an overridden OpenAI base URL | Codex loaded a custom address. Use the health endpoint to check whether the router is listening. |
| The router is offline and its task is registered | Start the exact task printed by the installer and check health again. |
| Health succeeds, but GLM is missing | Check that the configuration source contains the settings in `codex-routing.toml`. For Orca, use the source path in step 1. Open a fresh session from your usual launcher. |
| GLM appears, but a turn fails | Check the `third-party` route and HTTP status in `model-router\service.jsonl`. Confirm the stored key has access to the selected model. |

Use the exact task name from the installation when starting the router.

```powershell
$taskName = 'Codex model router <suffix printed by the installer>'
Start-ScheduledTask -TaskName $taskName
```

The installed files and service log are under the Codex home used for installation. For a failed installation trial, check the `model-router.failed-*` directory printed by the installer. If the launch environment uses an HTTP proxy, configure the Codex client to bypass it for `127.0.0.1`.

After rotating the Pi key, update `provider.key` in place through a private local file operation that preserves its access rules. The router reads that file for every third-party request.

## 5. Roll back

1. Remove the top-level settings shown in `model-router\codex-routing.toml` from the configuration source. Use `config.before.toml` for comparison and preserve later edits.
2. Open a new session from the same launcher and confirm a GPT turn succeeds directly.
3. Stop and unregister the installed scheduled task.

```powershell
$taskName = 'Codex model router <suffix printed by the installer>'
Stop-ScheduledTask -TaskName $taskName
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
```

Move the private `model-router` directory aside before reinstalling.
