# vphone-cli GUI 二开设计与任务拆分

本文用于规划本地小规模多开场景下的 `vphone-cli` GUI 二开。目标是把当前偏研究工具的 GUI，改造成更适合日常批量操作的本地实例控制台。

范围限定：

- 面向本机使用，不设计对外出租、多租户计费或公网服务。
- 优先复用现有 Swift GUI、`vphoned` vsock 控制通道、`vphone.sock` host-control socket 和已有 shell 脚本。
- 不修改固件补丁链，不涉及 kernel patch；因此无需更新 `research/0_binary_patch_comparison.md`。
- 不使用 `/TODO.md` 记录任务；任务状态放在本文、提交记录或实现注释中。

## 1. 当前 GUI 架构速览

主要源码目录：

```text
sources/vphone-cli/
```

关键文件：

| 文件 | 作用 |
| --- | --- |
| `main.swift` | AppKit 应用入口。 |
| `VPhoneCLI.swift` | CLI 参数定义，例如 `--install-ipa`。 |
| `VPhoneAppDelegate.swift` | 启动 VM、创建窗口、创建菜单、连接 `vphoned`、启动 host-control。 |
| `VPhoneVirtualMachine.swift` | Virtualization.framework VM 配置和生命周期。 |
| `VPhoneVirtualMachineView.swift` | VM 画面、触控、截图相关视图。 |
| `VPhoneWindowController.swift` | 主窗口、右侧快捷按钮栏和窗口标题状态。 |
| `VPhoneMenuController.swift` | 菜单总入口和菜单状态对象。 |
| `VPhoneMenuConnect.swift` | Connect 菜单：文件、钥匙串、剪贴板、设置、定位、电池等。 |
| `VPhoneMenuKeys.swift` | Keys 菜单：Home、Power、音量、Spotlight、粘贴输入。 |
| `VPhoneMenuApps.swift` | Apps 菜单：App Browser、Open URL、Install IPA/TIPA。 |
| `VPhoneMenuRecord.swift` | Record 菜单：录屏、截图。 |
| `VPhoneControl.swift` | Host 到 guest `vphoned` 的 vsock JSON 协议客户端。 |
| `VPhoneHostControl.swift` | Host 本地 Unix socket：`<vm-dir>/vphone.sock`，给脚本/自动化调用 GUI 能力。 |
| `VPhoneFileBrowser*` | SwiftUI 文件管理器。 |
| `VPhoneAppBrowser*` | SwiftUI App 管理器。 |
| `VPhoneKeychain*` | SwiftUI 钥匙串浏览器。 |

当前 GUI 启动链路：

```text
main.swift
  -> VPhoneAppDelegate.applicationDidFinishLaunching
    -> startVirtualMachine()
      -> VPhoneVirtualMachine.start()
      -> VPhoneControl.connect(vsock)
      -> VPhoneWindowController.showWindow()
      -> VPhoneMenuController(...).setupMenuBar()
      -> VPhoneHostControl.start(<vm-dir>/vphone.sock)
```

## 2. 二开目标

优先满足本地多开操作：

1. 菜单中文化，并新增“实例管理”菜单。
2. 主窗口顶部增加高频按钮。
3. 新增本地“多开管理器”窗口，管理 `vm.instances/*`。
4. 扩展 `vphone.sock` 命令，让命令行和 GUI 复用同一套能力。

## 3. 设计原则

- **先本地、后服务化**：当前不做 Web 后台，不引入数据库。实例状态从目录、`config.plist`、`instance.env`、`connection_info.txt`、`logs/` 和 `lsof` 推断。
- **动作逻辑复用**：菜单、右侧栏、host-control 不要各自复制业务逻辑。建议新增一个 action 层，例如 `VPhoneGUIActions.swift`，统一实现安装 IPA、截图、按键、读取连接信息等。
- **运行态优先走 `VPhoneControl`**：VM 已运行并且 `vphoned` 已连接时，优先通过 vsock 调用 guest 能力。
- **外部批量优先走 `vphone.sock` 或脚本**：命令行批量控制优先使用 `<vm-dir>/vphone.sock`；如果 VM 未运行，则由脚本启动并传入一次性参数。
- **避免 UI 阻塞**：耗时任务使用 `Task` 或后台 `Process`，日志写入实例目录 `logs/`。
- **保留研究工具风格**：界面简洁、单色、状态明确，不做复杂装饰。
- **路径长度限制**：macOS Unix socket 路径约 103 bytes；实例目录名过长时 `vphone.sock` 可能创建失败。多开管理器默认生成短实例名。

## 4. 功能蓝图

### 4.1 菜单改造

目标菜单结构：

```text
vphone
连接
  文件管理器
  钥匙串
  开发者模式状态
  Ping
  Guest 版本
  读取剪贴板
  设置剪贴板文本...
  读取设置...
  写入设置...
按键
  主屏幕
  电源
  音量+
  音量-
  Spotlight
  从剪贴板粘贴输入ASCII
应用
  App 管理器
  打开 URL...
  安装 IPA/TIPA...
录制/截图
  开始录屏
  复制截图到剪贴板
  保存截图到文件
实例管理
  多开管理器...
  安装 IPA/TIPA...
  导入图片到相册...
  清空相册...
  一键重启
  Restart SpringBoard
  查看连接信息
  复制 UDID/ECID
  打开实例目录
  打开日志目录
```

实现文件：

```text
VPhoneMenuController.swift
VPhoneMenuConnect.swift
VPhoneMenuKeys.swift
VPhoneMenuApps.swift
VPhoneMenuRecord.swift
新增：VPhoneMenuInstance.swift
可选新增：VPhoneMenuText.swift
```

### 4.2 右侧栏快捷按钮

目标按钮：

```text
Home
安装 IPA
导入图片
粘贴输入ASCII
清空相册
截图
重启
Restart SpringBoard
SSH 信息
```

实现文件：

```text
VPhoneWindowController.swift
VPhoneAppDelegate.swift
可选新增：VPhoneGUIActions.swift
```

建议：

- `VPhoneWindowController` 只负责创建右侧栏按钮和触发 closure。
- 第一版通过 closure 复用菜单动作；后续动作复杂后再抽 `VPhoneGUIActions`，避免菜单、右侧栏、host-control 逻辑重复。
- 右侧栏按钮的启用/禁用状态跟随 `VPhoneControl.isConnected` 和 guest capabilities。

### 4.3 多开管理器

状态：已实现第二版（2026-05-05）。

当前入口：

```text
实例管理 -> 多开管理器...
双击：vphone_manager.command
命令行：make manager
命令行：.build/release/vphone-cli manager --project-root /Users/true/Documents/vphone-cli
```

第一版表格窗口能力：

- 扫描 `vm.instances/*/config.plist`。
- 展示实例名、状态、变体、CPU/内存/硬盘、SSH/VNC/RPC 端口、UDID/ECID、语言/网络。
- 支持刷新、启动 GUI、停止实例、克隆、安装 IPA/TIPA、查看连接信息、复制身份、打开目录、打开日志。
- 动作全部后台执行，不阻塞主 GUI；日志写入各实例：

```text
vm.instances/<实例名>/logs/manager-actions.log
```

已落地文件：

```text
sources/vphone-cli/VPhoneInstanceRecord.swift
sources/vphone-cli/VPhoneInstanceScanner.swift
sources/vphone-cli/VPhoneInstanceManager.swift
sources/vphone-cli/VPhoneInstanceListView.swift
sources/vphone-cli/VPhoneInstanceWindowController.swift
scripts/stop_vphone_instance.sh
```

第二版独立卡片式管理器能力：

- 新增 `manager` 子命令：只打开管理器，不启动任何 VM。
- 新增独立双击入口 `vphone_manager.command`，启动后自动后台打开管理器窗口，可关闭 Terminal 原窗口。
- 左侧显示分组、搜索、统计和坑位数量；主区域显示类似云机客户端的实例卡片网格。
- 每张卡片显示：编号、实例名、状态、变体、规格、网络、UDID/ECID、SSH/VNC/RPC 端口。
- 支持批量选择、批量启动、批量停止、批量安装同一个 IPA/TIPA。
- 空坑位支持“创建”：默认从已关机的 `trollstore-clean` 母盘克隆，生成短名 `phone-xx`。
- 右键卡片可执行：启动/停止、克隆、安装 IPA/TIPA、导入图片到相册、清空相册、粘贴输入ASCII、一键重启、Restart SpringBoard、连接信息、复制身份、打开目录、打开日志。
- 原生实例 GUI 的关闭按钮 / `Cmd+W` 改为隐藏窗口，不再触发 VM 退出；管理器里的“启动 GUI/打开”会通过 `vphone.sock` 的 `show_window` 命令唤回隐藏窗口；只有“停止/批量停止”才调用停止脚本真正关机。
- 停止脚本会先通过 `vphone.sock` 的 `terminate_host` 命令让当前 `vphone-cli` GUI 进程退出，再递归清理该实例相关 host 进程；如果仍有进程存活，脚本会返回失败，不再误报“stopped”。

第二版已落地文件：

```text
sources/vphone-cli/VPhoneManagerAppDelegate.swift
sources/vphone-cli/VPhoneManagerWindowController.swift
sources/vphone-cli/VPhoneManagerDashboardView.swift
sources/vphone-cli/VPhoneCLI.swift
sources/vphone-cli/main.swift
scripts/launch_vphone_manager.sh
vphone_manager.command
Makefile
```

管理器窗口列出本地实例：

```text
trollstore-clean
phone-01
phone-02
phone-03
```

每行显示：

```text
状态：运行中 / 已关机 / 启动中 / 异常
变体：regular / dev / jb
UDID
ECID
SSH 端口
VNC 端口
RPC 端口
磁盘大小
最后启动时间
```

每行动作：

```text
启动 GUI
关闭/停止
克隆
安装 IPA
打开实例目录
打开日志
查看连接信息
```

实现文件：

```text
新增：VPhoneInstanceManager.swift
新增：VPhoneInstanceListView.swift
新增：VPhoneInstanceRecord.swift
可选新增：VPhoneInstanceProcess.swift
```

数据来源：

```text
vm.instances/*/config.plist
vm.instances/*/.vm_name
vm.instances/*/.vphone_variant
vm.instances/*/instance.env
vm.instances/*/udid-prediction.txt
vm.instances/*/connection_info.txt
vm.instances/*/logs/boot.log
vm.instances/*/logs/boot.pid
lsof Disk.img / SEPStorage / nvram.bin / vphone.sock
```

操作复用已有脚本：

```text
scripts/launch_vphone_instance.sh
scripts/clone_vphone_instance.sh
scripts/install_ipa_to_instance.sh
scripts/import_photo_to_instance.sh
scripts/delete_all_photos_from_instance.sh
scripts/type_clipboard_ascii_to_instance.sh
```

### 4.4 `vphone.sock` 自动化扩展

当前已有 host-control 命令：

示例脚本位于 `scripts/businessScript/vphone_automation_example.py`；后续可在 `scripts/businessScript/<app>/` 下放置针对不同 App 的业务流程脚本，并复用该示例里的 socket / SSH helper。通用业务自动化层的分层、目录、迁移路线见 [vphone 业务自动化通用层设计](./BUSINESS_AUTOMATION_DESIGN_zh.md)。

```json
{"t":"screenshot"}
{"t":"tap","x":645,"y":1398}
{"t":"swipe","x1":645,"y1":2600,"x2":645,"y2":1400,"ms":300}
{"t":"key","name":"home"}
{"t":"type","text":"Hello"}
{"t":"app_launch","bundle_id":"com.example.app","screen":false}
{"t":"app_terminate","bundle_id":"com.example.app","screen":false}
{"t":"accessibility_tree","bundle_id":"com.example.app","max_nodes":500,"screen":false}
{"t":"install_ipa","path":"/path/App.ipa","screen":false}
{"t":"show_window","screen":false}
{"t":"terminate_host","screen":false}
```

`accessibility_tree` 不做 OCR；它由 guest `vphoned` 调用 iOS Accessibility 私有框架读取当前 App 暴露的可访问元素，并返回 `nodes/tree`、`label/value/identifier/role`、逻辑点坐标 `frame/center` 与可直接点击的截图像素坐标 `frame_pixels/center_pixels`。业务脚本优先传 `bundle_id`，再用 `scripts/businessScript/vphone.py ui find|tap-text ...` 封装查询和点击。

建议新增命令：

| 命令 | 示例 | 说明 |
| --- | --- | --- |
| `status` | `{"t":"status"}` | 返回 connected、guestIP、caps、ECID、窗口尺寸。 |
| `connection_info` | `{"t":"connection_info"}` | 返回 SSH/VNC/RPC/socket/log 路径。 |
| `show_window` | `{"t":"show_window","screen":false}` | 唤回隐藏的原生 GUI 窗口。 |
| `terminate_host` | `{"t":"terminate_host","screen":false}` | 让当前实例的 `vphone-cli` host GUI 进程退出，供停止脚本使用。 |
| `open_url` | `{"t":"open_url","url":"https://example.com"}` | 调用 guest 打开 URL。 |
| `clipboard_get` | `{"t":"clipboard_get"}` | 获取 guest 剪贴板文本。 |
| `clipboard_set` | `{"t":"clipboard_set","text":"abc"}` | 设置 guest 剪贴板。 |
| `app_list` | `{"t":"app_list"}` | 返回 App 列表。 |
| `import_photo` | `{"t":"import_photo","path":"/path/a.jpg"}` | 导入图片到相册。优先新增 guest `vphoned` 能力；短期可调用现有脚本。 |
| `delete_photos` | `{"t":"delete_photos","confirm":true}` | 清空相册。优先新增 guest `vphoned` 能力，避免 UI 弹窗导致状态异常。 |
| `reboot` | `{"t":"reboot"}` | guest 重启或 host 侧重启 VM。 |
| `shutdown` | `{"t":"shutdown"}` | 关闭当前 VM。 |

实现文件：

```text
VPhoneHostControl.swift
VPhoneControl.swift
scripts/install_ipa_to_instance.sh
后续按需修改 scripts/vphoned/*
```

## 5. 任务拆分

### M0 — 基线整理

**GUI-000：确认当前可编译基线**

- 文件：无代码改动。
- 命令：

```bash
make build
```

- 验收：`.build/release/vphone-cli --help` 可运行；现有 `make boot` 不退化。

**GUI-001：建立 GUI 二开文档入口**

- 文件：

```text
docs/GUI_SECONDARY_DEVELOPMENT_zh.md
docs/README_zh.md
```

- 验收：README 能跳转到本文。

### M1 — 菜单中文化和实例管理菜单

状态：已实现第一版（2026-05-05）。

已落地文件：

```text
sources/vphone-cli/VPhoneMenuText.swift
sources/vphone-cli/VPhoneMenuInstance.swift
sources/vphone-cli/VPhoneMenuController.swift
sources/vphone-cli/VPhoneMenuConnect.swift
sources/vphone-cli/VPhoneMenuKeys.swift
sources/vphone-cli/VPhoneMenuApps.swift
sources/vphone-cli/VPhoneMenuRecord.swift
sources/vphone-cli/VPhoneMenuLocation.swift
sources/vphone-cli/VPhoneMenuBattery.swift
sources/vphone-cli/VPhoneAppDelegate.swift
```

已验证：`make build` 成功。

**GUI-101：新增菜单文案集中定义**

- 文件：

```text
新增：sources/vphone-cli/VPhoneMenuText.swift
```

- 内容：集中定义中文菜单名和 alert 标题。
- 验收：替换文案时不需要到多个文件里搜索硬编码英文。

**GUI-102：中文化现有菜单**

- 文件：

```text
VPhoneMenuController.swift
VPhoneMenuConnect.swift
VPhoneMenuKeys.swift
VPhoneMenuApps.swift
VPhoneMenuRecord.swift
VPhoneMenuLocation.swift
VPhoneMenuBattery.swift
```

- 验收：顶部菜单显示中文；功能行为保持不变。

**GUI-103：新增“实例管理”菜单**

- 文件：

```text
新增：VPhoneMenuInstance.swift
修改：VPhoneMenuController.swift
修改：VPhoneAppDelegate.swift
```

- 菜单项：多开管理器、安装 IPA、导入图片、清空相册、一键重启、Restart SpringBoard、查看连接信息、复制 UDID/ECID、打开实例目录、打开日志目录。
- 验收：所有菜单项可点击；不可用状态正确禁用。

**GUI-104：连接信息弹窗**

- 文件：

```text
VPhoneMenuInstance.swift
VPhoneAppDelegate.swift
```

- 内容：读取当前 `VM_DIR/connection_info.txt` 和 `udid-prediction.txt`。
- 验收：弹窗显示 SSH/VNC/RPC/socket/log；提供“复制”按钮。

### M2 — 右侧栏快捷按钮

状态：已实现第一版（2026-05-05）。

已落地文件：

```text
sources/vphone-cli/VPhoneWindowController.swift
sources/vphone-cli/VPhoneAppDelegate.swift
```

已新增右侧栏按钮：主屏幕、安装 IPA、导入图片、粘贴输入ASCII、清空相册、截图、重启、Restart SpringBoard、SSH 信息。顶部 toolbar 不再承载这些按钮，避免折叠并保留窗口标题/实例信息显示空间。右侧栏第一版调整为 35px 图标栏，按钮默认只显示图标，鼠标悬停快速显示文字说明。

已验证：`make build` 成功。

**GUI-201：设计快捷按钮 action closure**

- 文件：

```text
VPhoneWindowController.swift
VPhoneAppDelegate.swift
```

- 内容：`VPhoneWindowController` 暴露 closure，例如 `onInstallPackagePressed`、`onImportPhotoPressed`、`onScreenshotPressed`、`onRebootPressed`、`onConnectionInfoPressed`。
- 第一版通过 closure 复用 `VPhoneMenuController` 已有动作；后续动作变多时再抽 `VPhoneGUIActions.swift`。
- 验收：WindowController 不直接持有复杂业务逻辑。

**GUI-202：新增右侧栏按钮**

- 文件：

```text
VPhoneWindowController.swift
```

- 按钮：安装 IPA、导入图片、粘贴输入ASCII、清空相册、截图、重启、Restart SpringBoard、SSH 信息。
- 验收：按钮位于 GUI 右侧 35px 图标栏，默认只显示图标，鼠标悬停快速显示 tooltip；点击后调用 action；顶部标题不被按钮挤压。

**GUI-203：统一菜单和右侧栏行为**

- 文件：

```text
VPhoneMenuInstance.swift
VPhoneWindowController.swift
VPhoneAppDelegate.swift
```

- 验收：从菜单和右侧栏执行同一动作，结果一致。

### M3 — 多开管理器

**GUI-301：实例扫描模型**

状态：已实现第一版。

- 文件：

```text
新增：VPhoneInstanceRecord.swift
新增：VPhoneInstanceManager.swift
新增：VPhoneInstanceScanner.swift
```

- 内容：扫描 `vm.instances/*`，解析 `config.plist`、`instance.env`、`udid-prediction.txt`、`connection_info.txt`。
- 验收：能列出所有实例和状态。

**GUI-302：SwiftUI 实例列表窗口**

状态：已实现第一版。

- 文件：

```text
新增：VPhoneInstanceListView.swift
新增：VPhoneInstanceWindowController.swift
修改：VPhoneMenuController.swift 或 VPhoneMenuInstance.swift
```

- 验收：菜单“多开管理器”可打开窗口；列表可刷新。

**GUI-303：启动/打开 GUI**

状态：已实现第一版。

- 文件：

```text
VPhoneInstanceManager.swift
```

- 实现：后台 `Process` 调用：

```bash
zsh scripts/launch_vphone_instance.sh <vm-dir>
```

- 验收：点击实例的“启动 GUI”不阻塞主 UI。

**GUI-304：克隆实例**

状态：已实现第一版。

- 文件：

```text
VPhoneInstanceManager.swift
VPhoneInstanceListView.swift
```

- 实现：后台 `Process` 调用：

```bash
VPHONE_CLONE_NAME=<name> VPHONE_CLONE_COUNT=<n> zsh scripts/clone_vphone_instance.sh <source-vm-dir>
```

- 验收：可从 `trollstore-clean` 克隆短名实例；克隆完成后列表刷新。

**GUI-305：实例级安装 IPA**

状态：已实现第一版。

- 文件：

```text
VPhoneInstanceManager.swift
VPhoneInstanceListView.swift
```

- 实现：后台调用：

```bash
zsh scripts/install_ipa_to_instance.sh <ipa> <vm-dir>
```

- 验收：实例未运行时可启动后安装；实例运行且 socket 可用时可直接安装。

**GUI-306：停止实例**

状态：已实现第二版。

- 文件：

```text
新增：scripts/stop_vphone_instance.sh
修改：VPhoneInstanceManager.swift
修改：VPhoneInstanceListView.swift
```

- 实现：优先通过 SSH `halt/shutdown -h now`；随后通过 `<vm-dir>/vphone.sock` 发送 `terminate_host`，让当前实例的 `vphone-cli` GUI 进程退出；再递归清理 boot pid、Virtualization XPC 进程和本地 SSH/VNC/RPC 转发。
- 验收：点击“停止”后实例状态刷新为“已关机”；如果仍有 host 进程存活，脚本返回失败，管理器底部显示“停止实例 失败”。

**GUI-307：独立卡片式多开管理器**

状态：已实现第一版。

- 文件：

```text
新增：VPhoneManagerAppDelegate.swift
新增：VPhoneManagerWindowController.swift
新增：VPhoneManagerDashboardView.swift
修改：VPhoneCLI.swift
修改：main.swift
修改：VPhoneInstanceManager.swift
新增：scripts/launch_vphone_manager.sh
新增：vphone_manager.command
修改：Makefile
```

- 实现：新增 `vphone-cli manager` 子命令，独立打开管理器 App，不启动 VM；主界面采用左侧分组 + 顶部标签 + 批量工具条 + 实例卡片网格。
- 验收：

```bash
make manager
# 或 Finder 双击 vphone_manager.command
```

- 说明：空坑位“创建”默认从 `trollstore-clean` 克隆，适合本地小规模快速多开。

**GUI-308：关闭 GUI 窗口仅隐藏，不关机**

状态：已实现第一版。

- 文件：

```text
修改：VPhoneWindowController.swift
修改：VPhoneAppDelegate.swift
修改：VPhoneHostControl.swift
修改：scripts/launch_vphone_instance.sh
```

- 实现：`windowShouldClose` 拦截关闭按钮 / `Cmd+W`，执行 `orderOut` 隐藏窗口并返回 `false`；`applicationShouldTerminateAfterLastWindowClosed` 固定返回 `false`；host-control 新增 `show_window` 命令；`launch_vphone_instance.sh` 在检测到实例已运行且 socket 可用时调用 `show_window` 唤回 GUI。
- 验收：关闭原生 GUI 窗口后实例仍为“运行中”；SSH/VNC/RPC 仍可用；从多开管理器点击“启动 GUI/打开”能重新显示窗口；点击“停止”才真正关机。

### M4 — Host-control 扩展

**GUI-401：`status` 命令**

- 文件：

```text
VPhoneHostControl.swift
```

- 返回字段：`ok`、`connected`、`guest_ip`、`caps`、`ecid`、`screen_width`、`screen_height`。
- 验收：

```bash
python3 - <<'PY'
import json, socket
s=socket.socket(socket.AF_UNIX)
s.connect('vm.instances/trollstore-clean/vphone.sock')
s.sendall(b'{"t":"status","screen":false}\n')
print(s.recv(65536).decode())
PY
```

**GUI-402：`connection_info` 命令**

- 文件：

```text
VPhoneHostControl.swift
VPhoneVirtualMachine.Options 或 VPhoneAppDelegate 注入 vmDir
```

- 验收：脚本可直接拿到 SSH/VNC/RPC 信息，不必解析文本文件。

**GUI-402A：`type_ascii` 命令和独立脚本**

- 文件：

```text
VPhoneHostControl.swift
VPhoneKeyHelper.swift
VPhoneAppDelegate.swift
scripts/type_clipboard_ascii_to_instance.sh
```

- 状态：已实现第一版（2026-05-05）。
- 用途：把 macOS 剪贴板、stdin、文件或指定文本通过 VM 键盘事件输入到当前 guest 焦点字段。
- 验收：`make build` 和 `zsh -n scripts/type_clipboard_ascii_to_instance.sh` 成功。

**GUI-403：剪贴板 / URL / App 控制命令**

- 文件：

```text
VPhoneHostControl.swift
VPhoneControl.swift
```

- 命令：`open_url`、`clipboard_get`、`clipboard_set`、`app_list`；`app_launch` / `app_terminate` 已接入 host-control。
- 验收：返回 JSON 可供批量脚本调用。

**GUI-404：相册导入命令**

- 短期实现：host-control 调用现有脚本 `scripts/import_photo_to_instance.sh`。
- 长期实现：给 `scripts/vphoned/` 增加原生 `photo_import` 请求，避免依赖 SSH/外部脚本。
- 验收：导入后相册可识别，不需要手动刷新。

**GUI-405：相册清空命令**

- 短期实现：复用现有脚本，但需要避免 Photos App 弹窗路径。
- 长期实现：给 guest daemon 增加原生清理逻辑，并重建 Photos 数据库/缓存一致性。
- 验收：清空后 Photos App 不闪退。

### M5 — 验证与打包

**GUI-501：编译验证**

```bash
make build
```

**GUI-502：单实例手测**

```bash
zsh scripts/launch_vphone_instance.sh vm.instances/trollstore-clean
```

检查：

- 菜单显示中文。
- 右侧栏按钮可用，顶部标题/实例信息不被按钮挤压。
- 安装 IPA 成功。
- 截图成功。
- 连接信息正确。

**GUI-503：多开手测**

```bash
VPHONE_CLONE_NAME=phone VPHONE_CLONE_COUNT=2 \
  zsh scripts/clone_vphone_instance.sh vm.instances/trollstore-clean
```

检查：

- 多开管理器能看到母盘和两个克隆。
- 克隆实例状态互不影响。
- 每个实例路径足够短，`vphone.sock` 可创建。

## 6. 建议实施顺序

推荐先做低风险、能马上提升效率的部分：

1. **M1 菜单中文化 + 实例管理菜单**
2. **M2 右侧栏快捷按钮**
3. **M4 host-control 的 `status` / `connection_info` / `clipboard` / `open_url`**
4. **M3 多开管理器**
5. **M4 相册原生导入/清空**

原因：

- 菜单和右侧栏改动集中在 host GUI，风险低。
- `status`/`connection_info` 可以先服务脚本和 GUI。
- 多开管理器涉及进程管理和状态刷新，适合在基础动作稳定后再做。
- 相册能力最容易踩 Photos 数据库一致性问题，放到后面单独验证。

## 7. 验收标准

完成第一阶段后至少满足：

- `make build` 成功。
- `trollstore-clean` 能正常启动 GUI。
- 菜单中文化，无明显英文高频入口。
- 右侧栏有安装 IPA、导入图片、粘贴输入ASCII、清空相册、截图、重启、Restart SpringBoard、SSH 信息按钮。
- `scripts/install_ipa_to_instance.sh <ipa> vm.instances/<name>` 继续可用。
- `<vm-dir>/vphone.sock` 支持 `status` 和 `install_ipa`。
- 克隆实例不因路径过长影响 host-control。

## 8. 注意事项

- 修改 Swift 后必须使用：

```bash
make build
```

不要只跑 `swift build`，否则签名和私有 entitlement 流程不完整。

- GUI 可运行依赖主机 AMFI/SIP 状态。若出现 `exit 137`，先运行：

```bash
make amfidont_allow_vphone
```

- 相册导入/清空不要只删文件。需要确保 Photos 数据库和缓存一致，否则 Photos App 可能闪退。
- 多开管理器调用脚本时，必须把工作目录固定到项目根目录 `/Users/true/Documents/vphone-cli`。
- 对运行中的实例做克隆前必须先关机；脚本会检测 `Disk.img`、`SEPStorage`、`nvram.bin`、`vphone.sock` 是否被占用。
