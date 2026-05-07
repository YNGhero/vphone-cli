from __future__ import annotations

import json
import socket
from pathlib import Path
from typing import Any


class HostControlError(RuntimeError):
    """中文注释：host-control socket 返回 ok=false 或协议异常时抛出。"""

    def __init__(self, message: str, response: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.response = response or {}


class HostControlClient:
    """中文注释：负责和 <vm-dir>/vphone.sock 通信，一条 JSON line 请求对应一条 JSON line 响应。"""

    def __init__(self, socket_path: Path, timeout: float = 45.0) -> None:
        self.socket_path = Path(socket_path)
        self.timeout = timeout

    def available(self) -> bool:
        return self.socket_path.exists()

    def request(self, req: dict[str, Any], *, require_ok: bool = True) -> dict[str, Any]:
        payload = (json.dumps(req, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(self.timeout)
            s.connect(str(self.socket_path))
            s.sendall(payload)
            data = bytearray()
            while not data.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                data.extend(chunk)
        if not data:
            raise HostControlError("empty response from host-control")
        resp = json.loads(data.decode("utf-8"))
        if require_ok and not resp.get("ok"):
            raise HostControlError(str(resp.get("error") or resp), resp)
        return resp
