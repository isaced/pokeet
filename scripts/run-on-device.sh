#!/usr/bin/env bash
#
# Build Pokeet, install it on a connected iPhone, and launch it.
#
#   scripts/run-on-device.sh                        # regenerate, build, install, launch
#   POKEET_SKIP_BUILD=1 scripts/run-on-device.sh    # install the last build
#   POKEET_SKIP_XCODEGEN=1 ...                      # keep the current project file
#
# Machine-specific values are deliberately not checked in. Either export them, or
# copy scripts/local.env.example to scripts/local.env (gitignored):
#
#   POKEET_DEVICE_ID     device UDID; defaults to the single connected iPhone
#   POKEET_TEAM_ID       Apple developer team used for signing
#   POKEET_DERIVED_DATA  build directory (default: /tmp/pokeet-dd)
set -euo pipefail

cd "$(dirname "$0")/.."

# An exported variable wins over the file, so one-off runs can override it:
#   POKEET_DEVICE_ID=<other phone> scripts/run-on-device.sh
preset_device="${POKEET_DEVICE_ID:-}"
preset_team="${POKEET_TEAM_ID:-}"
preset_data="${POKEET_DERIVED_DATA:-}"

if [[ -f scripts/local.env ]]; then
    # shellcheck disable=SC1091
    . scripts/local.env
fi

DEVICE_ID="${preset_device:-${POKEET_DEVICE_ID:-}}"
TEAM_ID="${preset_team:-${POKEET_TEAM_ID:-}}"
DERIVED_DATA="${preset_data:-${POKEET_DERIVED_DATA:-/tmp/pokeet-dd}}"
BUNDLE_ID="com.isaced.pokeet"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Pokeet.app"
LOG="/tmp/pokeet-device-build.log"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── device ────────────────────────────────────────────────────────────────
step "Looking for a connected iPhone"
if [[ -z "$DEVICE_ID" ]]; then
    phones=$(xcrun devicectl list devices \
        --hide-default-columns --columns UDID --columns Reality 2>/dev/null \
        | awk '$1 == "physical" { print $2 }')
    count=$(printf '%s\n' "$phones" | awk 'NF' | wc -l | tr -d ' ')

    case "$count" in
        0)
            fail "No iPhone found. Plug one in, unlock it, trust this Mac, then retry (or set POKEET_DEVICE_ID)."
            ;;
        1)
            DEVICE_ID="$phones"
            ;;
        *)
            printf 'Connected phones:\n%s\n' "$phones" >&2
            fail "Several iPhones are connected. Set POKEET_DEVICE_ID to pick one."
            ;;
    esac
fi

if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_ID"; then
    fail "Device $DEVICE_ID is not connected. Plug the iPhone in with a cable, unlock it, and trust this Mac."
fi
# devicectl sometimes needs a moment before the tunnel is usable.
xcrun devicectl device info details --device "$DEVICE_ID" >/dev/null 2>&1 \
    || fail "The device is paired but not reachable. Unlock the iPhone and try again."

# ── project ───────────────────────────────────────────────────────────────
if [[ "${POKEET_SKIP_XCODEGEN:-0}" != "1" ]]; then
    step "Regenerating Pokeet.xcodeproj"
    command -v xcodegen >/dev/null || fail "xcodegen is missing: brew install xcodegen"
    xcodegen generate >/dev/null
fi

# ── build ─────────────────────────────────────────────────────────────────
if [[ "${POKEET_SKIP_BUILD:-0}" != "1" ]]; then
    step "Building for the device (log: $LOG)"
    build_args=(
        -project Pokeet.xcodeproj
        -scheme Pokeet
        -configuration Debug
        -destination "id=$DEVICE_ID"
        -derivedDataPath "$DERIVED_DATA"
        -allowProvisioningUpdates
        CODE_SIGN_STYLE=Automatic
    )
    if [[ -n "$TEAM_ID" ]]; then
        build_args+=("DEVELOPMENT_TEAM=$TEAM_ID")
    fi

    if ! xcodebuild "${build_args[@]}" build >"$LOG" 2>&1; then
        grep -E "error:|The following build commands failed" -A 2 "$LOG" | head -30 >&2
        if grep -q "requires a development team" "$LOG"; then
            fail "Signing needs your Apple team ID: set POKEET_TEAM_ID (or put it in scripts/local.env). Full log: $LOG"
        fi
        fail "Build failed — full log in $LOG"
    fi
    echo "Build succeeded"
fi

[[ -d "$APP_PATH" ]] || fail "No build at $APP_PATH. Run without POKEET_SKIP_BUILD=1 first."

# ── install ───────────────────────────────────────────────────────────────
step "Installing"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null \
    || fail "Install failed. If the pipeline is stale, unlock the phone and retry."
echo "Installed $BUNDLE_ID"

# ── launch ────────────────────────────────────────────────────────────────
step "Launching"
for _ in 1 2 3 4 5; do
    if xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null \
        | grep -q "Launched application"; then
        echo "Pokeet is running on the iPhone"
        exit 0
    fi
    sleep 3
done

printf '\n\033[33m! Installed, but the launch was refused.\033[0m\n' >&2
printf '  The iPhone is locked. Unlock it and launch Pokeet from the home screen.\n' >&2
