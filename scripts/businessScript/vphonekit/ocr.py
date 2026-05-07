from __future__ import annotations

import json
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable

from .screen import ScreenService


class OCRService:
    """中文注释：基于 macOS Vision 的截图文字识别，用于 AX 不可靠时按文本找坐标。"""

    def __init__(self, screen: ScreenService, repo_root: Path) -> None:
        self.screen = screen
        self.repo_root = repo_root
        self.script = repo_root / "scripts" / "businessScript" / "tools" / "vision_ocr.swift"

    def recognize_image(self, image_path: str | Path, *, timeout: float = 30.0) -> dict[str, Any]:
        # 中文注释：识别指定图片，返回 Vision OCR 原始 JSON。
        if not self.script.exists():
            raise FileNotFoundError(f"OCR helper not found: {self.script}")
        proc = subprocess.run(
            ["swift", str(self.script), str(image_path)],
            cwd=str(self.repo_root),
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        stdout = (proc.stdout or "").strip()
        if not stdout:
            raise RuntimeError((proc.stderr or "OCR helper produced empty output").strip())
        resp = json.loads(stdout)
        if proc.returncode != 0 or not resp.get("ok"):
            raise RuntimeError(str(resp.get("error") or proc.stderr or "OCR failed"))
        return resp

    def snapshot(self, *, path: str | Path | None = None, timeout: float = 30.0) -> dict[str, Any]:
        # 中文注释：先通过 vphone.sock 截图，再对截图做 OCR。
        cleanup = False
        if path is None:
            tmp = tempfile.NamedTemporaryFile(prefix="vphone-ocr-", suffix=".png", delete=False)
            tmp.close()
            image_path = Path(tmp.name)
            cleanup = True
        else:
            image_path = Path(path)

        try:
            self.screen.screenshot(image_path)
            return self.recognize_image(image_path, timeout=timeout)
        finally:
            if cleanup:
                try:
                    image_path.unlink()
                except FileNotFoundError:
                    pass

    def nodes(self, *, path: str | Path | None = None, timeout: float = 30.0) -> list[dict[str, Any]]:
        # 中文注释：把 OCR 结果转成和 accessibility_tree 接近的节点结构，方便复用 ui.tap()。
        resp = self.snapshot(path=path, timeout=timeout)
        return self._nodes_from_response(resp)

    def image_nodes(self, image_path: str | Path, *, timeout: float = 30.0) -> list[dict[str, Any]]:
        # 中文注释：识别一张已经存在的图片；不会重新截图，适合排障或离线验证 OCR 坐标。
        resp = self.recognize_image(image_path, timeout=timeout)
        return self._nodes_from_response(resp)

    def _nodes_from_response(self, resp: dict[str, Any]) -> list[dict[str, Any]]:
        # 中文注释：把 Vision OCR 原始 items 统一转为“可点击节点”结构。
        nodes: list[dict[str, Any]] = []
        for index, item in enumerate(resp.get("items") or []):
            if not isinstance(item, dict):
                continue
            text = str(item.get("text") or "")
            if not text:
                continue
            nodes.append(
                {
                    "id": index + 1,
                    "index": index,
                    "label": text,
                    "value": text,
                    "role": "ocr_text",
                    "source": "ocr",
                    "confidence": item.get("confidence"),
                    "frame_pixels": item.get("frame_pixels"),
                    "center_pixels": item.get("center_pixels"),
                }
            )
        return nodes

    def find(
        self,
        text: str,
        *,
        exact: bool = False,
        case_sensitive: bool = False,
        path: str | Path | None = None,
        timeout: float = 30.0,
    ) -> list[dict[str, Any]]:
        # 中文注释：OCR 文本查找；默认包含匹配，exact=True 时全等匹配。
        return self.filter_nodes(self.nodes(path=path, timeout=timeout), text, exact=exact, case_sensitive=case_sensitive)

    def filter_nodes(
        self,
        nodes: Iterable[dict[str, Any]],
        text: str,
        *,
        exact: bool = False,
        case_sensitive: bool = False,
    ) -> list[dict[str, Any]]:
        # 中文注释：从现有 OCR 节点中过滤文本，供离线图片识别和 CLI 复用。
        return [
            node
            for node in nodes
            if self._matches(str(node.get("label") or ""), text, exact=exact, case_sensitive=case_sensitive)
        ]

    def find_any(
        self,
        texts: Iterable[str],
        *,
        exact: bool = False,
        case_sensitive: bool = False,
        path: str | Path | None = None,
        timeout: float = 30.0,
    ) -> dict[str, Any] | None:
        # 中文注释：按顺序查找多个候选文本，命中后返回第一个节点。
        nodes = self.nodes(path=path, timeout=timeout)
        for text in texts:
            for node in nodes:
                if self._matches(str(node.get("label") or ""), text, exact=exact, case_sensitive=case_sensitive):
                    node["matched_text"] = text
                    return node
        return None

    def bounds(
        self,
        text: str | None = None,
        *,
        exact: bool = False,
        case_sensitive: bool = False,
        path: str | Path | None = None,
        image_path: str | Path | None = None,
        timeout: float = 30.0,
    ) -> list[dict[str, Any]]:
        # 中文注释：只查询当前屏幕文字的坐标范围，不做点击；text 为空时返回所有 OCR 文本块。
        nodes = self.image_nodes(image_path, timeout=timeout) if image_path else self.nodes(path=path, timeout=timeout)
        if text:
            nodes = self.filter_nodes(nodes, text, exact=exact, case_sensitive=case_sensitive)
        return [self.node_bounds(node) for node in nodes if self.has_bounds(node)]

    def wait_for(
        self,
        text: str,
        *,
        timeout: float = 10.0,
        interval: float = 0.5,
        exact: bool = False,
        case_sensitive: bool = False,
        ocr_timeout: float = 30.0,
    ) -> dict[str, Any]:
        # 中文注释：持续截图 + OCR，直到指定文本出现；返回节点里的 center_pixels 可直接点击。
        deadline = time.monotonic() + max(0.0, timeout)
        last_count = 0
        last_error = ""
        while True:
            try:
                matches = self.find(text, exact=exact, case_sensitive=case_sensitive, timeout=ocr_timeout)
                last_count = len(matches)
                if matches:
                    return matches[0]
            except Exception as exc:
                last_error = str(exc)

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                suffix = f"; last_error={last_error}" if last_error else f"; last_matches={last_count}"
                raise TimeoutError(f"OCR text not found within {timeout:g}s: {text!r}{suffix}")
            time.sleep(min(max(0.1, interval), remaining))

    def wait_for_any(
        self,
        texts: Iterable[str],
        *,
        timeout: float = 10.0,
        interval: float = 0.5,
        exact: bool = False,
        case_sensitive: bool = False,
        ocr_timeout: float = 30.0,
    ) -> dict[str, Any]:
        # 中文注释：持续截图 + OCR，任意候选文本出现就返回；适合等待多个入口按钮。
        candidates = list(texts)
        deadline = time.monotonic() + max(0.0, timeout)
        last_error = ""
        while True:
            try:
                node = self.find_any(candidates, exact=exact, case_sensitive=case_sensitive, timeout=ocr_timeout)
                if node:
                    return node
            except Exception as exc:
                last_error = str(exc)

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                suffix = f"; last_error={last_error}" if last_error else ""
                raise TimeoutError(f"OCR texts not found within {timeout:g}s: {candidates!r}{suffix}")
            time.sleep(min(max(0.1, interval), remaining))

    def tap(self, element: dict[str, Any], *, screen: bool = False, delay: int = 300) -> dict[str, Any]:
        # 中文注释：点击 OCR 节点中心点；OCR 坐标已经是截图像素坐标。
        x, y = self.center_pixels(element)
        resp = self.screen.tap(x, y, screen=screen, delay=delay)
        resp["target"] = {
            "x": x,
            "y": y,
            "label": element.get("label"),
            "source": element.get("source") or "ocr",
            "confidence": element.get("confidence"),
        }
        return resp

    def tap_text(
        self,
        text: str,
        *,
        timeout: float | None = None,
        interval: float = 0.5,
        exact: bool = False,
        case_sensitive: bool = False,
        screen: bool = False,
        delay: int = 300,
    ) -> dict[str, Any]:
        # 中文注释：按 OCR 文本点击；传 timeout 时会等待文本出现，不传则只识别当前屏幕一次。
        if timeout is None:
            matches = self.find(text, exact=exact, case_sensitive=case_sensitive)
            if not matches:
                raise LookupError(f"OCR text not found: {text!r}")
            node = matches[0]
        else:
            node = self.wait_for(text, timeout=timeout, interval=interval, exact=exact, case_sensitive=case_sensitive)
        return self.tap(node, screen=screen, delay=delay)

    @staticmethod
    def has_bounds(element: dict[str, Any]) -> bool:
        # 中文注释：判断 OCR 节点是否带有 Vision 返回的像素范围。
        center = element.get("center_pixels")
        frame = element.get("frame_pixels")
        return (isinstance(center, dict) and "x" in center and "y" in center) or (
            isinstance(frame, dict) and "x" in frame and "y" in frame and "width" in frame and "height" in frame
        )

    @classmethod
    def node_bounds(cls, element: dict[str, Any]) -> dict[str, Any]:
        # 中文注释：把 OCR 节点压缩成“文本 + 坐标范围”结构，方便业务脚本只拿范围后自行点击/判断。
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
            "source": element.get("source") or "ocr",
            "label": element.get("label") or "",
            "value": element.get("value") or "",
            "role": element.get("role") or "ocr_text",
            "confidence": element.get("confidence"),
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
        # 中文注释：读取 OCR 节点中心点；缺失时用 frame_pixels 计算。
        center = element.get("center_pixels")
        if isinstance(center, dict) and "x" in center and "y" in center:
            return float(center["x"]), float(center["y"])
        frame = element.get("frame_pixels")
        if isinstance(frame, dict):
            return float(frame["x"]) + float(frame["width"]) / 2.0, float(frame["y"]) + float(frame["height"]) / 2.0
        raise ValueError(f"OCR node has no center_pixels/frame_pixels: {element}")

    @staticmethod
    def _matches(value: str, needle: str, *, exact: bool, case_sensitive: bool) -> bool:
        if not case_sensitive:
            value = value.casefold()
            needle = needle.casefold()
        value_norm = " ".join(value.split())
        needle_norm = " ".join(needle.split())
        value_compact = "".join(ch for ch in value_norm if ch.isalnum())
        needle_compact = "".join(ch for ch in needle_norm if ch.isalnum())

        if exact:
            return value_norm == needle_norm or (bool(needle_compact) and value_compact == needle_compact)

        if needle_norm in value_norm:
            return True
        if needle_compact and needle_compact in value_compact:
            return True

        # 中文注释：Vision 偶尔会把大写 I 识别成小写 l，且可能和后面的单词粘连，
        # 例如 "I already have a profile" -> "lalready have a profile"。
        if needle_compact.startswith("i") and value_compact.startswith("l"):
            return needle_compact[1:] in value_compact[1:]
        return False
