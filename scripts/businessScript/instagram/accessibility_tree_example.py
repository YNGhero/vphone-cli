#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

BUSINESS_ROOT = Path(__file__).resolve().parents[1]
if str(BUSINESS_ROOT) not in sys.path:
    sys.path.insert(0, str(BUSINESS_ROOT))

from vphonekit import VPhoneSession

CONFIG = json.loads((Path(__file__).with_name("config.json")).read_text())


def node_text(node: dict[str, Any]) -> str:
    # 中文注释：把一个 AX 节点里常用的语义字段合并成可读文本。
    for key in ("label", "value", "identifier", "ax_identifier", "hint", "role"):
        value = node.get(key)
        if value:
            return str(value)
    return ""


def center_text(node: dict[str, Any]) -> str:
    # 中文注释：优先展示可直接点击的像素坐标 center_pixels。
    center = node.get("center_pixels")
    if isinstance(center, dict):
        x = center.get("x")
        y = center.get("y")
        if x is not None and y is not None:
            return f"({float(x):.1f}, {float(y):.1f})"
    return "(-, -)"


def print_nodes(nodes: list[dict[str, Any]], *, limit: int) -> None:
    # 中文注释：用表格方式打印当前页面元素，方便人工挑选要点击的文本或坐标。
    print(f"\n当前可访问元素：{len(nodes)} 个，展示前 {min(limit, len(nodes))} 个")
    print("-" * 96)
    print(f"{'id':>4}  {'role':<16}  {'center_pixels':<20}  text")
    print("-" * 96)
    for node in nodes[:limit]:
        role = str(node.get("role") or "")[:16]
        text = node_text(node).replace("\n", " ")[:90]
        print(f"{str(node.get('id', '')):>4}  {role:<16}  {center_text(node):<20}  {text}")
    print("-" * 96)


def save_json(path: Path, data: dict[str, Any]) -> None:
    # 中文注释：保存完整 accessibility_tree 响应，便于后续离线分析节点字段。
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"[+] 已保存完整元素树：{path}")


def main() -> int:
    # 中文注释：Instagram accessibility tree 示例入口。
    parser = argparse.ArgumentParser(
        description="Instagram accessibility_tree 示例：获取当前元素、查找元素、按元素点击（非 OCR）"
    )
    parser.add_argument("target", help="实例名或 VM 目录，例如 instagram-01")
    parser.add_argument("--transport", choices=["auto", "socket-only", "legacy"], default="auto")
    parser.add_argument("--bundle-id", default=CONFIG["bundle_id"], help="目标 App bundle id")
    parser.add_argument("--no-launch", action="store_true", help="不自动启动 Instagram，直接读取当前页面")
    parser.add_argument("--wait", type=float, default=2.0, help="启动 App 后等待秒数")
    parser.add_argument("--max-nodes", type=int, default=200, help="最多读取多少个 AX 节点")
    parser.add_argument("--print-limit", type=int, default=80, help="终端最多打印多少个节点")
    parser.add_argument("--find", help="按文本查找元素，例如 'Get started'")
    parser.add_argument("--exact", action="store_true", help="查找时使用精确匹配，默认包含匹配")
    parser.add_argument("--tap-text", help="查找并点击第一个匹配文本的元素")
    parser.add_argument("--screen", action="store_true", help="点击后返回截图 base64")
    parser.add_argument("--output", type=Path, help="保存完整 tree JSON 到指定路径")
    args = parser.parse_args()

    with VPhoneSession(args.target, app="instagram", flow="accessibility-tree", transport=args.transport) as vp:
        print(json.dumps(vp.info(), ensure_ascii=False, indent=2))

        if not args.no_launch:
            # 中文注释：先启动目标 App，确保 bundle_id 对应的进程存在。
            launch_resp = vp.app.launch(args.bundle_id)
            print("[+] launch:", json.dumps(launch_resp, ensure_ascii=False))
            time.sleep(args.wait)

        # 中文注释：获取当前页面 accessibility tree；nodes 是扁平化元素列表。
        tree = vp.ui.tree(bundle_id=args.bundle_id, max_nodes=args.max_nodes, screen=False)
        nodes = [n for n in tree.get("nodes", []) if isinstance(n, dict)]

        print(
            "[+] tree:",
            json.dumps(
                {
                    "ok": tree.get("ok"),
                    "bundle_id": tree.get("bundle_id"),
                    "pid": tree.get("pid"),
                    "node_count": tree.get("node_count"),
                    "query_ms": tree.get("query_ms"),
                    "scale": tree.get("scale"),
                    "screen": tree.get("screen"),
                },
                ensure_ascii=False,
            ),
        )
        print_nodes(nodes, limit=args.print_limit)

        if args.output:
            save_json(args.output, tree)

        if args.find:
            # 中文注释：演示按文本查找元素，默认匹配 label/value/hint/identifier/role。
            matches = vp.ui.find(args.find, bundle_id=args.bundle_id, exact=args.exact, max_nodes=args.max_nodes)
            print(f"\n[+] find {args.find!r}: {len(matches)} 个匹配")
            print_nodes(matches, limit=len(matches))

        if args.tap_text:
            # 中文注释：演示按文本定位元素，并点击元素中心像素坐标。
            resp = vp.ui.tap_text(
                args.tap_text,
                bundle_id=args.bundle_id,
                exact=args.exact,
                screen=args.screen,
                max_nodes=args.max_nodes,
            )
            printable = {k: v for k, v in resp.items() if k != "image"}
            print("\n[+] tap_text:", json.dumps(printable, ensure_ascii=False, indent=2))
            if resp.get("image"):
                print("[+] 点击后截图已返回在 response.image 字段（base64，终端不展开）。")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
