<div align="center">

# Pokeet

**Poke it, it ships.**

An agentic coding workshop in your pocket: a Claude Code-style agent that reads, writes and commits code — entirely on your iPhone. No computer needed.

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![iOS](https://img.shields.io/badge/iOS-18%2B-black)
![Status](https://img.shields.io/badge/status-early%20development-orange)

> ⚠️ Pokeet is in early development. The demo below is the goal, not the reality — yet. We're building it in public; follow along.

<!-- TODO: record the golden-path demo: clone → agent fixes a bug → diff cards → approve → push, all on iPhone -->

</div>

## Why Pokeet?

Coding agents live in terminals on computers. But most of what an agent does — reading, writing, editing, committing — doesn't need a computer at all.

Pokeet puts the whole loop on your iPhone:

| | |
|---|---|
| 🤖 **A real agent, not a chatbot** | ReAct loop with tools: read, write, edit, shell, git. It works until the job is done. |
| 📁 **A real workspace** | Each project lives in its own sandbox, visible in the Files app. Start empty or from a Git repository. |
| 🌳 **Real git** | Clone, diff, commit, push — libgit2 on the phone, over HTTPS with a personal access token. |
| 🖥️ **A virtual shell** | A curated set of shell commands for the agent, backed by the workspace. |
| 🔍 **Diff-first review** | Every edit arrives as a diff card. Approve per hunk, per file. Nothing lands without your poke. |
| 🖼️ **Image input** | Attach up to four photos. Images are downscaled and sent as native image parts to vision-capable models. |
| 🔑 **Your key, your model** | Bring your own API key. Add any number of providers — OpenAI, Anthropic, Gemini, or an OpenAI-compatible gateway/local server — each with its own key, base URL and model list. |
| 🔒 **Local-first** | No Pokeet server. No account. Your code leaves your phone only through your own model requests and git push. |

## How a task flows

```
You:     "Fix the crash when the username is empty"

Pokeet:  📖 reads the repo
         ✏️ edits 3 files → shows you 3 diff cards
You:     ✅ approves 2, rejects 1 with a note
Pokeet:  🔧 revises, commits, pushes to GitHub
```

## Get started

1. **Install**: TestFlight link (coming soon). Or build it yourself — it's open source.
2. **Add a model**: Settings → Manage providers → pick a template or add a provider. Choose an API format, base URL and key, then fetch the model list or add model IDs manually. Pick the active provider and model.
3. **Poke it**: create a project — empty, or from an optional Git repository — then say what needs doing. Private repos use an HTTPS personal access token; SSH isn't supported yet.

### Supported API formats

| Format | Endpoint | Auth |
|---|---|---|
| OpenAI Chat Completions | `{base}/chat/completions` | `Authorization: Bearer` |
| OpenAI Responses | `{base}/responses` | `Authorization: Bearer` |
| Anthropic Messages | `{base}/messages` | `x-api-key` + `anthropic-version` |
| Gemini generateContent | `{base}/models/{model}:generateContent` | `x-goog-api-key` |

All four support streaming and tool calling. API keys are stored per provider in the iOS Keychain; provider and model settings live in `UserDefaults`.

## Development

Requirements: Xcode 27+, iOS 18+, Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated project isn't checked in.

```sh
xcodegen generate
open Pokeet.xcodeproj
```

Run the agent-kernel tests:

```sh
swift test --package-path Packages/PokeetCore
```

Debug builds support a scripted demo model with no API key: launch the app with the `-PokeetMockModel` argument.

## Architecture

Native Swift / SwiftUI. The agent kernel is isolated behind protocols so it can travel to other platforms later without a rewrite:

```
┌──────────────────────────────────────┐
│  PokeetApp (iOS shell)               │
│  SwiftUI · workspace · Files         │
│  SwiftGitX · libgit2 · shell · diff  │
└───────────────┬──────────────────────┘
                │  protocols
┌───────────────▼──────────────────────┐
│  PokeetCore (agent kernel)           │
│  ReAct loop · tool registry          │
│  session persistence · model client  │
└──────────────────────────────────────┘
```

## Roadmap

- **v1** — Agent loop, workspace, git (clone/diff/commit/push over HTTPS with a personal access token), curated shell, diff-review UI, BYOK.
  The golden path: clone → fix → review → push, all on iPhone, no computer.
- **v2** — `run_script`: JavaScript via JavaScriptCore, embedded CPython; Mac mini one-tap test runs.
- **Later** — SSH remotes, more tools, skills learned from your repos, maybe Android.

## Contributing

Pokeet is built in public. Issues, PRs and ideas are welcome — especially:

- curated shell commands,
- new tool implementations,
- translations,
- device testing (it should run on any iPhone, not just the newest one).

No SLA: this is an indie project, maintained with care but not on a schedule. Please be kind.

## License

Apache-2.0. See [LICENSE](LICENSE).
