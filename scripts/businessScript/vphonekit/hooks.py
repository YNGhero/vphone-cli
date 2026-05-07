from __future__ import annotations

from .legacy import LegacyScripts


class HooksService:
    """中文注释：Hook/Tweak 安装入口。Phase 1 先包装现有安装脚本。"""

    def __init__(self, legacy: LegacyScripts, *, transport: str = "auto") -> None:
        self.legacy = legacy
        self.transport = transport

    def _require_legacy_allowed(self, action: str) -> None:
        if self.transport == "socket-only":
            raise NotImplementedError(f"{action} is not exposed through vphone.sock yet; use --transport auto or legacy")

    def install_instagram_audit(self, bundles: list[str] | None = None) -> dict[str, object]:
        self._require_legacy_allowed("hooks.install_instagram_audit")
        args = [self.legacy.instance.target_arg, *(bundles or [])]
        proc = self.legacy.run("install_instagram_audit_tweak_to_instance.sh", args)
        return {"ok": True, "transport": "legacy", "hook": "instagram_audit", "stdout": proc.stdout}

    def install_profile(self, bundles: list[str]) -> dict[str, object]:
        self._require_legacy_allowed("hooks.install_profile")
        if not bundles:
            raise ValueError("install_profile requires at least one bundle id")
        args = [self.legacy.instance.target_arg, *bundles]
        proc = self.legacy.run("install_profile_tweak_to_instance.sh", args)
        return {"ok": True, "transport": "legacy", "hook": "profile", "stdout": proc.stdout}
