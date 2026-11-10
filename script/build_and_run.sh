#!/usr/bin/env bash
# Build and launch only this custom app in its isolated test home/core.
# The user's installed Herdr and its terminal processes are never stopped.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
TASK_HOME="${HERDR_ROUTING_TEST_HOME:-/private/tmp/herdr-magpie-routing-test}"
BUNDLE="$ROOT_DIR/dist/Herdr Routing.app"
export HERDR_APP_HOME="$TASK_HOME" HC_SESSION=test-magpie-routing HERDR_APP_NO_SOUND=1
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
cd "$ROOT_DIR"
if [[ -S "$TASK_HOME/herdr-app.sock" && -x target/debug/herdr-app ]]; then
    target/debug/herdr-app do app.quit || true
fi
# Prefer the locally downloaded toolchain; callers may supply their own ZIG.
export ZIG="${ZIG:-$ROOT_DIR/../zig-python/ziglang/zig}"
export CARGO_PROFILE_DEV_DEBUG=1
cargo build --locked
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$TASK_HOME"
cp target/debug/herdr-app "$BUNDLE/Contents/MacOS/HerdrRouting.new"
mv -f "$BUNDLE/Contents/MacOS/HerdrRouting.new" "$BUNDLE/Contents/MacOS/HerdrRouting"
cp assets/icons/Herdr.icns "$BUNDLE/Contents/Resources/Herdr.icns"
# Test startup skips onboarding; it never writes the user's real app home.
python3 - "$TASK_HOME/shared.json" <<'PYSETUP'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); state=json.loads(path.read_text()) if path.exists() else {}
state.setdefault('frame.welcomed','skipped')
path.write_text(json.dumps(state))
PYSETUP
python3 - "$BUNDLE/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as file:
    plistlib.dump({'CFBundleExecutable':'HerdrRouting','CFBundleIdentifier':'dev.herdr.app.routing','CFBundleName':'Herdr Routing','CFBundleDisplayName':'Herdr Routing','CFBundlePackageType':'APPL','CFBundleIconFile':'Herdr.icns','CFBundleShortVersionString':'0.1.14','CFBundleVersion':'0.1.14','NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,'LSMinimumSystemVersion':'12.0'},file)
PY
xattr -cr "$BUNDLE"
codesign --force --sign - "$BUNDLE"
case "$MODE" in
  run|--verify)
    open -n --env "HERDR_APP_HOME=$TASK_HOME" --env "HC_SESSION=$HC_SESSION" --env "PATH=$PATH" --env HERDR_APP_NO_SOUND=1 "$BUNDLE"
    if [[ "$MODE" == --verify ]]; then
        for attempt in {1..30}; do
            [[ ! -S "$TASK_HOME/herdr-app.sock" ]] || { target/debug/herdr-app status; exit 0; }
            sleep 1
        done
        echo 'Custom app did not open its control socket' >&2; exit 1
    fi
    ;;
  --debug) lldb -- "$BUNDLE/Contents/MacOS/HerdrRouting" ;;
  --logs|--telemetry)
    open -n --env "HERDR_APP_HOME=$TASK_HOME" --env "HC_SESSION=$HC_SESSION" --env "PATH=$PATH" "$BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "HerdrRouting"'
    ;;
  *) echo 'usage: script/build_and_run.sh [run|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
