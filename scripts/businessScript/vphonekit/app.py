from __future__ import annotations

import shlex
from typing import Any

from .hostctl import HostControlClient
from .ssh import SSHClient


class AppService:
    """中文注释：封装 App 启动、关闭、URL 打开等生命周期操作。"""

    def __init__(self, hostctl: HostControlClient, ssh: SSHClient, *, transport: str = "auto") -> None:
        self.hostctl = hostctl
        self.ssh = ssh
        self.transport = transport

    def _allow_fallback(self) -> bool:
        return self.transport in {"auto", "legacy"}

    def launch(self, bundle_id: str, *, url: str | None = None, screen: bool = False) -> dict[str, Any]:
        req: dict[str, Any] = {"t": "app_launch", "bundle_id": bundle_id, "screen": screen}
        if url:
            req["url"] = url
        if self.transport != "legacy":
            try:
                resp = self.hostctl.request(req)
                resp["transport"] = "socket"
                return resp
            except Exception:
                if not self._allow_fallback():
                    raise
        self._launch_via_ssh(bundle_id, url=url)
        return {"ok": True, "transport": "ssh", "bundle_id": bundle_id}

    def terminate(self, bundle_id: str, *, process_name: str | None = None, screen: bool = False) -> dict[str, Any]:
        if self.transport != "legacy":
            try:
                resp = self.hostctl.request({"t": "app_terminate", "bundle_id": bundle_id, "screen": screen})
                resp["transport"] = "socket"
                return resp
            except Exception:
                if not self._allow_fallback():
                    raise
        proc = process_name or self.resolve_process_name(bundle_id)
        if not proc:
            raise RuntimeError("could not resolve process name; pass process_name")
        q_proc = shlex.quote(proc)
        self.ssh.run(f"killall {q_proc} 2>/dev/null || true; sleep 0.2; killall -9 {q_proc} 2>/dev/null || true", check=True)
        return {"ok": True, "transport": "ssh", "bundle_id": bundle_id, "process_name": proc}

    def open_url(self, url: str) -> dict[str, Any]:
        if self.transport != "legacy":
            try:
                resp = self.hostctl.request({"t": "open_url", "url": url})
                resp["transport"] = "socket"
                return resp
            except Exception:
                if not self._allow_fallback():
                    raise
        q_url = shlex.quote(url)
        self.ssh.run(f"url={q_url}; if command -v uiopen >/dev/null 2>&1; then uiopen \"$url\"; else open \"$url\"; fi", check=True)
        return {"ok": True, "transport": "ssh", "url": url}

    def list(self, filter: str = "all") -> dict[str, Any]:
        resp = self.hostctl.request({"t": "app_list", "filter": filter})
        resp["transport"] = "socket"
        return resp

    def foreground(self) -> dict[str, Any]:
        resp = self.hostctl.request({"t": "app_foreground"})
        resp["transport"] = "socket"
        return resp

    def _launch_via_ssh(self, bundle_id: str, *, url: str | None = None) -> None:
        q_bundle = shlex.quote(bundle_id)
        if url:
            q_url = shlex.quote(url)
            cmd = f"url={q_url}; if command -v uiopen >/dev/null 2>&1; then uiopen \"$url\" >/dev/null 2>&1; else open \"$url\" >/dev/null 2>&1; fi"
        else:
            cmd = f"bundle={q_bundle}; if command -v open >/dev/null 2>&1 && open -b \"$bundle\" >/dev/null 2>&1; then exit 0; fi; if command -v uiopen >/dev/null 2>&1 && uiopen --bundleid \"$bundle\" >/dev/null 2>&1; then exit 0; fi; echo 'no app launcher succeeded' >&2; exit 1"
        self.ssh.run(cmd, check=True)

    def resolve_process_name(self, bundle_id: str) -> str | None:
        q_bundle = shlex.quote(bundle_id)
        script = f"""
bundle={q_bundle}
for root in /private/var/containers/Bundle/Application /var/containers/Bundle/Application; do
  [ -d "$root" ] || continue
  list="/tmp/vphone-app-plists.$$"
  find "$root" -maxdepth 3 -name Info.plist -path "*.app/Info.plist" > "$list" 2>/dev/null || true
  while IFS= read -r plist; do
    bid=""
    if command -v plutil >/dev/null 2>&1; then bid=$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true); fi
    if [ "$bid" = "$bundle" ]; then
      exe=""
      if command -v plutil >/dev/null 2>&1; then exe=$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null || true); fi
      [ -n "$exe" ] || exe=$(basename "$(dirname "$plist")" .app)
      rm -f "$list"
      printf '%s\n' "$exe"
      exit 0
    fi
  done < "$list"
  rm -f "$list"
done
case "$bundle" in
  com.burbn.instagram) printf '%s\n' Instagram; exit 0 ;;
esac
exit 1
"""
        proc = self.ssh.run(script, check=False)
        if proc.returncode == 0 and proc.stdout:
            return str(proc.stdout).strip().splitlines()[-1]
        return None
