#!/bin/zsh
# Double-click to clone a stopped clean vphone instance, reset ECID/UDID, then launch GUI.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"
exec zsh scripts/clone_vphone_instance.sh
