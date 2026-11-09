#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
install_dir="${ORIV_DEV_INSTALL_DIR:-/Applications}"
app_name="Oriv-Dev.app"
destination="$install_dir/$app_name"

# Never replace a running dev executable, or a different application at this path.
if pgrep -x Oriv-Dev >/dev/null; then
  echo 'Quit Oriv-Dev, then run this script again to update it.' >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
  [[ "$existing_id" == 'local.personalbrowser.qa' ]] || { echo "A different app exists at $destination; leaving it untouched." >&2; exit 1; }
fi

xcodebuild -project PersonalBrowser.xcodeproj -scheme PersonalBrowser \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DevDerivedData build
source_app="$task_root/build/DevDerivedData/Build/Products/Debug/$app_name"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == 'local.personalbrowser.qa' ]]
codesign --verify --deep --strict "$source_app"
mkdir -p "$install_dir"
stage=$(mktemp -d "$install_dir/.oriv-dev-install.XXXXXX")
backup=''
cleanup() {
  if [[ -n "$backup" && -d "$backup" && ! -e "$destination" ]]; then
    mv "$backup" "$destination"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
ditto "$source_app" "$stage/$app_name"
codesign --verify --deep --strict "$stage/$app_name"
if pgrep -x Oriv-Dev >/dev/null; then
  echo 'Oriv-Dev opened during the build. Quit it and run this script again.' >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  mkdir -p "$task_root/build/dev-install-backups"
  backup="$task_root/build/dev-install-backups/Oriv-Dev-$(date +%Y%m%d-%H%M%S)-$$.app.inactive"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$destination" || true
  mv "$destination" "$backup"
fi
mv "$stage/$app_name" "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
echo "Development app installed: $destination"
