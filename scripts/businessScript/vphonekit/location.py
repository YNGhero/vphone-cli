from __future__ import annotations

import json
import urllib.request
from typing import Any

from .hostctl import HostControlClient


class LocationService:
    """中文注释：定位模拟。设置定位直接走 vphone.sock；按 IP 查询在 host 侧完成。"""

    def __init__(self, hostctl: HostControlClient) -> None:
        self.hostctl = hostctl

    def set(
        self,
        lat: float,
        lon: float,
        *,
        alt: float = 0,
        hacc: float = 1000,
        vacc: float = 50,
        speed: float = 0,
        course: float = -1,
        name: str = "businessScript",
        screen: bool = False,
        delay: int = 200,
    ) -> dict[str, Any]:
        return self.hostctl.request(
            {
                "t": "location",
                "lat": lat,
                "lon": lon,
                "alt": alt,
                "hacc": hacc,
                "vacc": vacc,
                "speed": speed,
                "course": course,
                "name": name,
                "screen": screen,
                "delay": delay,
            }
        )

    def clear(self) -> dict[str, Any]:
        # 需要 host-control 桥接 location_stop；未桥接时会返回 unknown command。
        return self.hostctl.request({"t": "location_stop", "screen": False})

    def set_by_ip(self, ip: str, **kwargs: Any) -> dict[str, Any]:
        url = f"https://ipapi.co/{ip}/json/"
        with urllib.request.urlopen(url, timeout=15) as r:
            info = json.loads(r.read().decode("utf-8"))
        lat = info.get("latitude")
        lon = info.get("longitude")
        if lat is None or lon is None:
            raise RuntimeError(f"ip location lookup failed: {info}")
        resp = self.set(float(lat), float(lon), name=f"ip:{ip}", **kwargs)
        resp["ip_info"] = info
        return resp
