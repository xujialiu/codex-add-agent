# Add an API-key-backed model to Codex

Add a third-party model alongside GPT in Codex's `/model` picker. A local router sends each turn to the selected provider so you can switch models in the same conversation. Both setup guides use GLM 5.3 Flash as the example.

## Setup

| Platform | Guide | Runs the router with |
| --- | --- | --- |
| Windows | [Windows setup](docs/windows.md) | PowerShell installer and Task Scheduler |
| macOS | [macOS setup](docs/macos.md) | Bash setup and a LaunchAgent |

## Repository layout

- `docs/` contains the platform runbooks, shared verification steps, and routing decision. [Router reference](docs/reference-router.md) · [Routing decision](docs/adr/0001-use-a-local-model-router.md)
- `router/` contains the router, model catalog, and offline test. [Run the test](docs/reference-router.md#run-the-offline-test)
- `scripts/` contains the Windows installer and live checker. [Windows installer](scripts/Install-Windows.ps1)
- `GLOSSARY.md` defines the terms used across both guides. [Glossary](GLOSSARY.md)
