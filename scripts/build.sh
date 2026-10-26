#!/usr/bin/env bash
# Builds the Release app and the UI-test runner for a connected iPhone.
#
#   TEAM_ID=ABCDE12345 BUNDLE_ID_PREFIX=com.yourname scripts/build.sh
#
# Optional: CMP_VERSION, KOTLIN_VERSION, MATERIAL3_VERSION override gradle.properties;
# DERIVED_DATA (default build/dd). Needs Xcode and a JDK; XcodeGen only when the project
# file is missing (it is committed).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${TEAM_ID:-}" ]]; then
    {
        echo "TEAM_ID = ${TEAM_ID}"
        echo "BUNDLE_ID_PREFIX = ${BUNDLE_ID_PREFIX:-com.example}"
    } > iosApp/Configuration/Local.xcconfig
fi
[[ -f iosApp/Configuration/Local.xcconfig ]] || {
    echo "set TEAM_ID (and BUNDLE_ID_PREFIX) once, or write iosApp/Configuration/Local.xcconfig" >&2
    exit 64
}

gradle_args=()
[[ -n "${CMP_VERSION:-}" ]] && gradle_args+=("-Prepro.cmp=${CMP_VERSION}")
[[ -n "${KOTLIN_VERSION:-}" ]] && gradle_args+=("-Prepro.kotlin=${KOTLIN_VERSION}")
[[ -n "${MATERIAL3_VERSION:-}" ]] && gradle_args+=("-Prepro.material3=${MATERIAL3_VERSION}")
[[ -n "${EXTRA_GRADLE_ARGS:-}" ]] && read -r -a extra <<< "${EXTRA_GRADLE_ARGS}" && gradle_args+=("${extra[@]}")

mkdir -p build
log=build/xcodebuild.log
if ! xcodebuild build-for-testing \
    -project iosApp/CmpA11yRepro.xcodeproj \
    -scheme CmpA11yRepro \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${DERIVED_DATA:-build/dd}" \
    -allowProvisioningUpdates \
    REPRO_GRADLE_ARGS="${gradle_args[*]:-}" > "$log" 2>&1; then
    grep -E 'error|FAILED|e: ' "$log" | head -40 >&2
    echo "build failed, full log: $log" >&2
    exit 1
fi
ls -d "${DERIVED_DATA:-build/dd}"/Build/Products/Release-iphoneos/CmpA11yRepro.app
ls "${DERIVED_DATA:-build/dd}"/Build/Products/*.xctestrun
