#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shlex
import string
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote
from urllib.error import HTTPError
from urllib.request import Request, urlopen

BUSINESS_ROOT = Path(__file__).resolve().parents[1]
if str(BUSINESS_ROOT) not in sys.path:
    sys.path.insert(0, str(BUSINESS_ROOT))

from vphonekit import VPhoneSession

CONFIG = json.loads((Path(__file__).with_name("config.json")).read_text())
DEFAULT_PROXY = "sbj9104335-region-Rand-sid-username-t-60:qwertyuiop@sg.arxlabs.io:3010"
INSTAGRAM_BUNDLE_ID = CONFIG.get("bundle_id", "com.burbn.instagram")
DEFAULT_META_MYSQL_DSN = "root:root@tcp(127.0.0.1:3306)/zeus_accounts?charset=utf8mb4&parseTime=true&loc=Local"
DEFAULT_META_MYSQL_TABLE = "ios_metaai_accounts"
PROXY_USERNAME_PLACEHOLDER = "username"
DEFAULT_PROFILE_PHOTO_DIR = Path("/Users/true/Documents/ZeusFramework/go/register_ins/picture")
SUPPORTED_PROFILE_PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp"}
DEFAULT_INSTAGRAM_ACCOUNT_JSON_PATH = str(
    CONFIG.get("hooks", {}).get("audit", {}).get("account_json", "/tmp/instagram_account.json")
)
DEFAULT_SECONDARY_ACCOUNT_REPORT_URL = "http://52.68.76.129:8081/api/InsRegister/createSecondaryAccount"


def log_start(name: str) -> None:
    # 中文注释：开始一个业务步骤，不换行；完成后由 log_done 补上 ok/failed。
    print(f"{name}...", end="", flush=True)


def log_done(ok: bool = True) -> None:
    # 中文注释：结束当前业务步骤，保证最终日志是一行一个步骤，例如“返回桌面...ok”。
    print("ok" if ok else "failed", flush=True)


def random_proxy_username(length: int = 8) -> str:
    # 中文注释：生成代理 sid 使用的 8 位随机字符串，包含大小写字母和数字。
    alphabet = string.ascii_letters + string.digits
    return "".join(random.choice(alphabet) for _ in range(max(1, length)))


def render_proxy_url(proxy: str) -> tuple[str, str | None]:
    # 中文注释：设置代理前，把 username 占位符替换成随机 8 位 sid；没有占位符则原样返回。
    if PROXY_USERNAME_PLACEHOLDER not in proxy:
        return proxy, None
    username = random_proxy_username()
    return proxy.replace(PROXY_USERNAME_PLACEHOLDER, username), username


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


def set_instance_proxy_with_retry(
    vp: VPhoneSession,
    *,
    proxy: str,
    test: bool = False,
    no_restart: bool = False,
    attempts: int = 4,
    retry_delay: float = 3.0,
) -> dict[str, Any]:
    # 中文注释：多实例并发时 guest SSH 偶发 Permission denied / connection reset。
    # 这里先探测 SSH 就绪，再对整个 set_instance_proxy.sh 重试；失败的 bridge 会在下次脚本启动时自动 stop/recreate。
    attempts = max(1, attempts)
    last_error = ""
    for attempt in range(1, attempts + 1):
        wait_for_guest_ssh_ready(
            vp,
            timeout=12.0 if attempt == 1 else 25.0,
            interval=1.5,
        )
        try:
            resp = set_instance_proxy(
                vp,
                proxy=proxy,
                test=test,
                no_restart=no_restart,
            )
            resp["attempt"] = attempt
            return resp
        except Exception as exc:
            last_error = str(exc)
            if attempt >= attempts:
                break
            if not is_transient_ssh_error(last_error):
                raise
            time.sleep((retry_delay * attempt) + random.uniform(0.2, 1.2))

    raise RuntimeError(f"设置代理失败，已重试 {attempts} 次；最后错误：{last_error}")


def reset_app_new_device(
    vp: VPhoneSession,
    *,
    bundle_id: str,
    backup_before: bool = False,
    relaunch: bool = True,
    respring: bool = False,
    attempts: int = 4,
    retry_delay: float = 3.0,
) -> dict[str, Any]:
    # 中文注释：对指定 App 执行一键新机。这里默认 yes=True，避免业务流程中断等待确认。
    attempts = max(1, attempts)
    last_error = ""
    for attempt in range(1, attempts + 1):
        # 中文注释：设置代理会刷新网络配置；紧接着跑 app_new_device 时 SSH 转发偶发认证失败。
        # 这里要求 guest SSH 先恢复，再对整个一键新机脚本做瞬时 SSH 错误重试。
        wait_for_guest_ssh_ready(
            vp,
            timeout=20.0 if attempt == 1 else 30.0,
            interval=1.5,
        )
        try:
            resp = vp.app_state.new_device(
                bundle_id,
                yes=True,
                backup_before=backup_before,
                relaunch=relaunch,
                respring=respring,
            )
            resp["attempt"] = attempt
            return resp
        except Exception as exc:
            last_error = str(exc)
            if attempt >= attempts or not is_transient_ssh_error(last_error):
                raise
            time.sleep((retry_delay * attempt) + random.uniform(0.2, 1.2))

    raise RuntimeError(f"Instagram一键新机失败，已重试 {attempts} 次；最后错误：{last_error}")


def pick_random_profile_photo(photo_dir: str | Path) -> Path:
    # 中文注释：从头像素材目录随机选择一张图片；目录不存在或没有图片时直接失败，避免后续点击头像时无图可选。
    root = Path(photo_dir).expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(f"头像照片目录不存在: {root}")
    if not root.is_dir():
        raise NotADirectoryError(f"头像照片路径不是目录: {root}")

    images = [
        path
        for path in root.iterdir()
        if path.is_file() and path.suffix.casefold() in SUPPORTED_PROFILE_PHOTO_EXTENSIONS
    ]
    if not images:
        supported = ", ".join(sorted(SUPPORTED_PROFILE_PHOTO_EXTENSIONS))
        raise FileNotFoundError(f"头像照片目录没有可导入图片: {root}，支持格式: {supported}")
    return random.choice(images)


def is_transient_ssh_error(error_text: str) -> bool:
    # 中文注释：照片导入底层走 sshpass/ssh，刚清空相册或 guest 短暂忙时可能出现临时 SSH 失败。
    text = str(error_text or "").casefold()
    transient_markers = [
        "permission denied",
        "connection refused",
        "connection reset",
        "connection closed",
        "operation timed out",
        "connect timed out",
        "timed out",
        "ssh_exchange_identification",
        "kex_exchange_identification",
        "broken pipe",
        "no route to host",
    ]
    return any(marker in text for marker in transient_markers)


def wait_for_guest_ssh_ready(
    vp: VPhoneSession,
    *,
    timeout: float = 20.0,
    interval: float = 2.0,
) -> bool:
    # 中文注释：静默等待 root SSH 可用；不单独打日志，避免破坏“导入头像照片...ok/failed”单行动作日志。
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        try:
            proc = vp.ssh.run("echo vphone_ssh_ready", check=False, timeout=10.0)
            stdout = proc.stdout.decode() if isinstance(proc.stdout, bytes) else str(proc.stdout or "")
            if proc.returncode == 0 and "vphone_ssh_ready" in stdout:
                return True
        except Exception:
            pass

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(max(0.2, interval), remaining))


def import_profile_photo_with_retry(
    vp: VPhoneSession,
    *,
    photo_dir: str | Path,
    album: str,
    attempts: int = 4,
    retry_delay: float = 4.0,
) -> tuple[dict[str, Any], Path]:
    # 中文注释：头像导入底层脚本会连续 SSH 多次；遇到临时认证/连接失败时，重跑整个导入脚本更可靠。
    selected_photo = pick_random_profile_photo(photo_dir)
    last_error = ""
    attempts = max(1, attempts)
    for attempt in range(1, attempts + 1):
        wait_for_guest_ssh_ready(
            vp,
            timeout=20.0 if attempt == 1 else 30.0,
            interval=2.0,
        )
        try:
            resp = vp.photos.import_photo(selected_photo, album=album)
            if bool(resp.get("ok")):
                resp["attempt"] = attempt
                return resp, selected_photo
            last_error = str(resp)
        except Exception as exc:
            last_error = str(exc)
            if not is_transient_ssh_error(last_error) and attempt >= 2:
                raise

        if attempt < attempts:
            time.sleep(retry_delay * attempt)

    raise RuntimeError(f"导入头像照片失败，已重试 {attempts} 次；最后错误：{last_error}")


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
    timeout: float = 30.0,
    interval: float = 0.5,
    exact: bool = False,
    prefer_bottom: bool = False,
) -> dict[str, Any]:
    # 中文注释：等待当前屏幕 OCR 出现指定文本；默认包含匹配且不区分大小写。
    deadline = time.monotonic() + max(0.0, timeout)
    last_error = ""
    last_values: list[str] = []
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
            node = find_ocr_node_by_text(vp, nodes, text, exact=exact, prefer_bottom=prefer_bottom)
            if node:
                return node
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            suffix = f"; {last_error}" if last_error else f"; 当前文本={last_values!r}"
            raise TimeoutError(f"OCR 未找到文本 {text!r}{suffix}")
        time.sleep(min(max(0.1, interval), remaining))


def wait_for_ocr_any_text(
    vp: VPhoneSession,
    texts: list[str],
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    exact: bool = False,
    prefer_bottom: bool = False,
) -> dict[str, Any]:
    # 中文注释：等待多个候选 OCR 文本中的任意一个出现；返回命中的节点。
    deadline = time.monotonic() + max(0.0, timeout)
    last_error = ""
    last_values: list[str] = []
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
            for text in texts:
                node = find_ocr_node_by_text(vp, nodes, text, exact=exact, prefer_bottom=prefer_bottom)
                if node:
                    node["matched_text"] = text
                    return node
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            suffix = f"; {last_error}" if last_error else f"; 当前文本={last_values!r}"
            raise TimeoutError(f"OCR 未找到任意文本 {texts!r}{suffix}")
        time.sleep(min(max(0.1, interval), remaining))


def wait_for_ocr_texts(
    vp: VPhoneSession,
    texts: list[str],
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, dict[str, Any]]:
    # 中文注释：等待同一张 OCR 快照里同时出现多个文本；用于确认页面已经进入指定步骤。
    deadline = time.monotonic() + max(0.0, timeout)
    last_error = ""
    last_values: list[str] = []
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
            matched: dict[str, dict[str, Any]] = {}
            for text in texts:
                # 中文注释：Next 可能被 OCR 识别成 “Next ( um” 这类带噪声文本，所以 Next 必须用包含匹配。
                # 中文注释：为避免误点说明文字里的 next，Next 仍然优先选择屏幕最靠下的匹配节点。
                node = find_ocr_node_by_text(
                    vp,
                    nodes,
                    text,
                    exact=False,
                    prefer_bottom=text.casefold() == "next",
                )
                if node is not None:
                    matched[text] = node
            if len(matched) == len(texts):
                return matched
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            suffix = f"; {last_error}" if last_error else f"; 当前文本={last_values!r}"
            raise TimeoutError(f"OCR 未同时找到文本 {texts!r}{suffix}")
        time.sleep(min(max(0.1, interval), remaining))


def wait_until_ocr_text_absent(
    vp: VPhoneSession,
    text: str,
    *,
    timeout: float = 5.0,
    interval: float = 0.5,
    exact: bool = False,
    prefer_bottom: bool = False,
) -> bool:
    # 中文注释：点击后等待某个 OCR 文本消失，用于避免“tap 接口返回 ok 但页面没响应”的假成功。
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            node = find_ocr_node_by_text(vp, nodes, text, exact=exact, prefer_bottom=prefer_bottom)
            if node is None:
                return True
        except Exception:
            # 中文注释：OCR 临时失败不直接当成功，继续等到超时。
            pass

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(max(0.1, interval), remaining))


def find_ocr_node_by_value_equal(
    nodes: list[dict[str, Any]],
    expected: str,
    *,
    prefer_bottom: bool = False,
) -> dict[str, Any] | None:
    # 中文注释：严格匹配 OCR 文本 value == expected；不做包含匹配，也不做大小写/空格归一化。
    matches = [
        node
        for node in nodes
        if str(node.get("value") or node.get("label") or "").strip() == expected
    ]
    if prefer_bottom:
        matches = sorted(
            matches,
            key=lambda node: float((node.get("center_pixels") or {}).get("y") or 0.0),
            reverse=True,
        )
    return matches[0] if matches else None


def wait_for_ocr_value_equal(
    vp: VPhoneSession,
    expected: str,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    prefer_bottom: bool = False,
) -> dict[str, Any]:
    # 中文注释：等待 OCR 严格识别到 value == expected 的文本；不会匹配包含 expected 的长文本。
    deadline = time.monotonic() + max(0.0, timeout)
    last_values: list[str] = []
    while True:
        nodes = vp.ocr.nodes(timeout=30.0)
        last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
        node = find_ocr_node_by_value_equal(nodes, expected, prefer_bottom=prefer_bottom)
        if node is not None:
            return node

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"OCR 未识别到严格文本 value == {expected!r}; 当前文本={last_values!r}")
        time.sleep(min(max(0.1, interval), remaining))


def wait_until_ocr_value_equal_absent(
    vp: VPhoneSession,
    expected: str,
    *,
    timeout: float = 5.0,
    interval: float = 0.5,
    prefer_bottom: bool = False,
) -> bool:
    # 中文注释：点击后等待严格文本 value == expected 消失；包含 expected 的长文本不会影响判断。
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            node = find_ocr_node_by_value_equal(nodes, expected, prefer_bottom=prefer_bottom)
            if node is None:
                return True
        except Exception:
            pass

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
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


def random_action_delay(min_seconds: float = 1.0, max_seconds: float = 2.0) -> float:
    # 中文注释：业务动作之间统一加入 1~2 秒随机等待，避免连续点击/输入太机械。
    min_seconds, max_seconds = sorted((max(0.0, min_seconds), max(0.0, max_seconds)))
    wait_seconds = random.uniform(min_seconds, max_seconds)
    log_start(f"等待{wait_seconds:.1f}秒")
    time.sleep(wait_seconds)
    log_done(True)
    return wait_seconds


def find_ocr_node_by_text(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    text: str,
    *,
    exact: bool = False,
    prefer_bottom: bool = False,
) -> dict[str, Any] | None:
    # 中文注释：用 vphonekit OCR 的包含匹配逻辑查询文字块；默认不区分大小写。
    matches = vp.ocr.filter_nodes(nodes, text, exact=exact, case_sensitive=False)
    if prefer_bottom:
        matches = sorted(
            matches,
            key=lambda node: float((node.get("center_pixels") or {}).get("y") or 0.0),
            reverse=True,
        )
    return matches[0] if matches else None


def ocr_node_value(node: dict[str, Any] | None) -> str:
    # 中文注释：统一读取 OCR 节点文本，避免 label/value 字段差异。
    if not isinstance(node, dict):
        return ""
    return str(node.get("value") or node.get("label") or "").strip()


def ocr_node_center(node: dict[str, Any] | None) -> tuple[float, float] | None:
    if not isinstance(node, dict):
        return None
    center = node.get("center_pixels")
    if not isinstance(center, dict):
        return None
    return float(center.get("x") or 0.0), float(center.get("y") or 0.0)


def extract_ocr_field_value_below_label(
    nodes: list[dict[str, Any]],
    label: str,
    *,
    max_down: float = 180.0,
) -> str:
    # 中文注释：从表单 OCR 里提取某个输入框的当前值。
    # Instagram 姓名页/用户名页的结构通常是：
    #   Name / Username
    #   <实际 full_name / username>
    # 所以用“指定 label 正下方最近的一行文本”作为字段值。
    label_nodes = [
        node
        for node in nodes
        if ocr_node_value(node).casefold() == label.casefold()
        and ocr_node_center(node) is not None
    ]
    if not label_nodes:
        return ""
    label_nodes.sort(key=lambda node: ocr_node_center(node)[1])  # type: ignore[index]
    label_node = label_nodes[0]
    label_center = ocr_node_center(label_node)
    if label_center is None:
        return ""
    label_x, label_y = label_center

    excluded_exact = {
        "",
        label.casefold(),
        "next",
        "done",
        "skip",
        "allow and continue",
        "create a username for instagram",
        "what's your name?",
    }
    candidates: list[dict[str, Any]] = []
    for node in nodes:
        value = ocr_node_value(node)
        if value.casefold() in excluded_exact:
            continue
        center = ocr_node_center(node)
        if center is None:
            continue
        x, y = center
        if not (label_y < y <= label_y + max_down):
            continue
        # 中文注释：字段值一般和 label 左对齐，避免选到底部按钮或说明文字。
        if abs(x - label_x) > 360.0:
            continue
        if len(value) < 2:
            continue
        candidates.append(node)

    candidates.sort(
        key=lambda node: (
            abs((ocr_node_center(node) or (0.0, 0.0))[1] - label_y),
            abs((ocr_node_center(node) or (0.0, 0.0))[0] - label_x),
        )
    )
    return ocr_node_value(candidates[0]) if candidates else ""


def parse_json_from_text(text: str) -> dict[str, Any]:
    # 中文注释：SSH 输出有时会混入少量非 JSON 文本；优先整体解析，失败后取首尾大括号之间解析。
    raw = text.strip()
    if not raw:
        raise ValueError("远端 instagram_account.json 为空")
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        start = raw.find("{")
        end = raw.rfind("}")
        if start < 0 or end <= start:
            raise
        parsed = json.loads(raw[start : end + 1])
    if not isinstance(parsed, dict):
        raise ValueError("远端 instagram_account.json 不是 JSON object")
    return parsed


def read_instagram_account_json(
    vp: VPhoneSession,
    *,
    path: str = DEFAULT_INSTAGRAM_ACCOUNT_JSON_PATH,
    timeout: float = 10.0,
) -> dict[str, Any]:
    # 中文注释：通过实例 SSH 读取 Instagram hook 写出的账号/session 信息。
    proc = vp.ssh.run(f"cat {shlex.quote(path)}", check=True, timeout=timeout)
    stdout = proc.stdout.decode() if isinstance(proc.stdout, bytes) else str(proc.stdout or "")
    return parse_json_from_text(stdout)


def read_instagram_account_json_with_retry(
    vp: VPhoneSession,
    *,
    path: str = DEFAULT_INSTAGRAM_ACCOUNT_JSON_PATH,
    timeout: float = 60.0,
    interval: float = 3.0,
) -> dict[str, Any]:
    # 中文注释：Allow and continue 后即使头像/引导页处理失败，也要继续等 hook 写出账号 JSON 并上报。
    # 因此这里用重试读取 /tmp/instagram_account.json 作为最终账号创建成功信号之一。
    deadline = time.monotonic() + max(0.0, timeout)
    last_error = ""
    while True:
        try:
            return read_instagram_account_json(
                vp,
                path=path,
                timeout=min(10.0, max(1.0, deadline - time.monotonic())),
            )
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f"等待账号JSON超时: {path}; 最后错误={last_error}")
        time.sleep(min(max(0.2, interval), remaining))


def build_secondary_account_payload(
    account_json: dict[str, Any],
    *,
    email: str,
    password: str,
    proxy: str,
    username: str,
    full_name: str,
) -> dict[str, Any]:
    # 中文注释：以上游 hook JSON 为基础，补齐本流程从 DB/OCR 得到的账号字段和固定业务字段。
    payload = dict(account_json)
    payload.update(
        {
            "email": email,
            "password": password,
            "proxy": proxy,
            "username": username,
            "full_name": full_name,
            "is_allow_following": "1",
            "master_email_id": "0",
            "platform": "52",
            "status": "1",
        }
    )
    return payload


def post_secondary_account_report(
    payload: dict[str, Any],
    *,
    url: str = DEFAULT_SECONDARY_ACCOUNT_REPORT_URL,
    timeout: float = 15.0,
) -> dict[str, Any]:
    # 中文注释：把注册成功的 Instagram 子账号信息上报到业务接口。
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json, text/plain, */*",
        },
    )
    try:
        with urlopen(req, timeout=timeout) as resp:
            resp_body = resp.read().decode("utf-8", errors="replace")
            status = int(getattr(resp, "status", 0) or resp.getcode())
    except HTTPError as exc:
        resp_body = exc.read().decode("utf-8", errors="replace")
        status = int(exc.code)

    parsed_body: Any
    try:
        parsed_body = json.loads(resp_body) if resp_body.strip() else None
    except json.JSONDecodeError:
        parsed_body = resp_body

    return {
        "ok": 200 <= status < 300,
        "status": status,
        "body": parsed_body,
        "url": url,
    }


def report_secondary_account_after_success(
    vp: VPhoneSession,
    *,
    email: str,
    password: str,
    proxy: str,
    username: str,
    full_name: str,
    account_json_path: str = DEFAULT_INSTAGRAM_ACCOUNT_JSON_PATH,
    report_url: str = DEFAULT_SECONDARY_ACCOUNT_REPORT_URL,
) -> dict[str, Any]:
    # 中文注释：创建资料成功后，读取 hook JSON，合并 email/username/full_name 后上报。
    if not email:
        raise ValueError("上报缺少 email")
    if not password:
        raise ValueError("上报缺少 password")
    if not proxy:
        raise ValueError("上报缺少 proxy")
    if not username:
        raise ValueError("上报缺少 username")
    if not full_name:
        raise ValueError("上报缺少 full_name")

    account_json = read_instagram_account_json(vp, path=account_json_path)
    payload = build_secondary_account_payload(
        account_json,
        email=email,
        password=password,
        proxy=proxy,
        username=username,
        full_name=full_name,
    )
    resp = post_secondary_account_report(payload, url=report_url)
    resp["payload"] = payload
    resp["account_json_path"] = account_json_path
    return resp


def instagram_entry_from_ocr_nodes(vp: VPhoneSession, nodes: list[dict[str, Any]]) -> dict[str, Any]:
    # 中文注释：只基于 OCR 识别结果，判断 Instagram 当前入口属于哪个分支。
    login_node = find_ocr_node_by_text(vp, nodes, "Log in")
    create_node = find_ocr_node_by_text(vp, nodes, "Create new account")
    profile_node = find_ocr_node_by_text(vp, nodes, "I already have a profile")
    sign_up_node = find_ocr_node_by_text(vp, nodes, "Sign up")
    continue_without_account_node = find_ocr_node_by_text(vp, nodes, "Continue without an account")
    username_field_node = (
        find_ocr_node_by_text(vp, nodes, "Username")
        or find_ocr_node_by_text(vp, nodes, "Mobile number or email")
    )
    password_field_node = find_ocr_node_by_text(vp, nodes, "Password")
    has_login = login_node is not None
    has_create = create_node is not None
    has_profile = profile_node is not None
    has_sign_up = sign_up_node is not None
    has_continue_without_account = continue_without_account_node is not None
    has_login_form = username_field_node is not None or password_field_node is not None

    if has_profile:
        branch = "already_have_profile"
    elif has_login and (has_continue_without_account or (has_sign_up and not has_login_form)):
        # 中文注释：新版启动页是 Sign up / Continue without an account / Log in；
        # 这里的 Log in 只是进入登录表单的入口按钮，不能直接等待 Username。
        branch = "landing_login"
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
        "has_sign_up": has_sign_up,
        "has_continue_without_account": has_continue_without_account,
        "has_login_form": has_login_form,
        "login_node": login_node,
        "create_node": create_node,
        "profile_node": profile_node,
        "sign_up_node": sign_up_node,
        "continue_without_account_node": continue_without_account_node,
        "username_field_node": username_field_node,
        "password_field_node": password_field_node,
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
    # 分支 1：新版启动页 Sign up / Continue without an account / Log in（后续点击 Log in 进入登录表单）
    # 分支 2：Log in / Create new account 或已经在登录表单
    # 分支 3：I already have a profile（独立分支，出现后后续会点击）
    # 任意入口出现就结束等待，最多等待 timeout 秒。
    deadline = time.monotonic() + max(0.0, timeout)
    last_resp: dict[str, Any] = {
        "ok": False,
        "branch": "not_found",
        "has_login": False,
        "has_create_new_account": False,
        "has_already_have_profile": False,
        "has_sign_up": False,
        "has_continue_without_account": False,
        "has_login_form": False,
        "login_node": None,
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


def after_login_state_from_ocr_nodes(vp: VPhoneSession, nodes: list[dict[str, Any]]) -> dict[str, Any]:
    # 中文注释：点击 Log in 后只用同一张 OCR 快照判断页面状态。
    # 状态 1：看到 Meta Horizon，后续直接点击 Meta Horizon。
    # 状态 2：同一屏同时看到 Sign up 和 Try again，说明登录失败，后续点击 Try again 再重按 Log in。
    # 状态 3：弹窗 Unable to log in / OK，也是临时登录失败，点 OK 后再重按 Log in。
    meta_horizon_node = find_ocr_node_by_text(vp, nodes, "Meta Horizon")
    sign_up_node = find_ocr_node_by_text(vp, nodes, "Sign up")
    try_again_node = find_ocr_node_by_text(vp, nodes, "Try again")
    unable_login_node = find_ocr_node_by_text(vp, nodes, "Unable to log in")
    unexpected_error_node = find_ocr_node_by_text(vp, nodes, "An unexpected error occurred")
    ok_node = find_bottom_value_equal_node(nodes, "OK")

    if meta_horizon_node is not None:
        state = "meta_horizon"
    elif sign_up_node is not None and try_again_node is not None:
        state = "sign_up_try_again"
    elif (unable_login_node is not None or unexpected_error_node is not None) and ok_node is not None:
        state = "unable_login_ok"
    else:
        state = "unknown"

    return {
        "ok": state != "unknown",
        "state": state,
        "has_meta_horizon": meta_horizon_node is not None,
        "has_sign_up": sign_up_node is not None,
        "has_try_again": try_again_node is not None,
        "has_unable_login": unable_login_node is not None,
        "has_unexpected_error": unexpected_error_node is not None,
        "has_ok": ok_node is not None,
        "meta_horizon_node": meta_horizon_node,
        "sign_up_node": sign_up_node,
        "try_again_node": try_again_node,
        "unable_login_node": unable_login_node,
        "unexpected_error_node": unexpected_error_node,
        "ok_node": ok_node,
        "node_count": len(nodes),
        "nodes": nodes,
        "source": "ocr",
    }


def wait_for_after_login_state(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：等待登录后的关键状态出现：Meta Horizon、Sign up + Try again、Unable to log in + OK。
    deadline = time.monotonic() + max(0.0, timeout)
    last_resp: dict[str, Any] = {
        "ok": False,
        "state": "unknown",
        "has_meta_horizon": False,
        "has_sign_up": False,
        "has_try_again": False,
        "has_unable_login": False,
        "has_unexpected_error": False,
        "has_ok": False,
        "node_count": 0,
        "source": "ocr",
    }
    last_error = ""

    while True:
        try:
            ocr_nodes = vp.ocr.nodes(timeout=30.0)
            last_resp = after_login_state_from_ocr_nodes(vp, ocr_nodes)
            if last_resp.get("ok"):
                break
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(max(0.1, interval), remaining))

    last_resp["error"] = last_error
    return last_resp


def click_login_button(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：通过 OCR 找到 Log in 并点击；初次登录和 Try again 后重试都复用这个动作。
    login_node = wait_for_ocr_text(vp, "log in", timeout=timeout, interval=interval)
    return vp.ocr.tap(login_node, screen=screen, delay=500)


def click_ocr_node_with_delay(
    vp: VPhoneSession,
    node: dict[str, Any],
    *,
    action_name: str,
    screen: bool = False,
) -> bool:
    # 中文注释：通用点击动作：点击前统一等待 1~2 秒，并输出“动作...ok/failed”单行日志。
    random_action_delay()
    log_start(action_name)
    try:
        resp = vp.ocr.tap(node, screen=screen, delay=500)
        ok = bool(resp.get("ok"))
    except Exception:
        log_done(False)
        raise
    log_done(ok)
    return ok


def find_name_page_title_node(vp: VPhoneSession, nodes: list[dict[str, Any]]) -> dict[str, Any] | None:
    # 中文注释：姓名页标题 OCR 偶尔漏掉问号，所以用更宽松的标题匹配。
    return (
        find_ocr_node_by_text(vp, nodes, "What's your name?")
        or find_ocr_node_by_text(vp, nodes, "What's your name")
    )


def page_has_name_step(vp: VPhoneSession) -> bool:
    # 中文注释：判断是否已经进入姓名页；只做一次 OCR 快照，不输出日志。
    try:
        nodes = vp.ocr.nodes(timeout=30.0)
    except Exception:
        return False
    if find_name_page_title_node(vp, nodes) is not None:
        return True
    return (
        find_ocr_node_by_value_equal(nodes, "Name") is not None
        and find_ocr_node_by_text(vp, nodes, "Next", exact=False, prefer_bottom=True) is not None
    )


def page_has_meta_horizon(vp: VPhoneSession) -> bool:
    # 中文注释：点击账号 row 后用来判断是否还停留在 Meta Horizon 账号选择页。
    try:
        nodes = vp.ocr.nodes(timeout=30.0)
    except Exception:
        return False
    return find_ocr_node_by_text(vp, nodes, "Meta Horizon") is not None


def wait_for_name_step_quiet(
    vp: VPhoneSession,
    *,
    timeout: float = 4.0,
    interval: float = 0.5,
) -> bool:
    # 中文注释：点击 Meta Horizon 后静默等待姓名页出现，用来确认点击真的生效。
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        if page_has_name_step(vp):
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(max(0.1, interval), remaining))


def meta_horizon_row_candidates(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    meta_horizon_node: dict[str, Any],
) -> list[dict[str, Any]]:
    # 中文注释：Meta Horizon 登录后页面是一个账号选择 row。
    # 直接点 “Meta Horizon” 副标题有时不会触发行点击，所以优先点账号 row 的中间/右侧坐标，再点箭头/账号名/副标题。
    candidates: list[dict[str, Any]] = []

    meta_center = meta_horizon_node.get("center_pixels") if isinstance(meta_horizon_node, dict) else None
    meta_x = float((meta_center or {}).get("x") or 0.0)
    meta_y = float((meta_center or {}).get("y") or 0.0)
    width, _height = ocr_nodes_extent(nodes)

    # 中文注释：先找 Meta Horizon 上方、同一账号 row 内的主标题，比如 “Ashlynn Wilson”，用于推导整行垂直中心。
    account_title_candidates: list[dict[str, Any]] = []
    for node in nodes:
        value = str(node.get("value") or node.get("label") or "").strip()
        center = node.get("center_pixels")
        if not value or not isinstance(center, dict):
            continue
        node_y = float(center.get("y") or 0.0)
        if not (0 < meta_y - node_y <= 120.0):
            continue
        if value in {"A", "OR", "Find account", "No Instagram account found", "Meta Horizon"}:
            continue
        if len(value) < 3:
            continue
        account_title_candidates.append(node)
    account_title_candidates.sort(key=lambda node: float((node.get("center_pixels") or {}).get("y") or 0.0), reverse=True)

    row_y = meta_y
    title_center = ocr_node_center(account_title_candidates[0]) if account_title_candidates else None
    if title_center is not None:
        row_y = (title_center[1] + meta_y) / 2.0

    # 中文注释：优先直接点账号 row 中心/右侧。用 screen.tap 发像素坐标，避免 OCR tap 点到副标题文字本身。
    if row_y > 0:
        candidates.append(synthetic_ocr_node("Meta Horizon row center", width * 0.50, row_y))
        candidates.append(synthetic_ocr_node("Meta Horizon row right", width * 0.88, row_y))
        if meta_x > 0:
            candidates.append(synthetic_ocr_node("Meta Horizon row text center", meta_x, row_y))

    # 中文注释：优先找同一行的右侧 chevron “>”；排除左上返回箭头，因为它通常不在 Meta Horizon 行附近。
    chevrons = vp.ocr.filter_nodes(nodes, ">", exact=True, case_sensitive=False)
    chevrons = sorted(
        [
            node
            for node in chevrons
            if abs(float((node.get("center_pixels") or {}).get("y") or 0.0) - meta_y) <= 160.0
        ],
        key=lambda node: float((node.get("center_pixels") or {}).get("x") or 0.0),
        reverse=True,
    )
    candidates.extend(chevrons)

    candidates.extend(account_title_candidates)

    # 中文注释：最后兜底点 Meta Horizon 文本本身。
    candidates.append(meta_horizon_node)

    # 中文注释：去重，避免同一坐标重复点击。
    unique: list[dict[str, Any]] = []
    seen: set[tuple[int, int]] = set()
    for node in candidates:
        center = node.get("center_pixels")
        if not isinstance(center, dict):
            continue
        key = (round(float(center.get("x") or 0.0)), round(float(center.get("y") or 0.0)))
        if key in seen:
            continue
        seen.add(key)
        unique.append(node)
    return unique


def tap_meta_horizon_candidate(
    vp: VPhoneSession,
    node: dict[str, Any],
    *,
    screen: bool = False,
) -> bool:
    # 中文注释：Meta Horizon row 点击统一走 screen.tap，确保点击的是候选中心坐标，而不是 OCR 文本边界。
    center = ocr_node_center(node)
    if center is None:
        return False
    x, y = center
    resp = vp.screen.tap(x, y, screen=screen, delay=500)
    return bool(resp.get("ok"))


def extract_meta_horizon_full_name(
    nodes: list[dict[str, Any]],
    meta_horizon_node: dict[str, Any],
) -> str:
    # 中文注释：Meta Horizon 账号选择页里，“Meta Horizon”上一行通常就是账号 full_name。
    meta_center = ocr_node_center(meta_horizon_node)
    if meta_center is None:
        return ""
    _meta_x, meta_y = meta_center
    ignored = {"A", "OR", "Find account", "No Instagram account found", "Meta Horizon"}
    candidates: list[dict[str, Any]] = []
    for node in nodes:
        value = ocr_node_value(node)
        if value in ignored or len(value) < 3:
            continue
        center = ocr_node_center(node)
        if center is None:
            continue
        _x, y = center
        if 0 < meta_y - y <= 140.0:
            candidates.append(node)
    candidates.sort(key=lambda node: ocr_node_center(node)[1], reverse=True)  # type: ignore[index]
    return ocr_node_value(candidates[0]) if candidates else ""


def tap_meta_horizon_and_confirm(
    vp: VPhoneSession,
    state_resp: dict[str, Any],
    *,
    interval: float = 0.5,
    screen: bool = False,
) -> bool:
    # 中文注释：点击 Meta Horizon 账号 row，并用“姓名页出现”确认点击真的生效。
    if page_has_name_step(vp):
        return True

    meta_horizon_node = state_resp.get("meta_horizon_node")
    if not isinstance(meta_horizon_node, dict):
        raise LookupError("Meta Horizon 缺少 OCR 坐标")

    current_state = state_resp
    for _attempt in range(2):
        nodes = current_state.get("nodes")
        current_meta_node = current_state.get("meta_horizon_node")
        if not isinstance(current_meta_node, dict):
            current_meta_node = meta_horizon_node
        if not isinstance(nodes, list):
            nodes = [current_meta_node]

        for node in meta_horizon_row_candidates(vp, nodes, current_meta_node):
            if not tap_meta_horizon_candidate(vp, node, screen=screen):
                continue
            if wait_for_name_step_quiet(vp, timeout=3.0, interval=interval):
                return True
            # 中文注释：如果 Meta Horizon 已经消失，说明点击已触发页面跳转/加载；给姓名页更长时间出现。
            if not page_has_meta_horizon(vp):
                if wait_for_name_step_quiet(vp, timeout=10.0, interval=interval):
                    return True
                try:
                    refreshed_nodes = vp.ocr.nodes(timeout=30.0)
                    refreshed_state = after_login_state_from_ocr_nodes(vp, refreshed_nodes)
                except Exception:
                    return False
                if refreshed_state.get("state") == "meta_horizon":
                    current_state = refreshed_state
                    break
                return False

        if wait_for_name_step_quiet(vp, timeout=2.0, interval=interval):
            return True

        try:
            refreshed_nodes = vp.ocr.nodes(timeout=30.0)
            refreshed_state = after_login_state_from_ocr_nodes(vp, refreshed_nodes)
        except Exception:
            break
        if refreshed_state.get("state") != "meta_horizon":
            return wait_for_name_step_quiet(vp, timeout=8.0, interval=interval)
        current_state = refreshed_state

    return False


def synthetic_ocr_node(label: str, x: float, y: float) -> dict[str, Any]:
    # 中文注释：当 OCR 漏识别按钮文字时，基于当前页面已识别元素推导一个可点击的虚拟 OCR 节点。
    return {
        "label": label,
        "value": label,
        "role": "ocr_text",
        "source": "ocr_fallback",
        "confidence": 0.0,
        "center_pixels": {"x": x, "y": y},
        "frame_pixels": {"x": x, "y": y, "width": 0.0, "height": 0.0, "max_x": x, "max_y": y},
    }


def ocr_nodes_extent(nodes: list[dict[str, Any]]) -> tuple[float, float]:
    # 中文注释：从当前 OCR 节点估算屏幕宽高；没有完整截图尺寸时按当前实例常用分辨率兜底。
    width = 1290.0
    height = 2796.0
    for node in nodes:
        frame = node.get("frame_pixels")
        if isinstance(frame, dict):
            width = max(width, float(frame.get("max_x") or 0.0))
            height = max(height, float(frame.get("max_y") or 0.0))
        center = node.get("center_pixels")
        if isinstance(center, dict):
            width = max(width, float(center.get("x") or 0.0))
            height = max(height, float(center.get("y") or 0.0))
    return width, height


def find_exact_ocr_value_node(nodes: list[dict[str, Any]], value: str) -> dict[str, Any] | None:
    matches = [
        node
        for node in nodes
        if ocr_node_value(node).casefold() == value.casefold()
        and ocr_node_center(node) is not None
    ]
    matches.sort(key=lambda node: ocr_node_center(node)[1])  # type: ignore[index]
    return matches[0] if matches else None


def form_page_blank_points_from_state(
    form_state: dict[str, Any],
    *,
    field_label: str,
) -> list[tuple[float, float]]:
    # 中文注释：表单页点击“标题和输入框 label 中间”的真空白区域，比点标题上方更容易让输入框失焦。
    nodes = form_state.get("nodes")
    if not isinstance(nodes, list):
        nodes = []
    width, height = ocr_nodes_extent(nodes)

    title_y = height * 0.18
    title_node = form_state.get("title_node")
    title_center = ocr_node_center(title_node if isinstance(title_node, dict) else None)
    if title_center is not None:
        title_y = title_center[1]

    label_y = 0.0
    label_node = find_exact_ocr_value_node(nodes, field_label)
    label_center = ocr_node_center(label_node)
    if label_center is not None:
        label_y = label_center[1]

    if label_y > title_y + 120.0:
        blank_y = title_y + (label_y - title_y) * 0.52
    else:
        blank_y = title_y + 180.0
    blank_y = max(360.0, min(blank_y, height * 0.42))

    # 中文注释：同一个动作里点两个横向位置，避免中间区域被透明输入层/插图覆盖导致没有失焦。
    return [
        (width * 0.50, blank_y),
        (width * 0.18, blank_y),
    ]


def click_form_blank_with_delay(
    vp: VPhoneSession,
    form_state: dict[str, Any],
    *,
    field_label: str,
    action_name: str,
    screen: bool = False,
) -> bool:
    # 中文注释：直接按坐标点击空白处，不依赖 synthetic OCR tap，确保真的发出屏幕点击事件。
    random_action_delay()
    log_start(action_name)
    try:
        ok = True
        for index, (x, y) in enumerate(form_page_blank_points_from_state(form_state, field_label=field_label)):
            resp = vp.screen.tap(x, y, screen=screen, delay=300)
            ok = ok and bool(resp.get("ok"))
            if index == 0:
                time.sleep(0.2)
    except Exception:
        log_done(False)
        raise
    log_done(ok)
    return ok


def click_name_page_next(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> bool:
    return bool(
        click_name_page_next_with_info(
            vp,
            timeout=timeout,
            interval=interval,
            screen=screen,
        ).get("ok")
    )


def wait_for_name_page_state(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：等待姓名页，同时保留 OCR 节点，用来提取 full_name。
    deadline = time.monotonic() + max(0.0, timeout)
    last_error = ""
    last_values: list[str] = []
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            last_values = [ocr_node_value(node) for node in nodes]
            title_node = find_name_page_title_node(vp, nodes)
            next_node = find_ocr_node_by_text(vp, nodes, "Next", exact=False, prefer_bottom=True)
            if title_node is not None and next_node is not None:
                return {
                    "ok": True,
                    "nodes": nodes,
                    "title_node": title_node,
                    "next_node": next_node,
                    "full_name": extract_ocr_field_value_below_label(nodes, "Name"),
                    "last_values": last_values,
                    "error": "",
                }
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            suffix = f"; {last_error}" if last_error else f"; 当前文本={last_values!r}"
            raise TimeoutError(f"OCR 未同时找到文本 [\"What's your name?\", 'Next']{suffix}")
        time.sleep(min(max(0.1, interval), remaining))


def click_name_page_next_with_info(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：等待姓名页后，先点空白处取消输入框聚焦，再重新 OCR 提取 full_name，然后点击 Next。
    log_start("等待姓名页面")
    try:
        name_state = wait_for_name_page_state(
            vp,
            timeout=timeout,
            interval=interval,
        )
    except Exception:
        log_done(False)
        raise
    log_done(True)

    blank_clicked = click_form_blank_with_delay(
        vp,
        name_state,
        field_label="Name",
        action_name="点击姓名页空白处",
        screen=screen,
    )
    name_state["blank_clicked"] = blank_clicked
    if not blank_clicked:
        name_state["clicked"] = False
        name_state["ok"] = False
        name_state["error"] = "点击姓名页空白处失败"
        return name_state

    time.sleep(0.5)
    log_start("刷新姓名OCR")
    try:
        name_state = wait_for_name_page_state(
            vp,
            timeout=timeout,
            interval=interval,
        )
    except Exception:
        log_done(False)
        raise
    log_done(True)
    name_state["blank_clicked"] = blank_clicked

    clicked = click_ocr_node_with_delay(
        vp,
        name_state["next_node"],
        action_name="点击姓名页Next",
        screen=screen,
    )
    name_state["clicked"] = clicked
    name_state["ok"] = clicked
    return name_state


def wait_for_username_page_next_node(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：用户名页的蓝色 Next 按钮是白字蓝底，macOS Vision 偶尔完全漏识别。
    # 所以这里先等待用户名页标题；如果同屏 OCR 能识别 Next，就点 Next；
    # 如果只识别到标题/输入框/建议用户名，则按这些元素的坐标推导蓝色按钮中心点。
    deadline = time.monotonic() + max(0.0, timeout)
    last_values: list[str] = []
    while True:
        nodes = vp.ocr.nodes(timeout=30.0)
        last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
        title_node = find_ocr_node_by_text(vp, nodes, "Create a username for Instagram")
        if title_node is not None:
            next_node = find_ocr_node_by_text(vp, nodes, "Next", exact=False, prefer_bottom=True)
            if next_node is not None:
                return next_node

            # 中文注释：Next 没被 OCR 输出时，使用用户名输入框下方约 200px 的蓝色按钮中心。
            # 这个坐标不是硬编码屏幕坐标，而是从当前 OCR 已识别的页面元素动态推导：
            # x 取当前页面文字区域的中线；y 取最靠下文本块底部再向下偏移到按钮中线。
            max_x = 0.0
            max_y = 0.0
            for node in nodes:
                frame = node.get("frame_pixels")
                if not isinstance(frame, dict):
                    continue
                max_x = max(max_x, float(frame.get("max_x") or 0.0))
                max_y = max(max_y, float(frame.get("max_y") or 0.0))

            if max_x > 0 and max_y > 0:
                return synthetic_ocr_node("Next", max_x / 2.0, max_y + 200.0)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                "OCR 未找到用户名页 Next；"
                f"当前文本={last_values!r}"
            )
        time.sleep(min(max(0.1, interval), remaining))


def click_username_page_next(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> bool:
    return bool(
        click_username_page_next_with_info(
            vp,
            timeout=timeout,
            interval=interval,
            screen=screen,
        ).get("ok")
    )


def username_page_next_node_from_nodes(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> dict[str, Any] | None:
    # 中文注释：用户名页 Next 可能被 OCR 漏掉；先找 OCR 文本，找不到再根据当前页面元素动态推导按钮中心。
    next_node = find_ocr_node_by_text(vp, nodes, "Next", exact=False, prefer_bottom=True)
    if next_node is not None:
        return next_node

    max_x = 0.0
    max_y = 0.0
    for node in nodes:
        frame = node.get("frame_pixels")
        if not isinstance(frame, dict):
            continue
        max_x = max(max_x, float(frame.get("max_x") or 0.0))
        max_y = max(max_y, float(frame.get("max_y") or 0.0))

    if max_x > 0 and max_y > 0:
        return synthetic_ocr_node("Next", max_x / 2.0, max_y + 200.0)
    return None


def wait_for_username_page_state(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：等待用户名页，同时保留 OCR 节点，用来提取 username。
    deadline = time.monotonic() + max(0.0, timeout)
    last_values: list[str] = []
    while True:
        nodes = vp.ocr.nodes(timeout=30.0)
        last_values = [ocr_node_value(node) for node in nodes]
        title_node = find_ocr_node_by_text(vp, nodes, "Create a username for Instagram")
        if title_node is not None:
            next_node = username_page_next_node_from_nodes(vp, nodes)
            if next_node is not None:
                username = extract_ocr_field_value_below_label(nodes, "Username")
                return {
                    "ok": True,
                    "nodes": nodes,
                    "title_node": title_node,
                    "next_node": next_node,
                    "username": username,
                    "last_values": last_values,
                    "error": "",
                }

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                "OCR 未找到用户名页 Next；"
                f"当前文本={last_values!r}"
            )
        time.sleep(min(max(0.1, interval), remaining))


def click_username_page_next_with_info(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：等待用户名页后，先点空白处取消输入框聚焦，再重新 OCR 提取 username，避免把光标识别进用户名。
    log_start("等待用户名页面")
    try:
        username_state = wait_for_username_page_state(
            vp,
            timeout=timeout,
            interval=interval,
        )
    except Exception:
        log_done(False)
        raise
    log_done(True)

    blank_clicked = click_form_blank_with_delay(
        vp,
        username_state,
        field_label="Username",
        action_name="点击用户名页空白处",
        screen=screen,
    )
    username_state["blank_clicked"] = blank_clicked
    if not blank_clicked:
        username_state["clicked"] = False
        username_state["ok"] = False
        username_state["error"] = "点击用户名页空白处失败"
        return username_state

    time.sleep(0.5)
    log_start("刷新用户名OCR")
    try:
        username_state = wait_for_username_page_state(
            vp,
            timeout=timeout,
            interval=interval,
        )
    except Exception:
        log_done(False)
        raise
    log_done(True)
    username_state["blank_clicked"] = blank_clicked

    clicked = click_ocr_node_with_delay(
        vp,
        username_state["next_node"],
        action_name="点击用户名页Next",
        screen=screen,
    )
    username_state["clicked"] = clicked
    username_state["ok"] = clicked
    return username_state


def click_allow_and_continue(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> bool:
    # 中文注释：等待严格文本 value == “Allow and continue” 出现，然后点击 Allow and continue。
    log_start("等待Allow and continue")
    try:
        allow_node = wait_for_ocr_value_equal(
            vp,
            "Allow and continue",
            timeout=timeout,
            interval=interval,
            prefer_bottom=True,
        )
    except Exception:
        log_done(False)
        raise
    log_done(True)

    # 中文注释：Allow and continue 页面可能存在“包含 Allow and continue 的长文本”和底部按钮；
    # 这里严格选择 value == Allow and continue 的节点，点击后也只用严格相等判断按钮是否消失。
    random_action_delay()
    log_start("点击Allow and continue")
    try:
        allow_resp = vp.ocr.tap(allow_node, screen=screen, delay=500)
        allow_ok = bool(allow_resp.get("ok"))

        if allow_ok and not wait_until_ocr_value_equal_absent(
            vp,
            "Allow and continue",
            timeout=5.0,
            interval=interval,
            prefer_bottom=True,
        ):
            # 中文注释：如果按钮还在，说明大概率只点到了文字/坐标偏上；向下偏移一点重试一次。
            x, y = vp.ocr.center_pixels(allow_node)
            retry_resp = vp.screen.tap(x, y + 24.0, screen=screen, delay=500)
            allow_ok = bool(retry_resp.get("ok")) and wait_until_ocr_value_equal_absent(
                vp,
                "Allow and continue",
                timeout=5.0,
                interval=interval,
                prefer_bottom=True,
            )
    except Exception:
        log_done(False)
        raise
    log_done(allow_ok)
    return allow_ok


def ocr_snapshot_nodes(vp: VPhoneSession) -> tuple[list[dict[str, Any]], int, int]:
    # 中文注释：获取一次 OCR 快照，同时保留截图宽高；头像这类非文字区域需要用宽高推导点击点。
    resp = vp.ocr.snapshot(timeout=30.0)
    nodes = vp.ocr._nodes_from_response(resp)
    return nodes, int(resp.get("width") or 0), int(resp.get("height") or 0)


def find_top_right_value_equal_node(
    nodes: list[dict[str, Any]],
    expected: str,
    *,
    width: int = 0,
    max_y: float = 420.0,
) -> dict[str, Any] | None:
    # 中文注释：查右上角按钮，例如可选权限页的 Skip；严格 value == expected，避免匹配说明文字里的 skip。
    min_x = float(width) * 0.60 if width > 0 else 0.0
    matches: list[dict[str, Any]] = []
    for node in nodes:
        if ocr_node_value(node) != expected:
            continue
        center = ocr_node_center(node)
        if center is None:
            continue
        x, y = center
        if y <= max_y and x >= min_x:
            matches.append(node)
    matches.sort(key=lambda node: (ocr_node_center(node)[1], -ocr_node_center(node)[0]))  # type: ignore[index]
    return matches[0] if matches else None


def find_bottom_value_equal_node(
    nodes: list[dict[str, Any]],
    expected: str,
) -> dict[str, Any] | None:
    # 中文注释：查严格文本 value == expected 的最靠下节点；用于确认弹窗里的 Skip。
    matches = [node for node in nodes if ocr_node_value(node) == expected and ocr_node_center(node) is not None]
    matches.sort(key=lambda node: ocr_node_center(node)[1], reverse=True)  # type: ignore[index]
    return matches[0] if matches else None


def find_skip_confirm_node(vp: VPhoneSession, nodes: list[dict[str, Any]]) -> dict[str, Any] | None:
    # 中文注释：统一识别“确认跳过”弹窗；弹窗出现时点击弹窗里靠下的 Skip，而不是右上角 Skip。
    has_confirm_popup = (
        find_ocr_node_by_text(vp, nodes, "skip this step") is not None
        or find_ocr_node_by_text(vp, nodes, "Are you sure you want to") is not None
        or find_ocr_node_by_value_equal(nodes, "Find friends") is not None
    )
    if not has_confirm_popup:
        return None
    return find_bottom_value_equal_node(nodes, "Skip")


RECOMMENDED_FOLLOW_PAGE_TEXTS = [
    "Try following 5+ people",
    "Follow 5 or more people",
    "Follow 5 or more",
]


def find_recommended_follow_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：推荐关注页有多种标题：旧版 Try following 5+ people，新版 Follow 5 or more people。
    for text in RECOMMENDED_FOLLOW_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node
    return None


def find_recommended_follow_action_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：推荐关注页底部按钮有时是 Follow，有时是 Next；优先 Follow，找不到再点 Next。
    for value in ("Follow", "Next"):
        node = find_bottom_value_equal_node(nodes, value)
        if node is not None:
            return node
    return synthetic_ocr_node(
        "Next",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.91,
    )


def find_pick_interests_action_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：兴趣选择页底部是 Done；OCR 漏掉时用屏幕底部中间坐标兜底。
    node = find_bottom_value_equal_node(nodes, "Done")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "Done",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.924,
    )


FREE_WITH_ADS_CHOICE_PAGE_TEXTS = [
    "Want to subscribe or continue using our products free of charge with ads?",
    "Want to subscribe or continue using our products",
    "continue using our products free of charge with ads",
    "Use free of charge with ads",
    "Subscribe to use without ads",
]

FREE_WITH_ADS_AGREE_PAGE_TEXTS = [
    "To use our products free of charge with ads",
    "agree to Meta processing your data",
    "Meta processing your data",
    "processing your data for the following",
]

AD_EXPERIENCE_MANAGE_PAGE_TEXTS = [
    "You can manage your ad experience",
    "manage your ad experience",
]

FREE_WITH_ADS_ACTION_STATES = {
    "free_with_ads_choice",
    "free_with_ads_agree",
    "ad_experience_manage",
}


def find_free_with_ads_choice_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别“免费含广告继续使用”选择页；该页需要先选 Use free... 再点 Continue。
    for text in FREE_WITH_ADS_CHOICE_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node

    # 中文注释：OCR 有时把标题/选项拆成多行；同时出现 Use free 与 Subscribe 才判定为选择页。
    use_node = (
        find_ocr_node_by_text(vp, nodes, "Use free of charge")
        or find_ocr_node_by_text(vp, nodes, "free of charge with ads")
    )
    subscribe_node = find_ocr_node_by_text(vp, nodes, "Subscribe to use without ads")
    if use_node is not None and subscribe_node is not None:
        return "Use free of charge with ads", use_node
    return None


def find_free_with_ads_agree_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别“同意 Meta 处理广告数据”页；底部按钮是 Agree。
    for text in FREE_WITH_ADS_AGREE_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node

    agree_node = find_bottom_value_equal_node(nodes, "Agree")
    processing_node = (
        find_ocr_node_by_text(vp, nodes, "Meta processing")
        or find_ocr_node_by_text(vp, nodes, "processing your data")
    )
    if agree_node is not None and processing_node is not None:
        return "Agree", agree_node
    return None


def find_ad_experience_manage_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别“可以管理广告体验”确认页；底部按钮是 OK。
    for text in AD_EXPERIENCE_MANAGE_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node
    return None


def find_free_with_ads_use_node(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：优先点击 Use free of charge with ads 选项文本；OCR 漏识别时根据同页按钮/选项位置兜底。
    for text in ("Use free of charge with ads", "Use free of charge"):
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return node

    subscribe_node = find_ocr_node_by_text(vp, nodes, "Subscribe to use without ads")
    subscribe_center = ocr_node_center(subscribe_node)
    if subscribe_center is not None:
        x, y = subscribe_center
        return synthetic_ocr_node(
            "Use free of charge with ads",
            x,
            max(float(height or 2796) * 0.38, y - float(height or 2796) * 0.12),
        )

    continue_node = find_bottom_value_equal_node(nodes, "Continue")
    continue_center = ocr_node_center(continue_node)
    if continue_center is not None:
        x, y = continue_center
        return synthetic_ocr_node(
            "Use free of charge with ads",
            x,
            max(float(height or 2796) * 0.45, y - float(height or 2796) * 0.30),
        )

    return synthetic_ocr_node(
        "Use free of charge with ads",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.60,
    )


def find_free_with_ads_continue_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：选择免费含广告后点击底部 Continue；OCR 漏掉时合成底部按钮中心。
    node = find_bottom_value_equal_node(nodes, "Continue")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "Continue",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.923,
    )


def find_free_with_ads_agree_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：广告数据同意页底部按钮是 Agree。
    node = find_bottom_value_equal_node(nodes, "Agree")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "Agree",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.923,
    )


def find_ad_experience_ok_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：广告体验管理说明页底部按钮是 OK。
    node = find_bottom_value_equal_node(nodes, "OK")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "OK",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.923,
    )


def find_free_with_ads_action(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any] | None:
    # 中文注释：返回免费含广告链路中的下一步动作：
    # 1. 选择页：Use free of charge with ads -> Continue；
    # 2. 同意页：Agree；
    # 3. 管理提示页：OK。
    choice_anchor = find_free_with_ads_choice_page_anchor(vp, nodes)
    if choice_anchor is not None:
        matched_text, _ = choice_anchor
        use_node = find_free_with_ads_use_node(vp, nodes, width=width, height=height)
        continue_node = find_free_with_ads_continue_node(nodes, width=width, height=height)
        return {
            "state": "free_with_ads_choice",
            "matched_text": matched_text,
            "select_node": use_node,
            "use_node": use_node,
            "continue_node": continue_node,
            "action_node": continue_node,
        }

    agree_anchor = find_free_with_ads_agree_page_anchor(vp, nodes)
    if agree_anchor is not None:
        matched_text, _ = agree_anchor
        return {
            "state": "free_with_ads_agree",
            "matched_text": matched_text,
            "action_node": find_free_with_ads_agree_node(nodes, width=width, height=height),
        }

    manage_anchor = find_ad_experience_manage_page_anchor(vp, nodes)
    if manage_anchor is not None:
        matched_text, _ = manage_anchor
        return {
            "state": "ad_experience_manage",
            "matched_text": matched_text,
            "action_node": find_ad_experience_ok_node(nodes, width=width, height=height),
        }

    return None


def click_free_with_ads_action(
    vp: VPhoneSession,
    action: dict[str, Any],
    *,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：执行免费含广告链路动作。选择页必须先点 Use free...，再点 Continue。
    state = str(action.get("state") or "")
    result: dict[str, Any] = {
        "ok": False,
        "state": state,
        "free_with_ads_choice": False,
        "free_with_ads_use_clicked": False,
        "free_with_ads_continue_clicked": False,
        "free_with_ads_agree": False,
        "free_with_ads_agree_clicked": False,
        "ad_experience_manage": False,
        "ad_experience_ok_clicked": False,
        "error": "",
    }

    if state == "free_with_ads_choice":
        use_node = action.get("use_node") or action.get("select_node")
        continue_node = action.get("continue_node") or action.get("action_node")
        if not isinstance(use_node, dict):
            result["error"] = "免费含广告选择页缺少 Use free OCR 坐标"
            return result
        if not isinstance(continue_node, dict):
            result["error"] = "免费含广告选择页缺少 Continue OCR 坐标"
            return result

        result["free_with_ads_choice"] = True
        use_clicked = click_ocr_node_with_delay(
            vp,
            use_node,
            action_name="点击免费含广告选项",
            screen=screen,
        )
        result["free_with_ads_use_clicked"] = use_clicked
        if not use_clicked:
            result["error"] = "点击 Use free of charge with ads 失败"
            return result

        continue_clicked = click_ocr_node_with_delay(
            vp,
            continue_node,
            action_name="点击免费含广告Continue",
            screen=screen,
        )
        result["free_with_ads_continue_clicked"] = continue_clicked
        result["ok"] = use_clicked and continue_clicked
        if not continue_clicked:
            result["error"] = "点击 Continue 失败"
        return result

    if state == "free_with_ads_agree":
        action_node = action.get("action_node")
        if not isinstance(action_node, dict):
            result["error"] = "免费含广告同意页缺少 Agree OCR 坐标"
            return result
        result["free_with_ads_agree"] = True
        agree_clicked = click_ocr_node_with_delay(
            vp,
            action_node,
            action_name="点击免费含广告Agree",
            screen=screen,
        )
        result["free_with_ads_agree_clicked"] = agree_clicked
        result["ok"] = agree_clicked
        if not agree_clicked:
            result["error"] = "点击 Agree 失败"
        return result

    if state == "ad_experience_manage":
        action_node = action.get("action_node")
        if not isinstance(action_node, dict):
            result["error"] = "广告体验管理页缺少 OK OCR 坐标"
            return result
        result["ad_experience_manage"] = True
        ok_clicked = click_ocr_node_with_delay(
            vp,
            action_node,
            action_name="点击广告体验OK",
            screen=screen,
        )
        result["ad_experience_ok_clicked"] = ok_clicked
        result["ok"] = ok_clicked
        if not ok_clicked:
            result["error"] = "点击 OK 失败"
        return result

    result["error"] = f"未知免费含广告状态: {state}"
    return result




ADS_DATA_CONSENT_DIALOG_TEXTS = [
    "Choose if we process your data for ads",
    "process your data for ads",
    "personalized ads on Meta Company Products",
]


def find_ads_data_consent_dialog_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别“Choose if we process your data for ads”弹窗；需要点击 Get started 继续。
    for text in ADS_DATA_CONSENT_DIALOG_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node
    return None


def find_ads_data_get_started_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：弹窗底部按钮是 Get started；OCR 漏掉时按弹窗底部中间坐标兜底。
    node = find_bottom_value_equal_node(nodes, "Get started")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "Get started",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.695,
    )


def find_ads_data_consent_action(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any] | None:
    anchor = find_ads_data_consent_dialog_anchor(vp, nodes)
    if anchor is None:
        return None
    matched_text, _ = anchor
    return {
        "state": "ads_data_consent",
        "matched_text": matched_text,
        "action_node": find_ads_data_get_started_node(nodes, width=width, height=height),
    }


COOKIES_PAGE_TEXTS = [
    "Allow the use of cookies by Instagram?",
    "Allow the use of cookies",
    "About cookies",
    "Decline optional cookies",
]


def find_cookies_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别成功后可能出现的 cookies 授权页；该页需要点底部 Allow all cookies。
    for text in COOKIES_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node
    return None


def find_allow_all_cookies_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：cookies 页底部按钮是 Allow all cookies；OCR 漏掉时合成底部蓝色按钮中心。
    node = find_bottom_value_equal_node(nodes, "Allow all cookies")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "Allow all cookies",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.923,
    )


def find_cookies_action(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any] | None:
    anchor = find_cookies_page_anchor(vp, nodes)
    if anchor is None:
        return None
    matched_text, _ = anchor
    return {
        "state": "cookies_page",
        "matched_text": matched_text,
        "action_node": find_allow_all_cookies_node(nodes, width=width, height=height),
    }


PHOTOS_ACCESS_PAGE_TEXTS = [
    "Allow Instagram to access your photos and videos",
    "your photos and videos",
    "access your photos and videos",
    "photos and videos from your camera roll",
    "add photos and videos from your camera roll",
]

PHOTOS_PERMISSION_DIALOG_TEXTS = [
    "would like full access to your Photo Library",
    "full access to your Photo Library",
    "Photo Library",
    "Would Like to Access Your Photos",
    "Allow “Instagram” to access your photos?",
    "Allow \"Instagram\" to access your photos?",
    "Allow Instagram to access your photos?",
    "would like to access your photos",
    "would like access to your photos",
    "Instagram would like to access",
    "access your photos?",
]


def find_photos_access_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别点击头像后出现的 Instagram 照片/视频访问说明页；该页需要点底部 Continue。
    for text in PHOTOS_ACCESS_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node

    combined = " ".join(ocr_node_value(node) for node in nodes).casefold()
    combined = re.sub(r"\s+", " ", combined)
    if (
        "allow instagram" in combined
        and "photos" in combined
        and "videos" in combined
        and (
            "camera roll" in combined
            or "settings work" in combined
            or "how you'll use" in combined
            or "how we'll use" in combined
        )
    ):
        anchor_node = (
            find_ocr_node_by_text(vp, nodes, "photos and videos")
            or find_ocr_node_by_text(vp, nodes, "How you'll use this")
            or find_ocr_node_by_text(vp, nodes, "How we'll use this")
        )
        if anchor_node is None:
            width, height = ocr_nodes_extent(nodes)
            anchor_node = synthetic_ocr_node("photos_access_page", width * 0.50, height * 0.50)
        return "photos_access_combined", anchor_node
    return None


def find_photos_permission_dialog_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别 iOS 系统相册权限弹窗；不要把 Instagram 自己页面插画里的 Allow Full Access 当弹窗。
    has_dialog_button = any(
        find_ocr_node_by_text(vp, nodes, text) is not None
        for text in (
            "Allow Full Access",
            "Allow Access to All Photos",
            "Allow All Photos",
            "Select Photos",
            "Don't Allow",
            "Don’t Allow",
            "Dont Allow",
            "Keep Current Selection",
            "OK",
        )
    )
    if not has_dialog_button:
        return None

    combined = " ".join(ocr_node_value(node) for node in nodes).casefold()
    combined = re.sub(r"\s+", " ", combined)
    has_system_dialog_text = (
        "photo library" in combined
        or "would like full access" in combined
        or "would like to access your photos" in combined
        or "would like access to your photos" in combined
        or "would like to access your photo" in combined
        or ("select photos" in combined and "would like" in combined)
    )
    if not has_system_dialog_text:
        return None

    for text in PHOTOS_PERMISSION_DIALOG_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node

    anchor_node = (
        find_ocr_node_by_text(vp, nodes, "Photo Library")
        or find_ocr_node_by_text(vp, nodes, "would like")
        or find_ocr_node_by_text(vp, nodes, "Allow Full Access")
    )
    if anchor_node is None:
        width, height = ocr_nodes_extent(nodes)
        anchor_node = synthetic_ocr_node("photos_permission_dialog", width * 0.50, height * 0.50)
    return "photos_permission_combined", anchor_node


def find_photos_access_continue_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：照片访问说明页底部按钮是 Continue；OCR 漏掉时合成底部蓝色按钮中心。
    node = find_bottom_value_equal_node(nodes, "Continue")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "Continue",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.923,
    )


def find_photos_permission_allow_node(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：上传头像需要相册可见；系统弹窗优先点 Allow Full Access。
    for text in (
        "Allow Full Access",
        "Allow Access to All Photos",
        "Allow access to all photos",
        "Allow All Photos",
        "Full Access",
        "OK",
    ):
        node = find_ocr_node_by_text(vp, nodes, text, prefer_bottom=True)
        if node is not None:
            return node

    allow_matches = [
        node
        for node in vp.ocr.filter_nodes(nodes, "Allow", exact=False, case_sensitive=False)
        if "don't" not in ocr_node_value(node).casefold()
        and "dont" not in ocr_node_value(node).casefold()
        and "not now" not in ocr_node_value(node).casefold()
        and ocr_node_center(node) is not None
    ]
    allow_matches.sort(key=lambda node: ocr_node_center(node)[1], reverse=True)  # type: ignore[index]
    if allow_matches:
        return allow_matches[0]

    return synthetic_ocr_node(
        "Allow Full Access",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.62,
    )


def find_photos_access_action(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any] | None:
    # 中文注释：返回照片访问说明页 / iOS 相册权限弹窗的下一步动作。
    dialog_anchor = find_photos_permission_dialog_anchor(vp, nodes)
    if dialog_anchor is not None:
        matched_text, _ = dialog_anchor
        return {
            "state": "photos_permission_dialog",
            "matched_text": matched_text,
            "action_node": find_photos_permission_allow_node(vp, nodes, width=width, height=height),
        }

    page_anchor = find_photos_access_page_anchor(vp, nodes)
    if page_anchor is not None:
        matched_text, _ = page_anchor
        return {
            "state": "photos_access_page",
            "matched_text": matched_text,
            "action_node": find_photos_access_continue_node(nodes, width=width, height=height),
        }

    return None


CONTACTS_ACCESS_PAGE_TEXTS = [
    "Next, you can allow access to your contacts",
    "allow access to your contacts",
    "your contacts to make it easier",
    "make it easier to find your friends",
    "find your friends on Instagram",
    "Your contacts will be periodically synced",
    "periodically synced and stored securely",
    "You can turn off syncing",
]

CONTACTS_PERMISSION_DIALOG_TEXTS = [
    "would like to access your Contacts",
    "Instagram will use your contacts",
    "Your contacts will be periodically synced",
]


def find_contacts_access_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别联系人同步引导页。该页可能出现在头像页前，也可能出现在头像流程结束后。
    for text in CONTACTS_ACCESS_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node

    # 中文注释：截图里的标题经常被 OCR 拆成多行：
    # “Next, you can allow access to” / “your contacts ...”。
    # 所以除了单节点包含匹配，还要用整屏 OCR 拼接后的关键词组合兜底。
    combined = " ".join(ocr_node_value(node) for node in nodes).casefold()
    combined = re.sub(r"\s+", " ", combined)
    contact_page_markers = (
        ("allow access" in combined and "contacts" in combined and "instagram" in combined),
        ("contacts" in combined and "make it easier" in combined and "find your friends" in combined),
        ("contacts" in combined and "periodically synced" in combined),
        ("syncing" in combined and "settings" in combined and "learn more" in combined),
        ("allow full access" in combined and "select contacts" in combined and "contacts" in combined),
    )
    if any(contact_page_markers):
        anchor_node = (
            find_ocr_node_by_text(vp, nodes, "contacts")
            or find_ocr_node_by_text(vp, nodes, "Allow Full Access")
            or find_ocr_node_by_text(vp, nodes, "Learn more")
        )
        if anchor_node is None:
            width, height = ocr_nodes_extent(nodes)
            anchor_node = synthetic_ocr_node("contacts_access_page", width * 0.50, height * 0.50)
        return "contacts_access_combined", anchor_node
    return None


def find_contacts_permission_dialog_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：识别 iOS 联系人权限弹窗；弹窗出现时优先点 Don't Allow，避免业务流程依赖联系人授权。
    # 注意：Instagram 自己的联系人引导页正文也有 “Your contacts will be periodically synced”，
    # 不能只靠正文判定弹窗；必须同屏有 Don't Allow / OK / Allow 这类系统弹窗按钮。
    has_dialog_button = any(
        find_ocr_node_by_text(vp, nodes, text) is not None
        for text in ("Don't Allow", "Don’t Allow", "Dont Allow", "Allow", "OK")
    )
    if not has_dialog_button:
        return None

    for text in CONTACTS_PERMISSION_DIALOG_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node
    return None


def find_contacts_access_next_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：联系人引导页底部按钮是 Next；OCR 漏掉时合成底部中间按钮坐标。
    node = find_bottom_value_equal_node(nodes, "Next")
    if node is not None:
        return node
    # 中文注释：如果 OCR 把按钮识别成带空格/标点的文本，也选最靠下的 Next，而不是标题里的 “Next,”。
    next_like_nodes = [
        node
        for node in nodes
        if re.fullmatch(r"(?i)\s*next\s*[\).,>»]*\s*", ocr_node_value(node))
        and ocr_node_center(node) is not None
    ]
    next_like_nodes.sort(key=lambda node: ocr_node_center(node)[1], reverse=True)  # type: ignore[index]
    if next_like_nodes:
        return next_like_nodes[0]
    return synthetic_ocr_node(
        "Next",
        float(width or 1290) * 0.50,
        float(height or 2796) * 0.92,
    )


def find_contacts_permission_deny_node(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    # 中文注释：iOS 弹窗按钮可能 OCR 成 Don't Allow 或 Don’t Allow；找不到时用弹窗左下按钮坐标兜底。
    for text in ("Don't Allow", "Don’t Allow", "Dont Allow"):
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return node
    return synthetic_ocr_node(
        "Don't Allow",
        float(width or 1290) * 0.31,
        float(height or 2796) * 0.672,
    )


def find_contacts_access_action(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any] | None:
    # 中文注释：返回可处理的联系人页/弹窗状态。
    # Instagram 联系人引导页正文和 iOS 权限弹窗文本相似；先识别完整页面，避免把页面误判成弹窗后反复点左侧兜底坐标。
    page_anchor = find_contacts_access_page_anchor(vp, nodes)
    if page_anchor is not None:
        matched_text, _ = page_anchor
        return {
            "state": "contacts_access",
            "matched_text": matched_text,
            "action_node": find_contacts_access_next_node(nodes, width=width, height=height),
        }

    dialog_anchor = find_contacts_permission_dialog_anchor(vp, nodes)
    if dialog_anchor is not None:
        matched_text, _ = dialog_anchor
        return {
            "state": "contacts_permission_dialog",
            "matched_text": matched_text,
            "action_node": find_contacts_permission_deny_node(vp, nodes, width=width, height=height),
        }

    return None


GENERIC_TOP_SKIP_PAGE_TEXTS = [
    "Get Facebook suggestions",
    "Remember login info?",
]

PROFILE_AVATAR_PAGE_TEXTS = [
    "Create a profile that shows",
    "Add bio",
]

PROFILE_CREATE_SUCCESS_TEXTS = [
    "Create a profile that shows",
    "Add bio",
    "Keep Instagram open to finish",
]

POST_ALLOW_NON_AVATAR_SUCCESS_GRACE = 18.0


def find_generic_top_skip_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：Allow 成功后的非头像链路基本都是右上角 Skip 页；用页面标题做兜底锚点。
    for text in GENERIC_TOP_SKIP_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node
    return None


def find_generic_top_skip_node(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
    max_y: float = 420.0,
) -> tuple[dict[str, Any] | None, str]:
    # 中文注释：统一找“右上角 Skip”。如果标题能证明这是 Skip 页但 OCR 漏掉 Skip，就合成右上角坐标。
    top_skip_node = find_top_right_value_equal_node(nodes, "Skip", width=width, max_y=max_y)
    if top_skip_node is not None:
        return top_skip_node, "Skip"

    anchor = find_generic_top_skip_page_anchor(vp, nodes)
    if anchor is None:
        return None, ""

    matched_text, _ = anchor
    return (
        synthetic_ocr_node(
            "Skip",
            float(width or 1290) * 0.90,
            float(height or 2796) * 0.088,
        ),
        matched_text,
    )


FACEBOOK_SUGGESTIONS_PAGE_TEXTS = [
    "Get Facebook suggestions",
    "Find people you know",
    "from Facebook",
    "Accounts Center",
]

FACEBOOK_OAUTH_DIALOG_TEXTS = [
    "Wants to Use",
    "facebook.com",
    "to Sign In",
    "This allows the app and website",
    "share information about you",
]


def find_facebook_suggestions_page_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：Facebook 找人页有两个版本：
    # 1. Get Facebook suggestions
    # 2. Find people you know / from Facebook
    # 这类页面必须点右上角 Skip，不能点底部 Next/Continue，否则会弹 facebook.com 登录确认框。
    for text in FACEBOOK_SUGGESTIONS_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node

    combined = " ".join(ocr_node_value(node) for node in nodes).casefold()
    combined = re.sub(r"\s+", " ", combined)
    if "facebook" in combined and ("find people" in combined or "suggestions" in combined or "accounts center" in combined):
        anchor_node = (
            find_ocr_node_by_text(vp, nodes, "Facebook")
            or find_ocr_node_by_text(vp, nodes, "Find people")
            or find_ocr_node_by_text(vp, nodes, "suggestions")
        )
        if anchor_node is None:
            width, height = ocr_nodes_extent(nodes)
            anchor_node = synthetic_ocr_node("facebook_suggestions", width * 0.50, height * 0.25)
        return "facebook_suggestions_combined", anchor_node
    return None


def find_facebook_oauth_sign_in_dialog_anchor(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    # 中文注释：iOS 弹窗：“Instagram” Wants to Use “facebook.com” to Sign In。
    # 出现时必须点 Cancel；如果继续点背景 Skip，会一直卡循环。
    has_cancel = find_bottom_value_equal_node(nodes, "Cancel") is not None
    has_continue = find_bottom_value_equal_node(nodes, "Continue") is not None
    if not (has_cancel and has_continue):
        return None

    combined = " ".join(ocr_node_value(node) for node in nodes).casefold()
    combined = re.sub(r"\s+", " ", combined)
    if not ("facebook.com" in combined and ("sign in" in combined or "wants to use" in combined)):
        return None

    for text in FACEBOOK_OAUTH_DIALOG_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            return text, node

    width, height = ocr_nodes_extent(nodes)
    return "facebook_oauth_combined", synthetic_ocr_node("facebook_oauth_dialog", width * 0.50, height * 0.50)


def find_facebook_oauth_cancel_node(
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any]:
    node = find_bottom_value_equal_node(nodes, "Cancel")
    if node is not None:
        return node
    return synthetic_ocr_node(
        "Cancel",
        float(width or 1290) * 0.33,
        float(height or 2796) * 0.576,
    )


def find_facebook_oauth_sign_in_action(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any] | None:
    anchor = find_facebook_oauth_sign_in_dialog_anchor(vp, nodes)
    if anchor is None:
        return None
    matched_text, _ = anchor
    return {
        "state": "facebook_oauth_dialog",
        "matched_text": matched_text,
        "action_node": find_facebook_oauth_cancel_node(nodes, width=width, height=height),
    }


def find_profile_setup_done_action(
    vp: VPhoneSession,
    nodes: list[dict[str, Any]],
    *,
    width: int = 0,
    height: int = 0,
) -> dict[str, Any] | None:
    # 中文注释：兜底处理“Create a profile that shows your vibe”资料页。
    # 正常情况下这里会走头像上传流程；但有时先出现 Keep Instagram open 过渡页，
    # 脚本可能已进入补充引导扫描，此时不能把这个资料页留在屏幕上，至少要点底部 Done 继续。
    matched_text = ""
    for text in PROFILE_AVATAR_PAGE_TEXTS:
        node = find_ocr_node_by_text(vp, nodes, text)
        if node is not None:
            matched_text = text
            break
    if not matched_text:
        return None

    done_node = find_bottom_value_equal_node(nodes, "Done")
    if done_node is None:
        done_node = synthetic_ocr_node(
            "Done",
            float(width or 1290) * 0.50,
            float(height or 2796) * 0.923,
        )
    return {
        "state": "profile_avatar_done",
        "matched_text": matched_text,
        "action_node": done_node,
    }


def wait_for_profile_create_result(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    non_avatar_success_grace: float = 0.0,
) -> dict[str, Any]:
    # 中文注释：步骤 19：Allow and continue 后同时等待失败/成功页面。
    # 失败标记：Please try again。
    # 成功标记：Keep Instagram open to finish / Create a profile that shows / Add bio 任意一个。
    # 头像流程只在 Create a profile that shows / Add bio 资料页执行；Keep Instagram open to finish 只代表创建成功。
    # 可选中间页：Allow Instagram to access / 右上角 Skip / 确认 Skip 弹窗，出现时由上层点击 Skip 后继续等待资料页或首页。
    deadline = time.monotonic() + max(0.0, timeout)
    pending_non_avatar_success: dict[str, Any] | None = None
    pending_non_avatar_deadline = 0.0
    last_error = ""
    last_values: list[str] = []
    while True:
        try:
            nodes, width, height = ocr_snapshot_nodes(vp)
            last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]

            if find_ocr_node_by_value_equal(nodes, "Your story") is not None:
                return {
                    "ok": True,
                    "state": "home",
                    "matched_text": "Your story",
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "avatar_flow_required": False,
                    "error": "",
                }

            confirm_skip_node = find_skip_confirm_node(vp, nodes)
            if confirm_skip_node is not None:
                return {
                    "ok": False,
                    "state": "skip_confirm",
                    "matched_text": "skip this step",
                    "skip_node": confirm_skip_node,
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            follow_anchor = find_recommended_follow_page_anchor(vp, nodes)
            if follow_anchor is not None:
                matched_text, _ = follow_anchor
                action_node = find_recommended_follow_action_node(nodes, width=width, height=height)
                return {
                    "ok": False,
                    "state": "recommended_follow",
                    "matched_text": matched_text,
                    "action_node": action_node,
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            pick_node = find_ocr_node_by_text(vp, nodes, "Pick what you want to see")
            if pick_node is not None:
                action_node = find_pick_interests_action_node(nodes, width=width, height=height)
                return {
                    "ok": False,
                    "state": "pick_interests",
                    "matched_text": "Pick what you want to see",
                    "action_node": action_node,
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            free_with_ads_action = find_free_with_ads_action(
                vp,
                nodes,
                width=width,
                height=height,
            )
            if free_with_ads_action is not None:
                resp = {
                    "ok": False,
                    "state": free_with_ads_action["state"],
                    "matched_text": free_with_ads_action["matched_text"],
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }
                for key in ("action_node", "select_node", "use_node", "continue_node"):
                    if key in free_with_ads_action:
                        resp[key] = free_with_ads_action[key]
                return resp

            photos_action = find_photos_access_action(
                vp,
                nodes,
                width=width,
                height=height,
            )
            if photos_action is not None:
                return {
                    "ok": False,
                    "state": photos_action["state"],
                    "matched_text": photos_action["matched_text"],
                    "action_node": photos_action["action_node"],
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            contacts_action = find_contacts_access_action(
                vp,
                nodes,
                width=width,
                height=height,
            )
            if contacts_action is not None:
                return {
                    "ok": False,
                    "state": contacts_action["state"],
                    "matched_text": contacts_action["matched_text"],
                    "action_node": contacts_action["action_node"],
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            ads_data_action = find_ads_data_consent_action(
                vp,
                nodes,
                width=width,
                height=height,
            )
            if ads_data_action is not None:
                return {
                    "ok": False,
                    "state": ads_data_action["state"],
                    "matched_text": ads_data_action["matched_text"],
                    "action_node": ads_data_action["action_node"],
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            cookies_action = find_cookies_action(
                vp,
                nodes,
                width=width,
                height=height,
            )
            if cookies_action is not None:
                return {
                    "ok": False,
                    "state": cookies_action["state"],
                    "matched_text": cookies_action["matched_text"],
                    "action_node": cookies_action["action_node"],
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            top_skip_node, skip_matched_text = find_generic_top_skip_node(
                vp,
                nodes,
                width=width,
                height=height,
            )
            if top_skip_node is not None:
                return {
                    "ok": False,
                    "state": "skip_page",
                    "matched_text": skip_matched_text,
                    "skip_node": top_skip_node,
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "",
                }

            failed_node = find_ocr_node_by_text(vp, nodes, "Please try again")
            if failed_node is not None:
                return {
                    "ok": False,
                    "state": "please_try_again",
                    "matched_text": "Please try again",
                    "nodes": nodes,
                    "width": width,
                    "height": height,
                    "last_values": last_values,
                    "error": "出现 Please try again",
                }

            for text in PROFILE_CREATE_SUCCESS_TEXTS:
                node = find_ocr_node_by_text(vp, nodes, text)
                if node is not None:
                    avatar_flow_required = text in PROFILE_AVATAR_PAGE_TEXTS
                    resp = {
                        "ok": True,
                        "state": "profile_avatar_page" if avatar_flow_required else "profile_create_success",
                        "matched_text": text,
                        "nodes": nodes,
                        "width": width,
                        "height": height,
                        "last_values": last_values,
                        "avatar_flow_required": avatar_flow_required,
                        "error": "",
                    }
                    if avatar_flow_required or non_avatar_success_grace <= 0:
                        return resp

                    # 中文注释：Keep Instagram open to finish 有时只是成功后的过渡页；
                    # 短暂继续观察，允许后续 Skip/头像设置页/首页接管，而不是立刻结束头像链路。
                    if pending_non_avatar_success is None:
                        pending_non_avatar_deadline = time.monotonic() + max(0.0, non_avatar_success_grace)
                    pending_non_avatar_success = resp
        except Exception as exc:
            # 中文注释：单次 OCR 截图/识别失败不立刻中断，继续轮询到 timeout。
            last_error = str(exc)

        now = time.monotonic()
        if pending_non_avatar_success is not None:
            remaining = pending_non_avatar_deadline - now
            if remaining <= 0:
                return pending_non_avatar_success
        else:
            remaining = deadline - now
        if remaining <= 0:
            error = f"未等待到创建资料成功/失败标记；当前文本={last_values!r}"
            if last_error:
                error += f"; OCR错误={last_error}"
            return {
                "ok": False,
                "state": "timeout",
                "matched_text": "",
                "nodes": [],
                "width": 0,
                "height": 0,
                "last_values": last_values,
                "error": error,
            }
        time.sleep(min(max(0.1, interval), remaining))


def wait_for_profile_create_result_after_allow(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：步骤 19 的完整处理：等待资料创建结果；
    # 如果中间出现任意可跳过页面（右上角 Skip）或确认 Skip 弹窗，就自动点击 Skip 后继续等待资料页/首页。
    post_allow_skip_clicked = False
    post_allow_skip_count = 0
    post_allow_action_flags: dict[str, bool] = {
        "free_with_ads_choice": False,
        "free_with_ads_use_clicked": False,
        "free_with_ads_continue_clicked": False,
        "free_with_ads_agree": False,
        "free_with_ads_agree_clicked": False,
        "ad_experience_manage": False,
        "ad_experience_ok_clicked": False,
        "photos_access_page": False,
        "photos_access_continue_clicked": False,
        "photos_permission_dialog": False,
        "photos_permission_allow_clicked": False,
        "contacts_access": False,
        "contacts_next_clicked": False,
        "contacts_permission_dialog": False,
        "contacts_permission_denied_clicked": False,
        "ads_data_consent": False,
        "ads_data_get_started_clicked": False,
        "cookies_page": False,
        "cookies_allow_all_clicked": False,
    }
    max_skip_pages = 20
    for _ in range(max_skip_pages + 1):
        log_start("等待创建资料结果")
        try:
            resp = wait_for_profile_create_result(
                vp,
                timeout=30.0,
                interval=interval,
                non_avatar_success_grace=POST_ALLOW_NON_AVATAR_SUCCESS_GRACE,
            )
        except Exception:
            log_done(False)
            raise

        if resp.get("state") in {
            "skip_page",
            "skip_confirm",
            "recommended_follow",
            "pick_interests",
            "free_with_ads_choice",
            "free_with_ads_agree",
            "ad_experience_manage",
            "photos_access_page",
            "photos_permission_dialog",
            "contacts_access",
            "contacts_permission_dialog",
            "ads_data_consent",
            "cookies_page",
        }:
            log_done(True)
            post_allow_skip_count += 1
            state = str(resp.get("state") or "")

            if state in FREE_WITH_ADS_ACTION_STATES:
                action_result = click_free_with_ads_action(vp, resp, screen=screen)
                resp.update(action_result)
                for key in post_allow_action_flags:
                    post_allow_action_flags[key] = post_allow_action_flags[key] or bool(action_result.get(key))
                post_allow_skip_clicked = bool(action_result.get("ok"))
                resp["post_allow_skip_clicked"] = post_allow_skip_clicked
                resp["post_allow_skip_count"] = post_allow_skip_count
                resp.update(post_allow_action_flags)
                if not post_allow_skip_clicked:
                    resp["ok"] = False
                    resp["error"] = str(action_result.get("error") or "免费含广告链路点击失败")
                    return resp
                continue

            action_node = resp.get("action_node") or resp.get("skip_node")
            if not isinstance(action_node, dict):
                resp["ok"] = False
                resp["error"] = "可处理页面缺少按钮 OCR 坐标"
                return resp
            action_value = ocr_node_value(action_node)
            if state == "skip_confirm":
                action_name = "点击弹窗Skip"
            elif state == "recommended_follow":
                action_name = f"点击推荐关注{action_value or 'Next'}"
            elif state == "pick_interests":
                action_name = "点击兴趣页Done"
            elif state == "photos_access_page":
                action_name = "点击照片权限Continue"
            elif state == "photos_permission_dialog":
                action_name = "点击照片权限允许完整访问"
            elif state == "contacts_access":
                action_name = "点击联系人页Next"
            elif state == "contacts_permission_dialog":
                action_name = "点击联系人权限不允许"
            elif state == "ads_data_consent":
                action_name = "点击广告数据Get started"
            elif state == "cookies_page":
                action_name = "点击允许所有Cookies"
            else:
                action_name = "点击Skip"
            post_allow_skip_clicked = click_ocr_node_with_delay(
                vp,
                action_node,
                action_name=action_name,
                screen=screen,
            )
            if state == "photos_access_page":
                post_allow_action_flags["photos_access_page"] = True
                post_allow_action_flags["photos_access_continue_clicked"] = post_allow_skip_clicked
            elif state == "photos_permission_dialog":
                post_allow_action_flags["photos_permission_dialog"] = True
                post_allow_action_flags["photos_permission_allow_clicked"] = post_allow_skip_clicked
            elif state == "contacts_access":
                post_allow_action_flags["contacts_access"] = True
                post_allow_action_flags["contacts_next_clicked"] = post_allow_skip_clicked
            elif state == "contacts_permission_dialog":
                post_allow_action_flags["contacts_permission_dialog"] = True
                post_allow_action_flags["contacts_permission_denied_clicked"] = post_allow_skip_clicked
            elif state == "ads_data_consent":
                post_allow_action_flags["ads_data_consent"] = True
                post_allow_action_flags["ads_data_get_started_clicked"] = post_allow_skip_clicked
            elif state == "cookies_page":
                post_allow_action_flags["cookies_page"] = True
                post_allow_action_flags["cookies_allow_all_clicked"] = post_allow_skip_clicked
            resp["post_allow_skip_clicked"] = post_allow_skip_clicked
            resp["post_allow_skip_count"] = post_allow_skip_count
            resp.update(post_allow_action_flags)
            if not post_allow_skip_clicked:
                resp["ok"] = False
                resp["error"] = f"{action_name}失败"
                return resp
            continue

        ok = bool(resp.get("ok"))
        resp["post_allow_skip_clicked"] = post_allow_skip_clicked
        resp["post_allow_skip_count"] = post_allow_skip_count
        resp.update(post_allow_action_flags)
        log_done(ok)
        return resp

    resp = {
        "ok": False,
        "state": "post_allow_skip_loop",
        "matched_text": "Skip",
        "nodes": [],
        "width": 0,
        "height": 0,
        "last_values": [],
        "post_allow_skip_clicked": post_allow_skip_clicked,
        "post_allow_skip_count": post_allow_skip_count,
        "error": f"Allow 后可跳过页面超过最大处理次数 {max_skip_pages}",
    }
    resp.update(post_allow_action_flags)
    return resp


def profile_avatar_node_from_result(result: dict[str, Any]) -> dict[str, Any]:
    # 中文注释：成功页头像不是文字，OCR 不会返回头像节点；这里根据 OCR 截图宽高和 Add bio/标题位置推导头像中心。
    nodes = result.get("nodes")
    if not isinstance(nodes, list):
        nodes = []
    width = int(result.get("width") or 0)
    height = int(result.get("height") or 0)
    if width <= 0:
        max_x = 0.0
        for node in nodes:
            frame = node.get("frame_pixels")
            if isinstance(frame, dict):
                max_x = max(max_x, float(frame.get("max_x") or 0.0))
        width = int(max_x) if max_x > 0 else 1290
    if height <= 0:
        height = 2796

    x = float(width) / 2.0
    y = float(height) * 0.43

    for node in nodes:
        value = str(node.get("value") or node.get("label") or "").strip()
        if "Add bio".casefold() in value.casefold():
            center = node.get("center_pixels")
            if isinstance(center, dict):
                # 中文注释：头像中心在 Add bio 上方约 22.5% 屏幕高度处。
                x = float(width) / 2.0
                y = float(center.get("y") or y) - float(height) * 0.225
            break

    # 中文注释：限制到资料卡头像常见区域，避免 OCR 异常导致点到标题或底部按钮。
    y = max(float(height) * 0.32, min(y, float(height) * 0.52))
    return synthetic_ocr_node("profile_avatar", x, y)


def click_profile_avatar(
    vp: VPhoneSession,
    result: dict[str, Any],
    *,
    screen: bool = False,
) -> bool:
    # 中文注释：点击成功页中间头像。
    avatar_node = profile_avatar_node_from_result(result)
    return click_ocr_node_with_delay(
        vp,
        avatar_node,
        action_name="点击头像",
        screen=screen,
    )


def wait_for_album_picker(
    vp: VPhoneSession,
    *,
    timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：点击头像后必须确认已经进入系统相册；同一张 OCR 快照里同时有 Library 和 Done 才算成功。
    # 如果中间插入 Instagram 照片访问说明页或 iOS 相册权限弹窗，就自动点 Continue / Allow Full Access 后继续等待。
    deadline = time.monotonic() + max(0.0, timeout)
    last_values: list[str] = []
    last_error = ""
    handled_permission_pages = 0
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
            library_node = find_ocr_node_by_value_equal(nodes, "Library")
            done_node = find_ocr_node_by_value_equal(nodes, "Done", prefer_bottom=False)
            if library_node is not None and done_node is not None:
                return {
                    "ok": True,
                    "state": "album_picker",
                    "library_node": library_node,
                    "done_node": done_node,
                    "nodes": nodes,
                    "last_values": last_values,
                    "error": "",
                }

            width, height = ocr_nodes_extent(nodes)
            photos_action = find_photos_access_action(
                vp,
                nodes,
                width=int(width),
                height=int(height),
            )
            if photos_action is not None:
                handled_permission_pages += 1
                if handled_permission_pages > 4:
                    return {
                        "ok": False,
                        "state": "photos_permission_loop",
                        "library_node": None,
                        "done_node": None,
                        "nodes": nodes,
                        "last_values": last_values,
                        "error": "照片权限页面处理次数过多，仍未进入相册",
                    }
                action_node = photos_action.get("action_node")
                if not isinstance(action_node, dict):
                    return {
                        "ok": False,
                        "state": str(photos_action.get("state") or "photos_permission"),
                        "library_node": None,
                        "done_node": None,
                        "nodes": nodes,
                        "last_values": last_values,
                        "error": "照片权限页面缺少按钮 OCR 坐标",
                    }
                state = str(photos_action.get("state") or "")
                action_name = (
                    "点击照片权限允许完整访问"
                    if state == "photos_permission_dialog"
                    else "点击照片权限Continue"
                )
                clicked = click_ocr_node_with_delay(
                    vp,
                    action_node,
                    action_name=action_name,
                    screen=screen,
                )
                if not clicked:
                    return {
                        "ok": False,
                        "state": state,
                        "library_node": None,
                        "done_node": None,
                        "nodes": nodes,
                        "last_values": last_values,
                        "error": f"{action_name}失败",
                    }
                time.sleep(0.5)
                continue
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            error = f"未进入相册，未同时看到 Library 和 Done；当前文本={last_values!r}"
            if last_error:
                error += f"; OCR错误={last_error}"
            return {
                "ok": False,
                "state": "timeout",
                "library_node": None,
                "done_node": None,
                "nodes": [],
                "last_values": last_values,
                "error": error,
            }
        time.sleep(min(max(0.1, interval), remaining))


def click_done_from_state(
    vp: VPhoneSession,
    state_resp: dict[str, Any],
    *,
    action_name: str,
    screen: bool = False,
) -> bool:
    # 中文注释：点击等待状态里记录的 Done 节点；用于“相册 Done”和“资料页 Done”两个不同页面。
    done_node = state_resp.get("done_node")
    if not isinstance(done_node, dict):
        raise LookupError(f"{action_name} 缺少 Done OCR 坐标")
    return click_ocr_node_with_delay(
        vp,
        done_node,
        action_name=action_name,
        screen=screen,
    )


def wait_for_profile_page_done_after_avatar_upload(
    vp: VPhoneSession,
    *,
    timeout: float = 60.0,
    interval: float = 0.5,
) -> dict[str, Any]:
    # 中文注释：相册 Done 后会触发头像上传网络请求；等待回到资料创建页，并且同屏出现资料页 Done。
    # 成功标记：Create a profile that shows / Add bio 任意一个 + Done。
    # 失败标记：Please try again。
    deadline = time.monotonic() + max(0.0, timeout)
    last_values: list[str] = []
    last_error = ""
    while True:
        try:
            nodes = vp.ocr.nodes(timeout=30.0)
            last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]

            failed_node = find_ocr_node_by_text(vp, nodes, "Please try again")
            if failed_node is not None:
                return {
                    "ok": False,
                    "state": "please_try_again",
                    "matched_text": "Please try again",
                    "done_node": None,
                    "nodes": nodes,
                    "last_values": last_values,
                    "error": "头像上传后出现 Please try again",
                }

            done_node = find_ocr_node_by_value_equal(nodes, "Done", prefer_bottom=False)
            if done_node is not None:
                for text in PROFILE_AVATAR_PAGE_TEXTS:
                    marker_node = find_ocr_node_by_text(vp, nodes, text)
                    if marker_node is not None:
                        return {
                            "ok": True,
                            "state": "profile_page_done",
                            "matched_text": text,
                            "done_node": done_node,
                            "marker_node": marker_node,
                            "nodes": nodes,
                            "last_values": last_values,
                            "error": "",
                        }
        except Exception as exc:
            last_error = str(exc)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            error = f"头像上传后未回到资料页 Done；当前文本={last_values!r}"
            if last_error:
                error += f"; OCR错误={last_error}"
            return {
                "ok": False,
                "state": "timeout",
                "matched_text": "",
                "done_node": None,
                "nodes": [],
                "last_values": last_values,
                "error": error,
            }
        time.sleep(min(max(0.1, interval), remaining))


def wait_profile_page_done_with_cancel_fallback(
    vp: VPhoneSession,
    *,
    upload_timeout: float = 30.0,
    after_cancel_timeout: float = 15.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：头像上传后先等待 30 秒自动回到资料页；如果超时，就点击相册 Cancel 手动返回资料页。
    # 返回值里 cancel_clicked 表示是否走了 Cancel 兜底。
    log_start(f"等待头像上传返回{upload_timeout:g}秒")
    try:
        first_resp = wait_for_profile_page_done_after_avatar_upload(
            vp,
            timeout=upload_timeout,
            interval=interval,
        )
    except Exception:
        log_done(False)
        raise
    first_ok = bool(first_resp.get("ok"))
    log_done(first_ok)
    if first_ok:
        first_resp["cancel_clicked"] = False
        first_resp["before_cancel_error"] = ""
        return first_resp

    # 中文注释：如果明确出现 Please try again，不走 Cancel 兜底，直接让上层按失败处理。
    if first_resp.get("state") != "timeout":
        first_resp["cancel_clicked"] = False
        first_resp["before_cancel_error"] = str(first_resp.get("error") or "")
        return first_resp

    log_start("等待Cancel")
    try:
        cancel_node = wait_for_ocr_value_equal(
            vp,
            "Cancel",
            timeout=10.0,
            interval=interval,
        )
    except Exception:
        log_done(False)
        raise
    log_done(True)

    cancel_clicked = click_ocr_node_with_delay(
        vp,
        cancel_node,
        action_name="点击Cancel返回资料页",
        screen=screen,
    )
    if not cancel_clicked:
        return {
            "ok": False,
            "state": "cancel_failed",
            "matched_text": "",
            "done_node": None,
            "nodes": [],
            "last_values": first_resp.get("last_values") or [],
            "cancel_clicked": False,
            "before_cancel_error": str(first_resp.get("error") or ""),
            "error": "点击 Cancel 返回资料页失败",
        }

    log_start("等待资料页Done")
    try:
        second_resp = wait_for_profile_page_done_after_avatar_upload(
            vp,
            timeout=after_cancel_timeout,
            interval=interval,
        )
    except Exception:
        log_done(False)
        raise
    second_ok = bool(second_resp.get("ok"))
    log_done(second_ok)
    second_resp["cancel_clicked"] = True
    second_resp["before_cancel_error"] = str(first_resp.get("error") or "")
    return second_resp


def click_skip_if_present(
    vp: VPhoneSession,
    *,
    timeout: float = 10.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：资料页 Done 后可能连续出现几个 Instagram 新号引导页：
    # 1. Get Facebook suggestions：点右上角 Skip，如弹确认框再点弹窗里的 Skip。
    # 2. Remember login info?：点右上角 Skip，不会二次确认。
    # 3. Try following 5+ people / Follow 5 or more people：点屏幕最下方 Follow，若按钮是 Next 就点 Next。
    # 4. Pick what you want to see：点屏幕最下方 Done。
    # 5. 免费含广告链路：Use free of charge with ads -> Continue -> Agree -> OK。
    # 如果直接看到 Your story，说明已经进入首页；如果这些页面都没出现，也不算失败。
    result: dict[str, Any] = {
        "ok": True,
        "state": "",
        "found": False,
        "clicked": False,
        "confirm_found": False,
        "confirm_clicked": False,
        "facebook_suggestions": False,
        "facebook_skip_clicked": False,
        "facebook_oauth_dialog": False,
        "facebook_oauth_cancel_clicked": False,
        "remember_login": False,
        "remember_skip_clicked": False,
        "recommended_follow": False,
        "recommended_follow_clicked": False,
        "recommended_follow_action": "",
        "pick_interests": False,
        "pick_interests_done_clicked": False,
        "profile_avatar_done_page": False,
        "profile_avatar_done_clicked": False,
        "free_with_ads_choice": False,
        "free_with_ads_use_clicked": False,
        "free_with_ads_continue_clicked": False,
        "free_with_ads_agree": False,
        "free_with_ads_agree_clicked": False,
        "ad_experience_manage": False,
        "ad_experience_ok_clicked": False,
        "photos_access_page": False,
        "photos_access_continue_clicked": False,
        "photos_permission_dialog": False,
        "photos_permission_allow_clicked": False,
        "contacts_access": False,
        "contacts_next_clicked": False,
        "contacts_permission_dialog": False,
        "contacts_permission_denied_clicked": False,
        "ads_data_consent": False,
        "ads_data_get_started_clicked": False,
        "cookies_page": False,
        "cookies_allow_all_clicked": False,
        "home": False,
        "generic_skip_count": 0,
        "last_values": [],
        "error": "",
    }

    def exact_nodes(nodes: list[dict[str, Any]], value: str) -> list[dict[str, Any]]:
        return [
            node
            for node in nodes
            if str(node.get("value") or node.get("label") or "").strip() == value
        ]

    def node_y(node: dict[str, Any]) -> float:
        return float((node.get("center_pixels") or {}).get("y") or 0.0)

    def top_node(nodes: list[dict[str, Any]], value: str) -> dict[str, Any] | None:
        matches = exact_nodes(nodes, value)
        matches.sort(key=node_y)
        return matches[0] if matches else None

    def bottom_node(nodes: list[dict[str, Any]], value: str) -> dict[str, Any] | None:
        matches = exact_nodes(nodes, value)
        matches.sort(key=node_y, reverse=True)
        return matches[0] if matches else None

    def inferred_width(nodes: list[dict[str, Any]]) -> int:
        max_x = 0.0
        for node in nodes:
            frame = node.get("frame_pixels")
            if isinstance(frame, dict):
                max_x = max(max_x, float(frame.get("max_x") or 0.0))
            center = node.get("center_pixels")
            if isinstance(center, dict):
                max_x = max(max_x, float(center.get("x") or 0.0))
        # 中文注释：nodes 里最大的文字坐标通常小于真实屏宽；合成右上角按钮时按当前实例常用屏宽兜底。
        return max(int(max_x), 1290)

    def inferred_height(nodes: list[dict[str, Any]]) -> int:
        max_y = 0.0
        for node in nodes:
            frame = node.get("frame_pixels")
            if isinstance(frame, dict):
                max_y = max(max_y, float(frame.get("max_y") or 0.0))
            center = node.get("center_pixels")
            if isinstance(center, dict):
                max_y = max(max_y, float(center.get("y") or 0.0))
        # 中文注释：同上，OCR 文本可能只覆盖到页面中部，合成 Skip 的 y 坐标需要屏高兜底。
        return max(int(max_y), 2796)

    def wait_current_nodes(label: str) -> tuple[list[dict[str, Any]] | None, list[str], str]:
        # 中文注释：等待下一张可识别的引导页/首页；返回 nodes=None 表示没等到可处理页面。
        deadline = time.monotonic() + max(0.0, timeout)
        last_values: list[str] = []
        last_error = ""
        log_start(label)
        while True:
            try:
                nodes = vp.ocr.nodes(timeout=30.0)
                last_values = [str(node.get("value") or node.get("label") or "").strip() for node in nodes]
                if (
                    find_facebook_oauth_sign_in_action(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    ) is not None
                    or find_facebook_suggestions_page_anchor(vp, nodes) is not None
                    or find_ocr_node_by_text(vp, nodes, "Remember login info?") is not None
                    or find_recommended_follow_page_anchor(vp, nodes) is not None
                    or find_ocr_node_by_text(vp, nodes, "Pick what you want to see") is not None
                    or find_profile_setup_done_action(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    ) is not None
                    or find_free_with_ads_action(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    ) is not None
                    or find_photos_access_action(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    ) is not None
                    or find_contacts_access_action(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    ) is not None
                    or find_ads_data_consent_action(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    ) is not None
                    or find_cookies_action(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    ) is not None
                    or find_ocr_node_by_text(vp, nodes, "Allow Instagram to access") is not None
                    or find_skip_confirm_node(vp, nodes) is not None
                    or find_ocr_node_by_text(vp, nodes, "Please try again") is not None
                    or find_generic_top_skip_node(
                        vp,
                        nodes,
                        width=inferred_width(nodes),
                        height=inferred_height(nodes),
                    )[0] is not None
                    or find_ocr_node_by_value_equal(nodes, "Your story") is not None
                ):
                    log_done(True)
                    return nodes, last_values, ""
            except Exception as exc:
                last_error = str(exc)

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                log_done(True)
                return None, last_values, last_error
            time.sleep(min(max(0.1, interval), remaining))

    def handle_facebook_confirm_popup() -> bool:
        # 中文注释：点击 Facebook 建议页 Skip 后，可能弹“skip this step?”确认框；有弹窗就点弹窗里的 Skip。
        popup_deadline = time.monotonic() + min(max(0.0, timeout), 5.0)
        popup_last_values: list[str] = []
        popup_last_error = ""
        saw_confirm_popup = False
        log_start("判断Skip确认弹窗")
        while True:
            try:
                popup_nodes = vp.ocr.nodes(timeout=30.0)
                popup_last_values = [
                    str(node.get("value") or node.get("label") or "").strip()
                    for node in popup_nodes
                ]
                result["last_values"] = popup_last_values

                oauth_action = find_facebook_oauth_sign_in_action(
                    vp,
                    popup_nodes,
                    width=inferred_width(popup_nodes),
                    height=inferred_height(popup_nodes),
                )
                if oauth_action is not None:
                    action_node = oauth_action.get("action_node")
                    if not isinstance(action_node, dict):
                        raise LookupError("Facebook 登录确认弹窗缺少 Cancel OCR 坐标")
                    log_done(True)
                    cancel_clicked = click_ocr_node_with_delay(
                        vp,
                        action_node,
                        action_name="点击Facebook登录弹窗Cancel",
                        screen=screen,
                    )
                    result["facebook_oauth_dialog"] = True
                    result["facebook_oauth_cancel_clicked"] = cancel_clicked
                    if not cancel_clicked:
                        result["ok"] = False
                        result["error"] = "点击 Facebook 登录弹窗 Cancel 失败"
                    else:
                        wait_until_ocr_text_absent(
                            vp,
                            "facebook.com",
                            timeout=min(max(1.0, timeout), 5.0),
                            interval=interval,
                        )
                    return cancel_clicked

                # 中文注释：如果已经跳到后续页面/首页，说明没有确认弹窗，直接继续后续引导处理。
                if (
                    find_ocr_node_by_text(vp, popup_nodes, "Remember login info?") is not None
                    or find_recommended_follow_page_anchor(vp, popup_nodes) is not None
                    or find_ocr_node_by_text(vp, popup_nodes, "Pick what you want to see") is not None
                    or find_free_with_ads_action(
                        vp,
                        popup_nodes,
                        width=inferred_width(popup_nodes),
                        height=inferred_height(popup_nodes),
                    ) is not None
                    or find_profile_setup_done_action(
                        vp,
                        popup_nodes,
                        width=inferred_width(popup_nodes),
                        height=inferred_height(popup_nodes),
                    ) is not None
                    or find_photos_access_action(
                        vp,
                        popup_nodes,
                        width=inferred_width(popup_nodes),
                        height=inferred_height(popup_nodes),
                    ) is not None
                    or find_ocr_node_by_value_equal(popup_nodes, "Your story") is not None
                ):
                    log_done(True)
                    return True

                has_confirm_popup = (
                    find_ocr_node_by_text(vp, popup_nodes, "skip this step") is not None
                    or find_ocr_node_by_value_equal(popup_nodes, "Find friends") is not None
                )
                if has_confirm_popup:
                    saw_confirm_popup = True
                    result["confirm_found"] = True
                    dialog_skip_node = bottom_node(popup_nodes, "Skip")
                    if dialog_skip_node is None:
                        raise LookupError("Skip 确认弹窗缺少 Skip OCR 坐标")
                    log_done(True)
                    confirm_clicked = click_ocr_node_with_delay(
                        vp,
                        dialog_skip_node,
                        action_name="点击弹窗Skip",
                        screen=screen,
                    )
                    result["confirm_clicked"] = confirm_clicked
                    if not confirm_clicked:
                        result["ok"] = False
                        result["error"] = "点击弹窗 Skip 失败"
                    else:
                        wait_until_ocr_text_absent(
                            vp,
                            "skip this step",
                            timeout=min(max(1.0, timeout), 5.0),
                            interval=interval,
                        )
                    return confirm_clicked
            except Exception as exc:
                popup_last_error = str(exc)

            popup_remaining = popup_deadline - time.monotonic()
            if popup_remaining <= 0:
                popup_ok = not saw_confirm_popup
                log_done(popup_ok)
                if not popup_ok:
                    result["ok"] = False
                    result["error"] = popup_last_error or "Skip 确认弹窗缺少 Skip OCR 坐标"
                return popup_ok
            time.sleep(min(max(0.1, interval), popup_remaining))

    # 中文注释：后续页顺序不固定，但同一类页面不能无限重试。
    # 例如 Facebook 找人页若误点到底部 Next，会弹 iOS facebook.com 登录框；
    # 弹框处理失败时最多尝试几次，然后退出补充处理，让账号 JSON 上报继续。
    max_pages = 12
    max_same_page_attempts = 3
    facebook_suggestions_attempts = 0
    facebook_oauth_attempts = 0
    profile_done_attempts = 0
    recommended_follow_attempts = 0
    generic_skip_attempts = 0
    for _ in range(max_pages):
        nodes, last_values, last_error = wait_current_nodes("判断后续引导")
        result["last_values"] = last_values
        if nodes is None:
            # 中文注释：后续引导页不是必出；没看到可处理页面时直接结束。
            result["error"] = last_error
            return result

        try:
            if find_ocr_node_by_value_equal(nodes, "Your story") is not None:
                result["home"] = True
                result["state"] = "home"
                return result

            if find_ocr_node_by_text(vp, nodes, "Please try again") is not None:
                # 中文注释：Allow and continue 后唯一硬失败条件是明确出现 Please try again。
                result["ok"] = False
                result["state"] = "please_try_again"
                result["error"] = "出现 Please try again"
                return result

            facebook_oauth_action = find_facebook_oauth_sign_in_action(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if facebook_oauth_action is not None:
                facebook_oauth_attempts += 1
                if facebook_oauth_attempts > max_same_page_attempts:
                    result["state"] = "facebook_oauth_max_attempts"
                    result["error"] = f"Facebook 登录确认弹窗处理超过最大次数 {max_same_page_attempts}"
                    return result
                result["found"] = True
                action_node = facebook_oauth_action.get("action_node")
                if not isinstance(action_node, dict):
                    raise LookupError("Facebook 登录确认弹窗缺少 Cancel OCR 坐标")
                cancel_clicked = click_ocr_node_with_delay(
                    vp,
                    action_node,
                    action_name="点击Facebook登录弹窗Cancel",
                    screen=screen,
                )
                result["clicked"] = True
                result["facebook_oauth_dialog"] = True
                result["facebook_oauth_cancel_clicked"] = cancel_clicked
                if not cancel_clicked:
                    result["ok"] = False
                    result["error"] = "点击 Facebook 登录弹窗 Cancel 失败"
                    return result
                wait_until_ocr_text_absent(
                    vp,
                    "facebook.com",
                    timeout=min(max(1.0, timeout), 5.0),
                    interval=interval,
                )
                continue

            profile_done_action = find_profile_setup_done_action(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if profile_done_action is not None:
                profile_done_attempts += 1
                if profile_done_attempts > max_same_page_attempts:
                    result["state"] = "profile_done_max_attempts"
                    result["error"] = f"资料页 Done 处理超过最大次数 {max_same_page_attempts}"
                    return result
                result["found"] = True
                action_node = profile_done_action.get("action_node")
                if not isinstance(action_node, dict):
                    raise LookupError("资料页缺少 Done OCR 坐标")
                done_clicked = click_ocr_node_with_delay(
                    vp,
                    action_node,
                    action_name="点击资料页Done",
                    screen=screen,
                )
                result["clicked"] = True
                result["profile_avatar_done_page"] = True
                result["profile_avatar_done_clicked"] = done_clicked
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not done_clicked:
                    result["ok"] = False
                    result["error"] = "点击资料页 Done 失败"
                    return result
                wait_until_ocr_text_absent(
                    vp,
                    str(profile_done_action.get("matched_text") or "Create a profile that shows"),
                    timeout=min(max(1.0, timeout), 5.0),
                    interval=interval,
                )
                continue

            free_with_ads_action = find_free_with_ads_action(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if free_with_ads_action is not None:
                result["found"] = True
                action_result = click_free_with_ads_action(
                    vp,
                    free_with_ads_action,
                    screen=screen,
                )
                for key in (
                    "free_with_ads_choice",
                    "free_with_ads_use_clicked",
                    "free_with_ads_continue_clicked",
                    "free_with_ads_agree",
                    "free_with_ads_agree_clicked",
                    "ad_experience_manage",
                    "ad_experience_ok_clicked",
                ):
                    result[key] = bool(action_result.get(key))
                result["clicked"] = True
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not bool(action_result.get("ok")):
                    result["ok"] = False
                    result["error"] = str(action_result.get("error") or "免费含广告链路点击失败")
                    return result
                continue

            photos_action = find_photos_access_action(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if photos_action is not None:
                result["found"] = True
                state = str(photos_action.get("state") or "")
                action_node = photos_action.get("action_node")
                if not isinstance(action_node, dict):
                    raise LookupError("照片权限页面缺少按钮 OCR 坐标")
                if state == "photos_permission_dialog":
                    result["photos_permission_dialog"] = True
                    clicked = click_ocr_node_with_delay(
                        vp,
                        action_node,
                        action_name="点击照片权限允许完整访问",
                        screen=screen,
                    )
                    result["photos_permission_allow_clicked"] = clicked
                    action_desc = "照片权限允许完整访问"
                else:
                    result["photos_access_page"] = True
                    clicked = click_ocr_node_with_delay(
                        vp,
                        action_node,
                        action_name="点击照片权限Continue",
                        screen=screen,
                    )
                    result["photos_access_continue_clicked"] = clicked
                    action_desc = "照片权限 Continue"
                result["clicked"] = True
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not clicked:
                    result["ok"] = False
                    result["error"] = f"点击 {action_desc} 失败"
                    return result
                continue

            ads_data_action = find_ads_data_consent_action(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if ads_data_action is not None:
                result["found"] = True
                action_node = ads_data_action.get("action_node")
                if not isinstance(action_node, dict):
                    raise LookupError("广告数据弹窗缺少 Get started OCR 坐标")
                clicked = click_ocr_node_with_delay(
                    vp,
                    action_node,
                    action_name="点击广告数据Get started",
                    screen=screen,
                )
                result["clicked"] = True
                result["ads_data_consent"] = True
                result["ads_data_get_started_clicked"] = clicked
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not clicked:
                    result["ok"] = False
                    result["error"] = "点击 Get started 失败"
                    return result
                continue

            cookies_action = find_cookies_action(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if cookies_action is not None:
                result["found"] = True
                action_node = cookies_action.get("action_node")
                if not isinstance(action_node, dict):
                    raise LookupError("Cookies 页面缺少 Allow all cookies OCR 坐标")
                clicked = click_ocr_node_with_delay(
                    vp,
                    action_node,
                    action_name="点击允许所有Cookies",
                    screen=screen,
                )
                result["clicked"] = True
                result["cookies_page"] = True
                result["cookies_allow_all_clicked"] = clicked
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not clicked:
                    result["ok"] = False
                    result["error"] = "点击 Allow all cookies 失败"
                    return result
                continue

            contacts_action = find_contacts_access_action(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if contacts_action is not None:
                result["found"] = True
                state = str(contacts_action.get("state") or "")
                action_node = contacts_action.get("action_node")
                if not isinstance(action_node, dict):
                    raise LookupError("联系人权限页面缺少按钮 OCR 坐标")
                if state == "contacts_permission_dialog":
                    result["contacts_permission_dialog"] = True
                    clicked = click_ocr_node_with_delay(
                        vp,
                        action_node,
                        action_name="点击联系人权限不允许",
                        screen=screen,
                    )
                    result["contacts_permission_denied_clicked"] = clicked
                    action_desc = "联系人权限不允许"
                else:
                    result["contacts_access"] = True
                    clicked = click_ocr_node_with_delay(
                        vp,
                        action_node,
                        action_name="点击联系人页Next",
                        screen=screen,
                    )
                    result["contacts_next_clicked"] = clicked
                    action_desc = "联系人页 Next"
                result["clicked"] = True
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not clicked:
                    result["ok"] = False
                    result["error"] = f"点击 {action_desc} 失败"
                    return result
                continue

            confirm_skip_node = find_skip_confirm_node(vp, nodes)
            if confirm_skip_node is not None:
                result["found"] = True
                result["confirm_found"] = True
                confirm_clicked = click_ocr_node_with_delay(
                    vp,
                    confirm_skip_node,
                    action_name="点击弹窗Skip",
                    screen=screen,
                )
                result["clicked"] = True
                result["confirm_clicked"] = confirm_clicked
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not confirm_clicked:
                    result["ok"] = False
                    result["error"] = "点击弹窗 Skip 失败"
                    return result
                continue

            facebook_suggestions_anchor = find_facebook_suggestions_page_anchor(vp, nodes)
            if facebook_suggestions_anchor is not None:
                facebook_suggestions_attempts += 1
                if facebook_suggestions_attempts > max_same_page_attempts:
                    result["state"] = "facebook_suggestions_max_attempts"
                    result["error"] = f"Facebook 找人页处理超过最大次数 {max_same_page_attempts}"
                    return result
                result["found"] = True
                result["facebook_suggestions"] = True
                skip_node, _ = find_generic_top_skip_node(
                    vp,
                    nodes,
                    width=inferred_width(nodes),
                    height=inferred_height(nodes),
                )
                if skip_node is None:
                    width = inferred_width(nodes)
                    height = inferred_height(nodes)
                    skip_node = synthetic_ocr_node("Skip", float(width) * 0.90, float(height) * 0.088)

                skip_clicked = click_ocr_node_with_delay(
                    vp,
                    skip_node,
                    action_name="点击Facebook建议Skip",
                    screen=screen,
                )
                if not skip_clicked:
                    result["ok"] = False
                    result["error"] = "点击 Facebook 建议 Skip 失败"
                    return result
                result["clicked"] = True
                result["facebook_skip_clicked"] = True
                if not handle_facebook_confirm_popup():
                    return result
                continue

            remember_node = find_ocr_node_by_text(vp, nodes, "Remember login info?")
            if remember_node is not None:
                result["found"] = True
                result["remember_login"] = True
                skip_node, _ = find_generic_top_skip_node(
                    vp,
                    nodes,
                    width=inferred_width(nodes),
                    height=inferred_height(nodes),
                )
                if skip_node is None:
                    raise LookupError("Remember login info 页面缺少 Skip OCR 坐标")
                skip_clicked = click_ocr_node_with_delay(
                    vp,
                    skip_node,
                    action_name="点击记住登录Skip",
                    screen=screen,
                )
                if not skip_clicked:
                    result["ok"] = False
                    result["error"] = "点击记住登录 Skip 失败"
                    return result
                result["clicked"] = True
                result["remember_skip_clicked"] = True
                wait_until_ocr_text_absent(
                    vp,
                    "Remember login info?",
                    timeout=min(max(1.0, timeout), 5.0),
                    interval=interval,
                )
                continue

            follow_anchor = find_recommended_follow_page_anchor(vp, nodes)
            if follow_anchor is not None:
                recommended_follow_attempts += 1
                if recommended_follow_attempts > max_same_page_attempts:
                    result["state"] = "recommended_follow_max_attempts"
                    result["error"] = f"推荐关注页处理超过最大次数 {max_same_page_attempts}"
                    return result
                matched_text, _follow_node = follow_anchor
                result["found"] = True
                result["recommended_follow"] = True
                bottom_follow_node = find_recommended_follow_action_node(
                    nodes,
                    width=inferred_width(nodes),
                    height=inferred_height(nodes),
                )
                action_value = ocr_node_value(bottom_follow_node) or "Next"
                follow_clicked = click_ocr_node_with_delay(
                    vp,
                    bottom_follow_node,
                    action_name=f"点击推荐关注{action_value}",
                    screen=screen,
                )
                if not follow_clicked:
                    result["ok"] = False
                    result["error"] = f"点击推荐关注 {action_value} 失败"
                    return result
                result["clicked"] = True
                result["recommended_follow_clicked"] = True
                result["recommended_follow_action"] = action_value
                wait_until_ocr_text_absent(
                    vp,
                    matched_text,
                    timeout=min(max(1.0, timeout), 5.0),
                    interval=interval,
                )
                continue

            pick_node = find_ocr_node_by_text(vp, nodes, "Pick what you want to see")
            if pick_node is not None:
                result["found"] = True
                result["pick_interests"] = True
                done_node = find_pick_interests_action_node(
                    nodes,
                    width=inferred_width(nodes),
                    height=inferred_height(nodes),
                )
                done_clicked = click_ocr_node_with_delay(
                    vp,
                    done_node,
                    action_name="点击兴趣页Done",
                    screen=screen,
                )
                if not done_clicked:
                    result["ok"] = False
                    result["error"] = "点击兴趣页 Done 失败"
                    return result
                result["clicked"] = True
                result["pick_interests_done_clicked"] = True
                wait_until_ocr_text_absent(
                    vp,
                    "Pick what you want to see",
                    timeout=min(max(1.0, timeout), 5.0),
                    interval=interval,
                )
                continue

            top_skip_node, _skip_matched_text = find_generic_top_skip_node(
                vp,
                nodes,
                width=inferred_width(nodes),
                height=inferred_height(nodes),
            )
            if top_skip_node is not None:
                generic_skip_attempts += 1
                if generic_skip_attempts > max_same_page_attempts:
                    result["state"] = "generic_skip_max_attempts"
                    result["error"] = f"通用 Skip 处理超过最大次数 {max_same_page_attempts}"
                    return result
                result["found"] = True
                skip_clicked = click_ocr_node_with_delay(
                    vp,
                    top_skip_node,
                    action_name="点击Skip",
                    screen=screen,
                )
                result["clicked"] = True
                result["generic_skip_count"] = int(result.get("generic_skip_count") or 0) + 1
                if not skip_clicked:
                    result["ok"] = False
                    result["error"] = "点击 Skip 失败"
                    return result
                continue

            return result
        except Exception as exc:
            result["ok"] = False
            result["error"] = str(exc)
            return result

    # 中文注释：防止引导页异常循环；正常情况下不会走到这里。
    # Allow and continue 后除 Please try again 外不作为硬失败；超过轮数就停止补充处理，继续账号 JSON 上报。
    result["ok"] = True
    result["state"] = "post_guide_max_pages"
    result["error"] = f"后续引导处理超过最大轮数 {max_pages}"
    return result


def handle_after_login_by_ocr(
    vp: VPhoneSession,
    *,
    max_retry_loops: int = 3,
    timeout: float = 30.0,
    interval: float = 0.5,
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：点击 Log in 后处理登录结果，最终只负责点击 Meta Horizon。
    # 1. 如果看到 Meta Horizon：随机等待后点击 Meta Horizon，并返回给主流程继续步骤 16/17/18。
    # 2. 如果同屏看到 Sign up + Try again：随机等待后点击 Try again，再随机等待后重新点击 Log in。
    # 3. 如果看到 Unable to log in 弹窗：点 OK 后重新点击 Log in。
    # 4. 重试最多循环 max_retry_loops 次。
    try_again_count = 0
    unable_login_ok_count = 0
    login_retry_count = 0
    last_state: dict[str, Any] | None = None
    meta_horizon_clicked = False

    while True:
        # 中文注释：每次 Log in 后先等待 1~2 秒，再读取 OCR 页面内容。
        random_action_delay()

        # 中文注释：判断页面内容是否出现 Meta Horizon，或同时出现 Sign up / Try again。
        log_start("判断登录后页面")
        try:
            state_resp = wait_for_after_login_state(vp, timeout=timeout, interval=interval)
        except Exception:
            log_done(False)
            raise
        state_ok = bool(state_resp.get("ok"))
        last_state = state_resp
        log_done(state_ok)
        if not state_ok:
            return {
                "ok": False,
                "state": str(state_resp.get("state") or "unknown"),
                "try_again_count": try_again_count,
                "unable_login_ok_count": unable_login_ok_count,
                "login_retry_count": login_retry_count,
                "meta_horizon_clicked": False,
                "error": str(state_resp.get("error") or "未识别到登录后页面状态"),
            }

        if state_resp.get("state") == "meta_horizon":
            # 中文注释：有 Meta Horizon 时点击账号 row；后续姓名页/用户名页/Allow 页在主流程步骤 16/17/18 处理。
            full_name_candidate = ""
            meta_horizon_node = state_resp.get("meta_horizon_node")
            state_nodes = state_resp.get("nodes")
            if isinstance(meta_horizon_node, dict) and isinstance(state_nodes, list):
                full_name_candidate = extract_meta_horizon_full_name(state_nodes, meta_horizon_node)
            random_action_delay()
            log_start("点击Meta Horizon")
            try:
                meta_horizon_clicked = tap_meta_horizon_and_confirm(
                    vp,
                    state_resp,
                    interval=interval,
                    screen=screen,
                )
            except Exception:
                log_done(False)
                raise
            log_done(meta_horizon_clicked)
            return {
                "ok": meta_horizon_clicked,
                "state": "meta_horizon",
                "try_again_count": try_again_count,
                "unable_login_ok_count": unable_login_ok_count,
                "login_retry_count": login_retry_count,
                "meta_horizon_clicked": meta_horizon_clicked,
                "full_name_candidate": full_name_candidate,
                "error": "" if meta_horizon_clicked else "点击 Meta Horizon 失败",
            }

        if state_resp.get("state") == "sign_up_try_again":
            if try_again_count >= max(0, max_retry_loops):
                log_start("登录重试次数")
                log_done(False)
                return {
                    "ok": False,
                    "state": "sign_up_try_again",
                    "try_again_count": try_again_count,
                    "unable_login_ok_count": unable_login_ok_count,
                    "login_retry_count": login_retry_count,
                    "meta_horizon_clicked": False,
                    "error": f"Try again -> Log in 已达到最大循环 {max_retry_loops} 次",
                }

            # 中文注释：同屏同时有 Sign up 和 Try again 时，先点击 Try again。
            random_action_delay()
            log_start("点击Try again")
            try:
                try_again_node = state_resp.get("try_again_node")
                if not isinstance(try_again_node, dict):
                    raise LookupError("Try again 缺少 OCR 坐标")
                try_again_resp = vp.ocr.tap(try_again_node, screen=screen, delay=500)
                try_again_ok = bool(try_again_resp.get("ok"))
            except Exception:
                log_done(False)
                raise
            log_done(try_again_ok)
            if not try_again_ok:
                return {
                    "ok": False,
                    "state": "sign_up_try_again",
                    "try_again_count": try_again_count,
                    "unable_login_ok_count": unable_login_ok_count,
                    "login_retry_count": login_retry_count,
                    "meta_horizon_clicked": False,
                    "error": "点击 Try again 失败",
                }
            try_again_count += 1

            # 中文注释：点击 Try again 后等待 1~2 秒，再重新点击 Log in。
            random_action_delay()
            log_start("点击Log in")
            try:
                login_resp = click_login_button(vp, timeout=timeout, interval=interval, screen=screen)
                login_retry_ok = bool(login_resp.get("ok"))
            except Exception:
                log_done(False)
                raise
            log_done(login_retry_ok)
            if not login_retry_ok:
                return {
                    "ok": False,
                    "state": "sign_up_try_again",
                    "try_again_count": try_again_count,
                    "unable_login_ok_count": unable_login_ok_count,
                    "login_retry_count": login_retry_count,
                    "meta_horizon_clicked": False,
                    "error": "重新点击 Log in 失败",
                }
            login_retry_count += 1
            continue

        if state_resp.get("state") == "unable_login_ok":
            if unable_login_ok_count >= max(0, max_retry_loops):
                log_start("登录重试次数")
                log_done(False)
                return {
                    "ok": False,
                    "state": "unable_login_ok",
                    "try_again_count": try_again_count,
                    "unable_login_ok_count": unable_login_ok_count,
                    "login_retry_count": login_retry_count,
                    "meta_horizon_clicked": False,
                    "error": f"Unable to log in -> OK -> Log in 已达到最大循环 {max_retry_loops} 次",
                }

            # 中文注释：Unable to log in 弹窗是临时登录失败；点 OK 关闭弹窗，再重按 Log in。
            random_action_delay()
            log_start("点击登录错误OK")
            try:
                ok_node = state_resp.get("ok_node")
                if not isinstance(ok_node, dict):
                    raise LookupError("Unable to log in 弹窗缺少 OK OCR 坐标")
                ok_resp = vp.ocr.tap(ok_node, screen=screen, delay=500)
                ok_clicked = bool(ok_resp.get("ok"))
            except Exception:
                log_done(False)
                raise
            log_done(ok_clicked)
            if not ok_clicked:
                return {
                    "ok": False,
                    "state": "unable_login_ok",
                    "try_again_count": try_again_count,
                    "unable_login_ok_count": unable_login_ok_count,
                    "login_retry_count": login_retry_count,
                    "meta_horizon_clicked": False,
                    "error": "点击 Unable to log in OK 失败",
                }
            unable_login_ok_count += 1

            random_action_delay()
            log_start("点击Log in")
            try:
                login_resp = click_login_button(vp, timeout=timeout, interval=interval, screen=screen)
                login_retry_ok = bool(login_resp.get("ok"))
            except Exception:
                log_done(False)
                raise
            log_done(login_retry_ok)
            if not login_retry_ok:
                return {
                    "ok": False,
                    "state": "unable_login_ok",
                    "try_again_count": try_again_count,
                    "unable_login_ok_count": unable_login_ok_count,
                    "login_retry_count": login_retry_count,
                    "meta_horizon_clicked": False,
                    "error": "重新点击 Log in 失败",
                }
            login_retry_count += 1
            continue

        return {
            "ok": False,
            "state": str(state_resp.get("state") or "unknown"),
            "try_again_count": try_again_count,
            "unable_login_ok_count": unable_login_ok_count,
            "login_retry_count": login_retry_count,
            "meta_horizon_clicked": meta_horizon_clicked,
            "last_state": last_state,
            "error": "未知登录后状态",
        }


def flow_debug_from_step19(
    vp: VPhoneSession,
    *,
    ui_timeout: float = 15.0,
    ui_interval: float = 0.5,
    profile_photo_dir: str | Path = DEFAULT_PROFILE_PHOTO_DIR,
    profile_photo_album: str = "VPhoneImports",
    screen: bool = False,
) -> dict[str, Any]:
    # 中文注释：临时调试入口：假设实例已经停在步骤 18 点击 Allow and continue 之后的页面，只执行步骤 19 及后续动作。
    profile_create_resp: dict[str, Any] = {
        "ok": False,
        "state": "",
        "matched_text": "",
        "error": "",
    }
    profile_create_ok = False
    profile_avatar_flow_required = False
    photos_deleted_ok = False
    profile_photo_import_ok = False
    selected_profile_photo: Path | None = None
    profile_avatar_clicked = False
    album_picker_resp: dict[str, Any] = {"ok": False, "state": "", "error": ""}
    album_picker_ok = False
    album_done_clicked = False
    avatar_upload_return_resp: dict[str, Any] = {"ok": False, "state": "", "matched_text": "", "error": ""}
    avatar_upload_return_ok = False
    final_done_clicked = False
    skip_resp: dict[str, Any] = {"ok": True, "found": False, "clicked": False, "error": ""}
    skip_check_ok = False

    # 步骤 19：点击 Allow and continue 后，同时等待创建资料结果：
    # Please try again = 失败；
    # Keep Instagram open to finish / Create a profile that shows / Add bio 任意一个出现 = 成功。
    # 只有 Create a profile that shows / Add bio 才继续执行头像流程。
    try:
        profile_create_resp = wait_for_profile_create_result_after_allow(
            vp,
            timeout=ui_timeout,
            interval=ui_interval,
            screen=screen,
        )
    except Exception:
        raise
    profile_create_ok = bool(profile_create_resp.get("ok"))
    if not profile_create_ok:
        raise RuntimeError(str(profile_create_resp.get("error") or "创建资料失败"))
    profile_avatar_flow_required = bool(profile_create_resp.get("avatar_flow_required"))
    if not profile_avatar_flow_required:
        # 中文注释：Keep Instagram open to finish 或 Allow 后一路自动 Skip 到首页时，都没有头像页，直接结束。
        skip_check_ok = True
        ok = True
        log_start("流程完成")
        log_done(ok)
        return {
            "ok": ok,
            "flow": "meta2ig_debug_from_step19",
            "profile_create": profile_create_ok,
            "profile_avatar_flow_required": profile_avatar_flow_required,
            "profile_create_state": str(profile_create_resp.get("state") or ""),
            "profile_create_matched_text": str(profile_create_resp.get("matched_text") or ""),
            "post_allow_skip_clicked": bool(profile_create_resp.get("post_allow_skip_clicked")),
            "post_allow_skip_count": int(profile_create_resp.get("post_allow_skip_count") or 0),
            "post_allow_free_with_ads_choice": bool(profile_create_resp.get("free_with_ads_choice")),
            "post_allow_free_with_ads_use_clicked": bool(profile_create_resp.get("free_with_ads_use_clicked")),
            "post_allow_free_with_ads_continue_clicked": bool(profile_create_resp.get("free_with_ads_continue_clicked")),
            "post_allow_free_with_ads_agree": bool(profile_create_resp.get("free_with_ads_agree")),
            "post_allow_free_with_ads_agree_clicked": bool(profile_create_resp.get("free_with_ads_agree_clicked")),
            "post_allow_ad_experience_manage": bool(profile_create_resp.get("ad_experience_manage")),
            "post_allow_ad_experience_ok_clicked": bool(profile_create_resp.get("ad_experience_ok_clicked")),
            "profile_create_error": str(profile_create_resp.get("error") or ""),
            "photos_deleted": photos_deleted_ok,
            "profile_photo_imported": profile_photo_import_ok,
            "profile_photo": "",
            "profile_photo_album": profile_photo_album,
            "profile_avatar_clicked": profile_avatar_clicked,
            "album_picker": album_picker_ok,
            "album_done_clicked": album_done_clicked,
            "avatar_upload_returned": avatar_upload_return_ok,
            "avatar_upload_return_state": "",
            "avatar_upload_return_matched_text": "",
            "avatar_upload_return_error": "",
            "avatar_upload_cancel_clicked": False,
            "avatar_upload_before_cancel_error": "",
            "profile_done_clicked": final_done_clicked,
            "avatar_done_clicked": final_done_clicked,
            "skip_found": bool(skip_resp.get("found")),
            "skip_clicked": bool(skip_resp.get("clicked")),
            "skip_confirm_found": bool(skip_resp.get("confirm_found")),
            "skip_confirm_clicked": bool(skip_resp.get("confirm_clicked")),
            "skip_facebook_suggestions": bool(skip_resp.get("facebook_suggestions")),
            "skip_facebook_clicked": bool(skip_resp.get("facebook_skip_clicked")),
            "skip_facebook_oauth_dialog": bool(skip_resp.get("facebook_oauth_dialog")),
            "skip_facebook_oauth_cancel_clicked": bool(skip_resp.get("facebook_oauth_cancel_clicked")),
            "skip_remember_login": bool(skip_resp.get("remember_login")),
            "skip_remember_clicked": bool(skip_resp.get("remember_skip_clicked")),
            "recommended_follow": bool(skip_resp.get("recommended_follow")),
            "recommended_follow_clicked": bool(skip_resp.get("recommended_follow_clicked")),
            "recommended_follow_action": str(skip_resp.get("recommended_follow_action") or ""),
            "pick_interests": bool(skip_resp.get("pick_interests")),
            "pick_interests_done_clicked": bool(skip_resp.get("pick_interests_done_clicked")),
            "profile_avatar_done_page": bool(skip_resp.get("profile_avatar_done_page")),
            "profile_avatar_done_clicked": bool(skip_resp.get("profile_avatar_done_clicked")),
            "free_with_ads_choice": bool(skip_resp.get("free_with_ads_choice")),
            "free_with_ads_use_clicked": bool(skip_resp.get("free_with_ads_use_clicked")),
            "free_with_ads_continue_clicked": bool(skip_resp.get("free_with_ads_continue_clicked")),
            "free_with_ads_agree": bool(skip_resp.get("free_with_ads_agree")),
            "free_with_ads_agree_clicked": bool(skip_resp.get("free_with_ads_agree_clicked")),
            "ad_experience_manage": bool(skip_resp.get("ad_experience_manage")),
            "ad_experience_ok_clicked": bool(skip_resp.get("ad_experience_ok_clicked")),
            "contacts_access": bool(skip_resp.get("contacts_access")),
            "contacts_next_clicked": bool(skip_resp.get("contacts_next_clicked")),
            "contacts_permission_dialog": bool(skip_resp.get("contacts_permission_dialog")),
            "contacts_permission_denied_clicked": bool(skip_resp.get("contacts_permission_denied_clicked")),
            "ads_data_consent": bool(skip_resp.get("ads_data_consent")),
            "ads_data_get_started_clicked": bool(skip_resp.get("ads_data_get_started_clicked")),
            "cookies_page": bool(skip_resp.get("cookies_page")),
            "cookies_allow_all_clicked": bool(skip_resp.get("cookies_allow_all_clicked")),
            "entered_home": str(profile_create_resp.get("state") or "") == "home",
            "skip_error": str(skip_resp.get("error") or ""),
        }

    # 步骤 20：点击头像前，先通过 vphonekit.photos 清空实例所有相册。
    random_action_delay()
    log_start("清空相册")
    try:
        photos_delete_resp = vp.photos.delete_all(yes=True)
        photos_deleted_ok = bool(photos_delete_resp.get("ok"))
    except Exception:
        log_done(False)
        raise
    log_done(photos_deleted_ok)
    if not photos_deleted_ok:
        raise RuntimeError("清空相册失败")

    # 步骤 21：从头像素材目录随机取一张图片导入到实例相册。
    random_action_delay()
    log_start("导入头像照片")
    try:
        profile_photo_import_resp, selected_profile_photo = import_profile_photo_with_retry(
            vp,
            photo_dir=profile_photo_dir,
            album=profile_photo_album,
        )
        profile_photo_import_ok = bool(profile_photo_import_resp.get("ok"))
    except Exception:
        log_done(False)
        raise
    log_done(profile_photo_import_ok)
    if profile_photo_import_ok:
        print(f"照片信息：{selected_profile_photo}", flush=True)
    if not profile_photo_import_ok:
        raise RuntimeError("导入头像照片失败")

    # 步骤 22：相册准备好后，点击屏幕中间的头像。
    try:
        profile_avatar_clicked = click_profile_avatar(
            vp,
            profile_create_resp,
            screen=screen,
        )
    except Exception:
        raise
    if not profile_avatar_clicked:
        raise RuntimeError("点击头像失败")

    # 步骤 23：判断是否进入相册；同屏同时有 Library 和 Done 才算进入成功。
    log_start("等待进入相册")
    try:
        album_picker_resp = wait_for_album_picker(
            vp,
            timeout=ui_timeout,
            interval=ui_interval,
            screen=screen,
        )
    except Exception:
        log_done(False)
        raise
    album_picker_ok = bool(album_picker_resp.get("ok"))
    log_done(album_picker_ok)
    if not album_picker_ok:
        raise RuntimeError(str(album_picker_resp.get("error") or "未进入相册"))

    # 步骤 24：进入相册后，点击相册右上角 Done，触发头像上传。
    try:
        album_done_clicked = click_done_from_state(
            vp,
            album_picker_resp,
            action_name="点击相册Done",
            screen=screen,
        )
    except Exception:
        raise
    if not album_done_clicked:
        raise RuntimeError("点击相册 Done 失败")

    # 步骤 25：头像上传会触发网络请求；先等 30 秒自动返回资料页；超时则点 Cancel 手动返回。
    try:
        avatar_upload_return_resp = wait_profile_page_done_with_cancel_fallback(
            vp,
            upload_timeout=30.0,
            after_cancel_timeout=ui_timeout,
            interval=ui_interval,
            screen=screen,
        )
    except Exception:
        raise
    avatar_upload_return_ok = bool(avatar_upload_return_resp.get("ok"))
    if not avatar_upload_return_ok:
        raise RuntimeError(str(avatar_upload_return_resp.get("error") or "头像上传后未回到资料页"))

    # 步骤 26：回到资料创建页后，点击这个页面的 Done。
    try:
        final_done_clicked = click_done_from_state(
            vp,
            avatar_upload_return_resp,
            action_name="点击资料页Done",
            screen=screen,
        )
    except Exception:
        raise
    if not final_done_clicked:
        raise RuntimeError("点击资料页 Done 失败")

    # 步骤 27：处理资料页 Done 后的引导页：
    # Get Facebook suggestions -> Skip -> 弹窗 Skip；
    # Remember login info? -> Skip；
    # Try following 5+ people / Follow 5 or more people -> 底部 Follow/Next；
    # Pick what you want to see -> 底部 Done；
    # 免费含广告链路 -> Use free of charge with ads -> Continue -> Agree -> OK；
    # Your story -> 已进入首页。
    try:
        skip_resp = click_skip_if_present(
            vp,
            timeout=ui_timeout,
            interval=ui_interval,
            screen=screen,
        )
    except Exception:
        raise
    skip_check_ok = bool(skip_resp.get("ok"))
    if not skip_check_ok:
        raise RuntimeError(str(skip_resp.get("error") or "点击 Skip 失败"))

    ok = (
        profile_create_ok
        and photos_deleted_ok
        and profile_photo_import_ok
        and profile_avatar_clicked
        and album_picker_ok
        and album_done_clicked
        and avatar_upload_return_ok
        and final_done_clicked
        and skip_check_ok
    )
    log_start("流程完成")
    log_done(ok)
    return {
        "ok": ok,
        "flow": "meta2ig_debug_from_step19",
        "profile_create": profile_create_ok,
        "profile_create_state": str(profile_create_resp.get("state") or ""),
        "profile_create_matched_text": str(profile_create_resp.get("matched_text") or ""),
        "post_allow_skip_clicked": bool(profile_create_resp.get("post_allow_skip_clicked")),
        "post_allow_skip_count": int(profile_create_resp.get("post_allow_skip_count") or 0),
        "post_allow_free_with_ads_choice": bool(profile_create_resp.get("free_with_ads_choice")),
        "post_allow_free_with_ads_use_clicked": bool(profile_create_resp.get("free_with_ads_use_clicked")),
        "post_allow_free_with_ads_continue_clicked": bool(profile_create_resp.get("free_with_ads_continue_clicked")),
        "post_allow_free_with_ads_agree": bool(profile_create_resp.get("free_with_ads_agree")),
        "post_allow_free_with_ads_agree_clicked": bool(profile_create_resp.get("free_with_ads_agree_clicked")),
        "post_allow_ad_experience_manage": bool(profile_create_resp.get("ad_experience_manage")),
        "post_allow_ad_experience_ok_clicked": bool(profile_create_resp.get("ad_experience_ok_clicked")),
        "post_allow_photos_access_page": bool(profile_create_resp.get("photos_access_page")),
        "post_allow_photos_access_continue_clicked": bool(profile_create_resp.get("photos_access_continue_clicked")),
        "post_allow_photos_permission_dialog": bool(profile_create_resp.get("photos_permission_dialog")),
        "post_allow_photos_permission_allow_clicked": bool(profile_create_resp.get("photos_permission_allow_clicked")),
        "post_allow_contacts_access": bool(profile_create_resp.get("contacts_access")),
        "post_allow_contacts_next_clicked": bool(profile_create_resp.get("contacts_next_clicked")),
        "post_allow_contacts_permission_dialog": bool(profile_create_resp.get("contacts_permission_dialog")),
        "post_allow_contacts_permission_denied_clicked": bool(profile_create_resp.get("contacts_permission_denied_clicked")),
        "post_allow_ads_data_consent": bool(profile_create_resp.get("ads_data_consent")),
        "post_allow_ads_data_get_started_clicked": bool(profile_create_resp.get("ads_data_get_started_clicked")),
        "post_allow_cookies_page": bool(profile_create_resp.get("cookies_page")),
        "post_allow_cookies_allow_all_clicked": bool(profile_create_resp.get("cookies_allow_all_clicked")),
        "profile_create_error": str(profile_create_resp.get("error") or ""),
        "photos_deleted": photos_deleted_ok,
        "profile_photo_imported": profile_photo_import_ok,
        "profile_photo": str(selected_profile_photo) if selected_profile_photo else "",
        "profile_photo_album": profile_photo_album,
        "profile_avatar_clicked": profile_avatar_clicked,
        "album_picker": album_picker_ok,
        "album_done_clicked": album_done_clicked,
        "avatar_upload_returned": avatar_upload_return_ok,
        "avatar_upload_return_state": str(avatar_upload_return_resp.get("state") or ""),
        "avatar_upload_return_matched_text": str(avatar_upload_return_resp.get("matched_text") or ""),
        "avatar_upload_return_error": str(avatar_upload_return_resp.get("error") or ""),
        "avatar_upload_cancel_clicked": bool(avatar_upload_return_resp.get("cancel_clicked")),
        "avatar_upload_before_cancel_error": str(avatar_upload_return_resp.get("before_cancel_error") or ""),
        "profile_done_clicked": final_done_clicked,
        "avatar_done_clicked": final_done_clicked,
        "skip_found": bool(skip_resp.get("found")),
        "skip_clicked": bool(skip_resp.get("clicked")),
        "skip_confirm_found": bool(skip_resp.get("confirm_found")),
        "skip_confirm_clicked": bool(skip_resp.get("confirm_clicked")),
        "skip_facebook_suggestions": bool(skip_resp.get("facebook_suggestions")),
        "skip_facebook_clicked": bool(skip_resp.get("facebook_skip_clicked")),
        "skip_facebook_oauth_dialog": bool(skip_resp.get("facebook_oauth_dialog")),
        "skip_facebook_oauth_cancel_clicked": bool(skip_resp.get("facebook_oauth_cancel_clicked")),
        "skip_remember_login": bool(skip_resp.get("remember_login")),
        "skip_remember_clicked": bool(skip_resp.get("remember_skip_clicked")),
        "recommended_follow": bool(skip_resp.get("recommended_follow")),
        "recommended_follow_clicked": bool(skip_resp.get("recommended_follow_clicked")),
        "recommended_follow_action": str(skip_resp.get("recommended_follow_action") or ""),
        "pick_interests": bool(skip_resp.get("pick_interests")),
        "pick_interests_done_clicked": bool(skip_resp.get("pick_interests_done_clicked")),
        "profile_avatar_done_page": bool(skip_resp.get("profile_avatar_done_page")),
        "profile_avatar_done_clicked": bool(skip_resp.get("profile_avatar_done_clicked")),
        "free_with_ads_choice": bool(skip_resp.get("free_with_ads_choice")),
        "free_with_ads_use_clicked": bool(skip_resp.get("free_with_ads_use_clicked")),
        "free_with_ads_continue_clicked": bool(skip_resp.get("free_with_ads_continue_clicked")),
        "free_with_ads_agree": bool(skip_resp.get("free_with_ads_agree")),
        "free_with_ads_agree_clicked": bool(skip_resp.get("free_with_ads_agree_clicked")),
        "ad_experience_manage": bool(skip_resp.get("ad_experience_manage")),
        "ad_experience_ok_clicked": bool(skip_resp.get("ad_experience_ok_clicked")),
        "photos_access_page": bool(skip_resp.get("photos_access_page")),
        "photos_access_continue_clicked": bool(skip_resp.get("photos_access_continue_clicked")),
        "photos_permission_dialog": bool(skip_resp.get("photos_permission_dialog")),
        "photos_permission_allow_clicked": bool(skip_resp.get("photos_permission_allow_clicked")),
        "contacts_access": bool(skip_resp.get("contacts_access")),
        "contacts_next_clicked": bool(skip_resp.get("contacts_next_clicked")),
        "contacts_permission_dialog": bool(skip_resp.get("contacts_permission_dialog")),
        "contacts_permission_denied_clicked": bool(skip_resp.get("contacts_permission_denied_clicked")),
        "ads_data_consent": bool(skip_resp.get("ads_data_consent")),
        "ads_data_get_started_clicked": bool(skip_resp.get("ads_data_get_started_clicked")),
        "cookies_page": bool(skip_resp.get("cookies_page")),
        "cookies_allow_all_clicked": bool(skip_resp.get("cookies_allow_all_clicked")),
        "entered_home": bool(skip_resp.get("home")),
        "skip_error": str(skip_resp.get("error") or ""),
    }


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
    proxy_retry_attempts: int = 4,
    proxy_retry_delay: float = 3.0,
    new_device_retry_attempts: int = 4,
    new_device_retry_delay: float = 3.0,
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
    login_retry_limit: int = 3,
    profile_photo_dir: str | Path = DEFAULT_PROFILE_PHOTO_DIR,
    profile_photo_album: str = "VPhoneImports",
    account_json_path: str = DEFAULT_INSTAGRAM_ACCOUNT_JSON_PATH,
    report_url: str = DEFAULT_SECONDARY_ACCOUNT_REPORT_URL,
    report_enabled: bool = True,
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

    # 中文注释：每次设置代理前，把默认代理里的 username 占位符替换成随机 8 位大小写字母/数字，并输出最终代理。
    runtime_proxy, proxy_random_username = render_proxy_url(proxy)
    print(f"代理信息：{runtime_proxy}", flush=True)

    # 步骤 3：设置代理
    log_start("设置代理")
    try:
        proxy_resp = set_instance_proxy_with_retry(
            vp,
            proxy=runtime_proxy,
            test=proxy_test,
            no_restart=no_restart,
            attempts=proxy_retry_attempts,
            retry_delay=proxy_retry_delay,
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
            attempts=new_device_retry_attempts,
            retry_delay=new_device_retry_delay,
        )
    except Exception:
        log_done(False)
        raise
    log_done(bool(new_device_resp.get("ok")))

    # 步骤 5：只用 OCR 等待当前屏幕出现启动页 Log in / Create new account / I already have a profile，最大等待 ui_timeout 秒。
    log_start("等待Instagram入口按钮")
    try:
        entry_resp = wait_for_instagram_entry_branch(
            vp,
            timeout=30,
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
    landing_login_clicked = False
    meta_account: dict[str, Any] | None = None
    username_node: dict[str, Any] | None = None
    username_input_ok = False
    password_input_ok = False
    email_verified = False
    login_click_ok = False
    after_login_resp: dict[str, Any] = {
        "ok": False,
        "state": "",
        "try_again_count": 0,
        "unable_login_ok_count": 0,
        "login_retry_count": 0,
        "meta_horizon_clicked": False,
        "full_name_candidate": "",
        "error": "",
    }
    name_next_ok = False
    registered_full_name = ""
    username_next_ok = False
    registered_username = ""
    allow_and_continue_ok = False
    profile_create_resp: dict[str, Any] = {
        "ok": False,
        "state": "",
        "matched_text": "",
        "error": "",
    }
    profile_create_ok = False
    profile_avatar_flow_required = False
    photos_deleted_ok = False
    profile_photo_import_ok = False
    selected_profile_photo: Path | None = None
    profile_avatar_clicked = False
    album_picker_resp: dict[str, Any] = {"ok": False, "state": "", "error": ""}
    album_picker_ok = False
    album_done_clicked = False
    avatar_upload_return_resp: dict[str, Any] = {"ok": False, "state": "", "matched_text": "", "error": ""}
    avatar_upload_return_ok = False
    final_done_clicked = False
    skip_resp: dict[str, Any] = {"ok": True, "found": False, "clicked": False, "error": ""}
    skip_check_ok = False
    post_success_handling_error = ""
    post_success_handling_optional_ok = True
    post_allow_hard_failure = False
    post_allow_hard_failure_error = ""
    report_resp: dict[str, Any] = {"ok": not report_enabled, "status": 0, "error": ""}
    report_attempted = False
    report_ok = not report_enabled
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
    elif entry_resp.get("branch") == "landing_login":
        # 中文注释：适配新版启动页：Sign up / Continue without an account / Log in。
        # 这里必须先点启动页的 Log in，后面步骤 7 才能找到 Username / Mobile number or email 输入框。
        log_start("点击启动页Log in")
        try:
            login_node = entry_resp.get("login_node")
            if not isinstance(login_node, dict):
                raise LookupError("启动页 Log in 缺少 OCR 坐标")
            landing_login_resp = vp.ocr.tap(login_node, screen=screen, delay=500)
            landing_login_clicked = bool(landing_login_resp.get("ok"))
        except Exception:
            log_done(False)
            raise
        log_done(landing_login_clicked)
        if not landing_login_clicked:
            raise RuntimeError("点击启动页 Log in 失败")
    elif entry_resp.get("branch") == "login_or_create":
        # 中文注释：当前已经在登录表单分支；这里不做任何点击，直接进入步骤 7 查 Username。
        pass

    # 步骤 7：等待登录表单里的账号输入框；Instagram 有时显示 Username，有时显示 Mobile number or email。
    log_start("等待Username输入框")
    try:
        username_node = wait_for_ocr_any_text(
            vp,
            ["username", "Mobile number or email"],
            timeout=ui_timeout,
            interval=ui_interval,
        )
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

    # 步骤 13：暂时跳过 Meta 邮箱 OCR 完整校验；后续需要时再恢复下面这段。
    email_verified = True
    # log_start("校验Meta邮箱")
    # try:
    #     email_verify_node = wait_for_exact_ocr_value(
    #         vp,
    #         str(meta_account["email"]),
    #         timeout=ui_timeout,
    #         interval=ui_interval,
    #     )
    #     email_verified = bool(email_verify_node)
    # except Exception:
    #     log_done(False)
    #     raise
    # log_done(email_verified)
    # if not email_verified:
    #     raise RuntimeError("OCR 校验 Meta 邮箱失败")

    # 步骤 14：点击 Log in
    log_start("点击Log in")
    try:
        login_resp = click_login_button(vp, timeout=ui_timeout, interval=ui_interval, screen=screen)
        login_click_ok = bool(login_resp.get("ok"))
    except Exception:
        log_done(False)
        raise
    log_done(login_click_ok)
    if not login_click_ok:
        raise RuntimeError("点击 Log in 失败")

    # 步骤 15：点击 Log in 后判断页面并点击 Meta Horizon：
    # 如果看到 Meta Horizon，则直接点击 Meta Horizon；
    # 如果同屏同时看到 Sign up 和 Try again，则点击 Try again 后再重复点击 Log in，最多循环 3 次。
    try:
        after_login_resp = handle_after_login_by_ocr(
            vp,
            max_retry_loops=login_retry_limit,
            timeout=ui_timeout,
            interval=ui_interval,
            screen=screen,
        )
    except Exception:
        raise
    after_login_ok = bool(after_login_resp.get("ok"))
    registered_full_name = str(after_login_resp.get("full_name_candidate") or "").strip()

    # 步骤 16：Meta Horizon 点击成功后，等待姓名页出现 “What's your name?” 和 “Next”，然后点击姓名页 Next。
    if after_login_ok:
        try:
            name_next_resp = click_name_page_next_with_info(
                vp,
                timeout=ui_timeout,
                interval=ui_interval,
                screen=screen,
            )
        except Exception:
            raise
        name_next_ok = bool(name_next_resp.get("ok"))
        name_page_full_name = str(name_next_resp.get("full_name") or "").strip()
        if name_page_full_name:
            registered_full_name = name_page_full_name
        print(f"OCR full_name：{registered_full_name or '<empty>'}", flush=True)
        if not name_next_ok:
            raise RuntimeError("点击姓名页 Next 失败")
        if not registered_full_name:
            raise RuntimeError("OCR 提取 full_name 失败")

    # 步骤 17：等待用户名页出现 “Create a username for Instagram” 和 “Next”，然后点击用户名页 Next。
    if after_login_ok and name_next_ok:
        try:
            username_next_resp = click_username_page_next_with_info(
                vp,
                timeout=ui_timeout,
                interval=ui_interval,
                screen=screen,
            )
        except Exception:
            raise
        username_next_ok = bool(username_next_resp.get("ok"))
        registered_username = str(username_next_resp.get("username") or "").strip()
        print(f"OCR username：{registered_username or '<empty>'}", flush=True)
        if not username_next_ok:
            raise RuntimeError("点击用户名页 Next 失败")
        if not registered_username:
            raise RuntimeError("OCR 提取 username 失败")

    # 步骤 18：等待 “Allow and continue” 出现，然后点击 Allow and continue。
    if after_login_ok and name_next_ok and username_next_ok:
        try:
            allow_and_continue_ok = click_allow_and_continue(
                vp,
                timeout=ui_timeout,
                interval=ui_interval,
                screen=screen,
            )
        except Exception:
            raise
        if not allow_and_continue_ok:
            raise RuntimeError("点击 Allow and continue 失败")

    # 步骤 19：点击 Allow and continue 后，同时等待创建资料结果：
    # Please try again = 失败；
    # Keep Instagram open to finish / Create a profile that shows / Add bio 任意一个出现 = 成功。
    # 只有 Create a profile that shows / Add bio 才继续执行头像流程。
    if after_login_ok and name_next_ok and username_next_ok and allow_and_continue_ok:
        try:
            profile_create_resp = wait_for_profile_create_result_after_allow(
                vp,
                timeout=ui_timeout,
                interval=ui_interval,
                screen=screen,
            )
        except Exception as exc:
            # 中文注释：Allow 后的头像/广告/联系人/cookies 等成功后链路是非关键链路。
            # 这里失败不再中断，后续继续等待并上报账号 JSON。
            profile_create_resp = {
                "ok": False,
                "state": "post_allow_exception",
                "matched_text": "",
                "error": str(exc),
            }
            post_success_handling_optional_ok = False
            post_success_handling_error = str(exc)
        if str(profile_create_resp.get("state") or "") == "please_try_again":
            post_allow_hard_failure = True
            post_allow_hard_failure_error = str(profile_create_resp.get("error") or "出现 Please try again")
            raise RuntimeError(post_allow_hard_failure_error)

        profile_create_ok = bool(profile_create_resp.get("ok"))
        if not profile_create_ok:
            post_success_handling_optional_ok = False
            post_success_handling_error = str(profile_create_resp.get("error") or "创建资料后续链路处理失败")
        profile_avatar_flow_required = bool(profile_create_resp.get("avatar_flow_required"))
        if not profile_avatar_flow_required:
            # 中文注释：Keep Instagram open to finish 或 Allow 后一路 Skip 直接进入首页时，都没有头像设置页。
            skip_check_ok = True

    # 步骤 20：点击头像前，先通过 vphonekit.photos 清空实例所有相册。
    if profile_create_ok and profile_avatar_flow_required:
        random_action_delay()
        log_start("清空相册")
        try:
            photos_delete_resp = vp.photos.delete_all(yes=True)
            photos_deleted_ok = bool(photos_delete_resp.get("ok"))
        except Exception as exc:
            log_done(False)
            post_success_handling_optional_ok = False
            post_success_handling_error = f"清空相册失败: {exc}"
            photos_deleted_ok = False
        else:
            log_done(photos_deleted_ok)
        if not photos_deleted_ok:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or "清空相册失败"

    # 步骤 21：从头像素材目录随机取一张图片导入到实例相册。
    if profile_create_ok and photos_deleted_ok:
        random_action_delay()
        log_start("导入头像照片")
        try:
            profile_photo_import_resp, selected_profile_photo = import_profile_photo_with_retry(
                vp,
                photo_dir=profile_photo_dir,
                album=profile_photo_album,
            )
            profile_photo_import_ok = bool(profile_photo_import_resp.get("ok"))
        except Exception as exc:
            log_done(False)
            post_success_handling_optional_ok = False
            post_success_handling_error = f"导入头像照片失败: {exc}"
            profile_photo_import_ok = False
        else:
            log_done(profile_photo_import_ok)
        if profile_photo_import_ok:
            print(f"照片信息：{selected_profile_photo}", flush=True)
        if not profile_photo_import_ok:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or "导入头像照片失败"

    # 步骤 21.5：页面顺序不固定，导入头像期间可能插入广告/cookies/联系人/推荐关注等页。
    # 点击头像前重新跑一次 post-allow 页面处理，确保当前仍是头像页；如果已经进首页/非头像成功页，就跳过头像上传。
    if profile_create_ok and profile_avatar_flow_required and photos_deleted_ok and profile_photo_import_ok:
        try:
            refreshed_profile_resp = wait_for_profile_create_result_after_allow(
                vp,
                timeout=min(max(5.0, ui_timeout), 20.0),
                interval=ui_interval,
                screen=screen,
            )
        except Exception as exc:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or f"刷新头像页状态失败: {exc}"
        else:
            if bool(refreshed_profile_resp.get("ok")):
                profile_create_resp = refreshed_profile_resp
                profile_avatar_flow_required = bool(refreshed_profile_resp.get("avatar_flow_required"))
                if not profile_avatar_flow_required:
                    skip_check_ok = True
            else:
                post_success_handling_optional_ok = False
                post_success_handling_error = post_success_handling_error or str(
                    refreshed_profile_resp.get("error") or "刷新头像页状态失败"
                )

    # 步骤 22：相册准备好后，点击屏幕中间的头像。
    if profile_create_ok and profile_avatar_flow_required and photos_deleted_ok and profile_photo_import_ok:
        try:
            profile_avatar_clicked = click_profile_avatar(
                vp,
                profile_create_resp,
                screen=screen,
            )
        except Exception as exc:
            post_success_handling_optional_ok = False
            post_success_handling_error = f"点击头像失败: {exc}"
            profile_avatar_clicked = False
        if not profile_avatar_clicked:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or "点击头像失败"

    # 步骤 23：判断是否进入相册；同屏同时有 Library 和 Done 才算进入成功。
    if profile_create_ok and photos_deleted_ok and profile_photo_import_ok and profile_avatar_clicked:
        log_start("等待进入相册")
        try:
            album_picker_resp = wait_for_album_picker(
                vp,
                timeout=ui_timeout,
                interval=ui_interval,
                screen=screen,
            )
        except Exception as exc:
            log_done(False)
            post_success_handling_optional_ok = False
            post_success_handling_error = f"等待进入相册失败: {exc}"
            album_picker_ok = False
        else:
            album_picker_ok = bool(album_picker_resp.get("ok"))
            log_done(album_picker_ok)
        if not album_picker_ok:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or str(album_picker_resp.get("error") or "未进入相册")

    # 步骤 24：进入相册后，点击相册右上角 Done，触发头像上传。
    if profile_create_ok and photos_deleted_ok and profile_photo_import_ok and profile_avatar_clicked and album_picker_ok:
        try:
            album_done_clicked = click_done_from_state(
                vp,
                album_picker_resp,
                action_name="点击相册Done",
                screen=screen,
            )
        except Exception as exc:
            post_success_handling_optional_ok = False
            post_success_handling_error = f"点击相册 Done 失败: {exc}"
            album_done_clicked = False
        if not album_done_clicked:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or "点击相册 Done 失败"

    # 步骤 25：头像上传会触发网络请求；先等 30 秒自动返回资料页；超时则点 Cancel 手动返回。
    if (
        profile_create_ok
        and photos_deleted_ok
        and profile_photo_import_ok
        and profile_avatar_clicked
        and album_picker_ok
        and album_done_clicked
    ):
        try:
            avatar_upload_return_resp = wait_profile_page_done_with_cancel_fallback(
                vp,
                upload_timeout=30.0,
                after_cancel_timeout=ui_timeout,
                interval=ui_interval,
                screen=screen,
            )
        except Exception as exc:
            post_success_handling_optional_ok = False
            post_success_handling_error = f"头像上传后返回资料页失败: {exc}"
            avatar_upload_return_ok = False
        else:
            avatar_upload_return_ok = bool(avatar_upload_return_resp.get("ok"))
        if str(avatar_upload_return_resp.get("state") or "") == "please_try_again":
            post_allow_hard_failure = True
            post_allow_hard_failure_error = str(avatar_upload_return_resp.get("error") or "出现 Please try again")
            raise RuntimeError(post_allow_hard_failure_error)
        if not avatar_upload_return_ok:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or str(avatar_upload_return_resp.get("error") or "头像上传后未回到资料页")

    # 步骤 26：回到资料创建页后，点击这个页面的 Done。
    if (
        profile_create_ok
        and photos_deleted_ok
        and profile_photo_import_ok
        and profile_avatar_clicked
        and album_picker_ok
        and album_done_clicked
        and avatar_upload_return_ok
    ):
        try:
            final_done_clicked = click_done_from_state(
                vp,
                avatar_upload_return_resp,
                action_name="点击资料页Done",
                screen=screen,
            )
        except Exception as exc:
            post_success_handling_optional_ok = False
            post_success_handling_error = f"点击资料页 Done 失败: {exc}"
            final_done_clicked = False
        if not final_done_clicked:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or "点击资料页 Done 失败"

    # 步骤 27：处理资料页 Done 后的引导页：
    # Get Facebook suggestions -> Skip -> 弹窗 Skip；
    # Remember login info? -> Skip；
    # Try following 5+ people / Follow 5 or more people -> 底部 Follow/Next；
    # Pick what you want to see -> 底部 Done；
    # 免费含广告链路 -> Use free of charge with ads -> Continue -> Agree -> OK；
    # Your story -> 已进入首页。
    if (
        profile_create_ok
        and photos_deleted_ok
        and profile_photo_import_ok
        and profile_avatar_clicked
        and album_picker_ok
        and album_done_clicked
        and avatar_upload_return_ok
        and final_done_clicked
    ):
        try:
            skip_resp = click_skip_if_present(
                vp,
                timeout=ui_timeout,
                interval=ui_interval,
                screen=screen,
            )
        except Exception as exc:
            post_success_handling_optional_ok = False
            post_success_handling_error = f"处理后续引导失败: {exc}"
            skip_resp = {"ok": False, "found": False, "clicked": False, "error": str(exc)}
            skip_check_ok = False
        else:
            skip_check_ok = bool(skip_resp.get("ok"))
        if str(skip_resp.get("state") or "") == "please_try_again":
            post_allow_hard_failure = True
            post_allow_hard_failure_error = str(skip_resp.get("error") or "出现 Please try again")
            raise RuntimeError(post_allow_hard_failure_error)
        if not skip_check_ok:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or str(skip_resp.get("error") or "点击 Skip 失败")

    # 步骤 27.5：Allow 后页面顺序不固定；头像页、广告授权、cookies、联系人、推荐关注等可能前后穿插。
    # 无论上面的头像/引导处理是否成功，都再做一次非阻塞后续引导扫描；失败也不影响账号 JSON 上报。
    if allow_and_continue_ok and not bool(skip_resp.get("home")):
        try:
            extra_skip_resp = click_skip_if_present(
                vp,
                timeout=min(max(5.0, ui_timeout), 20.0),
                interval=ui_interval,
                screen=screen,
            )
        except Exception as exc:
            post_success_handling_optional_ok = False
            post_success_handling_error = post_success_handling_error or f"补充处理后续引导失败: {exc}"
        else:
            for key in (
                "found",
                "clicked",
                "confirm_found",
                "confirm_clicked",
                "facebook_suggestions",
                "facebook_skip_clicked",
                "facebook_oauth_dialog",
                "facebook_oauth_cancel_clicked",
                "remember_login",
                "remember_skip_clicked",
                "recommended_follow",
                "recommended_follow_clicked",
                "pick_interests",
                "pick_interests_done_clicked",
                "profile_avatar_done_page",
                "profile_avatar_done_clicked",
                "free_with_ads_choice",
                "free_with_ads_use_clicked",
                "free_with_ads_continue_clicked",
                "free_with_ads_agree",
                "free_with_ads_agree_clicked",
                "ad_experience_manage",
                "ad_experience_ok_clicked",
                "photos_access_page",
                "photos_access_continue_clicked",
                "photos_permission_dialog",
                "photos_permission_allow_clicked",
                "contacts_access",
                "contacts_next_clicked",
                "contacts_permission_dialog",
                "contacts_permission_denied_clicked",
                "ads_data_consent",
                "ads_data_get_started_clicked",
                "cookies_page",
                "cookies_allow_all_clicked",
                "home",
            ):
                skip_resp[key] = bool(skip_resp.get(key)) or bool(extra_skip_resp.get(key))
            if not skip_resp.get("recommended_follow_action"):
                skip_resp["recommended_follow_action"] = str(extra_skip_resp.get("recommended_follow_action") or "")
            skip_check_ok = bool(skip_check_ok or extra_skip_resp.get("ok"))
            if str(extra_skip_resp.get("state") or "") == "please_try_again":
                post_allow_hard_failure = True
                post_allow_hard_failure_error = str(extra_skip_resp.get("error") or "出现 Please try again")
                raise RuntimeError(post_allow_hard_failure_error)
            if not bool(extra_skip_resp.get("ok")):
                post_success_handling_optional_ok = False
                post_success_handling_error = post_success_handling_error or str(
                    extra_skip_resp.get("error") or "补充处理后续引导失败"
                )

    # 步骤 28：Allow and continue 之后都尝试读取 /tmp/instagram_account.json 并上报账号信息。
    # 中文注释：后续头像/引导处理失败不影响这里；账号 JSON 能读到并上报成功就视为账号创建成功。
    if allow_and_continue_ok and report_enabled:
        report_attempted = True
        random_action_delay()
        log_start("查询账号JSON")
        try:
            remote_account_json = read_instagram_account_json_with_retry(
                vp,
                path=account_json_path,
                timeout=60.0,
                interval=3.0,
            )
            report_payload = build_secondary_account_payload(
                remote_account_json,
                email=str(meta_account.get("email") or "") if meta_account else "",
                password=str(meta_account.get("password") or "") if meta_account else "",
                proxy=runtime_proxy,
                username=registered_username,
                full_name=registered_full_name,
            )
        except Exception:
            log_done(False)
            raise
        log_done(True)

        random_action_delay()
        log_start("上报账号信息")
        try:
            report_resp = post_secondary_account_report(report_payload, url=report_url)
            report_ok = bool(report_resp.get("ok"))
        except Exception:
            log_done(False)
            raise
        log_done(report_ok)
        if not report_ok:
            raise RuntimeError(f"上报账号信息失败: HTTP {report_resp.get('status')}")

    # 步骤 29：流程完成
    profile_avatar_flow_ok = True
    account_create_or_report_ok = (
        profile_create_ok
        or bool(report_attempted and report_ok)
        or bool(allow_and_continue_ok and not report_enabled)
    )
    entry_transition_ok = str(entry_resp.get("branch") or "") != "landing_login" or landing_login_clicked
    ok = (
        bool(desktop_resp.get("ok"))
        and bool(proxy_resp.get("ok"))
        and bool(new_device_resp.get("ok"))
        and bool(entry_resp.get("ok"))
        and entry_transition_ok
        and profile_click_ok
        and username_input_ok
        and password_input_ok
        and email_verified
        and login_click_ok
        and after_login_ok
        and name_next_ok
        and username_next_ok
        and allow_and_continue_ok
        and account_create_or_report_ok
        and profile_avatar_flow_ok
        and report_ok
    )
    log_start("流程完成")
    log_done(ok)

    # 步骤 30：返回本流程最终结果，供外部调用时判断成功/失败；不返回密码。
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
        "has_sign_up": bool(entry_resp.get("has_sign_up")),
        "has_continue_without_account": bool(entry_resp.get("has_continue_without_account")),
        "has_login_form": bool(entry_resp.get("has_login_form")),
        "already_have_profile_clicked": profile_clicked,
        "landing_login_clicked": landing_login_clicked,
        "meta_account_id": meta_account.get("id") if meta_account else None,
        "meta_account_email": meta_account.get("email") if meta_account else None,
        "meta_account_used_at": meta_account.get("used_at") if meta_account else None,
        "username_input": username_input_ok,
        "password_input": password_input_ok,
        "email_verified": email_verified,
        "login_clicked": login_click_ok,
        "after_login": after_login_ok,
        "after_login_state": str(after_login_resp.get("state") or ""),
        "after_login_error": str(after_login_resp.get("error") or ""),
        "try_again_count": int(after_login_resp.get("try_again_count") or 0),
        "unable_login_ok_count": int(after_login_resp.get("unable_login_ok_count") or 0),
        "login_retry_count": int(after_login_resp.get("login_retry_count") or 0),
        "meta_horizon_clicked": bool(after_login_resp.get("meta_horizon_clicked")),
        "name_next_clicked": name_next_ok,
        "registered_full_name": registered_full_name,
        "username_next_clicked": username_next_ok,
        "registered_username": registered_username,
        "allow_and_continue_clicked": allow_and_continue_ok,
        "account_create_or_report_ok": account_create_or_report_ok,
        "profile_create": profile_create_ok,
        "profile_create_state": str(profile_create_resp.get("state") or ""),
        "profile_create_matched_text": str(profile_create_resp.get("matched_text") or ""),
        "profile_avatar_flow_required": profile_avatar_flow_required,
        "post_allow_hard_failure": post_allow_hard_failure,
        "post_allow_hard_failure_error": post_allow_hard_failure_error,
        "post_success_handling_optional_ok": post_success_handling_optional_ok,
        "post_success_handling_error": post_success_handling_error,
        "post_allow_skip_clicked": bool(profile_create_resp.get("post_allow_skip_clicked")),
        "post_allow_skip_count": int(profile_create_resp.get("post_allow_skip_count") or 0),
        "post_allow_free_with_ads_choice": bool(profile_create_resp.get("free_with_ads_choice")),
        "post_allow_free_with_ads_use_clicked": bool(profile_create_resp.get("free_with_ads_use_clicked")),
        "post_allow_free_with_ads_continue_clicked": bool(profile_create_resp.get("free_with_ads_continue_clicked")),
        "post_allow_free_with_ads_agree": bool(profile_create_resp.get("free_with_ads_agree")),
        "post_allow_free_with_ads_agree_clicked": bool(profile_create_resp.get("free_with_ads_agree_clicked")),
        "post_allow_ad_experience_manage": bool(profile_create_resp.get("ad_experience_manage")),
        "post_allow_ad_experience_ok_clicked": bool(profile_create_resp.get("ad_experience_ok_clicked")),
        "post_allow_photos_access_page": bool(profile_create_resp.get("photos_access_page")),
        "post_allow_photos_access_continue_clicked": bool(profile_create_resp.get("photos_access_continue_clicked")),
        "post_allow_photos_permission_dialog": bool(profile_create_resp.get("photos_permission_dialog")),
        "post_allow_photos_permission_allow_clicked": bool(profile_create_resp.get("photos_permission_allow_clicked")),
        "post_allow_contacts_access": bool(profile_create_resp.get("contacts_access")),
        "post_allow_contacts_next_clicked": bool(profile_create_resp.get("contacts_next_clicked")),
        "post_allow_contacts_permission_dialog": bool(profile_create_resp.get("contacts_permission_dialog")),
        "post_allow_contacts_permission_denied_clicked": bool(profile_create_resp.get("contacts_permission_denied_clicked")),
        "post_allow_ads_data_consent": bool(profile_create_resp.get("ads_data_consent")),
        "post_allow_ads_data_get_started_clicked": bool(profile_create_resp.get("ads_data_get_started_clicked")),
        "post_allow_cookies_page": bool(profile_create_resp.get("cookies_page")),
        "post_allow_cookies_allow_all_clicked": bool(profile_create_resp.get("cookies_allow_all_clicked")),
        "profile_create_error": str(profile_create_resp.get("error") or ""),
        "photos_deleted": photos_deleted_ok,
        "profile_photo_imported": profile_photo_import_ok,
        "profile_photo": str(selected_profile_photo) if selected_profile_photo else "",
        "profile_photo_album": profile_photo_album,
        "profile_avatar_clicked": profile_avatar_clicked,
        "album_picker": album_picker_ok,
        "album_done_clicked": album_done_clicked,
        "avatar_upload_returned": avatar_upload_return_ok,
        "avatar_upload_return_state": str(avatar_upload_return_resp.get("state") or ""),
        "avatar_upload_return_matched_text": str(avatar_upload_return_resp.get("matched_text") or ""),
        "avatar_upload_return_error": str(avatar_upload_return_resp.get("error") or ""),
        "avatar_upload_cancel_clicked": bool(avatar_upload_return_resp.get("cancel_clicked")),
        "avatar_upload_before_cancel_error": str(avatar_upload_return_resp.get("before_cancel_error") or ""),
        "profile_done_clicked": final_done_clicked,
        "avatar_done_clicked": final_done_clicked,
        "skip_found": bool(skip_resp.get("found")),
        "skip_clicked": bool(skip_resp.get("clicked")),
        "skip_confirm_found": bool(skip_resp.get("confirm_found")),
        "skip_confirm_clicked": bool(skip_resp.get("confirm_clicked")),
        "skip_facebook_suggestions": bool(skip_resp.get("facebook_suggestions")),
        "skip_facebook_clicked": bool(skip_resp.get("facebook_skip_clicked")),
        "skip_facebook_oauth_dialog": bool(skip_resp.get("facebook_oauth_dialog")),
        "skip_facebook_oauth_cancel_clicked": bool(skip_resp.get("facebook_oauth_cancel_clicked")),
        "skip_remember_login": bool(skip_resp.get("remember_login")),
        "skip_remember_clicked": bool(skip_resp.get("remember_skip_clicked")),
        "recommended_follow": bool(skip_resp.get("recommended_follow")),
        "recommended_follow_clicked": bool(skip_resp.get("recommended_follow_clicked")),
        "recommended_follow_action": str(skip_resp.get("recommended_follow_action") or ""),
        "pick_interests": bool(skip_resp.get("pick_interests")),
        "pick_interests_done_clicked": bool(skip_resp.get("pick_interests_done_clicked")),
        "profile_avatar_done_page": bool(skip_resp.get("profile_avatar_done_page")),
        "profile_avatar_done_clicked": bool(skip_resp.get("profile_avatar_done_clicked")),
        "free_with_ads_choice": bool(skip_resp.get("free_with_ads_choice")),
        "free_with_ads_use_clicked": bool(skip_resp.get("free_with_ads_use_clicked")),
        "free_with_ads_continue_clicked": bool(skip_resp.get("free_with_ads_continue_clicked")),
        "free_with_ads_agree": bool(skip_resp.get("free_with_ads_agree")),
        "free_with_ads_agree_clicked": bool(skip_resp.get("free_with_ads_agree_clicked")),
        "ad_experience_manage": bool(skip_resp.get("ad_experience_manage")),
        "ad_experience_ok_clicked": bool(skip_resp.get("ad_experience_ok_clicked")),
        "photos_access_page": bool(skip_resp.get("photos_access_page")),
        "photos_access_continue_clicked": bool(skip_resp.get("photos_access_continue_clicked")),
        "photos_permission_dialog": bool(skip_resp.get("photos_permission_dialog")),
        "photos_permission_allow_clicked": bool(skip_resp.get("photos_permission_allow_clicked")),
        "contacts_access": bool(skip_resp.get("contacts_access")),
        "contacts_next_clicked": bool(skip_resp.get("contacts_next_clicked")),
        "contacts_permission_dialog": bool(skip_resp.get("contacts_permission_dialog")),
        "contacts_permission_denied_clicked": bool(skip_resp.get("contacts_permission_denied_clicked")),
        "ads_data_consent": bool(skip_resp.get("ads_data_consent")),
        "ads_data_get_started_clicked": bool(skip_resp.get("ads_data_get_started_clicked")),
        "cookies_page": bool(skip_resp.get("cookies_page")),
        "cookies_allow_all_clicked": bool(skip_resp.get("cookies_allow_all_clicked")),
        "entered_home": bool(skip_resp.get("home")),
        "skip_error": str(skip_resp.get("error") or ""),
        "account_report_enabled": report_enabled,
        "account_report_attempted": report_attempted,
        "account_reported": bool(report_attempted and report_ok),
        "account_report_status": int(report_resp.get("status") or 0),
        "account_report_url": report_url if report_enabled else "",
        "account_json_path": account_json_path if report_enabled else "",
        "entry_error": str(entry_resp.get("error") or ""),
        "proxy": runtime_proxy,
        "proxy_template": proxy,
        "proxy_random_username": proxy_random_username,
        "instagram_bundle_id": instagram_bundle_id,
    }


def run_selected_flow_once(vp: VPhoneSession, args: argparse.Namespace) -> dict[str, Any]:
    # 中文注释：单轮执行入口。循环模式和非循环模式共用这里，避免两边参数列表不一致。
    if args.debug_from_step19:
        return flow_debug_from_step19(
            vp,
            ui_timeout=args.ui_timeout,
            ui_interval=args.ui_interval,
            profile_photo_dir=args.profile_photo_dir,
            profile_photo_album=args.profile_photo_album,
            screen=args.screen,
        )

    return flow_meta2ig(
        vp,
        proxy=args.proxy,
        instagram_bundle_id=args.instagram_bundle_id,
        home_repeat=args.repeat,
        home_interval=args.interval,
        proxy_wait=args.proxy_wait,
        proxy_test=args.proxy_test,
        no_restart=args.no_restart,
        proxy_retry_attempts=args.proxy_retry_attempts,
        proxy_retry_delay=args.proxy_retry_delay,
        new_device_retry_attempts=args.new_device_retry_attempts,
        new_device_retry_delay=args.new_device_retry_delay,
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
        login_retry_limit=args.login_retry_limit,
        profile_photo_dir=args.profile_photo_dir,
        profile_photo_album=args.profile_photo_album,
        account_json_path=args.account_json_path,
        report_url=args.report_url,
        report_enabled=not args.no_report,
        screen=args.screen,
    )


def run_loop_mode(vp: VPhoneSession, args: argparse.Namespace, *, rounds: int) -> tuple[int, int]:
    # 中文注释：循环模式中单轮失败不退出进程，记录失败后继续下一轮，最后统一输出成功/失败次数。
    success_count = 0
    failure_count = 0
    failure_details: list[tuple[int, str]] = []

    for round_index in range(1, rounds + 1):
        print(f"\n========== meta2ig 循环 {round_index}/{rounds} ==========", flush=True)
        try:
            result = run_selected_flow_once(vp, args)
            ok = bool(result.get("ok"))
            if ok:
                success_count += 1
                print(f"本轮结果：成功（{round_index}/{rounds}）", flush=True)
            else:
                failure_count += 1
                failure_details.append((round_index, "流程返回 ok=false"))
                print(f"本轮结果：失败（{round_index}/{rounds}，流程返回 ok=false）", flush=True)
        except Exception as exc:
            failure_count += 1
            failure_details.append((round_index, str(exc)))
            print(f"本轮结果：失败（{round_index}/{rounds}）：{exc}", file=sys.stderr, flush=True)

    print(
        f"\n循环结束：总轮数={rounds}，成功={success_count}，失败={failure_count}",
        flush=True,
    )
    if failure_details:
        print("失败详情：", flush=True)
        for round_index, error in failure_details:
            print(f"  - 第 {round_index} 轮：{error}", flush=True)

    return success_count, failure_count


def main() -> int:
    # 中文注释：main 只做参数解析和 Session 初始化；业务步骤全部放在 flow_meta2ig() 里顺序执行。
    parser = argparse.ArgumentParser(description="Meta to Instagram automation helpers")
    parser.add_argument("target", help="实例名或 VM 目录，例如 instagram-01")
    parser.add_argument("--transport", choices=["auto", "socket-only", "legacy"], default="auto")
    parser.add_argument("--loop", action="store_true", help="开启循环模式；单轮失败后继续下一轮，结束后输出成功/失败次数")
    parser.add_argument("--loop-rounds", "--rounds", type=int, default=1, help="循环轮数，默认 1；设置大于 1 会自动开启循环模式")
    parser.add_argument("--repeat", type=int, default=1, help="Home 键次数，默认 1；不确定状态可用 2")
    parser.add_argument("--interval", type=float, default=0.8, help="多次 Home 之间的间隔秒数")
    parser.add_argument("--proxy", default=DEFAULT_PROXY, help="返回桌面后设置的代理；username 占位符会随机替换成 8 位大小写字母/数字；省略 scheme 时默认按 http:// 处理")
    parser.add_argument("--proxy-wait", type=float, default=2.0, help="返回桌面后等待多少秒再设置代理")
    parser.add_argument("--proxy-test", action="store_true", help="设置代理后测试出口 IP")
    parser.add_argument("--no-restart", action="store_true", help="设置代理后不重启/刷新网络相关服务")
    parser.add_argument("--proxy-retry-attempts", type=int, default=4, help="设置代理遇到临时 SSH 失败时最多重试次数，默认 4")
    parser.add_argument("--proxy-retry-delay", type=float, default=3.0, help="设置代理重试基础等待秒数，默认 3.0")
    parser.add_argument("--instagram-bundle-id", default=INSTAGRAM_BUNDLE_ID, help="要执行一键新机的 Instagram bundle id")
    parser.add_argument("--new-device-retry-attempts", type=int, default=4, help="一键新机遇到临时 SSH 失败时最多重试次数，默认 4")
    parser.add_argument("--new-device-retry-delay", type=float, default=3.0, help="一键新机重试基础等待秒数，默认 3.0")
    parser.add_argument("--backup-before-new-device", action="store_true", help="一键新机前先备份 App 状态")
    parser.add_argument("--no-relaunch-after-new-device", action="store_true", help="一键新机后不自动重新启动 App")
    parser.add_argument("--respring-after-new-device", action="store_true", help="一键新机后执行 respring")
    parser.add_argument("--ui-timeout", type=float, default=15.0, help="OCR 等待启动页 Log in / Create new account / I already have a profile 出现的最大秒数")
    parser.add_argument("--ui-wait", dest="ui_timeout", type=float, help=argparse.SUPPRESS)
    parser.add_argument("--ui-interval", type=float, default=0.5, help="OCR 轮询间隔秒数")
    parser.add_argument("--meta-db-dsn", default=os.environ.get("IOS_METAAI_MYSQL_DSN", DEFAULT_META_MYSQL_DSN), help="Meta 账号 MySQL DSN；默认读 IOS_METAAI_MYSQL_DSN")
    parser.add_argument("--meta-db-table", default=os.environ.get("IOS_METAAI_MYSQL_TABLE", DEFAULT_META_MYSQL_TABLE), help="Meta 账号表名；默认读 IOS_METAAI_MYSQL_TABLE")
    parser.add_argument("--focus-wait-min", type=float, default=1.0, help="点击输入框后最少等待秒数，默认 1.0")
    parser.add_argument("--focus-wait-max", type=float, default=2.0, help="点击输入框后最多等待秒数，默认 2.0")
    parser.add_argument("--char-delay-min", type=float, default=0.3, help="逐字输入最小间隔秒数，默认 0.3")
    parser.add_argument("--char-delay-max", type=float, default=0.8, help="逐字输入最大间隔秒数，默认 0.8")
    parser.add_argument("--login-retry-limit", type=int, default=3, help="Sign up + Try again 分支最多重试 Log in 次数，默认 3")
    parser.add_argument("--profile-photo-dir", default=str(DEFAULT_PROFILE_PHOTO_DIR), help="头像照片素材目录；点击头像前会随机导入一张")
    parser.add_argument("--profile-photo-album", default="VPhoneImports", help="导入实例相册时使用的相册名")
    parser.add_argument("--account-json-path", default=DEFAULT_INSTAGRAM_ACCOUNT_JSON_PATH, help="实例内 Instagram hook JSON 路径，默认 /tmp/instagram_account.json")
    parser.add_argument("--report-url", default=DEFAULT_SECONDARY_ACCOUNT_REPORT_URL, help="创建资料成功后的账号上报接口")
    parser.add_argument("--no-report", action="store_true", help="调试用：创建资料成功后不读取 JSON、不上报账号")
    parser.add_argument("--debug-from-step19", action="store_true", help="临时调试：跳过步骤 1-18，只从当前屏幕执行步骤 19 及后续动作")
    parser.add_argument("--screen", action="store_true", help="返回桌面后带一张截图 base64")
    parser.add_argument("--artifacts", action="store_true", help="记录 businessScript runs artifacts")
    args = parser.parse_args()
    if args.loop_rounds < 1:
        parser.error("--loop-rounds/--rounds 必须 >= 1")
    if args.proxy_retry_attempts < 1:
        parser.error("--proxy-retry-attempts 必须 >= 1")
    if args.proxy_retry_delay < 0:
        parser.error("--proxy-retry-delay 必须 >= 0")
    if args.new_device_retry_attempts < 1:
        parser.error("--new-device-retry-attempts 必须 >= 1")
    if args.new_device_retry_delay < 0:
        parser.error("--new-device-retry-delay 必须 >= 0")
    loop_rounds = args.loop_rounds
    loop_enabled = bool(args.loop or loop_rounds > 1)

    try:
        with VPhoneSession(
            args.target,
            app=CONFIG.get("name", "instagram"),
            flow="meta2ig",
            transport=args.transport,
            artifacts=args.artifacts,
        ) as vp:
            if loop_enabled:
                _, failure_count = run_loop_mode(vp, args, rounds=loop_rounds)
                if failure_count:
                    return 1
            else:
                run_selected_flow_once(vp, args)
    except Exception as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
