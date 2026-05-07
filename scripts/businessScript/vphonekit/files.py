from __future__ import annotations

from pathlib import Path
from typing import Any

from .hostctl import HostControlClient


class FilesService:
    """中文注释：guest 文件操作接口。Phase 1 先定义 API；具体 socket 桥接在 Phase 2 补齐。"""

    def __init__(self, hostctl: HostControlClient) -> None:
        self.hostctl = hostctl

    def list(self, path: str) -> dict[str, Any]:
        return self.hostctl.request({"t": "file_list", "path": path})

    def delete(self, path: str) -> dict[str, Any]:
        return self.hostctl.request({"t": "file_delete", "path": path})

    def mkdir(self, path: str) -> dict[str, Any]:
        return self.hostctl.request({"t": "file_mkdir", "path": path})

    def put(self, local_path: str | Path, remote_path: str, *, permissions: str = "644") -> dict[str, Any]:
        # 需要 host-control 支持 file_put host_path/remote_path；Phase 2 实现。
        return self.hostctl.request({"t": "file_put", "host_path": str(local_path), "path": remote_path, "perm": permissions})

    def get(self, remote_path: str, local_path: str | Path) -> dict[str, Any]:
        # 需要 host-control 支持 file_get 写到 host_path；Phase 2 实现。
        return self.hostctl.request({"t": "file_get", "path": remote_path, "host_path": str(local_path)})
