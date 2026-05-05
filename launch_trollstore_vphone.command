#!/bin/zsh
# Double-click this file in Finder to create/switch to the TrollStore/JB vphone
# and boot the native GUI. First run can take a long time because it restores
# firmware and installs the jailbreak/TrollStore environment.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"
exec zsh scripts/launch_trollstore_vphone.sh
