#!/usr/bin/env python3
"""vphone business automation unified CLI (Phase 1)."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from vphonekit import VPhoneSession


def parse_coords(text: str, count: int, label: str) -> list[float]:
    # 中文注释：解析 "x,y" / "x1,y1,x2,y2" 坐标字符串。
    parts = [p for p in re.split(r"[,x:\s]+", text.strip()) if p]
    if len(parts) != count:
        raise SystemExit(f"[-] {label} expects {count} numbers, got: {text!r}")
    return [float(p) for p in parts]


def print_result(result: Any) -> None:
    # 中文注释：统一输出 JSON，方便被上层流水线解析。
    print(json.dumps(result, ensure_ascii=False, indent=2, default=str))


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("target", help="实例名、VM 目录或可反查的 SSH 端口")
    parser.add_argument("--transport", choices=["auto", "socket-only", "legacy"], default="auto")
    parser.add_argument("--ssh-port", help="覆盖 instance.env 里的 SSH_LOCAL_PORT")


def make_session(args: argparse.Namespace, *, app: str = "generic", flow: str = "cli") -> VPhoneSession:
    return VPhoneSession(args.target, app=app, flow=flow, transport=args.transport, ssh_port=args.ssh_port)


def cmd_screen(args: argparse.Namespace) -> None:
    vp = make_session(args, flow=f"screen-{args.screen_cmd}")
    if args.screen_cmd == "tap":
        x, y = parse_coords(args.xy, 2, "xy")
        print_result(vp.screen.tap(x, y, screen=args.screen, delay=args.delay))
    elif args.screen_cmd == "swipe":
        x1, y1, x2, y2 = parse_coords(args.xyxy, 4, "xyxy")
        print_result(vp.screen.swipe(x1, y1, x2, y2, ms=args.ms, screen=args.screen, delay=args.delay))
    elif args.screen_cmd == "key":
        print_result(vp.screen.key(args.name, screen=args.screen, delay=args.delay))
    elif args.screen_cmd == "screenshot":
        print_result(vp.screen.screenshot(args.path))
    elif args.screen_cmd == "show-window":
        print_result(vp.screen.show_window(screen=args.screen))


def cmd_app(args: argparse.Namespace) -> None:
    vp = make_session(args, app=args.app_name or "generic", flow=f"app-{args.app_cmd}")
    if args.app_cmd == "launch":
        print_result(vp.app.launch(args.bundle_id, url=args.url))
    elif args.app_cmd == "terminate":
        print_result(vp.app.terminate(args.bundle_id, process_name=args.process_name))
    elif args.app_cmd == "open-url":
        print_result(vp.app.open_url(args.url))
    elif args.app_cmd == "list":
        print_result(vp.app.list(args.filter))
    elif args.app_cmd == "foreground":
        print_result(vp.app.foreground())


def cmd_photo(args: argparse.Namespace) -> None:
    vp = make_session(args, app="photo", flow=f"photo-{args.photo_cmd}")
    if args.photo_cmd == "import":
        print_result(vp.photos.import_photo(args.image, album=args.album))
    elif args.photo_cmd == "delete-all":
        print_result(vp.photos.delete_all(yes=args.yes))


def cmd_app_state(args: argparse.Namespace) -> None:
    vp = make_session(args, app=args.bundle_id, flow=f"app-state-{args.state_cmd}")
    if args.state_cmd == "backup":
        print_result(vp.app_state.backup(args.bundle_id, name=args.name, output_dir=args.output_dir))
    elif args.state_cmd == "new":
        print_result(
            vp.app_state.new_device(
                args.bundle_id,
                yes=args.yes,
                backup_before=args.backup_before,
                clean_pasteboard=not args.no_pasteboard,
                relaunch=not args.no_relaunch,
                respring=args.respring,
            )
        )
    elif args.state_cmd == "restore":
        print_result(vp.app_state.restore(args.bundle_id, args.archive, yes=args.yes, relaunch=not args.no_relaunch, respring=args.respring))


def cmd_proxy(args: argparse.Namespace) -> None:
    vp = make_session(args, app="proxy", flow=f"proxy-{args.proxy_cmd}")
    if args.proxy_cmd == "set":
        print_result(vp.proxy.set(args.proxy_url, test=args.test, no_restart=args.no_restart, bridge=args.bridge))
    elif args.proxy_cmd == "clear":
        print_result(vp.proxy.clear(yes=args.yes))
    elif args.proxy_cmd == "test":
        print_result(vp.proxy.test())


def cmd_location(args: argparse.Namespace) -> None:
    vp = make_session(args, app="location", flow=f"location-{args.location_cmd}")
    if args.location_cmd == "set":
        print_result(vp.location.set(args.lat, args.lon, alt=args.alt, hacc=args.hacc, vacc=args.vacc, screen=args.screen))
    elif args.location_cmd == "by-ip":
        print_result(vp.location.set_by_ip(args.ip, screen=args.screen))
    elif args.location_cmd == "clear":
        print_result(vp.location.clear())


def cmd_ui(args: argparse.Namespace) -> None:
    vp = make_session(args, app="ui", flow=f"ui-{args.ui_cmd}")
    if args.ui_cmd == "tree":
        print_result(
            vp.ui.tree(
                bundle_id=args.bundle_id,
                pid=args.pid,
                depth=args.depth,
                max_nodes=args.max_nodes,
                fetch_timeout_ms=args.fetch_timeout_ms,
                screen=args.screen,
                delay=args.delay,
            )
        )
    elif args.ui_cmd == "find":
        nodes = vp.ui.find(
            args.text,
            bundle_id=args.bundle_id,
            pid=args.pid,
            exact=args.exact,
            case_sensitive=args.case_sensitive,
            depth=args.depth,
            max_nodes=args.max_nodes,
            fetch_timeout_ms=args.fetch_timeout_ms,
        )
        print_result({"ok": True, "count": len(nodes), "nodes": nodes})
    elif args.ui_cmd == "bounds":
        bounds = vp.ui.bounds(
            args.text,
            bundle_id=args.bundle_id,
            pid=args.pid,
            exact=args.exact,
            case_sensitive=args.case_sensitive,
            depth=args.depth,
            max_nodes=args.max_nodes,
            fetch_timeout_ms=args.fetch_timeout_ms,
        )
        print_result({"ok": True, "count": len(bounds), "bounds": bounds})
    elif args.ui_cmd == "tap-text":
        print_result(
            vp.ui.tap_text(
                args.text,
                bundle_id=args.bundle_id,
                pid=args.pid,
                exact=args.exact,
                screen=args.screen,
                delay=args.delay,
                max_nodes=args.max_nodes,
            )
        )


def cmd_ocr(args: argparse.Namespace) -> None:
    vp = make_session(args, app="ocr", flow=f"ocr-{args.ocr_cmd}")
    if args.ocr_cmd == "nodes":
        if args.image:
            nodes = vp.ocr.image_nodes(args.image, timeout=args.ocr_timeout)
        else:
            nodes = vp.ocr.nodes(path=args.save_screenshot, timeout=args.ocr_timeout)
        print_result({"ok": True, "count": len(nodes), "nodes": nodes})
    elif args.ocr_cmd == "find":
        if args.image:
            nodes = vp.ocr.filter_nodes(
                vp.ocr.image_nodes(args.image, timeout=args.ocr_timeout),
                args.text,
                exact=args.exact,
                case_sensitive=args.case_sensitive,
            )
        else:
            nodes = vp.ocr.find(
                args.text,
                exact=args.exact,
                case_sensitive=args.case_sensitive,
                path=args.save_screenshot,
                timeout=args.ocr_timeout,
            )
        print_result({"ok": True, "count": len(nodes), "nodes": nodes})
    elif args.ocr_cmd == "bounds":
        bounds = vp.ocr.bounds(
            args.text,
            exact=args.exact,
            case_sensitive=args.case_sensitive,
            path=args.save_screenshot,
            image_path=args.image,
            timeout=args.ocr_timeout,
        )
        print_result({"ok": True, "count": len(bounds), "bounds": bounds})
    elif args.ocr_cmd == "wait":
        node = vp.ocr.wait_for(
            args.text,
            timeout=args.timeout,
            interval=args.interval,
            exact=args.exact,
            case_sensitive=args.case_sensitive,
            ocr_timeout=args.ocr_timeout,
        )
        print_result({"ok": True, "node": node})
    elif args.ocr_cmd == "tap-text":
        print_result(
            vp.ocr.tap_text(
                args.text,
                timeout=args.timeout,
                interval=args.interval,
                exact=args.exact,
                case_sensitive=args.case_sensitive,
                screen=args.screen,
                delay=args.delay,
            )
        )


def cmd_hook(args: argparse.Namespace) -> None:
    vp = make_session(args, app="hook", flow=f"hook-{args.hook_cmd}")
    if args.hook_cmd == "instagram-audit":
        print_result(vp.hooks.install_instagram_audit(args.bundle or None))
    elif args.hook_cmd == "profile":
        print_result(vp.hooks.install_profile(args.bundle))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="vphone business automation CLI (Phase 1)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    screen = sub.add_parser("screen", help="屏幕动作：tap/swipe/key/screenshot")
    screen_sub = screen.add_subparsers(dest="screen_cmd", required=True)
    p = screen_sub.add_parser("tap")
    add_common(p); p.add_argument("xy"); p.add_argument("--screen", action="store_true"); p.add_argument("--delay", type=int, default=300); p.set_defaults(func=cmd_screen)
    p = screen_sub.add_parser("swipe")
    add_common(p); p.add_argument("xyxy"); p.add_argument("--ms", type=int, default=350); p.add_argument("--screen", action="store_true"); p.add_argument("--delay", type=int, default=300); p.set_defaults(func=cmd_screen)
    p = screen_sub.add_parser("key")
    add_common(p); p.add_argument("name", choices=["home", "power", "volup", "voldown"]); p.add_argument("--screen", action="store_true"); p.add_argument("--delay", type=int, default=300); p.set_defaults(func=cmd_screen)
    p = screen_sub.add_parser("screenshot")
    add_common(p); p.add_argument("path", nargs="?"); p.set_defaults(func=cmd_screen)
    p = screen_sub.add_parser("show-window")
    add_common(p); p.add_argument("--screen", action="store_true"); p.set_defaults(func=cmd_screen)

    app = sub.add_parser("app", help="App 生命周期")
    app_sub = app.add_subparsers(dest="app_cmd", required=True)
    p = app_sub.add_parser("launch")
    add_common(p); p.add_argument("bundle_id"); p.add_argument("--url"); p.add_argument("--app-name"); p.set_defaults(func=cmd_app)
    p = app_sub.add_parser("terminate")
    add_common(p); p.add_argument("bundle_id"); p.add_argument("--process-name"); p.add_argument("--app-name"); p.set_defaults(func=cmd_app)
    p = app_sub.add_parser("open-url")
    add_common(p); p.add_argument("url"); p.add_argument("--app-name"); p.set_defaults(func=cmd_app)
    p = app_sub.add_parser("list")
    add_common(p); p.add_argument("--filter", default="all"); p.add_argument("--app-name"); p.set_defaults(func=cmd_app)
    p = app_sub.add_parser("foreground")
    add_common(p); p.add_argument("--app-name"); p.set_defaults(func=cmd_app)

    photo = sub.add_parser("photo", help="照片导入/清空")
    photo_sub = photo.add_subparsers(dest="photo_cmd", required=True)
    p = photo_sub.add_parser("import")
    add_common(p); p.add_argument("image"); p.add_argument("--album", default="VPhoneImports"); p.set_defaults(func=cmd_photo)
    p = photo_sub.add_parser("delete-all")
    add_common(p); p.add_argument("--yes", action="store_true"); p.set_defaults(func=cmd_photo)

    state = sub.add_parser("app-state", help="App 备份/一键新机/还原")
    state_sub = state.add_subparsers(dest="state_cmd", required=True)
    p = state_sub.add_parser("backup")
    add_common(p); p.add_argument("bundle_id"); p.add_argument("--name", default="manual"); p.add_argument("--output-dir"); p.set_defaults(func=cmd_app_state)
    p = state_sub.add_parser("new")
    add_common(p); p.add_argument("bundle_id"); p.add_argument("--yes", action="store_true"); p.add_argument("--backup-before", action="store_true"); p.add_argument("--no-pasteboard", action="store_true"); p.add_argument("--no-relaunch", action="store_true"); p.add_argument("--respring", action="store_true"); p.set_defaults(func=cmd_app_state)
    p = state_sub.add_parser("restore")
    add_common(p); p.add_argument("bundle_id"); p.add_argument("archive"); p.add_argument("--yes", action="store_true"); p.add_argument("--no-relaunch", action="store_true"); p.add_argument("--respring", action="store_true"); p.set_defaults(func=cmd_app_state)

    proxy = sub.add_parser("proxy", help="代理设置/清理/测试")
    proxy_sub = proxy.add_subparsers(dest="proxy_cmd", required=True)
    p = proxy_sub.add_parser("set")
    add_common(p); p.add_argument("proxy_url"); p.add_argument("--test", action="store_true"); p.add_argument("--no-restart", action="store_true"); p.add_argument("--bridge", choices=["auto", "off", "force"], default="auto"); p.set_defaults(func=cmd_proxy)
    p = proxy_sub.add_parser("clear")
    add_common(p); p.add_argument("--yes", action="store_true"); p.set_defaults(func=cmd_proxy)
    p = proxy_sub.add_parser("test")
    add_common(p); p.set_defaults(func=cmd_proxy)

    loc = sub.add_parser("location", help="定位设置")
    loc_sub = loc.add_subparsers(dest="location_cmd", required=True)
    p = loc_sub.add_parser("set")
    add_common(p); p.add_argument("lat", type=float); p.add_argument("lon", type=float); p.add_argument("--alt", type=float, default=0); p.add_argument("--hacc", type=float, default=1000); p.add_argument("--vacc", type=float, default=50); p.add_argument("--screen", action="store_true"); p.set_defaults(func=cmd_location)
    p = loc_sub.add_parser("by-ip")
    add_common(p); p.add_argument("ip"); p.add_argument("--screen", action="store_true"); p.set_defaults(func=cmd_location)
    p = loc_sub.add_parser("clear")
    add_common(p); p.set_defaults(func=cmd_location)

    ui = sub.add_parser("ui", help="无 OCR 的 Accessibility 元素树/查询/坐标范围/点击")
    ui_sub = ui.add_subparsers(dest="ui_cmd", required=True)
    p = ui_sub.add_parser("tree")
    add_common(p); p.add_argument("--bundle-id"); p.add_argument("--pid", type=int); p.add_argument("--depth", type=int, default=-1); p.add_argument("--max-nodes", type=int, default=500); p.add_argument("--fetch-timeout-ms", type=int, default=8000); p.add_argument("--screen", action="store_true"); p.add_argument("--delay", type=int, default=300); p.set_defaults(func=cmd_ui)
    p = ui_sub.add_parser("find")
    add_common(p); p.add_argument("text"); p.add_argument("--bundle-id"); p.add_argument("--pid", type=int); p.add_argument("--exact", action="store_true"); p.add_argument("--case-sensitive", action="store_true"); p.add_argument("--depth", type=int, default=-1); p.add_argument("--max-nodes", type=int, default=500); p.add_argument("--fetch-timeout-ms", type=int, default=8000); p.set_defaults(func=cmd_ui)
    p = ui_sub.add_parser("bounds")
    add_common(p); p.add_argument("text", nargs="?"); p.add_argument("--bundle-id"); p.add_argument("--pid", type=int); p.add_argument("--exact", action="store_true"); p.add_argument("--case-sensitive", action="store_true"); p.add_argument("--depth", type=int, default=-1); p.add_argument("--max-nodes", type=int, default=500); p.add_argument("--fetch-timeout-ms", type=int, default=8000); p.set_defaults(func=cmd_ui)
    p = ui_sub.add_parser("tap-text")
    add_common(p); p.add_argument("text"); p.add_argument("--bundle-id"); p.add_argument("--pid", type=int); p.add_argument("--exact", action="store_true"); p.add_argument("--screen", action="store_true"); p.add_argument("--delay", type=int, default=300); p.add_argument("--max-nodes", type=int, default=500); p.set_defaults(func=cmd_ui)

    ocr = sub.add_parser("ocr", help="OCR 文本识别/坐标范围/等待/点击；用于 AX 不可靠或纯绘制页面")
    ocr_sub = ocr.add_subparsers(dest="ocr_cmd", required=True)
    p = ocr_sub.add_parser("nodes")
    add_common(p); p.add_argument("--image", help="识别已有图片，不重新截图"); p.add_argument("--save-screenshot", help="截图保存路径，便于排障"); p.add_argument("--ocr-timeout", type=float, default=30.0); p.set_defaults(func=cmd_ocr)
    p = ocr_sub.add_parser("find")
    add_common(p); p.add_argument("text"); p.add_argument("--image", help="识别已有图片，不重新截图"); p.add_argument("--save-screenshot", help="截图保存路径，便于排障"); p.add_argument("--exact", action="store_true"); p.add_argument("--case-sensitive", action="store_true"); p.add_argument("--ocr-timeout", type=float, default=30.0); p.set_defaults(func=cmd_ocr)
    p = ocr_sub.add_parser("bounds")
    add_common(p); p.add_argument("text", nargs="?"); p.add_argument("--image", help="识别已有图片，不重新截图"); p.add_argument("--save-screenshot", help="截图保存路径，便于排障"); p.add_argument("--exact", action="store_true"); p.add_argument("--case-sensitive", action="store_true"); p.add_argument("--ocr-timeout", type=float, default=30.0); p.set_defaults(func=cmd_ocr)
    p = ocr_sub.add_parser("wait")
    add_common(p); p.add_argument("text"); p.add_argument("--timeout", type=float, default=10.0); p.add_argument("--interval", type=float, default=0.5); p.add_argument("--exact", action="store_true"); p.add_argument("--case-sensitive", action="store_true"); p.add_argument("--ocr-timeout", type=float, default=30.0); p.set_defaults(func=cmd_ocr)
    p = ocr_sub.add_parser("tap-text")
    add_common(p); p.add_argument("text"); p.add_argument("--timeout", type=float, default=10.0); p.add_argument("--interval", type=float, default=0.5); p.add_argument("--exact", action="store_true"); p.add_argument("--case-sensitive", action="store_true"); p.add_argument("--screen", action="store_true"); p.add_argument("--delay", type=int, default=300); p.set_defaults(func=cmd_ocr)

    hook = sub.add_parser("hook", help="Hook/Tweak 安装")
    hook_sub = hook.add_subparsers(dest="hook_cmd", required=True)
    p = hook_sub.add_parser("instagram-audit")
    add_common(p); p.add_argument("bundle", nargs="*"); p.set_defaults(func=cmd_hook)
    p = hook_sub.add_parser("profile")
    add_common(p); p.add_argument("bundle", nargs="+"); p.set_defaults(func=cmd_hook)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
        return 0
    except Exception as exc:
        print(f"[-] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
