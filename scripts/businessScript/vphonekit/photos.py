from __future__ import annotations

from pathlib import Path

from .legacy import LegacyScripts


class PhotosService:
    """中文注释：照片导入/清空能力。Phase 1 先包装现有稳定 zsh 脚本。"""

    def __init__(self, legacy: LegacyScripts, *, transport: str = "auto") -> None:
        self.legacy = legacy
        self.transport = transport

    def _require_legacy_allowed(self, action: str) -> None:
        if self.transport == "socket-only":
            raise NotImplementedError(f"{action} is not exposed through vphone.sock yet; use --transport auto or legacy")

    def import_photo(self, image_path: str | Path, *, album: str = "VPhoneImports") -> dict[str, object]:
        self._require_legacy_allowed("photo.import")
        image = Path(image_path).expanduser().resolve()
        if not image.exists():
            raise FileNotFoundError(f"image not found: {image}")
        proc = self.legacy.run("import_photo_to_instance.sh", [str(image), self.legacy.instance.target_arg, album])
        return {"ok": True, "transport": "legacy", "image": str(image), "album": album, "stdout": proc.stdout}

    def delete_all(self, *, yes: bool = False) -> dict[str, object]:
        self._require_legacy_allowed("photo.delete_all")
        args = [self.legacy.instance.target_arg]
        if yes:
            args.append("--yes")
        proc = self.legacy.run("delete_all_photos_from_instance.sh", args)
        return {"ok": True, "transport": "legacy", "stdout": proc.stdout}
