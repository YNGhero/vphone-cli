#!/usr/bin/env python3
"""
vphone GUI 自动化示例脚本（Phase 1 版本）。

这个示例现在只保留业务流程，底层实例解析、vphone.sock、SSH fallback、App 生命周期等
公共逻辑已经抽到 scripts/businessScript/vphonekit/，后续针对其他 App 的脚本也应复用 vphonekit。
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
from pathlib import Path
from typing import Any

from vphonekit import HostControlError, VPhoneSession

DEFAULT_BUNDLE = "com.burbn.instagram"


# 中文注释：输出普通步骤日志，统一使用 [*] 前缀。
def log(msg: str) -> None:
    print(f"[*] {msg}")


# 中文注释：输出成功日志，统一使用 [+] 前缀。
def ok(msg: str) -> None:
    print(f"[+] {msg}")


# 中文注释：解析命令行传入的坐标字符串，例如 "645,1398" 或 "645,2400,645,1200"。
def parse_coords(text: str, count: int, label: str) -> list[float]:
    parts = [p for p in re.split(r"[,x:\s]+", text.strip()) if p]
    if len(parts) != count:
        raise SystemExit(f"[-] {label} expects {count} numbers, got: {text!r}")
    try:
        return [float(p) for p in parts]
    except ValueError as exc:
        raise SystemExit(f"[-] invalid {label} coordinates: {text!r}") from exc


# 中文注释：如果 host-control 响应里带 compact screenshot 的 base64 图片，就保存成本地 JPG 预览。
def save_preview(resp: dict[str, Any], preview_dir: Path | None, label: str) -> None:
    image_b64 = resp.get("image")
    if not preview_dir or not image_b64:
        return
    preview_dir.mkdir(parents=True, exist_ok=True)
    path = preview_dir / f"{int(time.time() * 1000)}-{label}.jpg"
    path.write_bytes(base64.b64decode(image_b64))
    ok(f"preview saved: {path}")


# 中文注释：脚本入口；演示“打开 App -> 截图 -> 点击 -> 滑动 -> Home -> 关闭 App”的通用流程。
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Example: launch an app, tap, swipe, press Home, and close the app on a running vphone instance."
    )
    parser.add_argument("target", nargs="?", help="instance name under vm.instances/ or full VM dir; omitted = newest running socket")
    parser.add_argument("--bundle", default=DEFAULT_BUNDLE, help=f"bundle id to launch/close (default: {DEFAULT_BUNDLE})")
    parser.add_argument("--url", help="optional URL to open while launching the app")
    parser.add_argument("--tap", default="645,1398", help="tap coordinate in screenshot pixels (default: 645,1398)")
    parser.add_argument("--swipe", default="645,2400,645,1200", help="swipe x1,y1,x2,y2 in screenshot pixels")
    parser.add_argument("--ms", type=int, default=350, help="swipe duration in ms (default: 350)")
    parser.add_argument("--launch-wait", type=float, default=2.0, help="seconds to wait after launching app")
    parser.add_argument("--delay", type=int, default=300, help="host-control screenshot settle delay in ms")
    parser.add_argument("--screenshot", help="optional host path to save a full screenshot after launch")
    parser.add_argument("--preview-dir", type=Path, help="save compact JPEG previews returned by host-control")
    parser.add_argument("--ssh-port", help="override SSH local port for old-binary fallback")
    parser.add_argument("--process-name", help="process name for SSH terminate fallback, e.g. Instagram")
    parser.add_argument("--transport", choices=["auto", "socket-only", "legacy"], default="auto", help="transport strategy")
    parser.add_argument("--skip-launch", action="store_true", help="do not launch the app first")
    parser.add_argument("--skip-tap", action="store_true", help="skip tap action")
    parser.add_argument("--skip-swipe", action="store_true", help="skip swipe action")
    parser.add_argument("--no-home", action="store_true", help="do not press Home before closing")
    parser.add_argument("--no-close", action="store_true", help="leave the app running")
    # 兼容旧参数名：旧版示例里 strict-hostctl 等价于新版 socket-only。
    parser.add_argument("--strict-hostctl", action="store_true", help="alias of --transport socket-only")
    args = parser.parse_args()

    transport = "socket-only" if args.strict_hostctl else args.transport
    vp = VPhoneSession(args.target, app="example", flow="automation-demo", transport=transport, ssh_port=args.ssh_port)

    info = vp.info()
    log(f"vm_dir={info['vm_dir']}")
    log(f"sock={info['socket']}")
    if info.get("ssh_port"):
        log(f"ssh_port={info['ssh_port']} (only used as fallback for old host-control binaries)")

    # 中文注释：先唤回/聚焦 VM 窗口，避免窗口隐藏时看不到自动化效果。
    vp.screen.show_window(screen=False)
    ok("window shown")

    # 中文注释：启动目标 App，例如 Instagram 的 bundle id 是 com.burbn.instagram。
    if not args.skip_launch:
        resp = vp.app.launch(args.bundle, url=args.url)
        ok(f"app launched via {resp.get('transport', 'socket')}: {args.bundle}")
        time.sleep(max(args.launch_wait, 0))

    # 中文注释：可选保存一张全尺寸截图，方便后续人工取坐标。
    if args.screenshot:
        out = Path(args.screenshot).expanduser().resolve()
        resp = vp.screen.screenshot(out)
        save_preview(resp, args.preview_dir, "screenshot")
        ok(f"full screenshot saved: {resp.get('path', out)}")

    wants_preview = args.preview_dir is not None

    # 中文注释：执行点击；坐标是 guest 截图像素坐标，不是 macOS 窗口坐标。
    if not args.skip_tap:
        x, y = parse_coords(args.tap, 2, "--tap")
        resp = vp.screen.tap(x, y, screen=wants_preview, delay=args.delay)
        save_preview(resp, args.preview_dir, "tap")
        ok(f"tap {x:g},{y:g}")

    # 中文注释：执行滑动；x1/y1 是起点，x2/y2 是终点，ms 是滑动耗时。
    if not args.skip_swipe:
        x1, y1, x2, y2 = parse_coords(args.swipe, 4, "--swipe")
        resp = vp.screen.swipe(x1, y1, x2, y2, ms=args.ms, screen=wants_preview, delay=args.delay)
        save_preview(resp, args.preview_dir, "swipe")
        ok(f"swipe {x1:g},{y1:g} -> {x2:g},{y2:g} ({args.ms}ms)")

    # 中文注释：按 Home 键，把当前 App 退到后台；可用 --no-home 跳过。
    if not args.no_home:
        resp = vp.screen.home(screen=wants_preview, delay=args.delay)
        save_preview(resp, args.preview_dir, "home")
        ok("home key pressed")

    # 中文注释：关闭目标 App；可用 --no-close 保持 App 运行方便继续调试。
    if not args.no_close:
        resp = vp.app.terminate(args.bundle, process_name=args.process_name)
        ok(f"app terminated via {resp.get('transport', 'socket')}: {args.bundle}")

    ok("automation demo done")
    return 0


if __name__ == "__main__":
    # 中文注释：统一捕获常见错误，避免 Python traceback 干扰自动化日志。
    try:
        raise SystemExit(main())
    except (HostControlError, RuntimeError, OSError, json.JSONDecodeError) as exc:
        print(f"[-] {exc}", file=sys.stderr)
        raise SystemExit(1)
