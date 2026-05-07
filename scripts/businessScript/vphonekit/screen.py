from __future__ import annotations

from pathlib import Path
from typing import Any

from .hostctl import HostControlClient


class ScreenService:
    """中文注释：封装点击、滑动、按键、截图、输入等屏幕自动化动作。"""

    def __init__(self, hostctl: HostControlClient) -> None:
        self.hostctl = hostctl

    def show_window(self, *, screen: bool = False) -> dict[str, Any]:
        return self.hostctl.request({"t": "show_window", "screen": screen})

    def tap(self, x: float, y: float, *, screen: bool = False, delay: int = 300) -> dict[str, Any]:
        return self.hostctl.request({"t": "tap", "x": x, "y": y, "screen": screen, "delay": delay})

    def swipe(
        self,
        x1: float,
        y1: float,
        x2: float,
        y2: float,
        *,
        ms: int = 350,
        screen: bool = False,
        delay: int = 300,
    ) -> dict[str, Any]:
        return self.hostctl.request(
            {"t": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "ms": ms, "screen": screen, "delay": delay}
        )

    def key(self, name: str, *, screen: bool = False, delay: int = 300) -> dict[str, Any]:
        return self.hostctl.request({"t": "key", "name": name, "screen": screen, "delay": delay})

    def home(self, *, screen: bool = False, delay: int = 300) -> dict[str, Any]:
        return self.key("home", screen=screen, delay=delay)

    def screenshot(self, path: str | Path | None = None) -> dict[str, Any]:
        req: dict[str, Any] = {"t": "screenshot"}
        if path:
            req["path"] = str(path)
        return self.hostctl.request(req)

    def type_ascii(self, text: str, *, screen: bool = False, delay: int = 300) -> dict[str, Any]:
        return self.hostctl.request({"t": "type_ascii", "text": text, "screen": screen, "delay": delay})

    def set_clipboard(self, text: str, *, screen: bool = False, delay: int = 300) -> dict[str, Any]:
        # 当前 host-control 的 "type" 命令语义是设置 guest 剪贴板。
        return self.hostctl.request({"t": "type", "text": text, "screen": screen, "delay": delay})
