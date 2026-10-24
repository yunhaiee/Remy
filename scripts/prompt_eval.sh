#!/bin/zsh
# Run the real board prompt on still photos in the iOS Simulator (CPU), no iPhone needed.
# Usage: zsh scripts/prompt_eval.sh /path/to/folder   (see RemyEval.swift for file naming)
set -euo pipefail
cd "${0:A:h:h}"
photos="${1:?Pass a folder with dish.txt, ingredients_*.jpg, <keyword>_*.jpg and *.wav files}"
shift  # anything after the folder is passed to the app (--short, --mtp)
sim="${REMY_SIM_ID:-$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}' || true)}"
[[ -n "$sim" ]] || { print -u2 'Boot an iPhone simulator first (open -a Simulator), or set REMY_SIM_ID.'; exit 1; }
python3.12 scripts/download_model.py
xcodegen generate --spec iOS/project.yml >/dev/null
# The LiteRT-LM binary only ships an arm64 simulator slice.
xcodebuild -project iOS/Remy.xcodeproj -scheme Remy -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-cache CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -quiet build
app=.build-cache/Build/Products/Debug-iphonesimulator/Remy.app
# The app ID depends on the developer's iOS/Local.xcconfig, so read it from the build.
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl install "$sim" "$app"
data="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
mkdir -p "$data/Documents/Models" "$data/Documents/Eval"
[[ -f "$data/Documents/Models/gemma-4-E2B-it.litertlm" ]] || cp -c models/gemma-4-E2B-it.litertlm "$data/Documents/Models/"
rm -f "$data/Documents/Eval/"*(N) "$data/Documents/eval-results.json"
cp "$photos"/*.(jpg|jpeg|wav|txt|json)(N) "$data/Documents/Eval/"
xcrun simctl launch --console-pty --terminate-running-process "$sim" "$bundle" --prompt-eval "$@" 2>&1 \
  | grep --line-buffered -A12 'REMY_EVAL' &
watcher=$!
for _ in {1..300}; do [[ -f "$data/Documents/eval-results.json" ]] && break; sleep 2; done
kill $watcher 2>/dev/null || true
print "\nResults: $data/Documents/eval-results.json"
