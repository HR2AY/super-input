#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
check_dir="${SUPERINPUT_CHECK_DIR:-$project_dir/.local-checks}"
mkdir -p "$check_dir"
swiftc -parse-as-library Sources/Models.swift Sources/Storage.swift Sources/FeishuCLI.swift Tests/FeishuChecks.swift -o "$check_dir/FeishuChecks"
"$check_dir/FeishuChecks"
python3 scripts/check-public.py
