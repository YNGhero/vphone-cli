from __future__ import annotations

import os
import random
import subprocess
import time
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

    @staticmethod
    def _env_int(name: str, default: int) -> int:
        try:
            return max(1, int(os.environ.get(name, str(default))))
        except ValueError:
            return default

    @staticmethod
    def _env_float(name: str, default: float) -> float:
        try:
            return max(0.0, float(os.environ.get(name, str(default))))
        except ValueError:
            return default

    @staticmethod
    def _decode(value: str | bytes | None) -> str:
        if isinstance(value, bytes):
            return value.decode(errors="replace")
        return str(value or "")

    @staticmethod
    def is_transient_ssh_error(text: str) -> bool:
        lowered = str(text or "").casefold()
        markers = [
            "permission denied, please try again",
            "permission denied (publickey,password)",
            "connection refused",
            "connection reset",
            "connection closed",
            "operation timed out",
            "connect timed out",
            "timed out",
            "ssh_exchange_identification",
            "kex_exchange_identification",
            "broken pipe",
            "no route to host",
        ]
        return any(marker in lowered for marker in markers)

    def run(
        self,
        name: str,
        args: list[str] | tuple[str, ...] = (),
        *,
        check: bool = True,
        input_data: bytes | str | None = None,
        timeout: float | None = None,
        attempts: int | None = None,
        retry_delay: float | None = None,
    ) -> subprocess.CompletedProcess[str | bytes]:
        path = self.script_path(name)
        text_mode = not isinstance(input_data, (bytes, bytearray))
        max_attempts = attempts or self._env_int("VPHONE_LEGACY_SSH_ATTEMPTS", self._env_int("VPHONE_SSH_ATTEMPTS", 3))
        base_delay = self._env_float("VPHONE_SSH_RETRY_DELAY", 1.5) if retry_delay is None else max(0.0, retry_delay)
        proc: subprocess.CompletedProcess[str | bytes] | None = None
        for attempt in range(1, max_attempts + 1):
            proc = subprocess.run(
                ["zsh", str(path), *map(str, args)],
                cwd=str(self.repo_root),
                input=input_data,
                text=text_mode,
                capture_output=True,
                timeout=timeout,
            )
            combined = f"{self._decode(proc.stderr)}\n{self._decode(proc.stdout)}"
            if (
                proc.returncode == 0
                or not check
                or not self.is_transient_ssh_error(combined)
                or attempt >= max_attempts
            ):
                break
            time.sleep((base_delay * attempt) + random.uniform(0.2, 0.8))
        assert proc is not None
        if check and proc.returncode != 0:
            stderr = self._decode(proc.stderr)
            stdout = self._decode(proc.stdout)
            raise RuntimeError((stderr or stdout or f"legacy script failed: {name}").strip())
        return proc
