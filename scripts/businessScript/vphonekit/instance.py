from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


# 中文注释：从当前文件位置向上寻找 vphone-cli 项目根目录。
def find_repo_root(start: Path | None = None) -> Path:
    base = (start or Path(__file__).resolve()).resolve()
    if base.is_file():
        base = base.parent
    for candidate in [base, *base.parents]:
        if (candidate / "Makefile").exists() and (candidate / "sources" / "vphone-cli").is_dir():
            return candidate
    raise RuntimeError(f"could not find vphone-cli repo root from: {base}")


# 中文注释：解析 shell 风格 env 文件，当前主要用于读取 instance.env。
def read_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw in path.read_text(errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key:
            env[key] = value
    return env


# 中文注释：判断目录是否像一个 vphone VM/实例目录。
def is_vm_dir(path: Path) -> bool:
    return (path / "config.plist").exists() or (path / "vphone.sock").exists()


# 中文注释：查找最近一个有 vphone.sock 的运行中实例。
def latest_running_instance_dir(repo_root: Path) -> Path | None:
    roots = [repo_root / "vm.instances", repo_root]
    sockets: list[Path] = []
    for root in roots:
        if root.exists():
            sockets.extend(root.glob("*/vphone.sock"))
    sockets = [s for s in sockets if s.exists()]
    if not sockets:
        return None
    sockets.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return sockets[0].parent.resolve()


# 中文注释：通过 SSH_LOCAL_PORT 反查实例目录。
def resolve_vm_dir_from_port(repo_root: Path, port: str) -> Path | None:
    for env_file in sorted((repo_root / "vm.instances").glob("*/instance.env")):
        env = read_env_file(env_file)
        if port in {env.get("SSH_LOCAL_PORT"), env.get("VPHONE_SSH_PORT")}:
            return env_file.parent.resolve()
    return None


# 中文注释：把实例名、实例目录、SSH 端口或空值解析成实例目录。
def resolve_vm_dir(target: str | Path | None = None, repo_root: Path | None = None) -> Path:
    root = repo_root or find_repo_root()
    if target is None or str(target).strip() == "":
        latest = latest_running_instance_dir(root)
        if latest:
            return latest
        raise FileNotFoundError("no running instance found; pass an instance name or VM dir")

    value = str(target)
    if value.isdigit():
        by_port = resolve_vm_dir_from_port(root, value)
        if by_port:
            return by_port
        raise FileNotFoundError(f"no instance.env maps SSH port: {value}")

    raw = Path(value).expanduser()
    candidates = [raw]
    if not raw.is_absolute():
        candidates.extend([Path.cwd() / raw, root / raw, root / "vm.instances" / value])
    for candidate in candidates:
        if is_vm_dir(candidate):
            return candidate.resolve()
    raise FileNotFoundError(f"instance/vm dir not found: {target}")


@dataclass(slots=True)
class VPhoneInstance:
    """中文注释：一个运行中/可定位的 vphone 实例描述。"""

    repo_root: Path
    vm_dir: Path
    name: str
    env: dict[str, str]
    socket_path: Path
    ssh_port: str | None

    @classmethod
    def resolve(
        cls,
        target: str | Path | None = None,
        *,
        repo_root: Path | None = None,
        ssh_port: str | None = None,
    ) -> "VPhoneInstance":
        root = repo_root or find_repo_root()
        vm_dir = resolve_vm_dir(target, root)
        env = read_env_file(vm_dir / "instance.env")
        port = ssh_port or env.get("SSH_LOCAL_PORT") or env.get("VPHONE_SSH_PORT")
        name = env.get("INSTANCE_NAME") or vm_dir.name
        return cls(
            repo_root=root,
            vm_dir=vm_dir,
            name=name,
            env=env,
            socket_path=vm_dir / "vphone.sock",
            ssh_port=str(port) if port else None,
        )

    @property
    def target_arg(self) -> str:
        """中文注释：传给 legacy zsh 脚本的目标参数，使用 VM 目录最稳。"""
        return str(self.vm_dir)

    def require_socket(self) -> Path:
        if not self.socket_path.exists():
            raise FileNotFoundError(f"host-control socket not found: {self.socket_path}")
        return self.socket_path

    def require_ssh_port(self, action: str = "operation") -> str:
        if self.ssh_port:
            return self.ssh_port
        raise RuntimeError(f"SSH_LOCAL_PORT not known; cannot run {action}")
