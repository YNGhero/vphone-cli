#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - uses the project path so amfidont covers binaries relevant for the project
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted
# - spoofs signatures to be recognized as apple signed for patchless variant

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  vphone_source_config_preserving_env "${PROJECT_ROOT}/.env"
fi
vphone_setup_sudo_password 0 >/dev/null 2>&1 || true

export PATH="${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

amfidont_bin="$(command -v amfidont 2>/dev/null || true)"
if [[ -z "$amfidont_bin" ]]; then
  echo "amfidont not found" >&2
  echo "Install it first: xcrun python3 -m pip install -U amfidont" >&2
  exit 1
fi

sudo_cmd=(sudo)
if [[ -n "${SUDO_ASKPASS:-}" ]]; then
  sudo_cmd=(sudo -A)
fi

encoded_project_root="$(
  /usr/bin/python3 - "$PROJECT_ROOT" <<'PY' 2>/dev/null || true
from __future__ import annotations
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe="/"))
PY
)"
[[ -n "$encoded_project_root" ]] || encoded_project_root="$PROJECT_ROOT"

amfidont_args=(daemon --path "$PROJECT_ROOT" --spoof-apple)
if [[ "$encoded_project_root" != "$PROJECT_ROOT" ]]; then
  amfidont_args+=(--path "$encoded_project_root")
fi

candidate_bins=(
  "${PROJECT_ROOT}/.build/release/vphone-cli"
  "${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
)
if [[ -d "${PROJECT_ROOT}/vm.instances" ]]; then
  for bin in "${PROJECT_ROOT}"/vm.instances/*/.vphone-cli.app/Contents/MacOS/vphone-cli; do
    [[ -f "$bin" ]] && candidate_bins+=("$bin")
  done
fi

seen_cdhashes=()
for bin in "${candidate_bins[@]}"; do
  [[ -f "$bin" ]] || continue
  cdhash="$(codesign -d -vvv "$bin" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}' || true)"
  [[ -n "$cdhash" ]] || continue
  if (( ! ${seen_cdhashes[(Ie)$cdhash]} )); then
    seen_cdhashes+=("$cdhash")
    amfidont_args+=(--cdhash "$cdhash")
  fi
done

"${sudo_cmd[@]}" "$amfidont_bin" "${amfidont_args[@]}"

echo "amfidont started"
