#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote

BUSINESS_ROOT = Path(__file__).resolve().parents[1]
if str(BUSINESS_ROOT) not in sys.path:
    sys.path.insert(0, str(BUSINESS_ROOT))

from vphonekit import VPhoneSession

CONFIG = json.loads((Path(__file__).with_name("config.json")).read_text())
DEFAULT_PROXY = "sbj9104335-region-JP-sid-ZEqDtRPw-t-60:qwertyuiop@sg.arxlabs.io:3010"
INSTAGRAM_BUNDLE_ID = CONFIG.get("bundle_id", "com.burbn.instagram")
DEFAULT_META_MYSQL_DSN = "root:root@tcp(127.0.0.1:3306)/zeus_accounts?charset=utf8mb4&parseTime=true&loc=Local"
DEFAULT_META_MYSQL_TABLE = "ios_metaai_accounts"


def log_start(name: str) -> None:
    # 中文注释：开始一个业务步骤，不换行；完成后由 log_done 补上 ok/failed。
    print(f"{name}...", end="", flush=True)


def log_done(ok: bool = True) -> None:
    # 中文注释：结束当前业务步骤，保证最终日志是一行一个步骤，例如“返回桌面...ok”。
    print("ok" if ok else "failed", flush=True)


def return_to_desktop(
    vp: VPhoneSession,
    *,
    repeat: int = 1,
    interval: float = 0.8,
    screen: bool = False,
) -> dict[str, Any]:
    """中文注释：返回 iOS 桌面，也就是发送 Home 键回到 SpringBoard。

    repeat 默认 1 次；如果当前可能在二级页面、搜索页、App Switcher 等状态，
    可以传 --repeat 2。每次之间留 interval，避免被系统识别成快速双击 Home。
    """

    repeat = max(1, repeat)
    last_resp: dict[str, Any] = {"ok": False}
    for index in range(repeat):
        # 中文注释：只有最后一次按 Home 时按需返回截图，避免前面步骤产生大 response。
        want_screen = screen and index == repeat - 1
        last_resp = vp.screen.home(screen=want_screen, delay=500)
        if index != repeat - 1:
            time.sleep(interval)
    return last_resp


def set_instance_proxy(
    vp: VPhoneSession,
    *,
    proxy: str,
    test: bool = False,
    no_restart: bool = False,
) -> dict[str, Any]:
    # 中文注释：设置实例代理。后续如果要加“判断代理是否已相同 / 失败重试”，放这里。
    return vp.proxy.set(
        proxy,
        test=test,
        no_restart=no_restart,
    )


def reset_app_new_device(
    vp: VPhoneSession,
    *,
    bundle_id: str,
    backup_before: bool = False,
    relaunch: bool = True,
    respring: bool = False,
) -> dict[str, Any]:
    # 中文注释：对指定 App 执行一键新机。这里默认 yes=True，避免业务流程中断等待确认。
    return vp.app_state.new_device(
        bundle_id,
        yes=True,
        backup_before=backup_before,
        relaunch=relaunch,
        respring=respring,
    )


def mysql_config_from_dsn(dsn: str) -> dict[str, str]:
    # 中文注释：解析 Go 风格 MySQL DSN，例如 user:pass@tcp(127.0.0.1:3306)/db?charset=utf8mb4。
    pattern = re.compile(
        r"^(?P<user>[^:@/]+)(?::(?P<password>[^@]*))?"
        r"@tcp\((?P<addr>[^)]*)\)/(?P<database>[^?]+)(?:\?(?P<query>.*))?$"
    )
    match = pattern.match(dsn.strip())
    if not match:
        raise ValueError(f"不支持的 MySQL DSN: {dsn!r}")

    addr = match.group("addr") or "127.0.0.1:3306"
    if ":" in addr:
        host, port = addr.rsplit(":", 1)
    else:
        host, port = addr, "3306"
    query = parse_qs(match.group("query") or "")
    charset = (query.get("charset") or ["utf8mb4"])[0]
    return {
        "user": unquote(match.group("user") or ""),
        "password": unquote(match.group("password") or ""),
        "host": host or "127.0.0.1",
        "port": port or "3306",
        "database": unquote(match.group("database") or ""),
        "charset": charset or "utf8mb4",
    }


def quote_mysql_identifier(name: str) -> str:
    # 中文注释：表名只允许普通标识符，避免把外部参数拼进 SQL 造成注入。
    if not re.fullmatch(r"[A-Za-z0-9_]+", name):
        raise ValueError(f"非法 MySQL 表名: {name!r}")
    return f"`{name}`"


def mysql_cli_json_query(dsn: str, sql: str, *, timeout: float = 10.0) -> dict[str, Any]:
    # 中文注释：通过本机 mysql CLI 执行查询，避免给业务脚本新增 Python MySQL 依赖。
    cfg = mysql_config_from_dsn(dsn)
    env = os.environ.copy()
    if cfg["password"]:
        env["MYSQL_PWD"] = cfg["password"]
    cmd = [
        "mysql",
        "--batch",
        "--raw",
        "--skip-column-names",
        "--protocol=TCP",
        "--default-character-set",
        cfg["charset"],
        "-h",
        cfg["host"],
        "-P",
        cfg["port"],
        "-u",
        cfg["user"],
        "--database",
        cfg["database"],
        "-e",
        sql,
    ]
    proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, env=env)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "mysql query failed").strip())

    lines = [line.strip() for line in (proc.stdout or "").splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("mysql query returned empty result")
    return json.loads(lines[-1])


def claim_meta_account_from_db(*, dsn: str, table: str) -> dict[str, Any]:
    # 中文注释：原子领取一条未使用 Meta 账号：is_used=0 -> is_used=1，并把 used_at 设置为领取时间。
    table_sql = quote_mysql_identifier(table)
    sql = f"""
SET @claim_id := NULL, @claim_email := NULL, @claim_password := NULL, @claim_used_at := NULL;
START TRANSACTION;
SELECT id, email, password, NOW(6)
  INTO @claim_id, @claim_email, @claim_password, @claim_used_at
  FROM {table_sql}
 WHERE is_used = 0
   AND email IS NOT NULL AND email <> ''
   AND password IS NOT NULL AND password <> ''
 ORDER BY id
 LIMIT 1
 FOR UPDATE;
UPDATE {table_sql}
   SET is_used = 1, used_at = @claim_used_at
 WHERE id = @claim_id;
SELECT JSON_OBJECT(
  'id', @claim_id,
  'email', @claim_email,
  'password', @claim_password,
  'used_at', DATE_FORMAT(@claim_used_at, '%Y-%m-%d %H:%i:%s.%f')
) AS claim_json;
COMMIT;
"""
    account = mysql_cli_json_query(dsn, sql)
    if not account.get("id") or not account.get("email") or not account.get("password"):
        raise LookupError(f"{table} 没有可用的 is_used=0 Meta 账号")
    return account


def wait_for_ocr_text(
    vp: VPhoneSession,
    text: str,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：等待当前屏幕 OCR 出现指定文本；默认包含匹配且不区分大小写。
    deadline = time.monotonic() + max(0.0, timeout)
    last_error = ""
    while True:
        try:
            node = vp.ocr.find_any([text], timeout=30.0)
            if node:
                return node
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            suffix = f"; {last_error}" if last_error else ""
            raise TimeoutError(f"OCR 未找到文本 {text!r}{suffix}")
        time.sleep(min(max(0.1, interval), remaining))


def wait_for_exact_ocr_value(
    vp: VPhoneSession,
    expected: str,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：等待 OCR 识别到完整文本；这里必须 value == expected，不能只做包含匹配。
    deadline = time.monotonic() + max(0.0, timeout)
    last_values: list[str] = []
    while True:
        nodes = vp.ocr.nodes(timeout=30.0)
        last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
        for node, value in zip(nodes, last_values):
            if value == expected:
                return node

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"OCR 未识别到完整邮箱 value == {expected!r}; 当前文本={last_values!r}")
        time.sleep(min(max(0.1, interval), remaining))


def tap_ocr_node_and_type(
    vp: VPhoneSession,
    node: dict[str, Any],
    text: str,
    *,
    focus_wait_min: float = 1.0,
    focus_wait_max: float = 2.0,
    char_delay_min: float = 0.3,
    char_delay_max: float = 0.8,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：点击 OCR 文字块中心点，等待输入框真正聚焦，再模拟人工速度逐字输入。
    # 注意：host-control 的 type_ascii 内部是异步排队；整段一次性输入太快，容易丢字符或串到其他输入框。
    tap_resp = vp.ocr.tap(node, screen=screen, delay=300)
    if not tap_resp.get("ok"):
        return {"ok": False, "tap": tap_resp, "type": None}

    focus_wait_min, focus_wait_max = sorted((max(0.0, focus_wait_min), max(0.0, focus_wait_max)))
    char_delay_min, char_delay_max = sorted((max(0.0, char_delay_min), max(0.0, char_delay_max)))
    focus_wait = random.uniform(focus_wait_min, focus_wait_max)
    time.sleep(focus_wait)

    char_responses: list[dict[str, Any]] = []
    for index, char in enumerate(text):
        # 中文注释：逐字发送；每个字符之间随机等待 300~800ms，避免输入过快导致漏字/错位。
        want_screen = screen and index == len(text) - 1
        resp = vp.screen.type_ascii(char, screen=want_screen, delay=100)
        char_responses.append(resp)
        if not resp.get("ok"):
            return {
                "ok": False,
                "tap": tap_resp,
                "focus_wait": focus_wait,
                "typed": index,
                "failed_char_index": index,
                "failed_char": char,
                "type": resp,
            }
        if index != len(text) - 1:
            time.sleep(random.uniform(char_delay_min, char_delay_max))

    return {
        "ok": True,
        "tap": tap_resp,
        "focus_wait": focus_wait,
        "typed": len(text),
        "char_delay_range": [char_delay_min, char_delay_max],
        "type": char_responses[-1] if char_responses else {"ok": True},
    }


def find_ocr_node_by_text(vp: VPhoneSession, nodes: list[dict[str, Any]], text: str) -> dict[str, Any] | None:
    # 中文注释：用 vphonekit OCR 的包含匹配逻辑查询文字块；默认不区分大小写。
    matches = vp.ocr.filter_nodes(nodes, text, exact=False, case_sensitive=False)
    return matches[0] if matches else None


def instagram_entry_from_ocr_nodes(vp: VPhoneSession, nodes: list[dict[str, Any]]) -> dict[str, Any]:
    # 中文注释：只基于 OCR 识别结果，判断 Instagram 当前入口属于哪个分支。
    login_node = find_ocr_node_by_text(vp, nodes, "Log in")
    create_node = find_ocr_node_by_text(vp, nodes, "Create new account")
    profile_node = find_ocr_node_by_text(vp, nodes, "I already have a profile")
    has_login = login_node is not None
    has_create = create_node is not None
    has_profile = profile_node is not None

    if has_profile:
        branch = "already_have_profile"
    elif has_login or has_create:
        branch = "login_or_create"
    else:
        branch = "not_found"

    return {
        "ok": has_login or has_create or has_profile,
        "branch": branch,
        "has_login": has_login,
        "has_create_new_account": has_create,
        "has_already_have_profile": has_profile,
        "login_node": login_node,
        "create_node": create_node,
        "profile_node": profile_node,
        "node_count": len(nodes),
        "source": "ocr",
    }


def wait_for_instagram_entry_branch(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：只使用 OCR 等待 Instagram 入口分支。
    # 分支 1：Log in / Create new account
    # 分支 2：I already have a profile（独立分支，出现后后续会点击）
    # 三个按钮任意一个出现就结束等待，最多等待 timeout 秒。
    deadline = time.monotonic() + max(0.0, timeout)
    last_resp: dict[str, Any] = {
        "ok": False,
        "branch": "not_found",
        "has_login": False,
        "has_create_new_account": False,
        "has_already_have_profile": False,
        "profile_node": None,
        "node_count": 0,
        "source": "",
    }
    last_error = ""

    while True:
        try:
            ocr_nodes = vp.ocr.nodes(timeout=30.0)
            last_resp = instagram_entry_from_ocr_nodes(vp, ocr_nodes)
            if last_resp.get("ok"):
                break
        except Exception as exc:
            last_error = f"OCR: {exc}"

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(max(0.1, interval), remaining))

    last_resp["error"] = last_error
    return last_resp


def flow_meta2ig(
    vp: VPhoneSession,
    *,
    proxy: str,
    instagram_bundle_id: str = INSTAGRAM_BUNDLE_ID,
    home_repeat: int = 1,
    home_interval: float = 0.8,
    proxy_wait: float = 2.0,
    proxy_test: bool = False,
    no_restart: bool = False,
    backup_before_new_device: bool = False,
    no_relaunch_after_new_device: bool = False,
    respring_after_new_device: bool = False,
    ui_timeout: float = 15.0,
    ui_interval: float = 0.5,
    meta_mysql_dsn: str = DEFAULT_META_MYSQL_DSN,
    meta_mysql_table: str = DEFAULT_META_MYSQL_TABLE,
    focus_wait_min: float = 1.0,
    focus_wait_max: float = 2.0,
    char_delay_min: float = 0.3,
    char_delay_max: float = 0.8,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：Meta -> Instagram 主业务流程。
    # 后续长链路继续在这里按“步骤 1、步骤 2、步骤 3...”往下加，不在 main() 里写 if/else 分支。

    # 步骤 1：返回桌面
    log_start("返回桌面")
    try:
        desktop_resp = return_to_desktop(
            vp,
            repeat=home_repeat,
            interval=home_interval,
            screen=screen,
        )
    except Exception:
        log_done(False)
        raise
    log_done(bool(desktop_resp.get("ok")))

    # 步骤 2：等待 proxy_wait 秒，然后设置代理
    log_start(f"等待{proxy_wait:g}秒")
    time.sleep(max(0.0, proxy_wait))
    log_done(True)

    # 步骤 3：设置代理
    log_start("设置代理")
    try:
        proxy_resp = set_instance_proxy(
            vp,
            proxy=proxy,
            test=proxy_test,
            no_restart=no_restart,
        )
    except Exception:
        log_done(False)
        raise
    log_done(bool(proxy_resp.get("ok")))

    # 步骤 4：对 Instagram 执行一键新机
    log_start("Instagram一键新机")
    try:
        new_device_resp = reset_app_new_device(
            vp,
            bundle_id=instagram_bundle_id,
            backup_before=backup_before_new_device,
            relaunch=not no_relaunch_after_new_device,
            respring=respring_after_new_device,
        )
    except Exception:
        log_done(False)
        raise
    log_done(bool(new_device_resp.get("ok")))

    # 步骤 5：只用 OCR 等待当前屏幕出现 Log in / Create new account / I already have a profile，最大等待 ui_timeout 秒。
    log_start("等待Instagram入口按钮")
    try:
        entry_resp = wait_for_instagram_entry_branch(
            vp,
            timeout=ui_timeout,
            interval=ui_interval,
        )
    except Exception:
        log_done(False)
        raise
    entry_ok = bool(entry_resp.get("ok"))
    log_done(entry_ok)
    if not entry_ok:
        raise TimeoutError("未找到 Instagram 入口按钮")

    # 步骤 6：根据入口按钮进入独立分支
    profile_click_ok = True
    profile_clicked = False
    meta_account: dict[str, Any] | None = None
    username_node: dict[str, Any] | None = None
    username_input_ok = False
    password_input_ok = False
    email_verified = False
    login_click_ok = False
    if entry_resp.get("branch") == "already_have_profile":
        # 中文注释：如果 OCR 识别到 “I already have a profile”，直接按 OCR 返回的中心点点击。
        log_start("点击I already have a profile")
        try:
            profile_node = entry_resp.get("profile_node")
            if not isinstance(profile_node, dict):
                raise LookupError("I already have a profile 缺少 OCR 坐标")
            profile_click_resp = vp.ocr.tap(profile_node)
            profile_click_ok = bool(profile_click_resp.get("ok"))
            profile_clicked = profile_click_ok
        except Exception:
            log_done(False)
            raise
        log_done(profile_click_ok)
        if not profile_click_ok:
            raise RuntimeError("点击 I already have a profile 失败")
    elif entry_resp.get("branch") == "login_or_create":
        # 中文注释：当前已经在登录表单分支；这里不做任何点击，直接进入步骤 7 查 Username。
        pass

    # 步骤 7：等待登录表单里的 Username 输入框
    log_start("等待Username输入框")
    try:
        username_node = wait_for_ocr_text(vp, "username", timeout=ui_timeout, interval=ui_interval)
    except Exception:
        log_done(False)
        raise
    log_done(True)

    # 步骤 8：从 MySQL 原子领取一条 is_used=0 的 Meta 账号，并立即标记 is_used=1 / used_at=领取时间
    log_start("领取Meta账号")
    try:
        meta_account = claim_meta_account_from_db(dsn=meta_mysql_dsn, table=meta_mysql_table)
    except Exception:
        log_done(False)
        raise
    log_done(True)

    # 步骤 9：点击 Username 输入框，输入 Meta 邮箱
    log_start("输入Meta邮箱")
    try:
        username_resp = tap_ocr_node_and_type(
            vp,
            username_node,
            str(meta_account["email"]),
            focus_wait_min=focus_wait_min,
            focus_wait_max=focus_wait_max,
            char_delay_min=char_delay_min,
            char_delay_max=char_delay_max,
            screen=screen,
        )
        username_input_ok = bool(username_resp.get("ok"))
    except Exception:
        log_done(False)
        raise
    log_done(username_input_ok)
    if not username_input_ok:
        raise RuntimeError("输入 Meta 邮箱失败")

    # 步骤 10：输入邮箱后等待 1~2 秒，让页面和键盘状态稳定
    email_wait = random.uniform(1.0, 2.0)
    log_start(f"等待{email_wait:.1f}秒")
    time.sleep(email_wait)
    log_done(True)

    # 步骤 11：点击 Password 输入框，输入 Meta 密码
    log_start("输入Meta密码")
    try:
        password_node = wait_for_ocr_text(vp, "password", timeout=ui_timeout, interval=ui_interval)
        password_resp = tap_ocr_node_and_type(
            vp,
            password_node,
            str(meta_account["password"]),
            focus_wait_min=focus_wait_min,
            focus_wait_max=focus_wait_max,
            char_delay_min=char_delay_min,
            char_delay_max=char_delay_max,
            screen=screen,
        )
        password_input_ok = bool(password_resp.get("ok"))
    except Exception:
        log_done(False)
        raise
    log_done(password_input_ok)
    if not password_input_ok:
        raise RuntimeError("输入 Meta 密码失败")

    # 步骤 12：输入密码后等待 1~2 秒，让登录按钮状态稳定
    password_wait = random.uniform(1.0, 2.0)
    log_start(f"等待{password_wait:.1f}秒")
    time.sleep(password_wait)
    log_done(True)

    # 步骤 13：账号密码都输入完成后，OCR 校验完整邮箱；必须 value == 账号邮箱，校验失败不点击登录。
    log_start("校验Meta邮箱")
    try:
        email_verify_node = wait_for_exact_ocr_value(
            vp,
            str(meta_account["email"]),
            timeout=ui_timeout,
            interval=ui_interval,
        )
        email_verified = bool(email_verify_node)
    except Exception:
        log_done(False)
        raise
    log_done(email_verified)
    if not email_verified:
        raise RuntimeError("OCR 校验 Meta 邮箱失败")

    # 步骤 14：点击 Log in
    log_start("点击Log in")
    try:
        login_node = wait_for_ocr_text(vp, "log in", timeout=ui_timeout, interval=ui_interval)
        login_resp = vp.ocr.tap(login_node, screen=screen, delay=500)
        login_click_ok = bool(login_resp.get("ok"))
    except Exception:
        log_done(False)
        raise
    log_done(login_click_ok)
    if not login_click_ok:
        raise RuntimeError("点击 Log in 失败")

    # 步骤 15：流程完成
    ok = (
        bool(desktop_resp.get("ok"))
        and bool(proxy_resp.get("ok"))
        and bool(new_device_resp.get("ok"))
        and bool(entry_resp.get("ok"))
        and profile_click_ok
        and username_input_ok
        and password_input_ok
        and email_verified
        and login_click_ok
    )
    log_start("流程完成")
    log_done(ok)

    # 步骤 16：返回本流程最终结果，供外部调用时判断成功/失败；不返回密码。
    return {
        "ok": ok,
        "flow": "meta2ig",
        "return_to_desktop": bool(desktop_resp.get("ok")),
        "set_proxy": bool(proxy_resp.get("ok")),
        "instagram_new_device": bool(new_device_resp.get("ok")),
        "entry_branch": str(entry_resp.get("branch") or ""),
        "entry_source": str(entry_resp.get("source") or ""),
        "has_login": bool(entry_resp.get("has_login")),
        "has_create_new_account": bool(entry_resp.get("has_create_new_account")),
        "has_already_have_profile": bool(entry_resp.get("has_already_have_profile")),
        "already_have_profile_clicked": profile_clicked,
        "meta_account_id": meta_account.get("id") if meta_account else None,
        "meta_account_email": meta_account.get("email") if meta_account else None,
        "meta_account_used_at": meta_account.get("used_at") if meta_account else None,
        "username_input": username_input_ok,
        "password_input": password_input_ok,
        "email_verified": email_verified,
        "login_clicked": login_click_ok,
        "entry_error": str(entry_resp.get("error") or ""),
        "proxy": proxy,
        "instagram_bundle_id": instagram_bundle_id,
    }


def main() -> int:
    # 中文注释：main 只做参数解析和 Session 初始化；业务步骤全部放在 flow_meta2ig() 里顺序执行。
    parser = argparse.ArgumentParser(description="Meta to Instagram automation helpers")
    parser.add_argument("target", help="实例名或 VM 目录，例如 instagram-01")
    parser.add_argument("--transport", choices=["auto", "socket-only", "legacy"], default="auto")
    parser.add_argument("--repeat", type=int, default=1, help="Home 键次数，默认 1；不确定状态可用 2")
    parser.add_argument("--interval", type=float, default=0.8, help="多次 Home 之间的间隔秒数")
    parser.add_argument("--proxy", default=DEFAULT_PROXY, help="返回桌面后设置的代理；省略 scheme 时 set_instance_proxy.sh 默认按 http:// 处理")
    parser.add_argument("--proxy-wait", type=float, default=2.0, help="返回桌面后等待多少秒再设置代理")
    parser.add_argument("--proxy-test", action="store_true", help="设置代理后测试出口 IP")
    parser.add_argument("--no-restart", action="store_true", help="设置代理后不重启/刷新网络相关服务")
    parser.add_argument("--instagram-bundle-id", default=INSTAGRAM_BUNDLE_ID, help="要执行一键新机的 Instagram bundle id")
    parser.add_argument("--backup-before-new-device", action="store_true", help="一键新机前先备份 App 状态")
    parser.add_argument("--no-relaunch-after-new-device", action="store_true", help="一键新机后不自动重新启动 App")
    parser.add_argument("--respring-after-new-device", action="store_true", help="一键新机后执行 respring")
    parser.add_argument("--ui-timeout", type=float, default=15.0, help="OCR 等待 Log in / Create new account / I already have a profile 出现的最大秒数")
    parser.add_argument("--ui-wait", dest="ui_timeout", type=float, help=argparse.SUPPRESS)
    parser.add_argument("--ui-interval", type=float, default=0.5, help="OCR 轮询间隔秒数")
    parser.add_argument("--meta-db-dsn", default=os.environ.get("IOS_METAAI_MYSQL_DSN", DEFAULT_META_MYSQL_DSN), help="Meta 账号 MySQL DSN；默认读 IOS_METAAI_MYSQL_DSN")
    parser.add_argument("--meta-db-table", default=os.environ.get("IOS_METAAI_MYSQL_TABLE", DEFAULT_META_MYSQL_TABLE), help="Meta 账号表名；默认读 IOS_METAAI_MYSQL_TABLE")
    parser.add_argument("--focus-wait-min", type=float, default=1.0, help="点击输入框后最少等待秒数，默认 1.0")
    parser.add_argument("--focus-wait-max", type=float, default=2.0, help="点击输入框后最多等待秒数，默认 2.0")
    parser.add_argument("--char-delay-min", type=float, default=0.3, help="逐字输入最小间隔秒数，默认 0.3")
    parser.add_argument("--char-delay-max", type=float, default=0.8, help="逐字输入最大间隔秒数，默认 0.8")
    parser.add_argument("--screen", action="store_true", help="返回桌面后带一张截图 base64")
    parser.add_argument("--artifacts", action="store_true", help="记录 businessScript runs artifacts")
    args = parser.parse_args()

    try:
        with VPhoneSession(
            args.target,
            app=CONFIG.get("name", "instagram"),
            flow="meta2ig",
            transport=args.transport,
            artifacts=args.artifacts,
        ) as vp:
            flow_meta2ig(
                vp,
                proxy=args.proxy,
                instagram_bundle_id=args.instagram_bundle_id,
                home_repeat=args.repeat,
                home_interval=args.interval,
                proxy_wait=args.proxy_wait,
                proxy_test=args.proxy_test,
                no_restart=args.no_restart,
                backup_before_new_device=args.backup_before_new_device,
                no_relaunch_after_new_device=args.no_relaunch_after_new_device,
                respring_after_new_device=args.respring_after_new_device,
                ui_timeout=args.ui_timeout,
                ui_interval=args.ui_interval,
                meta_mysql_dsn=args.meta_db_dsn,
                meta_mysql_table=args.meta_db_table,
                focus_wait_min=args.focus_wait_min,
                focus_wait_max=args.focus_wait_max,
                char_delay_min=args.char_delay_min,
                char_delay_max=args.char_delay_max,
                screen=args.screen,
            )
    except Exception as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
