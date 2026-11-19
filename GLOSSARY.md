# Codex model setup glossary

This project guides a setup agent through adding an API-key-backed model to an existing Codex model picker.

## Language

**Setup agent**

An AI agent that follows the runbook to configure and verify Codex on the user's machine.

**Codex home**

The directory a Codex instance uses for its account state and effective configuration.

**Configuration source**

The user configuration file where Codex settings are saved for future launches.

**Third-party model**

A model served by a provider outside OpenAI that the user can select in Codex.

_Avoid calling the model an “agent.”_

**Model provider**

A service that runs inference for a model and controls access to it.

**Provider API key**

The credential that grants access to the third-party model through its provider.

**Same-session switching**

Changing the active model within one Codex conversation while retaining the conversation context.

**Model catalog**

The list of models and their capabilities that Codex uses to populate the model picker.

**Model router**

A local intermediary that presents the model catalog to Codex and directs a turn to the provider for the selected model.
