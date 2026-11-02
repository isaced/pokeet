<div align="center">

# Pokeet

**Poke it, it ships.**

An agentic coding workshop in your pocket: a Claude Code-style agent that reads, writes and commits code — entirely on your iPhone. No computer needed.

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![iOS](https://img.shields.io/badge/iOS-17%2B-black)
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
| 📁 **A real workspace** | Each project lives in its own sandbox, visible in the Files app. |
| 🌳 **Real git** | Clone, diff, commit, push — powered by libgit2, right on the phone. |
| 🖥️ **A virtual shell** | A curated set of shell commands for the agent, backed by the workspace. |
| 🔍 **Diff-first review** | Every edit arrives as a diff card. Approve per hunk, per file. Nothing lands without your poke. |
| 🔑 **Your key, your model** | Bring your own API key. Any OpenAI-compatible endpoint: DeepSeek, Anthropic, OpenAI, OpenRouter… |
| 🔒 **Local-first** | No Pokeet server. No account. Your code never leaves your phone except through your own git push. |

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
2. **Add a model**: Settings → Model → paste an API key (any OpenAI-compatible endpoint).
3. **Poke it**: clone a repo or open a project, and say what needs doing.

## Architecture

Native Swift / SwiftUI. The agent kernel is isolated behind protocols so it can travel to other platforms later without a rewrite:

```
┌──────────────────────────────────────┐
│  PokeetApp (iOS shell)               │
│  SwiftUI · workspace · File Provider │
│  libgit2 · curated shell · diff UI   │
└───────────────┬──────────────────────┘
                │  protocols
┌───────────────▼──────────────────────┐
│  PokeetCore (agent kernel)           │
│  ReAct loop · tool registry          │
│  session persistence · model client  │
└──────────────────────────────────────┘
```

## Roadmap

- **v1** — Agent loop, workspace, git (clone/diff/commit/push), curated shell, diff-review UI, BYOK.
  The golden path: clone → fix → review → push, all on iPhone, no computer.
- **v2** — `run_script`: JavaScript via JavaScriptCore, embedded CPython; Mac mini one-tap test runs.
- **Later** — more tools, skills learned from your repos, maybe Android.

## Contributing

Pokeet is built in public. Issues, PRs and ideas are welcome — especially:

- curated shell commands,
- new tool implementations,
- translations,
- device testing (it should run on any iPhone, not just the newest one).

No SLA: this is an indie project, maintained with care but not on a schedule. Please be kind.

## License

Apache-2.0. See [LICENSE](LICENSE).
