#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build
open "$task_root/build/DerivedData/Build/Products/Debug/Oriv.app"
