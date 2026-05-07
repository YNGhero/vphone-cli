from __future__ import annotations

from pathlib import Path

from .legacy import LegacyScripts


class AppStateService:
    """中文注释：App 数据备份、一键新机、还原。Phase 1 复用现有 app_* shell 脚本。"""

    def __init__(self, legacy: LegacyScripts, *, transport: str = "auto") -> None:
        self.legacy = legacy
        self.transport = transport

    def _require_legacy_allowed(self, action: str) -> None:
        if self.transport == "socket-only":
            raise NotImplementedError(f"{action} is not exposed through vphone.sock yet; use --transport auto or legacy")

    def backup(self, bundle_id: str, *, name: str = "manual", output_dir: str | Path | None = None) -> dict[str, object]:
        self._require_legacy_allowed("app_state.backup")
        args = [self.legacy.instance.target_arg, bundle_id]
        if output_dir:
            args.extend(["--output-dir", str(output_dir)])
        if name:
            args.append(name)
        proc = self.legacy.run("app_backup.sh", args)
        archive = str(proc.stdout).strip().splitlines()[-1] if proc.stdout and str(proc.stdout).strip() else ""
        return {"ok": True, "transport": "legacy", "bundle_id": bundle_id, "archive": archive, "stdout": proc.stdout}

    def new_device(
        self,
        bundle_id: str,
        *,
        yes: bool = False,
        backup_before: bool = False,
        clean_pasteboard: bool = True,
        relaunch: bool = True,
        respring: bool = False,
    ) -> dict[str, object]:
        self._require_legacy_allowed("app_state.new_device")
        args = [self.legacy.instance.target_arg, bundle_id]
        if yes:
            args.append("--yes")
        if backup_before:
            args.append("--backup-before")
        if not clean_pasteboard:
            args.append("--no-pasteboard")
        if not relaunch:
            args.append("--no-relaunch")
        if respring:
            args.append("--respring")
        proc = self.legacy.run("app_new_device.sh", args)
        return {"ok": True, "transport": "legacy", "bundle_id": bundle_id, "stdout": proc.stdout}

    def restore(
        self,
        bundle_id: str,
        archive: str | Path,
        *,
        yes: bool = False,
        relaunch: bool = True,
        respring: bool = False,
    ) -> dict[str, object]:
        self._require_legacy_allowed("app_state.restore")
        archive_path = Path(archive).expanduser().resolve()
        if not archive_path.exists():
            raise FileNotFoundError(f"backup archive not found: {archive_path}")
        args = [self.legacy.instance.target_arg, bundle_id, str(archive_path)]
        if yes:
            args.append("--yes")
        if not relaunch:
            args.append("--no-relaunch")
        if respring:
            args.append("--respring")
        proc = self.legacy.run("app_restore.sh", args)
        return {"ok": True, "transport": "legacy", "bundle_id": bundle_id, "archive": str(archive_path), "stdout": proc.stdout}
