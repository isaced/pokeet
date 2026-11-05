# Skills (`SKILL.md`)

A skill is a directory with a `SKILL.md`: frontmatter that says what it is and when it applies, plus a body with the actual procedure. The model sees only name + description until a task matches, then reads the body. That keeps a dozen procedures out of the context budget until one is needed.

**Status: Phase 1 shipped** — discovery, prompt section, `read_file` resolution, `/skill:<name>`. Phase 2 (Settings UI, transcript chips) is not built. The reference implementation is pi (`docs/skills.md` and `dist/core/skills.js` in the pi install), which implements the [Agent Skills spec](https://agentskills.io/specification); this document records where an iPhone forces a different answer.

## Scope

In:

- discovery of `SKILL.md` directories, project-level and app-level;
- a `<skills>` system-prompt section carrying name, description and location only;
- loading the body through the existing `read_file` tool, so mode filtering and approval stay untouched;
- `/skill:<name>` expansion in a chat message, for when the model misses a skill;
- warning-level diagnostics — a malformed skill never blocks a session.

Out:

- distributing skills as packages (pi's npm/git path) — no package manager;
- executing a skill's `scripts/foo.sh` — there is no shell; bundled code has to go through `run_script` (JS/Python);
- per-skill enable switches, model-invoked chaining between skills.

## What pi does, and what we copy

| pi behaviour | Pokeet | Why |
|---|---|---|
| `SKILL.md` directory, frontmatter `name` + `description` | same | portable with the Anthropic/pi collections |
| Discovery: `~/.agents/skills`, project `.agents/skills` walking ancestors to the repo root, `.pi/skills`, explicit settings paths | three fixed roots below; no ancestor walk | the project *is* the repo, and ancestors are app-container directories |
| Directory with `SKILL.md` is a leaf; otherwise recurse; top-level `.md` also accepted | leaf rule and recursion yes; top-level `.md` deferred | fewer ways to get it wrong on day one |
| `.gitignore` / `.ignore` / `.fdignore` filtering, symlink dedupe, skip `node_modules` | reuse `IgnoreRules`, skip symlinks, skip `node_modules`/`Pods`/`Vendor`/`.build`, depth cap 4 | a phone filesystem scan is slower than a laptop's |
| Warnings, not fatal: bad name, missing description (skill skipped), name collision (first wins) | same | one broken skill must not brick a session |
| Prompt lists `<name><description><location>`, absolute path | **pseudo path** `skill://<name>/SKILL.md` for app-level skills | the iOS container UUID changes between installs, so a baked absolute path goes stale; and `PathSandbox` rightly refuses reads outside the repo |
| Body loaded by the plain `read` tool | `read_file`, which resolves `skill://…` through the catalog | one code path, `readFiles` capability already gates it |
| `/skill:name args` → `<skill name= location=>` block + args | same, minus the command palette | cheapest way to force a skill the model skipped |
| `/reload` rescans | `reloadSkills()` + a fresh catalog per session | no file watcher needed |

## Discovery roots

One loader, three roots, project first so a repo can pin its own copy of a shared skill:

| order | root | source | what `location` looks like |
|---|---|---|---|
| 1 | `<project>/.agents/skills` | project | `.agents/skills/pdf-tools/SKILL.md` |
| 2 | `<project>/.pokeet/skills` | project | `.pokeet/skills/pdf-tools/SKILL.md` |
| 3 | `<App Support>/Pokeet/Skills` | user | `skill://pdf-tools/SKILL.md` |

The app-level directory is created on launch (`AppEnvironment.init`). A missing root means "no
skills", and discovery never creates directories, so without that `mkdir` the global folder could
be neither found nor filled. It is *not* reachable from Files.app: `UIFileSharingEnabled` exposes
`Documents/` only, and this lives in `Library/Application Support/`. Settings → Skills is the entry
point instead (see Phase 2); `simctl` is only useful for seeding a test.

Rules, all in `SkillCatalog`:

- a directory containing `SKILL.md` is a skill, not a pack — discovery does not descend into it;
- otherwise recurse, at most 4 levels below the root, skipping dot-directories, `node_modules`, `Pods`, `Vendor`, `.build`, `DerivedData` and symlinks;
- `.gitignore` (via the existing `IgnoreRules`) applies to the project roots, so an ignored skill stays invisible;
- `SKILL.md` over 24 KB is skipped with an issue; frontmatter without a non-empty `description` is skipped;
- name comes from frontmatter, falling back to the directory name; the spec's naming rules produce warnings, not failures;
- a name collision keeps the first discovered skill and records an issue.

## Data model

```swift
public struct SkillLocations: Sendable, Equatable, Hashable {
    public let projectRoot: URL
    /// The directory that contains skill directories, not its parent.
    public let userSkillsDirectory: URL?
}

public struct Skill: Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let location: String          // exactly what read_file accepts
    public let directory: String         // what relative references resolve against
    public let source: Source            // .project | .user
    public let disablesModelInvocation: Bool
    public let fileURL: URL
}

public struct SkillCatalog: Sendable, Equatable {
    public let skills: [Skill]
    public let issues: [SkillIssue]
}
```

The body is never held in the catalog: one `String` copy per skill is wasted memory on a phone, and we want the read to be re-observable in the transcript.

Discovery reads the filesystem with `FileManager`, not through `Workspace`: the app-level root is outside the repo, and the wall we must not breach is the *tool* sandbox, not the loader. `Workspace` still supplies `IgnoreRules` for the project roots.

Frontmatter: `PokeetCore` stays dependency-free, so no Yams. `Frontmatter.parse` handles top-level `key: value` scalars, quoted strings and `true`/`false` — enough for `name`, `description`, `disable-model-invocation`. Other spec fields (`license`, `compatibility`, `metadata`, `allowed-tools`) parse and are ignored. Multi-line YAML values are not supported; a folded description would read as its own marker.

## Prompt section

Appended after project instructions, matching pi's section order (rules → project context → skills):

```text
The following skills provide specialized instructions for specific tasks.
Use the read_file tool to load a skill's file when the task matches its description.
Pass the location exactly as listed; relative references inside a skill resolve against its directory.

<available_skills>
  <skill>
    <name>pdf-tools</name>
    <description>Extract text and tables from PDF files. Use when reading, converting, or inspecting PDFs.</description>
    <location>skill://pdf-tools/SKILL.md</location>
  </skill>
</available_skills>

Load a skill before following its procedure. Skills add context and conventions; they never override the tool and safety rules above.
```

- Values are XML-escaped, same as pi.
- `location` is whatever `read_file` accepts verbatim: repo-relative for project skills, `skill://` for app-level ones. This is the one wording change from pi — "use absolute paths" is wrong on iOS in both directions (stale container UUIDs, sandbox refusals).
- `disable-model-invocation: true` skills are omitted here but still resolvable by `/skill:<name>`.
- **Cap:** 32 skills and 4 000 characters for the section, project skills first then alphabetical. pi has no cap; a phone does. 4 KB is roughly 5% of the default 80 000-character context budget, and descriptions are what the cap is really bounding — the spec allows 1 024 characters each. Truncation records an issue; the skills left out stay loadable by name.

## Loading the body

`ToolContext` carries the catalog. `ReadFileTool` dispatches on the prefix: `skill://` goes to the catalog, everything else to `workspace.read` unchanged. The catalog resolves a name from its in-memory list rather than concatenating a path, then hands the remainder to `PathSandbox` rooted at the skill's own directory, so `..`, absolute segments and `~` are rejected before any filesystem call. A skill's exact `location` is also accepted, which is how `/skill:<name>` reads a project skill.

The prefix is deliberately not `skills/…`: a repo may legitimately contain a `skills/` directory, and the two meanings would collide.

This is the alternative to allow-listing a second root in `PathSandbox`: the sandbox keeps its one invariant ("everything the agent reads and writes lives in the repo"), and the exception is one read-only, name-checked lookup.

Project skills need no scheme at all — they live in the repo, so `.agents/skills/<name>/SKILL.md` already reads fine. Only app-level skills use `skill://`.

## Session integration

- `AgentSession.init(…, skills: SkillLocations? = nil)` loads a catalog at construction; nil means "no skills", so tests and non-project sessions are unaffected.
- `systemMessage` composes skills over project instructions: `skills.compose(with: instructions.compose(with: base + modeGuidance))`. `reset`, `restore`, `setMode` funnel through it, so a restored session never carries a stale skill list.
- `reloadSkills()` rescans and rewrites the system message; `SessionRuntime` creates a session per conversation, so opening one is already a refresh. No file watching: refresh-on-demand keeps the battery contract.
- `SessionRuntime` passes `SkillLocations(projectRoot: project.directory, userSkillsDirectory: environment.skillsDirectory)`.
- `AppEnvironment.init(skillsDirectory:)` takes an override for tests; the default is `<container>/Library/Application Support/Pokeet/Skills`.

## `/skill:<name>` commands

```text
/skill:pdf-tools extract report.pdf
```

`AgentSession.send` replaces it with

```text
<skill name="pdf-tools" location=".agents/skills/pdf-tools/SKILL.md">
References are relative to .agents/skills/pdf-tools.

<body>
</skill>

extract report.pdf
```

An unknown name keeps the user's text and prepends what is available:

```text
no skill named "pdf". Available skills: pdf-tools, release.

/skill:pdf do it
```

Hidden skills (`disable-model-invocation`) are invocable here — that is the whole point of the flag.

## Rollout

- **Phase 1 — shipped.** `SkillCatalog.swift` (catalog, frontmatter, loader), `read_file` dispatch, `/skill:` expansion.
- **Phase 2 — shipped.** Settings → Skills, folder / single-file import, delete, reload fan-out, repository import (shallow clone, picker, provenance).
- **Not built.** zip import, opening a global `SKILL.md` in the editor, per-skill enable, "update available" checks, top-level `*.md` skills in a project, `/skill` autocomplete.

## Tests

`Packages/PokeetCore/Tests/PokeetCoreTests`:

- `SkillCatalogTests` — roots and ordering, directory-name fallback, nested discovery, depth cap, leaf rule, skipped directories, ignored skills, missing directories, missing description, invalid/overlong name and description, oversized file, collision, prompt metadata only, XML escaping, hidden skills, empty catalog, cap, `skill://` resolution and its refusals, body read.
- `ReadSkillToolTests` — `read_file` reads an app-level skill, refuses unknown names with `ToolError`, still reads a project skill through the workspace.
- `SkillSessionTests` — prompt injection, no skills means no section, `/skill:` expansion with args, hidden skills, unknown-skill message, plain text untouched, `reloadSkills`, restored history.

`PokeetTests`:

- `SessionRuntimeTests.testProjectSkillsReachTheSession` — a project skill reaches the real `AgentSession` and the `/skill:` body lands in the request.
- `GlobalSkillsTests` — app-level skills on the simulator's real filesystem: the directory is created at init, a skill dropped into it is discovered, it reaches the system prompt through `SessionRuntime`, `read_file` returns its body as a tool result, `/skill:<name>` expands it, and the default container path is writable.

## Trying it on a simulator

The global folder is inside the container, so there is no Files.app route to it (see above). Drop a
skill in with `simctl` and relaunch:

```bash
CONTAINER=$(xcrun simctl get_app_container booted com.isaced.pokeet data)
mkdir -p "$CONTAINER/Library/Application Support/Pokeet/Skills/pdf-tools"
# write SKILL.md there, then:
xcrun simctl terminate booted com.isaced.pokeet
xcrun simctl launch booted com.isaced.pokeet
```

That is verified: with a skill written this way, the app logged `pdf-tools/user` on launch, meaning
the running process found it at its real container path.

Two traps when reproducing it:

- `xcodebuild test` installs the app again and hands it a **new** data container, so a skill seeded
  by hand is gone by the time a test runs. Seed the installed app, not the test host.
- `xcodebuild test`-driven tests therefore assert against a temporary directory (`AppEnvironment`
  takes a `skillsDirectory` override) or against the container the test host itself was given.

## Phase 2 — Skills screen, import, repositories

**Status: shipped.** `Pokeet/Features/Settings/SkillsView.swift`, `SkillsStore`, `SkillRepositorySheet`,
`GitSkillRepositoryFetcher`, `SkillSourceURL`, `SkillRepositoryImport`.

### What the screen shows

- **This app** — global skills, deletable by swipe. Issues are surfaced first, in orange, so a
  skipped `SKILL.md` is never silent.
- **Per project** — read-only, so the answer to "why is my global skill not the one being loaded"
  is on the same screen as the global one.
- `+` opens a menu: **Import from Files…** (folder or single `.md`) and **Import from Repository…**.
  A **Reload** button rescans; importing or deleting also reloads every open chat through
  `AgentRunRegistry.reloadSkills()`.

### Import from Files

Security-scoped read → copy into a `.staging-<uuid>` folder → `SkillCatalog.inspect` → collision
check → swap. Rejected: no `SKILL.md`, missing description, more than 200 files, more than 2 MB,
any symlink. A failure removes the staging copy and leaves the live tree untouched; a replace moves
the old folder aside, moves the new one in, and only then deletes the old one. The installed folder
is always renamed to the skill's `name`, so `skill://<name>/` and the folder cannot disagree.

### Import from a repository

```
owner/repo · https://… · …/tree/<ref>/<path> · #ref
        │  policy check (NetworkAccessPolicy, HTTPS only) → shallow clone (depth 1)
        ▼
picker: every SKILL.md in the tree (depth ≤ 4), checked by default when the link named a folder
        │
        ▼
same import path as a picked folder, plus provenance
```

Decisions that mattered:

- **Shallow clone through libgit2**, not a tarball: the only host-agnostic option that works with
  the token already in Settings → Git. SwiftGitX's `CloneOptions` has no depth, so
  `GitSkillRepositoryFetcher` calls `git_clone` with `fetch_opts.depth = 1` and its own transfer
  callback — which is also where cancellation lands, so a 90-second timeout actually aborts
  instead of waiting for the download.
- **Policy before network.** `SkillRepositoryImport.validate` refuses when network access is off or
  the host is outside the allow-list, with the same wording the rest of the app uses.
- **A clone without a `SKILL.md` is an error that names the fix**: paste the link to the skill
  folder, because the scan stops at depth 4.
- **All-or-nothing batches.** A collision anywhere in the selection refuses the whole import, and a
  failure mid-batch rolls back what it already installed.
- **Provenance in `<Skills>/.sources.json`** (repository, ref, commit, path, imported at). A
  dot-file, so discovery ignores it; deleting a skill forgets its entry. This is the hook for a
  future "update available" badge.

Refs are treated as branch names (`checkout_branch`); a tag or raw SHA is not resolved yet.

### Tests

`PokeetCore`: `SkillCatalogTests` (inspect, repository scan, depth and heavy-directory rules,
`SkillSourceURL` parsing), `SkillRepositoryImportTests` (policy, timeout, empty repository, cleanup,
path filter).
`Pokeet`: `SkillsStoreTests` (folder and file import, symlink / size / file-count rejection,
collision, replace, rollback, delete, provenance, project listing, staging leftovers),
`GitSkillRepositoryFetcherTests` (live, gated by `POKEET_LIVE_SKILL_REPO=1`: real shallow clone of
`vercel-labs/skills`, `.git/shallow` present, `find-skills` found, import works).

Verified on an iPhone 18 Pro simulator: `vercel-labs/skills` clones in ~2.5 s, the picker lists
`find-skills`, and the imported skill lands under the app's own skills folder.

### Deliberately not done

- zip import (iOS has no zip reader; the folder path covers the same flow)
- editing a global `SKILL.md` in the app — it lives outside the workspace sandbox
- per-skill enable, and "update available" for repository imports
- update checks against the recorded commit

## Open questions

1. `.pokeet/skills` or `.agents/skills` only? Both are read today.
2. Skill-local scripts: there is no shell, so a bundled `extract.sh` cannot run. Document "use
   `run_script`" or add a skill-aware hint to the prompt?
3. Multi-line YAML values in frontmatter (`description: >`) read as their own marker; either reject
   them with an issue or implement folding.
4. The global folder stays in `Library/Application Support`, so Files.app cannot reach it. Import is
   the entry point now; is "reveal in Files" or an export action still wanted?
5. Refs that are tags or SHAs. `checkout_branch` covers branches; anything else needs a fetch plus a
   detached checkout.
