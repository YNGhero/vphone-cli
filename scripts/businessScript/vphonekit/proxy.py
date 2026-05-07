from __future__ import annotations

from .legacy import LegacyScripts


class ProxyService:
    """中文注释：实例代理管理。Phase 1 包装 set_instance_proxy.sh，保留 host bridge/env 管理逻辑。"""

    def __init__(self, legacy: LegacyScripts, *, transport: str = "auto") -> None:
        self.legacy = legacy
        self.transport = transport

    def _require_legacy_allowed(self, action: str) -> None:
        if self.transport == "socket-only":
            raise NotImplementedError(f"{action} is not exposed through vphone.sock yet; use --transport auto or legacy")

    def set(
        self,
        proxy_url: str,
        *,
        test: bool = False,
        no_restart: bool = False,
        bridge: str = "auto",
    ) -> dict[str, object]:
        self._require_legacy_allowed("proxy.set")
        args = [self.legacy.instance.target_arg, proxy_url]
        if test:
            args.append("--test")
        if no_restart:
            args.append("--no-restart")
        if bridge == "off":
            args.append("--no-bridge")
        elif bridge == "force":
            args.append("--force-bridge")
        proc = self.legacy.run("set_instance_proxy.sh", args)
        return {"ok": True, "transport": "legacy", "proxy_url": proxy_url, "stdout": proc.stdout}

    def clear(self, *, yes: bool = True) -> dict[str, object]:
        self._require_legacy_allowed("proxy.clear")
        args = [self.legacy.instance.target_arg, "clear"]
        if yes:
            args.append("--yes")
        proc = self.legacy.run("set_instance_proxy.sh", args)
        return {"ok": True, "transport": "legacy", "stdout": proc.stdout}

    def test(self) -> dict[str, object]:
        self._require_legacy_allowed("proxy.test")
        proc = self.legacy.run("set_instance_proxy.sh", [self.legacy.instance.target_arg, "test"])
        return {"ok": True, "transport": "legacy", "stdout": proc.stdout}
