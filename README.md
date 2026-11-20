# Add an API-key-backed model to Codex

Add a third-party model alongside GPT in Codex's `/model` picker. You can switch models in the same conversation or keep GPT as the parent and ask it to delegate a task to GLM 5.3 Flash using a native Codex subagent. [Check native delegation](docs/reference-router.md#check-native-delegation)

## Setup

| Platform | Guide | Runs the router with |
| --- | --- | --- |
| Windows | [Windows setup](docs/windows.md) | PowerShell installer and Task Scheduler |
| macOS | [macOS setup](docs/macos.md) | Bash installer and a LaunchAgent |

## Repository layout

- `docs/` contains the platform runbooks, shared verification steps, and routing decision. [Router reference](docs/reference-router.md) · [Routing decision](docs/adr/0001-use-a-local-model-router.md)
- `router/` contains the router, model catalog, and offline test. [Run the test](docs/reference-router.md#run-the-offline-test)
- `scripts/` contains the platform installers and their shared live checker. [Windows installer](scripts/install-windows.ps1) · [macOS installer](scripts/install-macos.sh)
- `GLOSSARY.md` defines the terms used across both guides. [Glossary](GLOSSARY.md)
