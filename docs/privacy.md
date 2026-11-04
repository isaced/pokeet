# Privacy policy

**Pokeet** is an iOS client for a coding agent. It runs entirely on your device: there is no Pokeet account, no Pokeet server, and no telemetry. The developer never receives your code, your prompts, your keys or your usage data.

Last updated: 2026-11-04

## What stays on your device

- **Repositories and sessions.** Projects you create, the files the agent reads or writes, and the conversation history live in the app's own storage. Uninstalling the app deletes them.
- **API keys.** Every provider key is stored in the iOS Keychain, scoped to this app.
- **Preferences.** Provider, model, tool and appearance settings live in `UserDefaults`.

None of this is copied to a Pokeet-operated service — there isn't one.

## What leaves your device, and where

The app makes a network request only when a feature you configured needs one, and the request goes straight to the party you chose:

| When | Destination |
|---|---|
| You send a message, attach an image, or the agent calls a tool | The model provider you configured (base URL, key and model in Settings) — prompt text, file excerpts and images needed to answer |
| The agent runs `web_search` | The search provider whose key you entered |
| The agent runs `http_request` | The URL the agent asked for, subject to the app's network policy (HTTPS anywhere, plain HTTP only to a local address) |
| You commit and push | The Git remote you configured, with the access token you supplied |

Those providers are third parties. Their handling of the data you send is governed by their own privacy policies, not this one. Pokeet does not proxy, log or retain any of it.

## What Apple collects

TestFlight and iOS may collect crash logs, diagnostics and beta feedback, depending on the settings on your device and the consent you gave when installing TestFlight. That data reaches the developer only in the forms Apple provides for beta testing.

## What Pokeet does not do

- No analytics or advertising SDKs, no third-party trackers, no device identifiers collected by the developer.
- No selling, renting or sharing of personal data.
- No background uploads: the app does nothing on the network while you are not using it.

## Your control

Remove a provider key in Settings → Model, or a search key in Settings → Tools → Web Search, at any time. Deleting the app removes the app's files, sessions and Keychain items stored for it.

## Children

Pokeet is a developer tool and is not directed at children under 13.

## Changes and contact

Material changes to this policy will be published on this page, with the date above updated. Questions: [isaced@63.com](mailto:isaced@63.com).
