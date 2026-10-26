#!/usr/bin/env bash
# Runs the reproduction on a connected iPhone and samples the app's CPU and wakeups.
#
#   scripts/measure.sh [-n RUNS] [-s SECONDS] [-o OUT_DIR] SCENARIO...
#
# Scenarios (each run starts from a fresh launch of the installed app):
#   control-fg  launch, stay in front, nothing reads the accessibility tree
#   read-fg     launch, the UI test reads the tree once, stay in front
#   read-bg     launch with background audio, the UI test reads the tree once, then the
#               Settings app is brought to the front (our app keeps running behind it)
#   control-bg  launch with background audio, Settings to the front, no tree read
#
# Runs are interleaved (a b c d a b c d ...) so slow drift on the device spreads over all of them.
# Needs: scripts/build.sh run first, `uv` (for pymobiledevice3), the iPhone unlocked on USB with
# auto-lock off (Settings > Display & Brightness > Auto-Lock > Never) for the foreground scenarios.
# Environment: UDID (default: the one connected iPhone), DERIVED_DATA (default build/dd),
# SETTLE_SECONDS (default 10), NO_INSTALL=1 to skip installing the app first.
set -euo pipefail
cd "$(dirname "$0")/.."

runs=3 seconds=60 out=out
while getopts "n:s:o:" opt; do
    case $opt in
        n) runs=$OPTARG ;;
        s) seconds=$OPTARG ;;
        o) out=$OPTARG ;;
        *) sed -n '2,19p' "$0"; exit 64 ;;
    esac
done
shift $((OPTIND - 1))
(($# > 0)) || { sed -n '2,19p' "$0"; exit 64; }

dd=${DERIVED_DATA:-build/dd}
settle=${SETTLE_SECONDS:-10}
app=$dd/Build/Products/Release-iphoneos/CmpA11yRepro.app
xctestrun=$(ls "$dd"/Build/Products/*.xctestrun | head -1)
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
udid=${UDID:-$(xcrun xctrace list devices 2>/dev/null | awk '/^== Devices ==/{d=1;next} /^== /{d=0} d && /\([0-9A-F-]{25}\)$/ {gsub(/.*\(|\)$/,""); print; exit}')}
[[ -n "$udid" ]] || { echo "no iPhone found; set UDID" >&2; exit 2; }
pmd=(uvx --python 3.13 --with pymobiledevice3==11.26.0 python -I scripts/sample.py)
mkdir -p "$out"

log() { echo "[$(date +%H:%M:%S)] $*"; }

launch() { # [extra launch arguments...]
    xcrun devicectl device process launch --device "$udid" --terminate-existing "$bundle" "$@" >/dev/null
}

read_tree() {
    xcodebuild test-without-building -xctestrun "$xctestrun" -destination "id=$udid" \
        -only-testing:ReproUITests/TreeReadTests/testReadAccessibilityTreeOnce \
        > "$out/xctest-$1.log" 2>&1 || { echo "tree read failed, see $out/xctest-$1.log" >&2; exit 1; }
}

to_settings() {
    xcrun devicectl device process launch --device "$udid" com.apple.Preferences >/dev/null
}

if [[ "${NO_INSTALL:-}" != 1 ]]; then
    log "installing $bundle on $udid"
    xcrun devicectl device install app --device "$udid" "$app" >/dev/null
fi

for ((i = 1; i <= runs; i++)); do
    for scenario in "$@"; do
        label=$scenario-$i
        case $scenario in
            control-fg) launch; sleep "$settle" ;;
            read-fg)    launch; sleep "$settle"; read_tree "$label"; sleep "$settle" ;;
            read-bg)    launch -backgroundAudio YES; sleep "$settle"; read_tree "$label"; to_settings; sleep "$settle" ;;
            control-bg) launch -backgroundAudio YES; sleep "$settle"; to_settings; sleep "$settle" ;;
            *) echo "unknown scenario $scenario" >&2; exit 64 ;;
        esac
        log "sampling $label for ${seconds}s"
        "${pmd[@]}" --udid "$udid" --bundle "$bundle" --seconds "$seconds" --label "$label" --out "$out" --notes "$scenario"
    done
done

python3 - "$out" "$@" <<'PY'
import json, statistics, sys
from pathlib import Path
out, scenarios = Path(sys.argv[1]), sys.argv[2:]
print(f"\n{'scenario':<12} {'n':>2} {'CPU % mean':>10} {'(min-max)':>14} {'wakeups/s mean':>15} {'(min-max)':>14}")
for s in scenarios:
    rows = [json.loads(p.read_text()) for p in sorted(out.glob(f"{s}-*.json"))]
    if not rows:
        continue
    cpu = [r["cpu_pct"] for r in rows]; wk = [r["wakeups_per_s"] for r in rows]
    print(f"{s:<12} {len(rows):>2} {statistics.fmean(cpu):>10.2f} {f'({min(cpu):.2f}-{max(cpu):.2f})':>14} "
          f"{statistics.fmean(wk):>15.1f} {f'({min(wk):.1f}-{max(wk):.1f})':>14}")
PY
