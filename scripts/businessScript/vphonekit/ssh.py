from __future__ import annotations

import os
import shutil
import subprocess


REMOTE_PATH = (
    "/var/jb/usr/bin:/var/jb/bin:/var/jb/sbin:/var/jb/usr/sbin:"
    "/iosbinpack64/usr/bin:/iosbinpack64/bin:/usr/bin:/bin:/sbin:/usr/sbin:"
    "/iosbinpack64/sbin:/iosbinpack64/usr/sbin:$PATH"
)


class SSHClient:
    """中文注释：通过 launch_vphone_instance 建立的本机端口 SSH 到 guest。"""

    def __init__(self, port: str | int | None, *, password: str | None = None, host: str | None = None) -> None:
        self.port = str(port) if port else None
        self.password = password or os.environ.get("VPHONE_SSH_PASSWORD", "alpine")
        self.host = host or os.environ.get("VPHONE_SSH_HOST", "127.0.0.1")

    def require_port(self, action: str = "operation") -> str:
        if self.port:
            return self.port
        raise RuntimeError(f"SSH_LOCAL_PORT not known; cannot run {action}")

    def run(
        self,
        cmd: str,
        *,
        check: bool = False,
        input_data: bytes | str | None = None,
        timeout: float | None = None,
    ) -> subprocess.CompletedProcess[str | bytes]:
        if not shutil.which("sshpass"):
            raise RuntimeError("sshpass not found; install with: brew install sshpass")
        port = self.require_port("ssh command")
        remote = f"export PATH={REMOTE_PATH}; {cmd}"
        text_mode = not isinstance(input_data, (bytes, bytearray))
        proc = subprocess.run(
            [
                "sshpass",
                "-p",
                self.password,
                "ssh",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-o",
                "PreferredAuthentications=password",
                "-o",
                "ConnectTimeout=8",
                "-o",
                "LogLevel=ERROR",
                "-p",
                port,
                f"root@{self.host}",
                remote,
            ],
            input=input_data,
            text=text_mode,
            capture_output=True,
            timeout=timeout,
        )
        if check and proc.returncode != 0:
            stderr = proc.stderr.decode() if isinstance(proc.stderr, bytes) else proc.stderr
            stdout = proc.stdout.decode() if isinstance(proc.stdout, bytes) else proc.stdout
            raise RuntimeError((stderr or stdout or f"ssh command failed: {cmd}").strip())
        return proc
