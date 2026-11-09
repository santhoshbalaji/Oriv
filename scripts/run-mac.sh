#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
"$task_root/scripts/install-dev.sh"
open "${ORIV_DEV_INSTALL_DIR:-/Applications}/Oriv-Dev.app"
