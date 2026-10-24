#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if ! xcodebuild -version >/dev/null; then
  print -u2 'Complete Xcode first-launch setup, including the Apple license and components.'
  exit 1
fi
python3 scripts/download_detector.py
xcodegen generate --spec iOS/project.yml
if [[ -z "${REMY_TEAM_ID:-}" || -z "${REMY_DEVICE_ID:-}" ]]; then
  print 'Building for a generic iPhone without signing. Set REMY_TEAM_ID and REMY_DEVICE_ID for device installation.'
  xcodebuild -project iOS/Remy.xcodeproj -scheme Remy -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath .build-cache CODE_SIGNING_ALLOWED=NO build
else
  xcodebuild -project iOS/Remy.xcodeproj -scheme Remy -configuration Release \
    -destination "id=$REMY_DEVICE_ID" -derivedDataPath .build-cache \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration "DEVELOPMENT_TEAM=$REMY_TEAM_ID" build
  xcrun devicectl device install app --device "$REMY_DEVICE_ID" .build-cache/Build/Products/Release-iphoneos/Remy.app
fi
