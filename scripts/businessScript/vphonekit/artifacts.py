from __future__ import annotations

import base64
import json
import time
from pathlib import Path
from typing import Any

from .instance import VPhoneInstance


class ArtifactStore:
    """中文注释：保存自动化运行过程中的截图、日志和结构化事件。"""

    def __init__(self, instance: VPhoneInstance, *, app: str = "generic", flow: str = "manual", base_dir: Path | None = None) -> None:
        self.instance = instance
        self.app = app
        self.flow = flow
        root = base_dir or (instance.repo_root / "scripts" / "businessScript" / "runs")
        ts = time.strftime("%Y%m%d-%H%M%S")
        self.run_dir = root / f"{ts}-{instance.name}-{app}-{flow}"
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.events_path = self.run_dir / "run.jsonl"
        self.event("run.start", instance=instance.name, vm_dir=str(instance.vm_dir))

    def path(self, name: str) -> Path:
        return self.run_dir / name

    def event(self, event: str, **data: Any) -> None:
        item = {"ts": time.time(), "event": event, **data}
        with self.events_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(item, ensure_ascii=False, default=str) + "\n")

    def save_base64_image(self, image_b64: str | None, label: str) -> Path | None:
        if not image_b64:
            return None
        path = self.path(f"{int(time.time() * 1000)}-{label}.jpg")
        path.write_bytes(base64.b64decode(image_b64))
        self.event("artifact.image", label=label, path=str(path))
        return path
