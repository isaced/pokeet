#!/usr/bin/env bash
#
# Fetch the CPython build that PokeetPython links against, and stage the pieces the
# app has to ship.
#
#   scripts/fetch-python.sh          # download, trim, write Vendor/
#   POKEET_PYTHON_TAG=3.12-b13 scripts/fetch-python.sh
#
# Vendor/ is gitignored: the framework is 23 MB and the stdlib is another 30 MB after
# trimming. Re-run this after cloning, and in CI before building the app.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${POKEET_PYTHON_TAG:-3.12-b13}"
VERSION="${TAG%%-*}"                      # 3.12
VENDOR="Vendor"
ARCHIVE="$VENDOR/python-support-$TAG.tar.gz"
ROOT="$VENDOR/python-$TAG"
URL="https://github.com/beeware/Python-Apple-support/releases/download/$TAG/Python-$VERSION-iOS-support.${TAG#*-}.tar.gz"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

mkdir -p "$VENDOR"

if [[ ! -f "$ARCHIVE" ]]; then
    step "Downloading Python-Apple-support $TAG"
    curl --fail --location --progress-bar "$URL" --output "$ARCHIVE"
fi

if [[ ! -d "$ROOT" ]]; then
    step "Extracting"
    mkdir -p "$ROOT"
    tar xzf "$ARCHIVE" -C "$ROOT"
fi

step "Linking the xcframework"
rm -rf "$VENDOR/Python.xcframework"
cp -R "$ROOT/Python.xcframework" "$VENDOR/Python.xcframework"

step "Staging the headers"
rm -rf "$VENDOR/python-include"
cp -R "$ROOT/Python.xcframework/lib/python$VERSION" "$VENDOR/.stdlib-copy" 2>/dev/null || true
rm -rf "$VENDOR/.stdlib-copy"
cp -R "$ROOT/Python.xcframework/ios-arm64/include/python$VERSION" "$VENDOR/python-include"

# The device slice ships pyconfig-arm64.h only, but pyconfig.h also has an
# `#ifdef __x86_64__` branch that includes pyconfig-x86_64.h. An Intel Mac
# simulating an iPhone — or an x86_64 CI runner — takes that branch and fails
# with "'pyconfig-x86_64.h' file not found". The universal simulator slice
# carries every arch's config, so top up whatever the device slice is missing;
# -n keeps the device arch's own file untouched.
SIM_INCLUDE="$ROOT/Python.xcframework/ios-arm64_x86_64-simulator/include/python$VERSION"
if [[ -d "$SIM_INCLUDE" ]]; then
    for config in "$SIM_INCLUDE"/pyconfig-*.h; do
        [[ -e "$config" ]] || continue
        cp -n "$config" "$VENDOR/python-include/" 2>/dev/null || true
    done
fi

step "Staging the stdlib"
STDLIB="$VENDOR/python-home/lib/python$VERSION"
rm -rf "$VENDOR/python-home"
mkdir -p "$(dirname "$STDLIB")"
cp -R "$ROOT/Python.xcframework/lib/python$VERSION" "$STDLIB"

# Extension modules live per-slice; the device ones are what ships.
EXTS="$ROOT/Python.xcframework/ios-arm64/lib-$VERSION/python$VERSION/lib-dynload"
if [[ -d "$EXTS" ]]; then
    rm -rf "$STDLIB/lib-dynload"
    cp -R "$EXTS" "$STDLIB/lib-dynload"
fi

step "Trimming"
# test/ alone is 32 MB. Then everything a sandboxed script has no business doing:
# ctypes can bypass every other control, and the network modules would let a script
# reach out without going through NetworkPolicy.
rm -rf "$STDLIB"/{test,idlelib,ensurepip,lib2to3,pydoc_data,tkinter,turtledemo,distutils,site-packages,venv,wsgiref,xmlrpc}
rm -f  "$STDLIB"/lib-dynload/{_ctypes,_ctypes_test,_test,_testbuffer,_testcapi,_testclinic,_testimportmultiple,_testinternalcapi,_testmultiphase,_testsinglephase,_socket,_ssl,_tkinter}*.so
rm -f  "$STDLIB"/{socket,ssl,socketserver,ftplib,smtplib,poplib,imaplib,telnetlib,uu,asynchat,asyncore}.py
rm -rf "$STDLIB"/{http,asyncio,concurrent,multiprocessing}
# urllib.parse is pure Python and useful in scripts; only the transport goes.
rm -f  "$STDLIB"/urllib/{request,response}.py

# Bytecode would be rebuilt on every run anyway (write_bytecode = 0).
find "$STDLIB" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

step "Verifying the trim"
if [[ ! -f "$STDLIB/encodings/__init__.py" ]]; then
    echo "✗ encodings is missing: the interpreter cannot start without it" >&2
    exit 1
fi
if [[ -e "$STDLIB/lib-dynload/_ctypes.cpython-$VERSION-iphoneos.so" ]]; then
    echo "✗ ctypes survived the trim" >&2
    exit 1
fi

step "Done"
printf '  framework   %s\n' "$(du -sh "$VENDOR/Python.xcframework" | cut -f1)"
printf '  stdlib      %s\n' "$(du -sh "$STDLIB" | cut -f1)"
printf '\nNothing here is committed: %s is gitignored.\n' "$VENDOR"
