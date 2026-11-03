<div align="center">

# Pokeet

**Poke it, it ships.**

An agentic coding workshop in your pocket: a Claude Code-style agent that reads, searches, edits and explains your code — entirely on your iPhone. You review every change, then commit and push from the app. No computer needed.

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![iOS](https://img.shields.io/badge/iOS-18%2B-black)
![Status](https://img.shields.io/badge/status-early%20development-orange)

> ⚠️ Pokeet is in early development. We're building it in public — follow along, and watch this space for the first demo.

<!-- TODO: record the golden-path demo: clone → agent fixes a bug → diff cards → approve → commit & push, all on iPhone -->

</div>

## Why Pokeet?

Coding agents live in terminals on computers. But most of what an agent does — reading, searching, editing, reviewing — doesn't need a computer at all.

Pokeet puts the whole loop on your iPhone:

| | |
|---|---|
| 🤖 **A real agent, not a chatbot** | ReAct loop with a file, search, git, HTTP and script tool set. It works until the job is done. |
| 📁 **A real workspace** | Each project lives in its own sandbox, visible in the Files app. Start empty or from a Git repository. |
| 🗂️ **Multiple sessions** | Every project keeps a list of conversations. Create, rename, switch and delete them independently — each with its own agent mode. |
| 🌳 **Real git** | Clone, diff, commit, push — libgit2 on the phone, over HTTPS with a personal access token. You review applied changes, then tap Commit & Push. |
| 🎛️ **Four modes** | Plan, Ask, Auto and Bypass — chosen per session, from read-only proposals to fully automatic edits. |
| 🔍 **Review-first by default** | In Ask mode every edit arrives as a diff card — approve per hunk or per file, reject with a note. Auto and Bypass trade review for speed. |
| 🧪 **Checks its own work** | A sandboxed JavaScript runtime runs quick verification scripts on-device: hard deadline, heap and stack limits, no network, and script writes still arrive as diff cards. |
| 🔎 **Web search** | Bring your own search key — Brave, Tavily, DeepSeek Search or Exa. The agent searches, then reads the pages it picked with the guarded fetch tool — snippets alone are never trusted. See [docs/web-search.md](docs/web-search.md). |
| 🌐 **Guarded web access** | The agent can fetch HTTPS URLs, but private and local addresses are blocked and hosts can be allowlisted. Network writes are reviewed except in Bypass mode. |
| 🖼️ **Image input** | Attach up to four photos. Images are downscaled and sent as native image parts to vision-capable models. |
| 📌 **Project context** | Attach project files as `@` context chips, and the agent loads `AGENTS.md` or `CLAUDE.md` at session start. Long sessions compact automatically. |
| 🧵 **A readable run** | Tool calls collapse into an expandable execution trace, reasoning gets its own bubble, and answers stream in as rendered markdown. |
| 🖥️ **Two-pane on landscape** | Project and session sidebar beside the conversation when width allows. |
| 🔑 **Your key, your model** | Bring your own API key. Add any number of providers — OpenAI, Anthropic, Gemini, or an OpenAI-compatible gateway/local server — each with its own key, base URL and model list. |
| 🔒 **Local-first** | No Pokeet server. No account. Your code leaves your phone only through your own model requests, the URLs you let the agent fetch, web searches and git push. |

## See it in action

<table align="center">
  <tr>
    <td align="center" valign="top">
      <a href="docs/images/01-agent-trace.webp"><img src="docs/images/thumbs/01-agent-trace.webp" width="250" height="312" alt="Agent execution trace with tool calls and reasoning"></a>
      <br>
      <sub><b>A real agent</b><br>Tools, reasoning, final answer.</sub>
    </td>
    <td align="center" valign="top">
      <a href="docs/images/02-diff-review.webp"><img src="docs/images/thumbs/02-diff-review.webp" width="250" height="312" alt="Diff review with per-hunk approval"></a>
      <br>
      <sub><b>Review every change</b><br>Approve per hunk, add notes.</sub>
    </td>
    <td align="center" valign="top">
      <a href="docs/images/05-plan-mode.webp"><img src="docs/images/thumbs/05-plan-mode.webp" width="250" height="312" alt="Plan mode showing a structured plan with steps and file paths"></a>
      <br>
      <sub><b>Plan first</b><br>Investigate first, then plan.</sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top">
      <a href="docs/images/03-changes.webp"><img src="docs/images/thumbs/03-changes.webp" width="250" height="312" alt="Changes list showing added and removed line counts per file"></a>
      <br>
      <sub><b>Changes</b><br>See exactly what changed.</sub>
    </td>
    <td align="center" valign="top">
      <a href="docs/images/04-commit-push.webp"><img src="docs/images/thumbs/04-commit-push.webp" width="250" height="312" alt="Commit and push dialog"></a>
      <br>
      <sub><b>Commit &amp; push</b><br>Ship without a computer.</sub>
    </td>
    <td align="center" valign="top">
      <a href="docs/images/06-settings.webp"><img src="docs/images/thumbs/06-settings.webp" width="250" height="312" alt="Web search settings listing Brave, Tavily, DeepSeek Search and Exa with a per-provider API key field"></a>
      <br>
      <sub><b>Bring your own key</b><br>Search and model providers.</sub>
    </td>
  </tr>
</table>

## How a task flows

```
You:     "Fix the crash when the username is empty"   (Ask mode)

Pokeet:  📖 reads the repo, traces the call site
         ✏️ proposes 3 file edits → 3 diff cards
You:     ✅ approves 2, rejects 1 with a note
Pokeet:  🔧 revises
You:     🚀 Changes → Commit & Push
```

Plan mode stops at a reviewed plan instead of editing. Auto and Bypass trade some or all of the diff cards for speed.

## The agent

Four modes, chosen per session:

| Mode | What it does |
|---|---|
| **Plan** | Read-only exploration. The agent investigates and submits a structured plan for you to approve. |
| **Ask** | Default. Every file change is proposed as a diff and waits for your approval. |
| **Auto** | Edits apply immediately; deletes and moves still need review. |
| **Bypass** | Every file change applies without review. |

The tool set is intentionally small:

- **Files** — `list_files`, `read_file`, `write_file`, `edit_file`, `delete_file`, `move_file`
- **Search** — `grep`, `find` (both respect `.gitignore`), `file_info` (size, lines, text vs binary)
- **Git (read-only)** — `git_status`, `git_diff`, `git_log`, `git_show` (a file at any revision, or a commit)
- **Images** — `read_image` (a repository screenshot or diagram, downscaled and attached for vision models)
- **Web** — `http_request` (GET and HEAD always; writes are reviewed, except in Bypass mode)
- **Search** — `web_search` (your own search provider key; returns snippets, pages are read with `http_request`)
- **Scripts** — `run_script` (sandboxed JavaScript via QuickJS; see [docs/scripts.md](docs/scripts.md))
- **Planning** — `submit_plan`, `todo_write` (a running checklist for multi-step work)

Guardrails: the agent cannot run shell commands and cannot commit or push — those are UI actions. Network egress is HTTPS-only with private and local addresses blocked. Repository instructions are loaded from `AGENTS.md` or `CLAUDE.md` when a session starts.

### Sandboxed scripts

`run_script` lets the agent check its own work: compute a value, test a regex, parse a file, or run a handful of assertions. It is not a shell and not a test runner.

- **No escape hatch** — no shell, no network, no `npm`, no file access outside the repository.
- **Hard limits** — a wall-clock deadline, a heap cap and a stack cap are enforced by the engine itself, so a runaway loop stops instead of pinning a thread.
- **Review still applies** — the sandbox has no direct write access. Script writes are buffered and surface as normal diff cards, so Ask mode reviews them like any other edit.
- **On-device and small** — QuickJS is an interpreter, so no JIT entitlement is needed and no code is downloaded. It adds about 2.8 MB to the app binary.

Toolchain is JavaScript today. Embedded CPython is a later step; a remote runner is the only path to real project test suites.

## Get started

1. **Install**: TestFlight link (coming soon). Or build it yourself — it's open source.
2. **Add a model**: Settings → Model → Manage providers. Pick a template or add a provider, choose an API format, base URL and key, then fetch its model list (or add model IDs by hand). Back on the Model page, pick the active provider and model.
3. **Optionally, add search**: Settings → Tools → Web Search. Toggle it on, pick a provider, paste that provider's key. Each provider keeps its own key in the Keychain, so switching does not lose one.
4. **Poke it**: create a project — empty, or from an optional Git repository — then say what needs doing. Approve the changes you want, then use Changes → Commit & Push. Private repos use an HTTPS personal access token; SSH isn't supported yet.

### Supported API formats

| Format | Endpoint | Auth |
|---|---|---|
| OpenAI Chat Completions | `{base}/chat/completions` | `Authorization: Bearer` |
| OpenAI Responses | `{base}/responses` | `Authorization: Bearer` |
| Anthropic Messages | `{base}/messages` | `x-api-key` + `anthropic-version` |
| Gemini generateContent | `{base}/models/{model}:generateContent` | `x-goog-api-key` |

All four support streaming, tool calling and image input. Provider templates include OpenAI, Anthropic, Gemini and a generic OpenAI-compatible option. API keys are stored per provider in the iOS Keychain; provider and model settings live in `UserDefaults`.

## Development

Requirements: Xcode 27+, iOS 18+, Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated project isn't checked in.

```sh
xcodegen generate
open Pokeet.xcodeproj
```

Run the agent-kernel tests:

```sh
swift test --package-path Packages/PokeetCore
swift test --package-path Packages/PokeetScripting
```

App tests run from the generated `Pokeet` scheme in Xcode: pick any available simulator, or use `xcodebuild test -project Pokeet.xcodeproj -scheme Pokeet -destination 'platform=iOS Simulator,name=iPhone 17'`.

Ship a build to a cabled iPhone — regenerate, build, install, launch:

```sh
scripts/run-on-device.sh
```

It picks the single connected iPhone automatically. With several devices, or when signing needs a specific team, copy `scripts/local.env.example` to `scripts/local.env` (gitignored) and fill in `POKEET_DEVICE_ID` / `POKEET_TEAM_ID`; the same names work as environment variables. `POKEET_SKIP_XCODEGEN=1` / `POKEET_SKIP_BUILD=1` keep the existing project or build.

Debug builds support a scripted demo model with no API key: launch the app with the `-PokeetMockModel` argument. `-PokeetSyntheticHistory` seeds a long conversation for scrolling and performance testing.

## Architecture

Native Swift / SwiftUI. The agent kernel is isolated behind protocols so it can travel to other platforms later without a rewrite:

```
┌──────────────────────────────────────┐
│  PokeetApp (iOS app)                 │
│  SwiftUI · workspace · Files         │
│  SwiftGitX · libgit2 · review UI     │
│  QuickJS sandbox · session snapshots │
└───────────────┬──────────────────────┘
                │  protocols
┌───────────────▼──────────────────────┐
│  PokeetCore (agent kernel)           │
│  ReAct loop · tools & modes          │
│  model clients · context compaction  │
└──────────────────────────────────────┘
```

Session snapshots live in the app, so the kernel stays portable. QuickJS sits behind a `ScriptRuntime` protocol in the app, so another interpreter can be swapped in without touching the agent loop.

## Roadmap

- **v1** — Agent loop with four review modes, workspace, git (clone/diff/commit/push over HTTPS with a personal access token), diff review, guarded HTTP tool, web search, sandboxed `run_script`, context compaction, BYOK.
  The golden path: clone → fix → verify → review → commit & push, all on iPhone, no computer.
- **v2** — Embedded CPython with an audit-hook sandbox so Python repositories can run their own tests; Mac mini one-tap test runs for everything the phone cannot execute.
- **Later** — SSH remotes, more tools, skills learned from your repos, maybe Android.

## Contributing

Pokeet is built in public. Issues, PRs and ideas are welcome — especially:

- agent tools and safety policy,
- new tool implementations,
- translations,
- device testing (it should run on any iPhone, not just the newest one).

No SLA: this is an indie project, maintained with care but not on a schedule. Please be kind.

Working with an AI agent? [`AGENTS.md`](AGENTS.md) has the repository map, the checks and the conventions — the same file Pokeet itself reads when you open this repo in the app.

## License

Apache-2.0. See [LICENSE](LICENSE).
