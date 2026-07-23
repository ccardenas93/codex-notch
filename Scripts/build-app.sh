#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/Codex Notch.app"

swift build -c release --package-path "$project_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/release/codex-notch" "$app_dir/Contents/MacOS/codex-notch"
codesign --force --deep --sign - "$app_dir"

echo "Built $app_dir"
