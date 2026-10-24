#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
contract_test_dir=$(mktemp -d)
trap 'rm -rf "$contract_test_dir"' EXIT
cat iOS/Remy/Sources/JSONOutputContract.swift scripts/ResponseContractChecks.swift > "$contract_test_dir/main.swift"
xcrun swift "$contract_test_dir/main.swift"
