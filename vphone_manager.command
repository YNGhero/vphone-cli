#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export VPHONE_MANAGER_CLOSE_TERMINAL="${VPHONE_MANAGER_CLOSE_TERMINAL:-1}"
exec zsh "scripts/launch_vphone_manager.sh"
