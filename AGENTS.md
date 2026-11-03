# Pokeet — agent notes

Native iOS client for a coding agent that works on repositories stored on the phone. SwiftUI, Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. Apache-2.0.

## Verify on a device when you have one

Simulator runs miss what actually bites: Keychain, QuickJS, libgit2, provisioning and signing. With an iPhone plugged in, one command does the whole loop:

```bash
scripts/run-on-device.sh          # xcodegen → device build → install → launch
```

- The script auto-detects the connected iPhone. With several plugged in, or to pin a signing team, copy `scripts/local.env.example` to `scripts/local.env` (gitignored) and fill in `POKEET_DEVICE_ID` / `POKEET_TEAM_ID`; environment variables work too.
- No device available? Fall back to the simulator and say so — don't claim a change was tried on hardware.
- A locked phone still installs; the launch is skipped with a warning. Report that instead of retrying in a loop.
- Iterating? `POKEET_SKIP_XCODEGEN=1` keeps the project file, `POKEET_SKIP_BUILD=1` installs the last build.

## Project layout

- `project.yml` → `Pokeet.xcodeproj`, which is **generated and gitignored**. After adding, renaming or deleting a file, run `xcodegen generate` or the new file silently stays out of the build.
- `Pokeet/` — the app (SwiftUI + services). `Pokeet/Features/<Area>/`, `Pokeet/Services/`.
- `Packages/PokeetCore` — dependency-free kernel: agent loop, tools, providers, workspace. No UIKit/SwiftUI here.
- `Packages/PokeetScripting` — QuickJS runtime wrapper.
- `PokeetTests/` — XCTest, runs against the app target. `Packages/*/Tests` — Swift Testing.
- `docs/` — design docs per subsystem; update the matching doc when behaviour changes.

## Checks

```bash
# App target (XCTest). Any available simulator works — list them with
# `xcrun simctl list devices available` and adjust the name.
xcodebuild test -project Pokeet.xcodeproj -scheme Pokeet \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/pokeet-dd

# Agent kernel and scripting runtime (Swift Testing)
swift test --package-path Packages/PokeetCore
swift test --package-path Packages/PokeetScripting
```

Green tests are the floor, not the finish line: try the change in the app, and on a device when it touches Keychain, file access, network policy or the agent loop.

## Conventions

- Never add a Pokeet-hosted server: no accounts, no proxy, no telemetry. Keys and traffic stay between the user and the provider they configured.
- Network egress goes through the existing guards (`NetworkPolicy`, `NetworkEndpointGuard`); do not hand-roll URL checks.
- Secrets live in the Keychain via `SecretStore`; preferences live in `UserDefaults` through `AppSettings`. Never log either, and never put a real key in a test, a fixture or a commit.
- Extension points are catalogs, not `switch` statements sprinkled across screens: see `ProviderTemplates` and `WebSearchProviderKind`. A new backend should touch one file plus its adapter.
- Machine-specific values (device UDIDs, team IDs, local paths) belong in `scripts/local.env` or the environment, never in tracked files.
- Match the surrounding style: small views, `@Observable` models on `@MainActor`, no third-party UI dependencies, SF Symbols over custom art unless a brand asset exists.
- Comments explain *why* (a constraint, a trade-off); skip narration of what the code plainly does.
- Provider adapters that fail should say what the user can do next ("top up", "check the key in Settings"), not just echo a status code.
