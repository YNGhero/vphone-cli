# vphone 业务自动化通用层设计

本文设计 `scripts/businessScript/` 下的通用自动化能力。目标是让 Instagram、TikTok、X、Telegram 等后续 App 自动化脚本复用同一套实例解析、`vphone.sock` 调用、SSH fallback、截图归档、App 生命周期、照片、代理、定位、Hook、App 状态备份/还原能力。

## 1. 设计目标

- **业务脚本只写业务流程**：登录、发帖、浏览、注册等脚本不直接拼 SSH / socket JSON。
- **通用能力集中维护**：点击、滑动、打开/关闭 App、照片导入/清空、定位、代理、App 备份/新机/还原、Hook 安装都放到公共库。
- **优先走 `vphone.sock`**：可用时通过 GUI host-control -> guest `vphoned` 完成；旧实例或未实现能力自动 fallback 到现有脚本/SSH。
- **兼容现有脚本**：第一阶段不破坏 `scripts/*.sh`，Python 公共层先包装它们，逐步下沉到 native `vphoned` 命令。
- **可观测、可复现**：每次业务运行都有 artifacts：截图、日志、请求结果、账号 JSON、备份路径、代理/定位状态。

## 2. 推荐目录结构

```text
scripts/businessScript/
├── README.md
├── vphone_automation_example.py
├── vphonekit/                       # 通用自动化 Python 包
│   ├── __init__.py
│   ├── instance.py                   # 实例目录/端口/socket/artifact 解析
│   ├── hostctl.py                    # vphone.sock JSON client
│   ├── ssh.py                        # SSH fallback client
│   ├── legacy.py                     # 调用现有 zsh 脚本的兼容层
│   ├── artifacts.py                  # 截图/日志/结果归档
│   ├── screen.py                     # tap/swipe/key/screenshot/type
│   ├── ui.py                         # accessibility_tree 元素查询/精准点击（非 OCR）
│   ├── app.py                        # launch/terminate/foreground/list/open_url
│   ├── files.py                      # file_put/file_get/file_delete 等
│   ├── photos.py                     # import/delete_all
│   ├── app_state.py                  # backup/new_device/restore
│   ├── proxy.py                      # set/clear/test/status
│   ├── ocr.py                        # macOS Vision OCR，按截图文字获取坐标/点击
│   ├── location.py                   # set/clear/set_by_ip
│   └── hooks.py                      # build/install/uninstall/restart hook
│
├── flows/                            # 可复用流程基类/组合器
│   ├── __init__.py
│   └── base.py
│
├── instagram/                        # Instagram 业务脚本和配置
│   ├── config.json
│   ├── install_hook.py
│   ├── backup.py
│   ├── new_device.py
│   ├── restore.py
│   └── smoke_test.py
├── example/                          # 其他 App 可按同级目录扩展
│   └── smoke_test.py
│
└── runs/                             # 默认 artifacts 输出目录，可 gitignore
    └── 20260507-052500-instagram-01-instagram-smoke/
```

> 说明：用户现有的 `scripts/businessScript/vphone_automation_example.py` 保留为示例；后续应把其中公共方法抽到 `vphonekit/`。

## 3. 分层模型

```text
业务流程层 <app>/*
  ↓ 调用
通用服务层 vphonekit.{screen,app,photos,app_state,proxy,location,hooks}
  ↓ 选择 transport
传输层 hostctl(vphone.sock) / ssh / legacy zsh
  ↓
vphone-cli HostControl.swift -> VPhoneControl.swift -> guest vphoned
```

### 3.1 Transport 策略

所有通用服务默认使用：

```text
auto: vphone.sock 优先 -> SSH fallback -> legacy zsh fallback
```

并提供强制模式：

```text
--transport auto        # 默认，最稳
--transport socket-only # CI/新能力验收用，禁止 SSH fallback
--transport legacy      # 排障时直接跑旧脚本
```

## 4. 通用服务职责

### 4.1 Instance / Session

负责统一解析实例信息：

- 实例名：`instagram-01`
- 实例目录：`vm.instances/instagram-01`
- socket：`vm.instances/instagram-01/vphone.sock`
- SSH 端口：`instance.env` 里的 `SSH_LOCAL_PORT`
- artifacts 目录：`scripts/businessScript/runs/<timestamp>-<instance>-<flow>/`

推荐接口：

```python
from vphonekit import VPhoneSession

with VPhoneSession("instagram-01", app="instagram", flow="smoke") as vp:
    vp.app.launch("com.burbn.instagram")
    vp.screen.tap(645, 1398)
    vp.screen.swipe(645, 2400, 645, 1200, ms=350)
    vp.app.terminate("com.burbn.instagram")
```

### 4.2 Screen

优先走 `vphone.sock`：

| 方法 | socket 命令 |
| --- | --- |
| `tap(x, y)` | `{"t":"tap","x":x,"y":y}` |
| `swipe(x1,y1,x2,y2,ms)` | `{"t":"swipe",...}` |
| `key("home")` | `{"t":"key","name":"home"}` |
| `screenshot(path)` | `{"t":"screenshot","path":path}` |
| `type_ascii(text)` | `{"t":"type_ascii","text":text}` |
| `set_clipboard(text)` | `{"t":"type","text":text}` 当前语义是设置剪贴板 |

坐标统一使用 guest 截图像素坐标，默认 `1290x2796`，`y=0` 在顶部。

### 4.3 App

优先走 `vphone.sock`：

| 方法 | socket 命令 |
| --- | --- |
| `launch(bundle_id, url=None)` | `app_launch` |
| `terminate(bundle_id)` | `app_terminate` |
| `home()` | `key home` |
| `foreground()` | 后续接 `app_foreground` |
| `list(filter="all")` | 后续接 `app_list` |
| `open_url(url)` | 后续接 `open_url` |

短期应把 `VPhoneControl.swift` 已有的 `app_list/app_foreground/open_url` 桥接到 `VPhoneHostControl.swift`。

### 4.4 UI / Accessibility tree

用于解决“只有点击/滑动不够精准”的问题。该能力不做 OCR，而是从 guest 内部的 iOS Accessibility 层读取目标 App 当前可访问元素：

```python
nodes = vp.ui.find("Get started", bundle_id="com.burbn.instagram")
boxes = vp.ui.bounds("Get started", bundle_id="com.burbn.instagram")
vp.ui.tap_text("Get started", bundle_id="com.burbn.instagram")
```

host-control 命令：

```json
{"t":"accessibility_tree","bundle_id":"com.burbn.instagram","depth":-1,"max_nodes":500,"screen":false}
```

返回核心字段：

| 字段 | 说明 |
| --- | --- |
| `nodes` | 扁平化可访问节点列表，适合业务脚本过滤。 |
| `tree` | 根节点 + children，便于调试输出。 |
| `label/value/hint/identifier/role` | 用于定位元素的语义字段。 |
| `frame/center` | iOS 逻辑点坐标。 |
| `frame_pixels/center_pixels` | 已按当前截图尺寸换算后的像素坐标，可直接传给 `tap`。 |
| `bundle_id/pid/target_source` | 实际查询的 App 目标。 |

如果业务流程只需要坐标范围，不希望公共层直接点击，使用：

```bash
python3 scripts/businessScript/vphone.py ui bounds instagram-01 "Get started" --bundle-id com.burbn.instagram
```

返回的 `bounds` 使用截图像素坐标：

```json
{
  "label": "Get started",
  "bounds": {"x1": 116.0, "y1": 2280.0, "x2": 1174.0, "y2": 2370.0},
  "center": {"x": 645.0, "y": 2325.0}
}
```

约定：

- 业务脚本应优先传 `bundle_id` 或 `pid`；如果不传，guest 会尽力猜 frontmost，但多个用户 App 运行时可能要求明确目标。
- accessibility tree 依赖 App 自身暴露的 accessibility label/identifier；没有暴露的纯 Canvas/自绘区域不会出现在结果里，这类场景再 fallback 到固定坐标或后续 OCR。
- 当前实现的 `tree.children` 来自 AXElementFetcher 的可操作元素集合，重点服务“查找并点击”，不是完整 UIKit 视图层级 dump。

### 4.4.1 OCR 文本坐标兜底

`accessibility_tree` 仍然是首选，因为它拿到的是 App 语义元素；但 Instagram 这类页面在 guest daemon 里可能出现 AXElementFetcher 超时或 App 不暴露按钮语义。此时使用 macOS Vision OCR 识别当前截图文字，并把 Vision 坐标转换为 vphone 点击坐标：

```python
node = vp.ocr.wait_for("I already have a profile", timeout=15)
boxes = vp.ocr.bounds("I already have a profile")
vp.ocr.tap(node)

# 或一步完成
vp.ocr.tap_text("I already have a profile", timeout=15)
```

CLI：

```bash
python3 scripts/businessScript/vphone.py ocr nodes instagram-01 --save-screenshot /tmp/ig.png
python3 scripts/businessScript/vphone.py ocr find instagram-01 "Log in"
python3 scripts/businessScript/vphone.py ocr bounds instagram-01 "Log in"
python3 scripts/businessScript/vphone.py ocr tap-text instagram-01 "I already have a profile" --timeout 15
```

OCR 节点同样返回：

| 字段 | 说明 |
| --- | --- |
| `label/value` | OCR 识别出的文本。 |
| `confidence` | Vision 识别置信度。 |
| `frame_pixels/center_pixels` | 已转换到截图像素坐标，可直接传给 `screen.tap`。 |
| `source` | 固定为 `ocr`，方便和 AX 节点区分。 |

### 4.5 Files

`VPhoneControl.swift` 已支持 guest 文件操作，但 host-control 还没全部暴露。建议新增 host-control 命令：

| host-control 命令 | 用途 |
| --- | --- |
| `file_put` | 上传本机文件/bytes 到 guest |
| `file_get` | 下载 guest 文件到本机 |
| `file_mkdir` | 创建 guest 目录 |
| `file_delete` | 删除 guest 文件/目录 |
| `file_rename` | guest 内重命名 |

这样照片、Hook、App 备份还原都可以少依赖 SSH/SCP。

### 4.6 Photos

第一阶段：`vphonekit.photos` 包装现有脚本。

```python
vp.photos.import_photo("/path/a.jpg", album="VPhoneImports")
vp.photos.delete_all(confirm=True)
```

内部优先级：

1. socket native：未来 `photo_import/photo_delete_all`
2. socket file_put + guest importer
3. fallback：`scripts/import_photo_to_instance.sh` / `scripts/delete_all_photos_from_instance.sh`

长期建议在 `vphoned` 加 capability：`photos`。

```json
{"t":"photo_import","host_path":"/host/a.jpg","album":"VPhoneImports"}
{"t":"photo_delete_all","confirm":true}
```

实现上 host-control 负责把 host 文件上传到 guest 临时目录，vphoned 负责调用 PhotoKit 或安全清理照片库。

### 4.7 App State：备份 / 一键新机 / 还原

这是通用能力，但逻辑复杂，包含：

- App data container
- App group container
- Preferences
- Keychain slice
- Pasteboard/cache 清理
- relaunch / respring

第一阶段继续复用现有稳定脚本：

```python
vp.app_state.backup(bundle_id, name="before-login")
vp.app_state.new_device(bundle_id, backup_before=True, yes=True)
vp.app_state.restore(bundle_id, archive="xxx.tar.gz", yes=True)
```

内部 fallback：

```text
app_backup.sh
app_new_device.sh
app_restore.sh
```

第二阶段可以新增 `vphoned` capability：`app_state`。

```json
{"t":"app_state_backup","bundle_id":"com.xxx","stage":"..."}
{"t":"app_state_new","bundle_id":"com.xxx","clean_pasteboard":true,"relaunch":true}
{"t":"app_state_restore","bundle_id":"com.xxx","stage":"...","relaunch":true}
```

迁移策略：先把 `vphone_app_state_guest.sh` 上传到 guest 并由受控 runner 执行，稳定后再逐步 Objective-C 原生化。

### 4.8 Hooks

Hook 安装是通用能力，但不同 App 有不同 dylib/plist/template。

推荐抽象：

```python
vp.hooks.install(
    name="InstagramAuditTweak",
    dylib=".build/instagram_audit_tweak/InstagramAuditTweak.dylib",
    plist_template="tweaks/instagram_audit_tweak/InstagramAuditTweak.plist.template",
    bundles=["com.burbn.instagram"],
    restart=True,
)
```

第一阶段：包装现有安装脚本，例如：

```text
install_instagram_audit_tweak_to_instance.sh
install_profile_tweak_to_instance.sh
```

第二阶段：用 `file_put` 上传 dylib/plist 到：

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/
```

然后通过 `app_terminate/app_launch` 重启目标 App。

### 4.9 Proxy

代理同时涉及 guest SystemConfiguration、host bridge、`instance.env`，不建议一开始完全放到 `vphone.sock` 里。

推荐：`vphonekit.proxy` 先包装现有脚本：

```python
vp.proxy.set("http://user:pass@host:port", test=True)
vp.proxy.clear(yes=True)
vp.proxy.test()
```

内部调用：

```text
scripts/set_instance_proxy.sh
```

后续如要 native 化，可以拆成两层：

- host Python 管理 bridge 和 `instance.env`
- guest `vphoned` 管理 SystemConfiguration 写入

### 4.10 Location

已有 socket 命令，直接封装：

```python
vp.location.set(lat, lon, hacc=1000)
vp.location.set_by_ip("8.8.8.8")
vp.location.clear()
```

建议补一个 host-control 命令桥接 `location_stop`：

```json
{"t":"location_stop"}
```

`set_by_ip` 的 IP 定位查询保留在 host Python 层。

## 5. App 配置规范

每个 App 一个 `config.json`：

```json
{
  "name": "instagram",
  "bundle_id": "com.burbn.instagram",
  "process_name": "Instagram",
  "default_album": "VPhoneImports",
  "coordinates": {
    "login_username": [645, 1120],
    "login_password": [645, 1280],
    "login_button": [645, 1480]
  },
  "hooks": {
    "audit": {
      "build_script": "scripts/build_instagram_audit_tweak.sh",
      "install_script": "scripts/install_instagram_audit_tweak_to_instance.sh",
      "account_json": "/tmp/instagram_account.json"
    }
  }
}
```

业务脚本只读配置，不硬编码 bundle/process/坐标。

## 6. CLI 入口设计

保留单文件业务脚本的同时，建议增加一个统一 CLI：

```bash
python3 scripts/businessScript/vphone.py screen tap instagram-01 645 1398
python3 scripts/businessScript/vphone.py app launch instagram-01 com.burbn.instagram
python3 scripts/businessScript/vphone.py photo import instagram-01 ./a.jpg --album VPhoneImports
python3 scripts/businessScript/vphone.py photo delete-all instagram-01 --yes
python3 scripts/businessScript/vphone.py app-state backup instagram-01 com.burbn.instagram --name before-login
python3 scripts/businessScript/vphone.py app-state new instagram-01 com.burbn.instagram --backup-before --yes
python3 scripts/businessScript/vphone.py app-state restore instagram-01 com.burbn.instagram ./backup.tar.gz --yes
python3 scripts/businessScript/vphone.py proxy set instagram-01 http://user:pass@host:port --test
python3 scripts/businessScript/vphone.py proxy clear instagram-01 --yes
python3 scripts/businessScript/vphone.py location set instagram-01 52.52 13.405
python3 scripts/businessScript/vphone.py ui find instagram-01 "Get started" --bundle-id com.burbn.instagram
python3 scripts/businessScript/vphone.py ui tap-text instagram-01 "Get started" --bundle-id com.burbn.instagram --screen
python3 scripts/businessScript/vphone.py hook install instagram-01 instagram:audit
```

App 业务脚本可以继续直接运行：

```bash
python3 scripts/businessScript/instagram/smoke_test.py instagram-01
```

## 7. 返回值和日志规范

所有公共方法返回结构化结果：

```python
{
  "ok": True,
  "transport": "socket|ssh|legacy",
  "action": "app.launch",
  "instance": "instagram-01",
  "bundle_id": "com.burbn.instagram",
  "artifact_dir": "...",
  "data": {...}
}
```

日志分三类：

- stdout：人看的关键步骤
- `run.jsonl`：机器可读事件流
- artifacts：截图、账号 JSON、backup archive、hook log 等

## 8. 迁移路线

### Phase 1：Python 公共层，不改 guest

- 从 `vphone_automation_example.py` 抽出 `vphonekit`。
- 通用能力先包装现有 `.sh`。
- 业务脚本统一调用 `vphonekit`。

优点：最快落地，不影响现有稳定脚本。

当前状态（已落地第一版）：

- `scripts/businessScript/vphonekit/` 已提供实例解析、`vphone.sock` client、SSH fallback、legacy shell wrapper。
- `screen/app/location` 已优先走 socket。
- `ui` 已通过 guest `accessibility_tree` 提供非 OCR 元素查询与精准点击。
- `photos/app_state/proxy/hooks` 已先包装现有稳定脚本，后续逐步 native 化。
- `scripts/businessScript/vphone.py` 提供统一 CLI。
- `scripts/businessScript/instagram/smoke_test.py` 提供 App 专属脚本示例。

### Phase 2：补齐 host-control 桥接

在 `VPhoneHostControl.swift` 增加这些对 `VPhoneControl.swift` 的桥接：

- `file_put/file_get/file_mkdir/file_delete/file_rename`
- `clipboard_get/clipboard_set`
- `open_url`
- `app_list/app_foreground`
- `location_stop`
- `settings_get/settings_set` 如后续需要

优点：大多数通用操作可以不再直接 SSH。

### Phase 3：高频能力 native 化

在 `scripts/vphoned/` 增加模块：

- `vphoned_photos.*`：`photo_import/photo_delete_all`
- `vphoned_app_state.*`：`app_state_backup/app_state_new/app_state_restore`
- `vphoned_proxy.*`：guest SystemConfiguration proxy set/clear/status
- 可选 `vphoned_hook.*`：安装/移除 MobileSubstrate dylib/plist

优点：更稳定、更快、错误更结构化。

### Phase 4：业务流程标准化

每个 App 只保留：

- `config.json`
- 少量业务流程脚本
- App 专属坐标/Hook/账号解析逻辑

## 9. 当前功能落点建议

| 功能 | 第一阶段落点 | 最终落点 |
| --- | --- | --- |
| 点击/滑动/按键 | `vphonekit.screen` -> socket | 保持 |
| 查询屏幕元素/按元素点击 | `vphonekit.ui` -> `accessibility_tree` socket | 保持，后续可叠加 OCR fallback |
| 打开/关闭 App | `vphonekit.app` -> socket | 保持 |
| 传照片 | `vphonekit.photos` -> legacy script | `photo_import` native |
| 删除所有照片 | `vphonekit.photos` -> legacy script | `photo_delete_all` native |
| 备份 App | `vphonekit.app_state` -> legacy script | `app_state_backup` native/runner |
| 一键新机 App | `vphonekit.app_state` -> legacy script | `app_state_new` native/runner |
| 还原备份 App | `vphonekit.app_state` -> legacy script | `app_state_restore` native/runner |
| 安装/运行 Hook | `vphonekit.hooks` -> build script + file/legacy | socket file_put + app restart |
| 设置代理 | `vphonekit.proxy` -> set_instance_proxy.sh | host proxy manager + guest proxy command |
| 清理代理 | `vphonekit.proxy` -> set_instance_proxy.sh clear | host proxy manager + guest proxy command |
| 设置定位 | `vphonekit.location` -> socket | 保持 |
| 按 IP 设置定位 | `vphonekit.location` host 查询 + socket | 保持 |

## 10. 开发约定

- 新业务脚本不要直接调用 `sshpass`、`socket.socket`、`subprocess zsh scripts/*.sh`，统一走 `vphonekit`。
- 每个通用方法必须支持 `transport="auto|socket-only|legacy"`。
- 默认所有 destructive 操作都需要 `yes=True` 或 `--yes`，业务批量脚本必须显式传入。
- 每次运行必须创建 artifact 目录并记录 `run.jsonl`。
- App 专属 bundle id、process name、坐标、hook 路径放到 `<app>/config.json`。
