from __future__ import annotations

from pathlib import Path

from .app import AppService
from .app_state import AppStateService
from .artifacts import ArtifactStore
from .files import FilesService
from .hooks import HooksService
from .hostctl import HostControlClient
from .instance import VPhoneInstance
from .legacy import LegacyScripts
from .location import LocationService
from .ocr import OCRService
from .photos import PhotosService
from .proxy import ProxyService
from .screen import ScreenService
from .ui import UIService
from .ssh import SSHClient


class VPhoneSession:
    """中文注释：业务脚本主入口，聚合 screen/app/photos/proxy/location 等通用能力。"""

    def __init__(
        self,
        target: str | Path | None = None,
        *,
        app: str = "generic",
        flow: str = "manual",
        transport: str = "auto",
        ssh_port: str | None = None,
        artifacts: bool = False,
        artifact_dir: str | Path | None = None,
    ) -> None:
        self.transport = transport
        self.instance = VPhoneInstance.resolve(target, ssh_port=ssh_port)
        self.hostctl = HostControlClient(self.instance.socket_path)
        self.ssh = SSHClient(self.instance.ssh_port)
        self.legacy = LegacyScripts(self.instance)
        self.artifacts = ArtifactStore(self.instance, app=app, flow=flow, base_dir=Path(artifact_dir) if artifact_dir else None) if artifacts else None

        self.screen = ScreenService(self.hostctl)
        self.ui = UIService(self.hostctl, self.screen)
        self.ocr = OCRService(self.screen, self.instance.repo_root)
        self.app = AppService(self.hostctl, self.ssh, transport=transport)
        self.files = FilesService(self.hostctl)
        self.photos = PhotosService(self.legacy, transport=transport)
        self.app_state = AppStateService(self.legacy, transport=transport)
        self.proxy = ProxyService(self.legacy, transport=transport)
        self.location = LocationService(self.hostctl)
        self.hooks = HooksService(self.legacy, transport=transport)

    def __enter__(self) -> "VPhoneSession":
        if self.artifacts:
            self.artifacts.event("session.enter")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:  # type: ignore[no-untyped-def]
        if self.artifacts:
            self.artifacts.event("session.exit", error=str(exc) if exc else None)

    def info(self) -> dict[str, object]:
        return {
            "instance": self.instance.name,
            "vm_dir": str(self.instance.vm_dir),
            "socket": str(self.instance.socket_path),
            "ssh_port": self.instance.ssh_port,
            "transport": self.transport,
            "artifact_dir": str(self.artifacts.run_dir) if self.artifacts else None,
        }
