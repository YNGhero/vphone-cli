#!/usr/bin/env python3
"""Small per-instance HTTP CONNECT bridge for vphone guest proxies.

The iOS SystemConfiguration proxy keys are HTTP/HTTPS/SOCKS settings.  Some
apps only consume the HTTP/HTTPS proxy keys, while many residential providers
hand out SOCKS5 URLs.  This bridge lets the guest see an HTTP CONNECT proxy on
the macOS NAT gateway and forwards those CONNECT tunnels to the configured
upstream HTTP(S) or SOCKS5 proxy.
"""

from __future__ import annotations

import argparse
import base64
import errno
import json
import os
import selectors
import signal
import socket
import ssl
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import unquote, urlsplit, urlunsplit


BUFFER_SIZE = 64 * 1024
CONNECT_TIMEOUT = 12.0
IDLE_TIMEOUT = 300.0


@dataclass(frozen=True)
class UpstreamProxy:
    raw_url: str
    scheme: str
    host: str
    port: int
    username: str = ""
    password: str = ""

    @property
    def is_http(self) -> bool:
        return self.scheme in {"http", "https"}

    @property
    def is_socks(self) -> bool:
        return self.scheme in {"socks", "socks5", "socks5h"}

    @property
    def proxy_authorization(self) -> str:
        if not self.username and not self.password:
            return ""
        token = f"{self.username}:{self.password}".encode()
        return "Basic " + base64.b64encode(token).decode("ascii")


def log(message: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {message}", flush=True)


def parse_upstream(url: str) -> UpstreamProxy:
    parsed = urlsplit(url)
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https", "socks", "socks5", "socks5h"}:
        raise SystemExit(f"unsupported upstream proxy scheme: {scheme}")
    if not parsed.hostname:
        raise SystemExit("upstream proxy host is required")
    default_port = 8080 if scheme in {"http", "https"} else 1080
    return UpstreamProxy(
        raw_url=url,
        scheme=scheme,
        host=parsed.hostname,
        port=int(parsed.port or default_port),
        username=unquote(parsed.username or ""),
        password=unquote(parsed.password or ""),
    )


def sanitize_url(url: str) -> str:
    parsed = urlsplit(url)
    if not parsed.password:
        return url
    netloc = parsed.hostname or ""
    if parsed.username:
        netloc = f"{parsed.username}:***@{netloc}"
    if parsed.port:
        netloc = f"{netloc}:{parsed.port}"
    return urlunsplit((parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment))


def read_headers(sock: socket.socket) -> bytes:
    data = bytearray()
    sock.settimeout(CONNECT_TIMEOUT)
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > 256 * 1024:
            raise OSError("request headers too large")
    return bytes(data)


def split_host_port(value: str, default_port: int) -> tuple[str, int]:
    value = value.strip()
    if not value:
        raise ValueError("empty host")
    if value.startswith("["):
        end = value.find("]")
        if end < 0:
            raise ValueError(f"invalid IPv6 host: {value}")
        host = value[1:end]
        rest = value[end + 1 :]
        if rest.startswith(":"):
            return host, int(rest[1:])
        return host, default_port
    if value.count(":") == 1:
        host, port = value.rsplit(":", 1)
        return host, int(port)
    return value, default_port


def parse_http_request(header_bytes: bytes) -> tuple[str, str, str, list[bytes], bytes]:
    head, sep, body = header_bytes.partition(b"\r\n\r\n")
    if not sep:
        raise OSError("incomplete HTTP proxy request")
    lines = head.split(b"\r\n")
    if not lines:
        raise OSError("empty HTTP proxy request")
    first = lines[0].decode("iso-8859-1", errors="replace")
    parts = first.split()
    if len(parts) != 3:
        raise OSError(f"invalid request line: {first!r}")
    return parts[0].upper(), parts[1], parts[2], lines[1:], body


def http_response(client: socket.socket, code: int, reason: str, body: bytes = b"") -> None:
    headers = [
        f"HTTP/1.1 {code} {reason}",
        "Proxy-Agent: vphone-proxy-bridge",
        "Connection: close" if body else "Connection: keep-alive",
    ]
    if body:
        headers.append(f"Content-Length: {len(body)}")
    client.sendall(("\r\n".join(headers) + "\r\n\r\n").encode("ascii") + body)


def open_tcp(host: str, port: int) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


def socks5_connect(upstream: UpstreamProxy, target_host: str, target_port: int) -> socket.socket:
    sock = open_tcp(upstream.host, upstream.port)
    try:
        if upstream.username or upstream.password:
            sock.sendall(b"\x05\x02\x00\x02")
        else:
            sock.sendall(b"\x05\x01\x00")
        resp = sock.recv(2)
        if len(resp) != 2 or resp[0] != 5:
            raise OSError("invalid SOCKS5 greeting response")
        if resp[1] == 2:
            user = upstream.username.encode("utf-8")
            password = upstream.password.encode("utf-8")
            if len(user) > 255 or len(password) > 255:
                raise OSError("SOCKS5 username/password too long")
            sock.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
            auth = sock.recv(2)
            if len(auth) != 2 or auth[1] != 0:
                raise OSError("SOCKS5 authentication failed")
        elif resp[1] != 0:
            raise OSError(f"unsupported SOCKS5 auth method: {resp[1]}")

        host_bytes = target_host.encode("idna")
        if len(host_bytes) > 255:
            raise OSError("target host too long")
        req = b"\x05\x01\x00\x03" + bytes([len(host_bytes)]) + host_bytes + int(target_port).to_bytes(2, "big")
        sock.sendall(req)
        reply = sock.recv(4)
        if len(reply) != 4 or reply[0] != 5:
            raise OSError("invalid SOCKS5 connect response")
        if reply[1] != 0:
            raise OSError(f"SOCKS5 connect failed with code {reply[1]}")
        atyp = reply[3]
        if atyp == 1:
            to_read = 4 + 2
        elif atyp == 3:
            ln = sock.recv(1)
            if not ln:
                raise OSError("truncated SOCKS5 domain response")
            to_read = ln[0] + 2
        elif atyp == 4:
            to_read = 16 + 2
        else:
            raise OSError(f"invalid SOCKS5 address type: {atyp}")
        remaining = to_read
        while remaining:
            chunk = sock.recv(remaining)
            if not chunk:
                raise OSError("truncated SOCKS5 bind response")
            remaining -= len(chunk)
        return sock
    except Exception:
        sock.close()
        raise


def http_proxy_connect(upstream: UpstreamProxy, target_host: str, target_port: int) -> socket.socket:
    raw = open_tcp(upstream.host, upstream.port)
    sock: socket.socket = raw
    try:
        if upstream.scheme == "https":
            context = ssl.create_default_context()
            sock = context.wrap_socket(raw, server_hostname=upstream.host)
        target = f"{target_host}:{target_port}"
        lines = [
            f"CONNECT {target} HTTP/1.1",
            f"Host: {target}",
            "Proxy-Connection: keep-alive",
            "User-Agent: vphone-proxy-bridge",
        ]
        if upstream.proxy_authorization:
            lines.append(f"Proxy-Authorization: {upstream.proxy_authorization}")
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("ascii"))
        response = read_headers(sock)
        first = response.split(b"\r\n", 1)[0].decode("iso-8859-1", errors="replace")
        parts = first.split()
        if len(parts) < 2 or not parts[1].isdigit() or int(parts[1]) // 100 != 2:
            raise OSError(f"HTTP upstream CONNECT failed: {first}")
        return sock
    except Exception:
        sock.close()
        if sock is not raw:
            raw.close()
        raise


def upstream_connect(upstream: UpstreamProxy, target_host: str, target_port: int) -> socket.socket:
    if upstream.is_socks:
        return socks5_connect(upstream, target_host, target_port)
    return http_proxy_connect(upstream, target_host, target_port)


def relay(left: socket.socket, right: socket.socket) -> None:
    selector = selectors.DefaultSelector()
    for sock in (left, right):
        sock.setblocking(False)
        selector.register(sock, selectors.EVENT_READ)
    deadline = time.time() + IDLE_TIMEOUT
    try:
        while True:
            events = selector.select(timeout=1.0)
            if not events:
                if time.time() > deadline:
                    break
                continue
            deadline = time.time() + IDLE_TIMEOUT
            for key, _ in events:
                src = key.fileobj
                dst = right if src is left else left
                try:
                    data = src.recv(BUFFER_SIZE)
                except (BlockingIOError, InterruptedError):
                    continue
                if not data:
                    return
                try:
                    dst.setblocking(True)
                    dst.sendall(data)
                    dst.setblocking(False)
                except (BrokenPipeError, ConnectionResetError):
                    return
                except BlockingIOError:
                    return
    finally:
        for sock in (left, right):
            try:
                selector.unregister(sock)
            except Exception:
                pass
        selector.close()


def filtered_headers(lines: list[bytes], upstream: Optional[UpstreamProxy] = None) -> list[bytes]:
    out: list[bytes] = []
    added_auth = False
    for line in lines:
        lower = line.lower()
        if lower.startswith(b"proxy-connection:"):
            continue
        if lower.startswith(b"proxy-authorization:"):
            continue
        out.append(line)
    if upstream and upstream.proxy_authorization:
        out.append(f"Proxy-Authorization: {upstream.proxy_authorization}".encode("ascii"))
        added_auth = True
    if not added_auth:
        out.append(b"Connection: close")
    return out


def handle_client(client: socket.socket, address: tuple[str, int], upstream: UpstreamProxy) -> None:
    remote: Optional[socket.socket] = None
    try:
        header_bytes = read_headers(client)
        method, target, version, headers, body = parse_http_request(header_bytes)
        if method == "CONNECT":
            host, port = split_host_port(target, 443)
            remote = upstream_connect(upstream, host, port)
            http_response(client, 200, "Connection Established")
            relay(client, remote)
            return

        parsed = urlsplit(target)
        if parsed.scheme.lower() != "http" or not parsed.hostname:
            http_response(client, 400, "Bad Request", b"Only CONNECT and absolute-form http:// requests are supported.\n")
            return
        host = parsed.hostname
        port = int(parsed.port or 80)

        if upstream.is_http:
            remote = open_tcp(upstream.host, upstream.port)
            if upstream.scheme == "https":
                context = ssl.create_default_context()
                remote = context.wrap_socket(remote, server_hostname=upstream.host)
            new_headers = filtered_headers(headers, upstream)
            request = (
                f"{method} {target} {version}\r\n".encode("iso-8859-1")
                + b"\r\n".join(new_headers)
                + b"\r\n\r\n"
                + body
            )
        else:
            remote = upstream_connect(upstream, host, port)
            path = urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
            new_headers = filtered_headers(headers)
            request = (
                f"{method} {path} {version}\r\n".encode("iso-8859-1")
                + b"\r\n".join(new_headers)
                + b"\r\n\r\n"
                + body
            )
        remote.sendall(request)
        relay(client, remote)
    except Exception as exc:
        log(f"client {address[0]}:{address[1]} error: {exc}")
        try:
            http_response(client, 502, "Bad Gateway", f"{exc}\n".encode())
        except Exception:
            pass
    finally:
        try:
            client.close()
        except Exception:
            pass
        if remote is not None:
            try:
                remote.close()
            except Exception:
                pass


def write_pid_file(path: str) -> None:
    if not path:
        return
    Path(path).write_text(f"{os.getpid()}\n")


def write_ready_file(path: str, host: str, port: int, upstream: UpstreamProxy) -> None:
    if not path:
        return
    payload = {
        "pid": os.getpid(),
        "listen_host": host,
        "listen_port": port,
        "upstream": sanitize_url(upstream.raw_url),
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    Path(path).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def serve(args: argparse.Namespace) -> None:
    upstream = parse_upstream(args.upstream)
    stop = threading.Event()
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    def handle_signal(signum, _frame):
        log(f"received signal {signum}; shutting down")
        stop.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((args.listen_host, int(args.listen_port)))
    except OSError as exc:
        if args.listen_host != "0.0.0.0" and exc.errno in {errno.EADDRNOTAVAIL, errno.EACCES}:
            log(f"bind {args.listen_host}:{args.listen_port} failed ({exc}); retrying on 0.0.0.0")
            srv.bind(("0.0.0.0", int(args.listen_port)))
        else:
            raise
    srv.listen(128)
    srv.settimeout(1.0)
    host, port = srv.getsockname()
    write_pid_file(args.pid_file)
    write_ready_file(args.ready_file, host, port, upstream)
    log(f"listening on {host}:{port}; upstream={sanitize_url(upstream.raw_url)}")

    try:
        while not stop.is_set():
            try:
                client, addr = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                if stop.is_set():
                    break
                raise
            thread = threading.Thread(target=handle_client, args=(client, addr, upstream), daemon=True)
            thread.start()
    finally:
        srv.close()
        log("stopped")


def main() -> None:
    parser = argparse.ArgumentParser(description="vphone HTTP CONNECT proxy bridge")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=0)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--pid-file", default="")
    parser.add_argument("--ready-file", default="")
    parser.add_argument("--daemonize", action="store_true")
    args = parser.parse_args()
    if args.daemonize:
        if os.fork() > 0:
            os._exit(0)
        os.setsid()
        if hasattr(signal, "SIGHUP"):
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
        if os.fork() > 0:
            os._exit(0)
        os.umask(0o022)
    serve(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
