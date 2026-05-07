from __future__ import annotations

import time
from typing import Any, Iterable

from .hostctl import HostControlClient
from .screen import ScreenService


class UIService:
    """中文注释：基于 accessibility_tree 的元素查询与精准点击封装，不使用 OCR。"""

    def __init__(self, hostctl: HostControlClient, screen: ScreenService) -> None:
        self.hostctl = hostctl
        self.screen = screen

    def tree(
        self,
        *,
        bundle_id: str | None = None,
        pid: int | None = None,
        depth: int = -1,
        max_nodes: int = 500,
        fetch_timeout_ms: int = 8000,
        screen: bool = False,
        delay: int = 300,
    ) -> dict[str, Any]:
        # 中文注释：从 guest AXRuntime 获取目标 App 的 accessibility tree。
        req: dict[str, Any] = {
            "t": "accessibility_tree",
            "depth": depth,
            "max_nodes": max_nodes,
            "fetch_timeout_ms": fetch_timeout_ms,
            "screen": screen,
            "delay": delay,
        }
        if bundle_id:
            req["bundle_id"] = bundle_id
        if pid:
            req["pid"] = int(pid)
        return self.hostctl.request(req)

    def nodes(self, **kwargs: Any) -> list[dict[str, Any]]:
        # 中文注释：只返回扁平化节点列表，方便脚本遍历和过滤。
        resp = self.tree(**kwargs)
        nodes = resp.get("nodes") or []
        return [n for n in nodes if isinstance(n, dict)]

    def find(
        self,
        text: str | None = None,
        *,
        label: str | None = None,
        label_contains: str | None = None,
        identifier: str | None = None,
        role: str | None = None,
        bundle_id: str | None = None,
        pid: int | None = None,
        exact: bool = False,
        case_sensitive: bool = False,
        depth: int = -1,
        max_nodes: int = 500,
        fetch_timeout_ms: int = 8000,
    ) -> list[dict[str, Any]]:
        # 中文注释：按文本、label、identifier、role 过滤 AX 节点。
        all_nodes = self.nodes(
            bundle_id=bundle_id,
            pid=pid,
            depth=depth,
            max_nodes=max_nodes,
            fetch_timeout_ms=fetch_timeout_ms,
        )
        matches: list[dict[str, Any]] = []
        for node in all_nodes:
            if text is not None and not self._node_text_matches(node, text, exact=exact, case_sensitive=case_sensitive):
                continue
            if label is not None and not self._text_matches(str(node.get("label") or ""), label, exact=exact, case_sensitive=case_sensitive):
                continue
            if label_contains is not None and not self._text_matches(str(node.get("label") or ""), label_contains, exact=False, case_sensitive=case_sensitive):
                continue
            if identifier is not None:
                ids = [str(node.get("identifier") or ""), str(node.get("ax_identifier") or "")]
                if not any(self._text_matches(v, identifier, exact=exact, case_sensitive=case_sensitive) for v in ids):
                    continue
            if role is not None and not self._text_matches(str(node.get("role") or ""), role, exact=exact, case_sensitive=case_sensitive):
                continue
            matches.append(node)
        return matches

    def bounds(
        self,
        text: str | None = None,
        *,
        bundle_id: str | None = None,
        pid: int | None = None,
        exact: bool = False,
        case_sensitive: bool = False,
        depth: int = -1,
        max_nodes: int = 500,
        fetch_timeout_ms: int = 8000,
    ) -> list[dict[str, Any]]:
        # 中文注释：只查询当前 AX 元素的坐标范围，不做点击；text 为空时返回所有有坐标的节点。
        if text:
            nodes = self.find(
                text,
                bundle_id=bundle_id,
                pid=pid,
                exact=exact,
                case_sensitive=case_sensitive,
                depth=depth,
                max_nodes=max_nodes,
                fetch_timeout_ms=fetch_timeout_ms,
            )
        else:
            nodes = self.nodes(
                bundle_id=bundle_id,
                pid=pid,
                depth=depth,
                max_nodes=max_nodes,
                fetch_timeout_ms=fetch_timeout_ms,
            )
        return [self.node_bounds(node, source="accessibility_tree") for node in nodes if self.has_bounds(node)]

    def wait_for(
        self,
        text: str,
        *,
        timeout: float = 10.0,
        interval: float = 0.5,
        bundle_id: str | None = None,
        pid: int | None = None,
        exact: bool = False,
        max_nodes: int = 500,
    ) -> dict[str, Any]:
        # 中文注释：轮询等待目标元素出现，常用于页面跳转后的同步。
        deadline = time.time() + timeout
        last: list[dict[str, Any]] = []
        while time.time() <= deadline:
            last = self.find(text, bundle_id=bundle_id, pid=pid, exact=exact, max_nodes=max_nodes)
            if last:
                return last[0]
            time.sleep(interval)
        raise TimeoutError(f"element not found within {timeout:g}s: {text!r}; last_matches={len(last)}")

    def tap(self, element: dict[str, Any], *, screen: bool = False, delay: int = 300) -> dict[str, Any]:
        # 中文注释：读取节点 center_pixels，并复用 screen.tap 注入点击。
        x, y = self.center_pixels(element)
        resp = self.screen.tap(x, y, screen=screen, delay=delay)
        resp["target"] = {"x": x, "y": y, "label": element.get("label"), "id": element.get("id")}
        return resp

    def tap_text(
        self,
        text: str,
        *,
        bundle_id: str | None = None,
        pid: int | None = None,
        exact: bool = False,
        screen: bool = False,
        delay: int = 300,
        max_nodes: int = 500,
    ) -> dict[str, Any]:
        # 中文注释：查找文本匹配的第一个 AX 节点并点击其中心点。
        matches = self.find(text, bundle_id=bundle_id, pid=pid, exact=exact, max_nodes=max_nodes)
        if not matches:
            raise LookupError(f"element not found: {text!r}")
        return self.tap(matches[0], screen=screen, delay=delay)

    @staticmethod
    def has_bounds(element: dict[str, Any]) -> bool:
        # 中文注释：判断节点是否带有可换算为点击坐标系的范围信息。
        center = element.get("center_pixels")
        frame = element.get("frame_pixels")
        return (isinstance(center, dict) and "x" in center and "y" in center) or (
            isinstance(frame, dict) and "x" in frame and "y" in frame and "width" in frame and "height" in frame
        )

    @classmethod
    def node_bounds(cls, element: dict[str, Any], *, source: str | None = None) -> dict[str, Any]:
        # 中文注释：把节点压缩成“文本 + 坐标范围”结构，方便业务脚本只拿范围后自行决策。
        frame = element.get("frame_pixels")
        center = element.get("center_pixels")
        if not isinstance(frame, dict):
            x, y = cls.center_pixels(element)
            frame = {"x": x, "y": y, "width": 0.0, "height": 0.0, "max_x": x, "max_y": y}
        if not isinstance(center, dict):
            center = {
                "x": float(frame["x"]) + float(frame["width"]) / 2.0,
                "y": float(frame["y"]) + float(frame["height"]) / 2.0,
            }
        return {
            "id": element.get("id"),
            "index": element.get("index"),
            "source": source or element.get("source") or "accessibility_tree",
            "label": element.get("label") or "",
            "value": element.get("value") or "",
            "identifier": element.get("identifier") or element.get("ax_identifier") or "",
            "role": element.get("role") or "",
            "bounds": {
                "x1": float(frame["x"]),
                "y1": float(frame["y"]),
                "x2": float(frame.get("max_x", float(frame["x"]) + float(frame["width"]))),
                "y2": float(frame.get("max_y", float(frame["y"]) + float(frame["height"]))),
                "width": float(frame["width"]),
                "height": float(frame["height"]),
            },
            "center": {"x": float(center["x"]), "y": float(center["y"])},
        }

    @staticmethod
    def center_pixels(element: dict[str, Any]) -> tuple[float, float]:
        # 中文注释：优先使用 guest 返回的像素中心；缺失时用 frame_pixels 计算。
        center = element.get("center_pixels")
        if isinstance(center, dict) and "x" in center and "y" in center:
            return float(center["x"]), float(center["y"])
        frame = element.get("frame_pixels")
        if isinstance(frame, dict):
            return float(frame["x"]) + float(frame["width"]) / 2.0, float(frame["y"]) + float(frame["height"]) / 2.0
        raise ValueError(f"element has no center_pixels/frame_pixels: {element}")

    @classmethod
    def _node_text_matches(cls, node: dict[str, Any], needle: str, *, exact: bool, case_sensitive: bool) -> bool:
        # 中文注释：text 会同时匹配 label/value/hint/identifier/role。
        fields: Iterable[str] = (
            str(node.get("label") or ""),
            str(node.get("value") or ""),
            str(node.get("hint") or ""),
            str(node.get("identifier") or ""),
            str(node.get("ax_identifier") or ""),
            str(node.get("role") or ""),
        )
        return any(cls._text_matches(value, needle, exact=exact, case_sensitive=case_sensitive) for value in fields)

    @staticmethod
    def _text_matches(value: str, needle: str, *, exact: bool, case_sensitive: bool) -> bool:
        # 中文注释：默认大小写不敏感的包含匹配；exact=True 时做全等匹配。
        if not case_sensitive:
            value = value.casefold()
            needle = needle.casefold()
        return value == needle if exact else needle in value
