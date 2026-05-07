#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

BUSINESS_ROOT = Path(__file__).resolve().parents[1]
if str(BUSINESS_ROOT) not in sys.path:
    sys.path.insert(0, str(BUSINESS_ROOT))

from vphonekit import VPhoneSession

CONFIG = json.loads((Path(__file__).with_name("config.json")).read_text())


# 中文注释：Instagram 最小冒烟流程，展示 App 专属脚本如何复用 vphonekit。
def main() -> int:
    parser = argparse.ArgumentParser(description="Instagram smoke automation flow")
    parser.add_argument("target", help="instance name or VM dir")
    parser.add_argument("--transport", choices=["auto", "socket-only", "legacy"], default="auto")
    parser.add_argument("--no-close", action="store_true")
    args = parser.parse_args()

    bundle = CONFIG["bundle_id"]
    process = CONFIG["process_name"]
    center = CONFIG["coordinates"]["center"]
    start = CONFIG["coordinates"]["feed_swipe_start"]
    end = CONFIG["coordinates"]["feed_swipe_end"]

    with VPhoneSession(args.target, app="instagram", flow="smoke", transport=args.transport, artifacts=True) as vp:
        print(json.dumps(vp.info(), ensure_ascii=False, indent=2))
        vp.screen.show_window()
        vp.app.launch(bundle)
        time.sleep(2)
        vp.screen.tap(*center)
        vp.screen.swipe(start[0], start[1], end[0], end[1], ms=350)
        vp.screen.home()
        if not args.no_close:
            vp.app.terminate(bundle, process_name=process)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
