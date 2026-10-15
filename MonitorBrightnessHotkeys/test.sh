#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
module_cache="${TMPDIR:-/tmp}/MonitorBrightnessHotkeysModuleCache"
test_binary="${TMPDIR:-/tmp}/MonitorBrightnessHotkeysLogicTests"

swiftc \
  -parse-as-library \
  -module-cache-path "$module_cache" \
  "$project_dir/Sources/CoreLogic.swift" \
  "$project_dir/Tests/LogicTests.swift" \
  -o "$test_binary" \
  -framework Carbon

"$test_binary"
