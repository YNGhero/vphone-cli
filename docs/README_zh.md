<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong>🇨🇳中文</strong> | <strong><a href="../README.md">🇬🇧English</a></strong></div>

# vphone-cli

通过 Apple 的 Virtualization.framework 使用 PCC 研究虚拟机基础设施引导虚拟 iPhone（iOS 26）。

![poc](./demo.jpeg)

## 测试环境

| 主机          | iPhone 系统           | CloudOS       |
| ------------- | --------------------- | ------------- |
| Mac16,12 26.3 | `17,3_26.1_23B85`     | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127`    | `26.1-23B85`  |
| Mac16,12 26.3 | `17,3_26.3_23D127`    | `26.3-23D128` |
| Mac16,12 26.3 | `17,3_26.3.1_23D8133` | `26.3-23D128` |

## 固件变体

提供四种补丁变体，安全绕过级别逐步递增：

| 变体          | 启动链     | 自定义固件 | Make 目标                                   |
| ------------- | :--------: | :--------: | ------------------------------------------- |
| **Patchless** | 3 个补丁   | 2 个阶段   | `fw_patch_less` + `boot_less`              |
| **常规版**    | 41 个补丁  | 10 个阶段  | `fw_patch` + `cfw_install`                  |
| **开发版**    | 52 个补丁  | 12 个阶段  | `fw_patch_dev` + `cfw_install_dev`          |
| **越狱版**    | 112 个补丁 | 14 个阶段  | `fw_patch_jb` + `cfw_install_jb`            |

> 越狱最终配置（符号链接、Sileo、apt、TrollStore）通过 `/cores/vphone_jb_setup.sh` LaunchDaemon 在首次启动时自动运行。查看进度：`/var/log/vphone_jb_setup.log`。

详见 [research/0_binary_patch_comparison.md](../research/0_binary_patch_comparison.md) 了解各组件的详细分项对比。

## 先决条件

**主机系统：** PV=3 虚拟化要求 macOS 15+（Sequoia）。

**配置 SIP/AMFI** —— 需要私有的 Virtualization.framework 权限和未签名二进制文件工作流。

重启到恢复模式（长按电源键），打开终端，选择以下任一设置方式：

- **方式 1：完全禁用 SIP + AMFI boot-arg（最宽松）**

  在恢复模式中：

  ```bash
  csrutil disable
  csrutil allow-research-guests enable
  ```

  重新启动回 macOS 后：

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

  再重启一次。

- **方式 2：保持 SIP 大部分启用，仅禁用调试限制，使用 [`amfidont`](https://github.com/zqxwce/amfidont) 或 [`amfree`](https://github.com/retX0/amfree)**

  在恢复模式中：

  ```bash
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  重新启动回 macOS 后：

  ```bash
  # 使用 amfidont：
  xcrun python3 -m pip install amfidont
  sudo amfidont --path [PATH_TO_VPHONE_DIR]
  
  # 或使用 amfree：
  brew install retX0/tap/amfree
  sudo amfree --path [PATH_TO_VPHONE_DIR]
  ```

  在本仓库中，可以运行 `make amfidont_allow_vphone` 一次性配置
  `amfidont` 所需的编码路径与 CDHash 允许项。

> Patchless 变体要求使用方式 1，或带 `-S` 参数的 amfidont（`sudo amfidont -S --path [PATH_TO_VPHONE_DIR]`）。

**安装依赖：**

```bash
brew install aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw
```

`scripts/fw_prepare.sh` 会优先使用 `aria2c` 进行更快的多连接下载，必要时再回退到 `curl` 或 `wget`。

**Submodules** —— 本仓库通过 git submodule 管理资源、Swift 依赖以及 `scripts/repos/` 下的工具链源码。克隆时请使用：

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
```

## 快速开始

```bash
make setup_machine            # 完全自动化完成"首次启动"流程（包含 restore/ramdisk/CFW）
# 选项：NONE_INTERACTIVE=1 SKIP_BOOT_ANALYSIS=1 SUDO_PASSWORD=...
# LESS=1 patchless 变体（- AMFI、SSV、Img4、TXM 绕过）
# DEV=1 开发变体（+ TXM 权限/调试绕过）
# JB=1 越狱变体（dev + 完整安全绕过）
```

## 手动设置

```bash
make setup_tools              # 安装 brew 依赖，构建 trustcache + insert_dylib，创建 Python 虚拟环境（含 pymobiledevice3/aria2c）
make build                    # 构建并签名 vphone-cli
make vm_new                   # 创建 VM 目录及清单文件（config.plist）
# 选项：CPU=8 MEMORY=8192 DISK_SIZE=64 NETWORK_MODE=nat
make fw_prepare               # 下载 IPSWs，提取、合并、生成 manifest
make fw_patch                 # 修补启动链（常规变体）
# 或：sudo make fw_patch_less # patchless 变体（- AMFI、SSV、Img4、TXM 绕过）
# 或：make fw_patch_dev       # 开发变体（+ TXM 权限/调试绕过）
# 或：make fw_patch_jb        # 越狱变体（dev + 完整安全绕过）
```

### VM 配置

从 v1.0 开始，VM 配置存储在 `vm/config.plist` 中。在创建 VM 时设置 CPU、内存和磁盘大小：

```bash
# 使用自定义配置创建 VM
make vm_new CPU=16 MEMORY=16384 DISK_SIZE=128 NETWORK_MODE=nat

# 桥接到宿主机 en0；或 NETWORK_MODE=none 创建离线 VM
make vm_new NETWORK_MODE=bridged NETWORK_INTERFACE=en0

# 启动时自动从 config.plist 读取配置
make boot
```

清单文件存储所有 VM 设置（CPU、内存、屏幕、ROM、存储、网络），并与 [security-pcc 的 VMBundle.Config 格式](https://github.com/apple/security-pcc)兼容。

网络模式：

- `nat`：默认，共享宿主机网络出口。
- `bridged`：桥接到宿主机指定网卡，例如 `NETWORK_INTERFACE=en0`。
- `none`：不挂载虚拟网卡，适合离线/隔离测试。

> **注意：** 网络模式决定虚拟网卡接入方式，不等同于“不同公网 IP/不同地区代理”。如果需要按实例分配代理或出口 IP，需要额外在 guest 或宿主机路由层配置。

## 恢复过程

该过程需要 **两个终端**。保持终端 1 运行，同时在终端 2 操作。

```bash
# 终端 1
make boot_dfu                 # 以 DFU 模式启动 VM（保持运行）
```

```bash
# 终端 2
make restore_get_shsh         # 获取 SHSH blob
make restore                  # 通过 pymobiledevice3 restore 后端刷写固件
# 或：make restore_offline    # 离线恢复（就地解密 AEA 镜像，并使用缓存的 .shsh blob）
                              # 首次运行需要联网以完成 AEA 解密
```

## 安装自定义固件

在终端 1 中停止 DFU 引导（Ctrl+C），然后再次进入 DFU，用于 ramdisk：

```bash
# 终端 1
make boot_dfu                 # 保持运行
```

```bash
# 终端 2
sudo make ramdisk_build       # 构建签名的 SSH ramdisk
make ramdisk_send             # 发送到设备
```

当 ramdisk 运行后（输出中应显示 `Running server`），打开**第三个终端**运行 usbmux 隧道，然后在终端 2 安装 CFW：

```bash
# 终端 3 —— 保持运行
python3 -m pymobiledevice3 usbmux forward 2222 22
```

```bash
# 终端 2
make cfw_install
# 或：make cfw_install_jb        # 越狱变体
```

## 首次启动

在终端 1 中停止 DFU 引导（Ctrl+C），然后：

```bash
make boot
```

执行 `cfw_install_jb` 后，越狱变体在首次启动时将提供 **Sileo** 和 **TrollStore**。你可以使用 Sileo 安装 `openssh-server` 以获得 SSH 访问。

对于常规版/开发版，VM 会提供**直接控制台**。当看到 `bash-4.4#` 时，按回车并运行以下命令以初始化 shell 环境并生成 SSH 主机密钥：

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

mkdir -p /var/dropbear
cp /iosbinpack64/etc/profile /var/profile
cp /iosbinpack64/etc/motd /var/motd

# 生成 SSH 主机密钥（SSH 能正常工作所必需）
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key

shutdown -h now
```

> **注意：** 若不执行主机密钥生成步骤，dropbear（SSH 服务器）会接受连接但立刻关闭，因为它没有密钥进行握手。

## 后续启动

```bash
make boot
```

在另一个终端中启动 usbmux 转发隧道：

```bash
python3 -m pymobiledevice3 usbmux forward 2222 22222    # SSH（dropbear）
python3 -m pymobiledevice3 usbmux forward 2222 22       # SSH（越狱版：在 Sileo 中安装 openssh-server 后）
python3 -m pymobiledevice3 usbmux forward 5901 5901     # VNC
python3 -m pymobiledevice3 usbmux forward 5910 5910     # RPC
```

连接方式：

- **SSH（越狱版）：** `ssh -p 2222 mobile@127.0.0.1`（密码：`alpine`）
- **SSH（常规版/开发版）：** `ssh -p 2222 root@127.0.0.1`（密码：`alpine`）
- **VNC：** `vnc://127.0.0.1:5901`
- [**RPC：**](http://github.com/doronz88/rpc-project) `rpcclient -p 5910 127.0.0.1`

## 一键 TrollStore/JB 启动脚本

仓库根目录提供一个双击入口：

```text
launch_trollstore_vphone.command
```

用途：维护一个固定的 TrollStore/JB 环境，适合“每天打开同一台越狱虚拟 iPhone”使用。

### 使用方法

在 Finder 中双击：

```text
/Users/true/Documents/vphone-cli/launch_trollstore_vphone.command
```

也可以从终端运行：

```bash
zsh launch_trollstore_vphone.command
```

脚本在可交互终端中会先询问配置；直接回车使用默认值：

```text
固件版本：
  1) 常规版
  2) 开发版
  3) 越狱版 / TrollStore-JB
请选择 1/2/3 [3]:
CPU 核心数 [4]:
内存 GB [4]:
硬盘 GB [32]:
系统语言，如 zh-Hans/en/ja；输入 default 跳过 [default]:
地区/区域，如 zh_CN/en_US/ja_JP；输入 default 跳过 [default]:
网络模式 nat/bridged/none [nat]:
```

对于已经存在的同版本备份，CPU/内存/硬盘沿用已有 VM 配置；语言和网络模式仍可在启动时修改。

如果本次需要新建/刷机，脚本还会在开始前询问一次 macOS 管理员密码（输入时不会显示）：

```text
=== macOS sudo 凭据 ===
macOS 管理员密码（不会显示）:
```

输入一次后会在本次运行内自动传给 `xcode-select`、`amfidont`、`fw_patch_*`、`ramdisk_build` 里的 `hdiutil` 等 sudo 步骤，避免中途卡在 `Password:`。

脚本完成后会启动原生 GUI，并自动准备以下连接入口：

```text
Host control socket: vm/vphone.sock
SSH: 127.0.0.1:2222 -> guest:22222
VNC: 127.0.0.1:5901 -> guest:5901
RPC: 127.0.0.1:5910 -> guest:5910
```

SSH 示例：

```bash
sshpass -p alpine ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@127.0.0.1
```

> 交互式 SSH 建议加 `-tt`。`sshpass` 可能让 `ssh` 判断本地不是 TTY；不加 `-tt` 时会出现“认证成功但马上回到本机终端”的现象。执行单条命令或 `scp` 不需要 `-tt`。

如果在 `vphone_instance.conf` 中配置了语言或网络模式，脚本会在启动时自动应用：

```bash
VPHONE_LANGUAGE=zh-Hans
VPHONE_LOCALE=zh_CN
VPHONE_NETWORK_MODE=nat
```

查看 TrollStore/Sileo 首次初始化进度：

```bash
sshpass -p alpine ssh -p 2222 root@127.0.0.1 'tail -f /var/log/vphone_jb_setup.log'
```

### 导入图片到相册

单纯把图片复制到 `/var/mobile/Media/DCIM/` 或 `/var/mobile/Documents/`，通常**不会**立刻被「照片」App 识别；相册数据需要通过 PhotoKit/Photos 数据库登记。

推荐使用项目内的导入脚本。它会自动：

1. 编译并签名 guest 侧 PhotoKit 导入器；
2. 通过 SSH 把导入器安装到 guest 的 `/var/root/vphone_photo_import`；
3. 把本机图片上传到 `/var/mobile/Documents/vphone-photo-imports/`；
4. 调用 PhotoKit 导入到「照片」App，并放入 `VPhoneImports` 相册。

用法：

```bash
zsh scripts/import_photo_to_instance.sh /path/to/image.jpg 2222 VPhoneImports
```

以当前实例端口 `2224` 为例：

```bash
zsh scripts/import_photo_to_instance.sh /Users/true/Documents/ZeusFramework/go/register_ins/picture/0a9b60e54220741bdda743b593b4dd74.jpg 2224 VPhoneImports
```

成功时会输出类似：

```text
OK imported XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/L0/001
```

如果只想用一行 SSH 命令，也可以在导入器已安装的实例上直接执行：

```bash
sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2224 root@127.0.0.1 '/var/jb/usr/bin/mkdir -p /var/mobile/Documents/vphone-photo-imports && /var/jb/usr/bin/cat > /var/mobile/Documents/vphone-photo-imports/image.jpg && /var/root/vphone_photo_import /var/mobile/Documents/vphone-photo-imports/image.jpg VPhoneImports; rc=$?; /var/jb/usr/bin/killall Photos 2>/dev/null || true; /var/jb/usr/bin/killall assetsd 2>/dev/null || true; exit $rc' < /path/to/image.jpg
```

> 如果提示 `/var/root/vphone_photo_import: not found`，说明这个实例还没安装导入器；先运行一次 `scripts/import_photo_to_instance.sh` 即可。执行后重新打开「照片」App，查看 `VPhoneImports` 相册或“最近项目”。

### 删除相册里的所有照片

如果要清空 guest 里的「照片」App，可以使用项目内的删除脚本。

> 说明：直接用 PhotoKit 的 `deleteAssets` 会触发 iOS 系统确认弹窗，需要在虚拟机里点“删除”。为了适合自动化，这个脚本不走 PhotoKit 删除；它会保留 `Photos.sqlite` 的数据库结构，只清空照片资产相关表、`DCIM` 文件、缩略图和临时导入缓存，然后重启 `Photos`/`assetsd`。不要直接删除 `Photos.sqlite`，否则「照片」App 可能闪退。

交互确认版：

```bash
zsh scripts/delete_all_photos_from_instance.sh 2224
```

免确认版，适合自动化脚本：

```bash
zsh scripts/delete_all_photos_from_instance.sh 2224 --yes
```

成功时会输出类似：

```text
OK purged Photos assets; before_assets=12, before_files=12, remaining_assets=0, remaining_dcim_files=0, triggers=25
```

执行后重新打开「照片」App 即可。如果仍看到旧缩略图，重启一次该 VM。

越狱版会在 CFW/JB 安装阶段把 TrollStore Lite、`ldid`、`libplist3` 的本地 deb 一并写入 preboot：

```text
/private/preboot/<boot-hash>/vphone-local-debs/
```

因此首次启动时会优先从本地 deb 安装 TrollStore Lite；如果本地 deb 不可用，才回退到 guest 内的 apt/Havoc 源。

越狱版首次启动时还会默认写入 BigBoss 源：

```text
deb http://apt.thebigboss.org/repofiles/cydia/ stable main
```

### 行为说明

- **第一次运行**：如果不存在 `vm.backups/trollstore-jb/`，脚本会创建全新的 JB 固件环境：

  ```bash
  make setup_machine JB=1 NONE_INTERACTIVE=1
  ```

  完成后保存为：

  ```text
  vm.backups/trollstore-jb/
  ```

- **之后运行**：不会重新刷机；会直接使用或恢复 `vm.backups/trollstore-jb/`，然后启动 GUI。
- 如果当前 `vm/` 是常规版或开发版，脚本会先备份到：

  ```text
  vm.backups/regular-before-trollstore-YYYYMMDD-HHMMSS/
  ```

- 脚本会检查 Full Xcode/iPhoneOS SDK，并确保 `amfidont` 已为本仓库启动。
- 端口默认固定为 `2222/5901/5910`。如果这些端口已被其他进程占用，请先停止旧转发或旧 VM。

## 多开 TrollStore/JB 实例脚本

仓库根目录还提供一个“每次都创建新实例”的双击入口：

```text
create_trollstore_instance.command
```

用途：每次运行都创建一台新的、互相独立的 TrollStore/JB 虚拟 iPhone，适合多开测试。

### 使用方法

在 Finder 中双击：

```text
/Users/true/Documents/vphone-cli/create_trollstore_instance.command
```

脚本开始时会先询问一次 macOS 管理员密码（可直接回车跳过，跳过后仍按系统 sudo 原始方式提示）。建议输入一次，这样后续 DFU/ramdisk 阶段不会再反复卡 `Password:`。

随后会在终端中交互询问创建配置；最后一个配置问题是“创建数量”：

```text
固件版本：1=常规版，2=开发版，3=越狱版/TrollStore-JB
CPU 核心数 [4]
内存 GB [4]
硬盘 GB [32]
系统语言/地区
网络模式 nat / bridged / none
桥接网卡，例如 en0（仅 bridged 时）
实例名称/前缀 [auto]
创建数量 [1]
```

`实例名称/前缀` 留空或输入 `auto` 会继续使用自动时间戳名称。创建母盘时可以直接填固定名称，例如：

```text
trollstore-clean
```

这样会创建：

```text
vm.instances/trollstore-clean/
```

每次运行都会新建目录：

```text
vm.instances/trollstore-YYYYMMDD-HHMMSS/
```

如果 `创建数量` 大于 1，会使用同一个批次时间戳自动加序号：

```text
vm.instances/trollstore-YYYYMMDD-HHMMSS-01/
vm.instances/trollstore-YYYYMMDD-HHMMSS-02/
vm.instances/trollstore-YYYYMMDD-HHMMSS-03/
```

如果命令行指定了实例名前缀，例如 `trollstore-a` 且创建数量为 3，则会创建：

```text
trollstore-a-01
trollstore-a-02
trollstore-a-03
```

在 Finder 双击 `create_trollstore_instance.command` 时也可以通过交互输入同样的前缀；创建数量大于 1 时会自动追加 `-01/-02`。实例名只能包含英文、数字、下划线和中划线。

创建完成后会自动启动 GUI，并在该实例目录内生成：

```text
vm.instances/trollstore-YYYYMMDD-HHMMSS/launch_gui.command
vm.instances/trollstore-YYYYMMDD-HHMMSS/connect_ssh.command
vm.instances/trollstore-YYYYMMDD-HHMMSS/connection_info.txt
vm.instances/trollstore-YYYYMMDD-HHMMSS/instance.env
```

以后想再次打开这个实例，只需要双击它自己的：

```text
vm.instances/<实例名>/launch_gui.command
```

双击 `launch_gui.command` 时，终端窗口会在实例就绪、连接信息写入完成后自动关闭；启动日志仍保存在：

```text
vm.instances/<实例名>/logs/boot.log
```

### 关闭 GUI 窗口与真正关机

新版 GUI 窗口左上角关闭按钮 / `Cmd+W` 只会**隐藏窗口**，不会关闭虚拟 iPhone。实例会继续在后台运行，`vphone.sock`、SSH/VNC/RPC 转发也会继续保留。

如果隐藏后想重新显示窗口：

```text
在多开管理器里点击该实例的“启动 GUI/打开”
或再次双击 vm.instances/<实例名>/launch_gui.command
```

只有以下操作才会真正停止实例：

```text
多开管理器 -> 停止 / 批量停止
zsh scripts/stop_vphone_instance.sh vm.instances/<实例名>
```

停止脚本会先通过 `<实例目录>/vphone.sock` 通知当前 `vphone-cli` GUI 进程退出，再清理 Virtualization XPC 和 SSH/VNC/RPC 转发。如果仍有实例进程存活，脚本会返回失败，不会再误报“已停止”。

如果想临时保留终端窗口用于排错，可以从终端运行：

```bash
VPHONE_LAUNCH_CLOSE_TERMINAL=0 zsh vm.instances/<实例名>/launch_gui.command
```

批量创建时还会额外生成一个批量启动脚本：

```text
vm.instances/launch_batch_YYYYMMDD-HHMMSS.command
```

双击它会按顺序启动这一批实例的 GUI/SSH/VNC/RPC 转发。为避免多个 Virtualization GUI 同时启动导致 WindowServer 卡死，批量启动默认是**串行启动**，每台就绪后等待 3 秒再启动下一台。

如果机器资源充足或需要更保守，可以调整间隔：

```bash
VPHONE_BATCH_LAUNCH_DELAY_SECONDS=20 zsh vm.instances/launch_batch_YYYYMMDD-HHMMSS.command
```

也可以从终端创建带名称的实例：

```bash
zsh scripts/create_trollstore_instance.sh trollstore-a
```

自定义资源规格示例：

```bash
VPHONE_VARIANT=jb CPU=4 MEMORY_GB=4 DISK_SIZE=32 \
  zsh scripts/create_trollstore_instance.sh trollstore-small-01
```

一次创建多个实例示例：

```bash
VPHONE_VARIANT=jb CPU=4 MEMORY_GB=4 DISK_SIZE=32 \
VPHONE_CREATE_COUNT=3 \
  zsh scripts/create_trollstore_instance.sh trollstore-batch
```

自定义语言与网络模式示例：

```bash
VPHONE_VARIANT=jb CPU=4 MEMORY_GB=4 DISK_SIZE=32 \
VPHONE_LANGUAGE=zh-Hans VPHONE_LOCALE=zh_CN \
VPHONE_NETWORK_MODE=bridged VPHONE_NETWORK_INTERFACE=en0 \
  zsh scripts/create_trollstore_instance.sh trollstore-zh-bridge
```

也可以用本地配置文件，让 Finder 双击脚本也使用固定规格：

```bash
cp vphone_instance.conf.example vphone_instance.conf
open -e vphone_instance.conf
```

编辑其中的：

```bash
VPHONE_VARIANT=jb  # regular / dev / jb；交互中对应 1 / 2 / 3
CPU=4          # CPU 核心数
MEMORY_GB=4    # 内存，单位 GB；脚本会自动换算成 Makefile MEMORY=4096
DISK_SIZE=32   # 磁盘，单位 GB
# VPHONE_INSTANCE_NAME=trollstore-clean  # 可选固定实例名/前缀；留空则自动生成
VPHONE_CREATE_COUNT=1  # 一次创建几个实例；交互模式下会在最后询问
VPHONE_AUTO_LAUNCH_CREATED=1  # 1=创建完自动启动 GUI；0=只创建不启动
VPHONE_INTERACTIVE_CONFIG=1  # 1=启动时询问；0=完全使用配置文件/环境变量
# VPHONE_LANGUAGE=zh-Hans  # 系统语言；注释/留空表示使用系统默认
# VPHONE_LOCALE=zh_CN      # 地区/区域格式；注释/留空表示使用系统默认
VPHONE_NETWORK_MODE=nat  # nat / bridged / none
# VPHONE_NETWORK_INTERFACE=en0  # bridged 时指定宿主机网卡
```

`vphone_instance.conf` 会被以下脚本自动读取：

```text
launch_trollstore_vphone.command
create_trollstore_instance.command
```

如果要把 macOS 管理员密码写入文件，建议单独放到项目根目录 `.env`，不要放进普通配置文件：

```bash
cp .env.example .env
chmod 600 .env
open -e .env
```

`.env` 中写入：

```bash
VPHONE_SUDO_PASSWORD="你的 macOS 管理员密码"
```

`.env` 已加入 `.gitignore`，会被以下脚本自动读取：

```text
launch_trollstore_vphone.command
create_trollstore_instance.command
```

配置优先级为：

```text
命令行临时环境变量 > .env > vphone_instance.conf > 脚本默认值
```

所以命令行临时传入的环境变量优先级最高，适合一次性创建不同规格/语言/网络的实例。

多开实例创建后，也会把当时的语言/网络设置写入该实例自己的 `instance.env`；后续双击 `launch_gui.command` 会继续使用这些设置。

如果要用于无人值守自动化，可以禁用交互并直接用环境变量传参：

```bash
VPHONE_INTERACTIVE_CONFIG=0 \
VPHONE_VARIANT=regular CPU=4 MEMORY_GB=4 DISK_SIZE=32 \
VPHONE_LANGUAGE=en VPHONE_LOCALE=en_US \
VPHONE_NETWORK_MODE=none \
  zsh scripts/create_trollstore_instance.sh trollstore-offline-en
```

如果希望无人值守时自动传入 sudo 密码，可以临时用环境变量：

```bash
VPHONE_INTERACTIVE_CONFIG=0 \
VPHONE_SUDO_PASSWORD='你的 macOS 管理员密码' \
VPHONE_VARIANT=jb CPU=4 MEMORY_GB=4 DISK_SIZE=32 \
  zsh scripts/create_trollstore_instance.sh trollstore-auto-01
```

也可以写入 `.env` 让双击创建时自动读取，但这会明文保存 macOS 密码，只建议在本机受控环境短期使用。真正“完全不需要密码”的做法是配置 sudoers 的精确 `NOPASSWD` 白名单；不要使用 `NOPASSWD: ALL`，并且要意识到 `make fw_patch_*` 本身会执行项目脚本，放行过宽会降低本机安全边界。

> **注意：** CPU/内存/磁盘大小只在“创建新 VM”时生效；已经创建好的实例不会因为修改配置文件而自动变更。要使用新规格，请重新运行 `create_trollstore_instance.command` 创建新实例。语言会在 SSH 可用后写入 guest 偏好并重启 SpringBoard；网络模式会写入 `config.plist`，需要 VM 下次启动才生效。

### 连接信息

每个实例启动后会自动分配本机端口，并写入：

```text
vm.instances/<实例名>/connection_info.txt
```

示例内容：

```text
Native GUI/control socket:
  vm.instances/<实例名>/vphone.sock

SSH:
  sshpass -p alpine ssh -p <自动端口> root@127.0.0.1

VNC:
  vnc://127.0.0.1:<自动端口>

RPC:
  127.0.0.1:<自动端口>
```

端口分配从以下默认值开始，如被占用则自动递增：

```text
SSH: 2222+
VNC: 5901+
RPC: 5910+
```

### 实现要点

- `scripts/create_trollstore_instance.sh` 负责创建新实例，内部通过 `VM_DIR=<实例目录>` 调用 `scripts/setup_machine.sh --jb`。
- `scripts/launch_vphone_instance.sh` 负责启动已有实例，并为该实例建立 SSH/VNC/RPC 转发。
- `scripts/vphone_guest_config.sh` 负责共享的语言偏好写入与网络清单更新逻辑。
- 每个实例都有独立的：

  ```text
  Disk.img
  SEPStorage
  nvram.bin
  config.plist（包含该实例自己的 machineIdentifier）
  UDID/ECID
  vphone.sock
  ```

- `machineIdentifier` 在新 VM 第一次启动时生成并写入 `config.plist`，因此每个实例会获得独立 ECID/UDID。
- `networkConfig.mode` 保存在每个实例自己的 `config.plist` 中；`nat` 为默认，`bridged` 需要指定可桥接网卡，`none` 为离线。
- 语言设置写入 guest 的 `/var/mobile/Library/Preferences/.GlobalPreferences.plist` 和 `/var/root/Library/Preferences/.GlobalPreferences.plist`，并记录 marker，避免每次启动重复重启 SpringBoard。
- 多开实例存放在 `vm.instances/`，该目录已加入 `.gitignore`，不会进入版本控制。
- 创建流程使用 `.multi_create_trollstore.lock` 防止同时执行多个“刷机/创建”流程；**创建新实例请串行执行**。
- `创建数量` 大于 1 时，脚本是在同一个流程中**批量串行创建**多个实例，不是并行刷机；这是为了避免 DFU/recovery 端点、`setup_logs/`、`hdiutil` 挂载点和全局 vphone 进程清理互相冲突。
- 已创建好的实例可以并行启动：分别双击各自的 `launch_gui.command`。
- 多开管理器里的“批量启动”默认会安全串行启动，避免同时拉起多个 GUI/Virtualization 进程压垮 WindowServer。默认间隔 3 秒，可通过 `VPHONE_MANAGER_BATCH_LAUNCH_DELAY=20` 调整。

### 注意事项

- 每次创建新 TrollStore/JB 实例都是完整固件准备、DFU restore、ramdisk、CFW/JB 安装流程，首次耗时较长。
- 多开会占用 CPU、内存和磁盘。一键脚本交互默认值为 `CPU=4 MEMORY_GB=4 DISK_SIZE=32`；如直接使用底层 Makefile，默认仍是 `CPU=8 MEMORY=8192 DISK_SIZE=64`。
- 多开实例可以设置不同语言和网络模式；但 `nat` 模式下默认仍共享宿主机出口网络。
- 如果只是想重复打开同一台 TrollStore 环境，用 `launch_trollstore_vphone.command`；如果需要全新设备身份/全新数据盘，才用 `create_trollstore_instance.command`。
- 首次启动后，Sileo 和 TrollStore Lite 由 guest 内的 `/cores/vphone_jb_setup.sh` 自动完成安装，日志在 `/var/log/vphone_jb_setup.log`；TrollStore Lite 优先使用创建阶段预置到 preboot 的本地 deb，避免完全依赖 guest 网络；APT 默认源包含 Havoc 和 BigBoss。
- 不要手动复制正在运行中的 `Disk.img`。需要保留实例时，先正常关机或停止 VM，再备份实例目录。

### 从干净基准实例快速克隆多开

如果你已经准备好一个“干净、已完成 TrollStore/JB 首次配置、已关机”的基准实例，可以不用每台都重新走 DFU restore。推荐流程：

```text
干净基准实例关机
  → 克隆运行时文件
  → 清空克隆体 config.plist 里的 machineIdentifier
  → 首次启动克隆体时自动生成新的 ECID/UDID
  → 自动打开原生 GUI 并写入连接信息
```

一键双击：

```text
clone_vphone_instance.command
```

命令行：

```bash
zsh scripts/clone_vphone_instance.sh vm.instances/trollstore-clean-base
```

批量克隆：

```bash
VPHONE_CLONE_COUNT=5 \
VPHONE_CLONE_NAME=phone \
zsh scripts/clone_vphone_instance.sh vm.instances/trollstore-clean-base
```

生成结果示例：

```text
vm.instances/phone-01/
vm.instances/phone-02/
vm.instances/phone-03/
...
```

每个克隆体都会有自己的：

```text
config.plist            # machineIdentifier 已清空，首次启动重新生成
udid-prediction.txt     # 首次启动后写入新的 UDID/ECID
launch_gui.command      # 双击启动该实例原生 GUI
instance.env            # 独立端口配置，SSH/VNC/RPC 自动分配
```

也可以只对已有的停止实例重置底层身份：

```bash
zsh scripts/reset_vphone_identity.sh vm.instances/phone-01 --yes
zsh scripts/launch_vphone_instance.sh vm.instances/phone-01
cat vm.instances/phone-01/udid-prediction.txt
```

注意：

- 克隆来源必须先关机；不要复制正在运行的 `Disk.img`。
- 默认只重置 `machineIdentifier`，也就是影响 ECID/UDID 的宿主侧身份；不会改 guest 用户数据盘，也不会重置 `SEPStorage`，这样更稳。
- 如果来源实例本身是干净环境，那么用户数据盘里的历史缓存可以忽略；克隆后主要差异就是新的 ECID/UDID、独立端口和独立实例目录。
- 脚本优先使用 APFS clonefile / 稀疏复制，通常比完整重新刷机快很多，也不会立刻占满完整硬盘镜像大小。
- macOS 的 Unix socket 路径长度有限，`<实例目录>/vphone.sock` 太长时原生 GUI 仍可用，但 host-control socket 会不可用；脚本会跳过该等待并继续建立 SSH/VNC/RPC。新版本默认克隆名已缩短，手动命名时也建议用短名。

### 创建停在 `=== Boot analysis ===`

如果创建日志已经出现：

```text
=== Done ===
Setup completed.
=== Boot analysis ===
```

说明 restore、ramdisk、CFW/JB 安装和首次启动阶段已经完成；这里是 `setup_machine.sh` 额外跑的一次最终启动验证，不是必需的创建步骤。在部分主机上这个验证会卡在 boot preflight / AMFI 检查，或者等待不适合当前启动阶段的 shell prompt。

一键创建脚本默认会设置：

```bash
SKIP_BOOT_ANALYSIS=1
```

也就是跳过这一步，创建完成后直接交给实例自己的 `launch_gui.command` 正常启动 GUI。

如果旧流程已经停在这里，可以按 `Ctrl+C` 中断，然后补写实例启动脚本：

```bash
zsh scripts/finalize_vphone_instance.sh vm.instances/<实例名> jb
```

随后双击：

```text
vm.instances/<实例名>/launch_gui.command
```

### 启动 GUI 报 `signed release vphone-cli ... exit 137`

如果双击 `launch_gui.command` 时看到：

```text
Policy: .../.build/release/vphone-cli: rejected
[release_help] exit=137
Error: signed release vphone-cli is not launchable on this host
```

这不是 VM 实例坏了，而是宿主机 AMFI / Gatekeeper 仍在拦截带私有虚拟化 entitlement 的 `vphone-cli`。处理方法：

```bash
cd /Users/true/Documents/vphone-cli
make amfidont_allow_vphone
```

按提示输入 macOS 管理员密码，然后验证：

```bash
.build/release/vphone-cli --help >/dev/null && echo OK
```

输出 `OK` 后重新双击该实例的：

```text
vm.instances/<实例名>/launch_gui.command
```

新版 `launch_gui.command` 会在发现 `vphone-cli` 被 137 杀掉时自动尝试启动 `amfidont`，并在终端里提示输入一次管理员密码。

### GUI 二开设计文档

本地 GUI 菜单中文化、toolbar 快捷按钮、多开管理器、`vphone.sock` 自动化扩展的设计和任务拆分，见 [GUI 二开设计与任务拆分](./GUI_SECONDARY_DEVELOPMENT_zh.md)。

当前右侧快捷栏包含：安装 IPA、导入图片、粘贴输入ASCII、清空相册、截图、重启、Restart SpringBoard、SSH 信息。

多开管理器有两个入口。

独立管理器（推荐，类似云手机客户端）：

```text
Finder 双击：vphone_manager.command
命令行：make manager
命令行：.build/release/vphone-cli manager --project-root /Users/true/Documents/vphone-cli
```

主 GUI 内嵌表格管理器入口：

```text
实例管理 -> 多开管理器...
```

独立管理器会扫描 `vm.instances/*`，以卡片网格显示实例状态、UDID/ECID、SSH/VNC/RPC 端口、CPU/内存/硬盘、语言和网络，并提供：

```text
批量启动
批量停止
批量安装 IPA
启动 GUI
停止
克隆
安装 IPA
导入图片到相册
清空相册
粘贴输入ASCII
一键重启
Restart SpringBoard
连接信息
复制身份
打开目录
打开日志
```

其中“启动 GUI”对已在后台运行的实例会唤回隐藏的原生 GUI 窗口；“停止”才是真正关机。

空坑位的“创建”按钮默认从 `trollstore-clean` 母盘克隆新实例，适合本地小规模多开。

管理器执行的后台任务日志在：

```text
vm.instances/<实例名>/logs/manager-actions.log
```

二开设计和后续任务拆分见 [GUI 二开设计与任务拆分](./GUI_SECONDARY_DEVELOPMENT_zh.md)。

### 一键把 macOS 剪贴板 ASCII 输入到实例

如果已经在 vphone 里点中了某个输入框，可以用脚本把 macOS 剪贴板里的 ASCII 文本通过虚拟键盘输入进去，等价于 GUI 菜单：

```text
按键 -> 从剪贴板输入 ASCII
```

用法：

```bash
cd /Users/true/Documents/vphone-cli
zsh scripts/type_clipboard_ascii_to_instance.sh vm.instances/<实例名>
```

指定文本，不读剪贴板：

```bash
zsh scripts/type_clipboard_ascii_to_instance.sh vm.instances/<实例名> --text 'hello123'
```

从 stdin 输入，适合自动化流水线：

```bash
printf 'hello123' | zsh scripts/type_clipboard_ascii_to_instance.sh vm.instances/<实例名> --stdin
```

从文件输入：

```bash
zsh scripts/type_clipboard_ascii_to_instance.sh vm.instances/<实例名> --file /tmp/input.txt
```

注意：

- 目标实例 GUI 必须已经运行，并且 `<实例目录>/vphone.sock` 存在。
- 输入前需要先让 guest 里的目标输入框获得焦点；自动化时可以先用 `vphone.sock` 的 `tap` 命令点一下输入框。
- 该脚本走虚拟键盘事件，只支持 ASCII；中文、emoji、复杂 Unicode 会被跳过。如果要输入中文，优先用 `连接 -> 设置剪贴板文本...` 或后续剪贴板同步脚本。

### 一键安装 IPA/TIPA 到指定实例

`vphone-cli` 自带菜单 `Apps → Install IPA/TIPA...`。如果要从命令行直接传入 IPA 路径和目标实例，可以用：

```bash
zsh scripts/install_ipa_to_instance.sh /path/to/App.ipa vm.instances/<实例名>
```

参数顺序也可以反过来：

```bash
zsh scripts/install_ipa_to_instance.sh vm.instances/<实例名> /path/to/App.tipa
```

双击交互版：

```text
install_ipa_to_instance.command
```

行为：

- 如果实例已经运行，并且 `<实例目录>/vphone.sock` 可用，脚本会直接通过当前 GUI 进程的 host-control socket 调用内置 IPA 安装器。
- 如果实例没有运行，脚本会启动该实例，并通过 `vphone-cli --install-ipa <路径>` 在 guest `vphoned` 连接后自动安装。
- 如果实例正在运行但路径太长导致 `vphone.sock` 不可用，GUI 仍可用，但运行时一键安装无法走 host-control；建议关闭实例后重跑安装脚本，或使用更短的实例目录名。

安装日志：

```bash
tail -f vm.instances/<实例名>/logs/boot.log
```

## VM 备份与切换

保存并切换多个 VM 环境（例如不同的 iOS 构建版本或固件变体）。备份存储在 `vm.backups/` 下，使用 `rsync --sparse` 高效处理稀疏磁盘镜像。

```bash
make vm_backup NAME=26.1-clean    # 保存当前 VM
rm -rf vm && make vm_new          # 清空后从新构建开始
# ... fw_prepare, fw_patch, restore, cfw_install, boot
make vm_backup NAME=26.3-jb       # 保存新的 VM
make vm_list                      # 列出所有备份
make vm_switch NAME=26.1-clean    # 在不同备份之间切换
```

> **注意：** 备份/切换/恢复前请先停止 VM。

## 常见问题（FAQ）

> **在做其他任何事情之前——先运行 `git pull` 确保你有最新版。**

**问：运行时出现 `zsh: killed ./vphone-cli`。**

AMFI/调试限制未正确绕过。选择以下任一方式：

- **方式 1（完全禁用 AMFI）：**

  ```bash
  sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
  ```

- **方式 2（仅禁用调试限制）：**
  在恢复模式中使用 `csrutil enable --without debug`（不完全禁用 SIP），然后安装/加载 [`amfidont`](https://github.com/zqxwce/amfidont) 或 [`amfree`](https://github.com/retX0/amfree)，保持 AMFI 其他功能不变。
  在本仓库中，也可通过 `make amfidont_allow_vphone` 自动写入 `amfidont` 所需的编码路径与 CDHash 允许配置。

**问：`make boot` / `make boot_dfu` 启动后报错 `VZErrorDomain Code=2 "Virtualization is not available on this hardware."`。**

这是因为宿主机本身运行在 Apple 虚拟机中，无法再进行嵌套 Virtualization.framework 来启动 guest。请在非嵌套的 macOS 15+ 主机上运行。可用 `make boot_host_preflight` 检查，若显示 `Model Name: Apple Virtual Machine 1` 和 `kern.hv_vmm_present=1` 即为该情况。当前版本会在此类宿主机上通过 `boot_binary_check` 在启动前快速失败。

**问：系统应用（App Store、信息等）无法下载或安装。**

在 iOS 初始设置过程中，请**不要**选择**日本**或**欧盟地区**作为你的国家/地区。这些地区要求额外的合规检查（如侧载披露、相机快门声等），虚拟机无法满足这些要求，因此系统应用无法正常下载安装。请选择其他地区（例如美国）以避免此问题。

**问：卡在"Press home to continue"屏幕。**

通过 VNC (`vnc://127.0.0.1:5901`) 连接，并在屏幕上右键单击任意位置（在 Mac 触控板上双指点击）。这会模拟 Home 按钮按下。

**问：如何获得 SSH 访问？**

从 Sileo 安装 `openssh-server`（越狱变体首次启动后可用）。

**问：安装 openssh-server 后 SSH 无法使用。**

重启虚拟机。SSH 服务器将在下次启动时自动启动。

**问：可以安装 `.tipa` 文件吗？**

可以。安装菜单同时支持 `.ipa` 和 `.tipa` 包。拖放或使用文件选择器即可。

**问：可以升级到更新的 iOS 版本吗？**

可以。使用你想要的版本的 IPSW URL 覆盖 `fw_prepare`：

```bash
export IPHONE_SOURCE=/path/to/some_os.ipsw
export CLOUDOS_SOURCE=/path/to/some_os.ipsw
make fw_prepare
make fw_patch
```

我们的补丁是通过二进制分析（binary analysis）而非静态偏移（static offsets）应用的，因此更新的版本应该也能正常工作。如果出现问题，可以寻求 AI 的帮助。

**问：使用 `restore_offline` 后卡在设置界面。**

设备在设置过程中会尝试连接 Apple，如果你使用了 `restore_offline`，很可能当前没有联网。
你可以将设备设为 supervised，以绕过大部分设置界面：

```bash
python3 -m pymobiledevice3 profile supervise vphone
```

## 致谢

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
