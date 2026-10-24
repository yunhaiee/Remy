#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${REMY_DEVICE_ID:?Set REMY_DEVICE_ID to the paired phone's identifier or name.}"
# Your app ID comes from iOS/Local.xcconfig (for example com.yunha.Remy); the shared default is com.tonykim.Remy.
bundle="${REMY_BUNDLE_ID:-com.tonykim.Remy}"
python3 scripts/download_model.py
# The app must have been installed first. This copies into its sandbox, not Photos.
xcrun devicectl device process launch --device "$REMY_DEVICE_ID" "$bundle"
xcrun devicectl device copy to --device "$REMY_DEVICE_ID" \
  --source models/gemma-4-E2B-it.litertlm --destination Documents/Models/gemma-4-E2B-it.litertlm \
  --domain-type appDataContainer --domain-identifier "$bundle"
xcrun devicectl device process launch --device "$REMY_DEVICE_ID" \
  --terminate-existing --console "$bundle" -- --local-smoke
