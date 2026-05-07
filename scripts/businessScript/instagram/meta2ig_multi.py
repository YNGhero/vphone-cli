#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import random
import re
import shlex
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

BUSINESS_ROOT = Path(__file__).resolve().parents[1]
if str(BUSINESS_ROOT) not in sys.path:
    sys.path.insert(0, str(BUSINESS_ROOT))

from vphonekit import VPhoneSession

SUMMARY_RE = re.compile(r"循环结束：总轮数=(?P<rounds>\d+)，成功=(?P<success>\d+)，失败=(?P<failure>\d+)")
ROUND_FAILURE_RE = re.compile(r"本轮结果：失败(?:（(?P<round>\d+)/(?P<rounds>\d+)[^）]*）)?")


def timestamp_slug() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S-%f")


def safe_name(name: str) -> str:
    # 中文注释：实例名正常是 instagram-01；这里做一下兜底，避免用户传路径时把日志写散。
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._") or "instance"


def append_log_line(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fp:
        fp.write(line.rstrip("\n") + "\n")


@dataclass
class InstanceResult:
    target: str
    returncode: int
    success: int
    failure: int
    rounds: int
    command: list[str]
    log_path: Path
    failure_log_path: Path
    screenshots: list[Path]


async def capture_failure_screenshot(
    *,
    target: str,
    log_dir: Path,
    failure_index: int,
    round_index: int | None,
    transport: str,
    settle_delay: float,
) -> tuple[Path | None, str]:
    # 中文注释：失败时立即截取当前实例屏幕，截图路径写进实例日志和 failures.log。
    if settle_delay > 0:
        await asyncio.sleep(settle_delay)

    round_part = f"-round{round_index:03d}" if round_index is not None else ""
    screenshot_path = log_dir / f"failure-{timestamp_slug()}{round_part}-{failure_index:02d}.png"

    def do_screenshot() -> Path:
        with VPhoneSession(
            target,
            app="instagram",
            flow="meta2ig_multi_failure",
            transport=transport,
        ) as vp:
            resp = vp.screen.screenshot(screenshot_path)
            return Path(str(resp.get("path") or screenshot_path)).expanduser().resolve()

    try:
        saved_path = await asyncio.to_thread(do_screenshot)
        return saved_path, f"失败截图：{saved_path}"
    except Exception as exc:
        return None, f"失败截图失败：{exc}"


async def run_instance(
    *,
    target: str,
    command: list[str],
    rounds: int,
    log_root: Path,
    failure_screenshot: bool,
    screenshot_transport: str,
    screenshot_settle_delay: float,
) -> InstanceResult:
    # 中文注释：每个实例单独启动一个 meta2ig.py 子进程；stdout/stderr 合并后按行加实例名前缀，方便并发观察。
    log_dir = log_root / safe_name(target)
    log_dir.mkdir(parents=True, exist_ok=True)
    run_id = timestamp_slug()
    log_path = log_dir / f"run-{run_id}.log"
    failure_log_path = log_dir / "failures.log"
    screenshots: list[Path] = []
    failure_event_count = 0

    header_lines = [
        f"时间：{datetime.now().isoformat(timespec='seconds')}",
        f"实例：{target}",
        f"命令：{shlex.join(command)}",
        f"日志：{log_path}",
        "-" * 80,
    ]
    append_log_line(log_path, "\n".join(header_lines))

    proc = await asyncio.create_subprocess_exec(
        *command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    parsed_rounds: int | None = None
    parsed_success: int | None = None
    parsed_failure: int | None = None

    assert proc.stdout is not None
    async for raw_line in proc.stdout:
        line = raw_line.decode(errors="replace").rstrip("\n")
        append_log_line(log_path, line)
        match = SUMMARY_RE.search(line)
        if match:
            parsed_rounds = int(match.group("rounds"))
            parsed_success = int(match.group("success"))
            parsed_failure = int(match.group("failure"))
        print(f"[{target}] {line}", flush=True)

        failure_match = ROUND_FAILURE_RE.search(line)
        if failure_match:
            failure_event_count += 1
            round_text = failure_match.group("round")
            round_index = int(round_text) if round_text else None
            failure_header = (
                f"{datetime.now().isoformat(timespec='seconds')} "
                f"实例={target} 失败事件={failure_event_count} 行={line}"
            )
            append_log_line(failure_log_path, failure_header)
            append_log_line(log_path, failure_header)
            if failure_screenshot:
                screenshot_path, screenshot_msg = await capture_failure_screenshot(
                    target=target,
                    log_dir=log_dir,
                    failure_index=failure_event_count,
                    round_index=round_index,
                    transport=screenshot_transport,
                    settle_delay=screenshot_settle_delay,
                )
                if screenshot_path is not None:
                    screenshots.append(screenshot_path)
                append_log_line(failure_log_path, screenshot_msg)
                append_log_line(log_path, screenshot_msg)
                print(f"[{target}] {screenshot_msg}", flush=True)

    returncode = await proc.wait()

    # 中文注释：正常情况下从 meta2ig.py 的“循环结束”汇总行解析成功/失败；如果子进程异常退出没有汇总行，则按整组失败处理。
    if parsed_success is None or parsed_failure is None:
        parsed_rounds = rounds
        if returncode == 0:
            parsed_success = rounds
            parsed_failure = 0
        else:
            parsed_success = 0
            parsed_failure = rounds

    needs_final_failure_screenshot = (
        failure_screenshot
        and not screenshots
        and (returncode != 0 or int(parsed_failure or 0) > 0)
    )
    if needs_final_failure_screenshot:
        failure_event_count += 1
        failure_header = (
            f"{datetime.now().isoformat(timespec='seconds')} "
            f"实例={target} 进程结束失败 returncode={returncode}, success={parsed_success}, failure={parsed_failure}"
        )
        append_log_line(failure_log_path, failure_header)
        append_log_line(log_path, failure_header)
        screenshot_path, screenshot_msg = await capture_failure_screenshot(
            target=target,
            log_dir=log_dir,
            failure_index=failure_event_count,
            round_index=None,
            transport=screenshot_transport,
            settle_delay=screenshot_settle_delay,
        )
        if screenshot_path is not None:
            screenshots.append(screenshot_path)
        append_log_line(failure_log_path, screenshot_msg)
        append_log_line(log_path, screenshot_msg)
        print(f"[{target}] {screenshot_msg}", flush=True)

    footer = (
        f"{datetime.now().isoformat(timespec='seconds')} "
        f"结束：returncode={returncode}, 轮数={parsed_rounds or rounds}, 成功={parsed_success}, 失败={parsed_failure}"
    )
    append_log_line(log_path, "-" * 80)
    append_log_line(log_path, footer)
    if int(parsed_failure or 0) > 0 or returncode != 0:
        append_log_line(failure_log_path, footer)

    return InstanceResult(
        target=target,
        returncode=returncode,
        success=parsed_success,
        failure=parsed_failure,
        rounds=parsed_rounds or rounds,
        command=command,
        log_path=log_path,
        failure_log_path=failure_log_path,
        screenshots=screenshots,
    )


async def run_all(
    *,
    targets: list[str],
    rounds: int,
    concurrency: int,
    python_bin: str,
    meta2ig_path: Path,
    child_args: list[str],
    start_stagger: float,
    start_jitter: float,
    log_root: Path,
    failure_screenshot: bool,
    screenshot_transport: str,
    screenshot_settle_delay: float,
) -> list[InstanceResult]:
    # 中文注释：默认 concurrency == 实例数，即所有 instagram-xx 同时跑；也可以限制并发批量跑。
    semaphore = asyncio.Semaphore(max(1, concurrency))

    async def run_one(index: int, target: str) -> InstanceResult:
        # 中文注释：并发启动时给每个实例错峰，避免所有实例同时打 SSH 导致 dropbear/端口转发偶发认证失败。
        delay = (max(0.0, start_stagger) * index) + random.uniform(0.0, max(0.0, start_jitter))
        if delay > 0:
            await asyncio.sleep(delay)
        async with semaphore:
            command = [
                python_bin,
                str(meta2ig_path),
                target,
                "--loop",
                "--loop-rounds",
                str(rounds),
                *child_args,
            ]
            print(f"[{target}] 启动：{shlex.join(command)}", flush=True)
            return await run_instance(
                target=target,
                command=command,
                rounds=rounds,
                log_root=log_root,
                failure_screenshot=failure_screenshot,
                screenshot_transport=screenshot_transport,
                screenshot_settle_delay=screenshot_settle_delay,
            )

    tasks = [asyncio.create_task(run_one(index, target)) for index, target in enumerate(targets)]
    results: list[InstanceResult] = []
    for task in asyncio.as_completed(tasks):
        results.append(await task)
    return results


def generated_targets(*, prefix: str, start: int, end: int | None, count: int | None, width: int) -> list[str]:
    if end is None and count is None:
        raise ValueError("没有传实例列表时，必须设置 --end 或 --count，例如 --start 1 --end 4")
    if start < 0:
        raise ValueError("--start 必须 >= 0")
    if width < 1:
        raise ValueError("--width 必须 >= 1")

    if end is not None:
        if end < start:
            raise ValueError("--end 必须 >= --start")
        indexes = range(start, end + 1)
    else:
        assert count is not None
        if count < 1:
            raise ValueError("--count 必须 >= 1")
        indexes = range(start, start + count)

    return [f"{prefix}{index:0{width}d}" for index in indexes]


def parse_args() -> tuple[argparse.Namespace, list[str]]:
    # 中文注释：父脚本参数和 meta2ig.py 参数必须用 -- 分隔，避免 argparse 把透传参数误当成实例名。
    argv = sys.argv[1:]
    if "--" in argv:
        separator_index = argv.index("--")
        parent_argv = argv[:separator_index]
        child_args = argv[separator_index + 1 :]
    else:
        parent_argv = argv
        child_args = []

    parser = argparse.ArgumentParser(
        description="并发运行多个 Instagram meta2ig 实例，并让每个实例按轮数循环",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例：
  # 同时跑 instagram-01 和 instagram-02，每个实例循环 10 轮
  python3 scripts/businessScript/instagram/meta2ig_multi.py instagram-01 instagram-02 --rounds 10

  # 自动生成 instagram-01 到 instagram-04，每个实例循环 20 轮
  python3 scripts/businessScript/instagram/meta2ig_multi.py --start 1 --end 4 --rounds 20

  # 限制最多 2 个实例并发；-- 后面的参数原样传给 meta2ig.py
  python3 scripts/businessScript/instagram/meta2ig_multi.py --start 1 --end 6 --rounds 5 --concurrency 2 -- --ui-timeout 20 --no-report

  # 如果确认 SSH 很稳，可以关闭启动错峰
  python3 scripts/businessScript/instagram/meta2ig_multi.py --start 1 --end 5 --rounds 1 --start-stagger 0 --start-jitter 0
""".strip(),
    )
    parser.add_argument("targets", nargs="*", help="实例名列表，例如 instagram-01 instagram-02；为空时用 --start/--end/--count 生成")
    parser.add_argument("--prefix", default="instagram-", help="自动生成实例名前缀，默认 instagram-")
    parser.add_argument("--start", type=int, default=1, help="自动生成实例的起始编号，默认 1")
    parser.add_argument("--end", type=int, help="自动生成实例的结束编号，包含该编号，例如 --start 1 --end 4")
    parser.add_argument("--count", type=int, help="自动生成多少个实例；和 --end 二选一")
    parser.add_argument("--width", type=int, default=2, help="自动生成编号宽度，默认 2，即 01/02")
    parser.add_argument("--rounds", type=int, default=1, help="每个实例循环多少轮，默认 1")
    parser.add_argument("--concurrency", type=int, default=0, help="最大并发实例数，默认等于实例数量")
    parser.add_argument("--start-stagger", type=float, default=0.8, help="实例启动错峰秒数，默认 0.8；用于降低并发 SSH 抖动，设 0 可关闭")
    parser.add_argument("--start-jitter", type=float, default=0.4, help="每个实例额外随机启动抖动秒数，默认 0.4；设 0 可关闭")
    parser.add_argument("--python", default=sys.executable, help="运行 meta2ig.py 的 Python 解释器，默认当前解释器")
    parser.add_argument("--meta2ig", default=str(Path(__file__).with_name("meta2ig.py")), help="meta2ig.py 路径")
    parser.add_argument("--log-root", default=str(BUSINESS_ROOT / "log"), help="每个实例独立日志根目录，默认 scripts/businessScript/log")
    parser.add_argument("--no-failure-screenshot", action="store_true", help="失败时不截图；默认失败会截图并把路径写入实例日志")
    parser.add_argument("--failure-screenshot-transport", default="auto", choices=["auto", "socket-only", "legacy"], help="失败截图使用的 vphonekit transport，默认 auto")
    parser.add_argument("--failure-screenshot-delay", type=float, default=0.5, help="检测到失败后延迟多少秒再截图，默认 0.5")
    parser.add_argument("--dry-run", action="store_true", help="只打印将要执行的命令，不启动子进程")
    args = parser.parse_args(parent_argv)

    if args.end is not None and args.count is not None:
        parser.error("--end 和 --count 只能设置一个")
    if args.rounds < 1:
        parser.error("--rounds 必须 >= 1")
    if args.concurrency < 0:
        parser.error("--concurrency 必须 >= 0")
    if args.start_stagger < 0:
        parser.error("--start-stagger 必须 >= 0")
    if args.start_jitter < 0:
        parser.error("--start-jitter 必须 >= 0")
    if args.failure_screenshot_delay < 0:
        parser.error("--failure-screenshot-delay 必须 >= 0")

    if not args.targets:
        try:
            args.targets = generated_targets(
                prefix=args.prefix,
                start=args.start,
                end=args.end,
                count=args.count,
                width=args.width,
            )
        except ValueError as exc:
            parser.error(str(exc))

    # 中文注释：去掉重复实例，保持用户传入顺序，避免同一个实例被两个子进程同时操作。
    seen: set[str] = set()
    unique_targets: list[str] = []
    for target in args.targets:
        if target in seen:
            continue
        seen.add(target)
        unique_targets.append(target)
    args.targets = unique_targets

    meta2ig_path = Path(args.meta2ig).expanduser().resolve()
    if not meta2ig_path.is_file():
        parser.error(f"meta2ig.py 不存在: {meta2ig_path}")
    args.meta2ig = str(meta2ig_path)
    args.log_root = str(Path(args.log_root).expanduser().resolve())

    return args, child_args


def main() -> int:
    args, child_args = parse_args()
    targets: list[str] = args.targets
    concurrency = args.concurrency or len(targets)
    meta2ig_path = Path(args.meta2ig)
    log_root = Path(args.log_root)

    print(
        f"并发配置：实例={len(targets)}，并发={concurrency}，每实例轮数={args.rounds}，"
        f"启动错峰={args.start_stagger:g}s，随机抖动={args.start_jitter:g}s，targets={targets}",
        flush=True,
    )
    print(
        f"日志目录：{log_root}，失败截图={'关闭' if args.no_failure_screenshot else '开启'}",
        flush=True,
    )
    if child_args:
        print(f"透传 meta2ig.py 参数：{shlex.join(child_args)}", flush=True)

    if args.dry_run:
        for target in targets:
            command = [
                args.python,
                str(meta2ig_path),
                target,
                "--loop",
                "--loop-rounds",
                str(args.rounds),
                *child_args,
            ]
            print(shlex.join(command), flush=True)
        return 0

    results = asyncio.run(
        run_all(
            targets=targets,
            rounds=args.rounds,
            concurrency=concurrency,
            python_bin=args.python,
            meta2ig_path=meta2ig_path,
            child_args=child_args,
            start_stagger=args.start_stagger,
            start_jitter=args.start_jitter,
            log_root=log_root,
            failure_screenshot=not args.no_failure_screenshot,
            screenshot_transport=args.failure_screenshot_transport,
            screenshot_settle_delay=args.failure_screenshot_delay,
        )
    )

    # 中文注释：按实例名排序输出最终汇总，便于人工核对 instagram-01/02/03... 的结果。
    results_by_target = sorted(results, key=lambda item: item.target)
    total_rounds = sum(result.rounds for result in results_by_target)
    total_success = sum(result.success for result in results_by_target)
    total_failure = sum(result.failure for result in results_by_target)

    print(
        f"\n并发结束：实例数={len(results_by_target)}，总轮数={total_rounds}，成功={total_success}，失败={total_failure}",
        flush=True,
    )
    print("实例明细：", flush=True)
    for result in results_by_target:
        print(
            f"  - {result.target}: returncode={result.returncode}, 轮数={result.rounds}, 成功={result.success}, 失败={result.failure}, log={result.log_path}",
            flush=True,
        )
        if result.failure > 0 or result.returncode != 0:
            print(f"    failure_log={result.failure_log_path}", flush=True)
            for screenshot_path in result.screenshots:
                print(f"    screenshot={screenshot_path}", flush=True)

    return 0 if total_failure == 0 and all(result.returncode == 0 for result in results_by_target) else 1


if __name__ == "__main__":
    raise SystemExit(main())
