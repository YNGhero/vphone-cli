#!/bin/zsh
# Double-click to install an IPA/TIPA into a selected vphone instance.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"
exec zsh scripts/install_ipa_to_instance.sh
