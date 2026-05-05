#!/bin/zsh
# Double-click to create a brand-new independent TrollStore/JB vphone instance,
# then boot its native GUI and start SSH/VNC/RPC forwards.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"
exec zsh scripts/create_trollstore_instance.sh
