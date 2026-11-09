#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

hook_dir=$(git rev-parse --git-path hooks)
hook="$hook_dir/pre-push"
if [[ -e "$hook" || -L "$hook" ]]; then
  if [[ -L "$hook" ]] || ! grep -qx '# Oriv public-safety pre-push hook' "$hook"; then
    echo 'An existing pre-push hook is present; integrate the public-safety check manually.' >&2
    exit 1
  fi
fi
mkdir -p "$hook_dir"
cat > "$hook" <<'HOOK'
#!/bin/bash
# Oriv public-safety pre-push hook
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
while read -r local_ref local_oid remote_ref remote_oid; do
  # Deleted remote refs publish no commits.
  [[ "$local_oid" =~ ^0+$ ]] && continue
  revision_range="$local_oid"
  # New refs and unknown remote objects require the full local ancestry scan.
  if [[ ! "$remote_oid" =~ ^0+$ ]] && git cat-file -e "$remote_oid^{commit}" 2>/dev/null; then
    revision_range="$remote_oid..$local_oid"
  fi
  python3 scripts/check-public-safety.py --range "$revision_range"
done
HOOK
chmod +x "$hook"
echo 'Installed the local Oriv public-safety pre-push hook.'
