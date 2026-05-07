from __future__ import annotations

import subprocess
from pathlib import Path

from .instance import VPhoneInstance


class LegacyScripts:
    """中文注释：Phase 1 兼容层，统一调用现有 scripts/*.sh。"""

    def __init__(self, instance: VPhoneInstance) -> None:
        self.instance = instance
        self.repo_root = instance.repo_root

    def script_path(self, name: str) -> Path:
        path = self.repo_root / "scripts" / name
        if not path.exists():
            raise FileNotFoundError(f"legacy script not found: {path}")
        return path

    def run(
        self,
        name: str,
        args: list[str] | tuple[str, ...] = (),
        *,
        check: bool = True,
        input_data: bytes | str | None = None,
        timeout: float | None = None,
    ) -> subprocess.CompletedProcess[str | bytes]:
        path = self.script_path(name)
        text_mode = not isinstance(input_data, (bytes, bytearray))
        proc = subprocess.run(
            ["zsh", str(path), *map(str, args)],
            cwd=str(self.repo_root),
            input=input_data,
            text=text_mode,
            capture_output=True,
            timeout=timeout,
        )
        if check and proc.returncode != 0:
            stderr = proc.stderr.decode() if isinstance(proc.stderr, bytes) else proc.stderr
            stdout = proc.stdout.decode() if isinstance(proc.stdout, bytes) else proc.stdout
            raise RuntimeError((stderr or stdout or f"legacy script failed: {name}").strip())
        return proc
