from __future__ import annotations

from vphonekit import VPhoneSession


class BaseFlow:
    """中文注释：业务流程基类；具体 App flow 可继承后只写 run()。"""

    app_name = "generic"
    flow_name = "manual"

    def __init__(self, target: str | None, *, transport: str = "auto", artifacts: bool = True) -> None:
        self.vp = VPhoneSession(target, app=self.app_name, flow=self.flow_name, transport=transport, artifacts=artifacts)

    def run(self) -> None:
        raise NotImplementedError
