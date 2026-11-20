# Model router reference

The router and its offline test use Node built-ins. The platform guides cover installation and service management. [Router source](../router/router.mjs) · [Windows setup](windows.md) · [macOS setup](macos.md)

The router binds to loopback and requires a random path prefix and a Bearer header for inference and discovery. The third-party route authenticates with a separate provider key, keeps ordinary conversation and tool history, and removes OpenAI-specific metadata and opaque history items. On Windows the installer protects the key file with a current-user-only directory ACL. On macOS the router checks file ownership and POSIX mode.

The router responds to WebSocket upgrades with HTTP 426 so Codex 0.170.0 can fall back to SSE. GPT inference and compaction use the selected OpenAI upstream. Third-party compaction requires a provider-specific adapter. [Codex 0.170.0 HTTP fallback](https://github.com/openai/codex/blob/rust-v0.170.0/codex-rs/core/src/client.rs#L1806)

## Check same-session switching

Open a new Codex session that uses the router. Check that an available GPT model and the third-party model are both selectable in `/model`. Use one thread for all three turns and replace the example marker with a new random string.

| Turn | Select with `/model` | Prompt | Expected |
| --- | --- | --- | --- |
| 1 | An available GPT model | Remember the marker `ROUTER-83719`. Reply exactly `GPT_READY`. | `GPT_READY` |
| 2 | The third-party model | What marker did I give you? Reply with just the marker. | `ROUTER-83719` |
| 3 | The original GPT model | What marker did I give you? Reply with just the marker. | `ROUTER-83719` |

Confirm that the replies stream and that the router logs successful `openai` → `third-party` → `openai` Responses requests. In a mixed-model thread, the selected provider receives the conversation and tool context included in its turn.

For a coding check, ask the third-party model to use a shell tool to print a synthetic marker in a disposable directory. Confirm that the tool exited successfully and returned the marker. Image input, long threads, and compaction need separate checks when used.

## Check native delegation

Start a fresh GPT session and ask it to “use `glm-5.3-flash` as a subagent to calculate 137 × 29, wait for it, and report its answer.” The native agent trace should show the GLM child completing with `3973`. The installation trial checks the child model, its completion message and the parent reply using a random marker.

Codex 0.171.0 encrypts the task argument in its v2 collaboration tools. The router selects Codex's native v1 tools for catalog entries that advertise v2 so a third-party child receives its assignment as ordinary user input. GPT children in those sessions also use the v1 workflow. An explicit `features.multi_agent_v2 = true` overrides the catalog choice. Use the catalog default in sessions that delegate to GLM. [Codex v1 and v2 task schemas](https://github.com/openai/codex/blob/rust-v0.171.0/codex-rs/core/src/tools/handlers/multi_agents_spec.rs#L608-L657) · [Codex version selection](https://github.com/openai/codex/blob/rust-v0.171.0/codex-rs/core/src/config/mod.rs#L1780-L1807)

## Run the offline test

Run the test from the repository root.

```sh
node --test router/router.test.mjs
```

The test uses synthetic keys and loopback upstreams. It checks catalog discovery and refresh, both OpenAI auth routes, credential isolation, key rotation, history filtering, compression, SSE framing, and HTTP upgrade fallback. Both installers also run a live test with the selected account. [Offline test](../router/router.test.mjs) · [Live checker](../scripts/check-codex.mjs)
