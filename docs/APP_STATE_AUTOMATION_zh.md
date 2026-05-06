# 指定 App：一键新机 / 备份 / 还原

本文档记录 vphone 本地多开环境中，针对指定 App 的状态管理脚本。

## 脚本列表

```bash
scripts/app_backup.sh        # 备份指定 App
scripts/app_new_device.sh    # 指定 App 一键新机
scripts/app_restore.sh       # 还原指定 App 备份
```

这些脚本通过实例的 SSH 转发端口连接 guest，默认账号为：

```text
root / alpine
```

现在这三个脚本也支持直接传 **实例名** 或 **实例目录**，脚本会自动从：

```text
vm.instances/<实例名>/instance.env
```

里解析当前 `SSH_LOCAL_PORT`，不必手动记端口。例如：

```bash
zsh scripts/app_backup.sh instagram-01 com.example.app before-login
zsh scripts/app_new_device.sh instagram-01 com.example.app --yes
zsh scripts/app_restore.sh instagram-01 com.example.app app_backups/com.example.app/phone-01-20260506-120000-before-login.tar.gz --yes
```

也可以传实例目录：

```bash
zsh scripts/app_backup.sh vm.instances/instagram-01 com.example.app before-login
```

如密码不是 `alpine`，可以临时指定：

```bash
VPHONE_SSH_PASSWORD='你的密码' zsh scripts/app_backup.sh 2224 com.example.app test
```

备份文件名默认会自动带上实例名。脚本会按 SSH 端口从 `vm.instances/*/instance.env` 反查实例名；如果没有找到，会退回为 `ssh-<端口>`。也可以手动指定：

```bash
zsh scripts/app_backup.sh 2224 com.example.app before-login --instance-name phone-01
```

## 通过 GUI 使用

现在这三个动作也已经接入 GUI：

- 多开管理器：右键实例卡片/列表行 -> `备份 App` / `一键新机` / `还原 App`
- 实例窗口：右侧快捷栏 -> `备份 App` / `一键新机` / `还原 App`
- 实例菜单栏：`实例管理` -> `备份 App...` / `一键新机...` / `还原 App...`

使用条件：

1. 目标实例需要已经启动，并且 `launch_gui.command` 已完成 SSH 转发。
2. 如果提示“没有 SSH 本地端口”，先等待实例 ready，或检查实例目录里的 `connection_info.txt` / `instance.env`。
3. Bundle ID 输入框会记住上一次输入；初始默认值是 `com.burbn.instagram`。
4. GUI 触发后会在实例日志目录写入日志：

```text
vm.instances/<实例名>/logs/manager-actions.log
vm.instances/<实例名>/logs/gui-actions.log
```

其中多开管理器动作写入 `manager-actions.log`，实例窗口/菜单动作写入 `gui-actions.log`。

## 1. 备份指定 App

```bash
zsh scripts/app_backup.sh 2224 com.example.app before-login
```

输出示例：

```text
app_backups/com.example.app/phone-01-20260506-120000-before-login.tar.gz
```

备份内容包括：

- App data container
- App Group container，按 entitlements / metadata 尽量定位
- `/var/mobile/Library/Preferences/<bundle-id>.plist`
- ByHost 下对应 preferences
- 该 App keychain access group 的 keychain 子集
- `/var/mobile/vphone_app_profiles/<bundle-id>.json`，如果存在
- `manifest.env` 和 `summary.txt`

## 2. 指定 App 一键新机

推荐先自动备份再清理：

```bash
zsh scripts/app_new_device.sh 2224 com.example.app --backup-before --yes
```

仅清理，不自动备份：

```bash
zsh scripts/app_new_device.sh 2224 com.example.app --yes
```

可选参数：

```text
--backup-before    清理前先备份
--yes              跳过确认
--no-pasteboard    不清剪贴板缓存
--no-relaunch      清理后不尝试重开 App
--respring         清理后 Restart SpringBoard
```

一键新机会执行：

1. 结束目标 App 进程。
2. 清空 App data container，但保留容器根目录里的 `.com.apple.mobile_container_manager.metadata.plist`。
3. 清空识别到的 App Group container，也会保留对应 metadata。
4. 删除目标 App preferences。
5. 删除目标 App keychain access group 记录。
6. 生成新的 profile：

```text
/var/mobile/vphone_app_profiles/<bundle-id>.json
```

   默认会随机生成 `idfa`、`idfv`、`udid/oudid`、序列号、Wi-Fi/蓝牙 MAC、英文地区和匹配时区；`preferredLanguages` 固定为 `["en"]`。`systemName`、`model` 保持 iPhone 合理默认值，`systemVersion/buildVersion` 默认回退到系统真实值。

7. 清理 pasteboard，除非指定 `--no-pasteboard`。
8. 重启 `cfprefsd` / `securityd`。
9. 尝试重新打开目标 App。

注意：profile 需要配合 `VPhoneProfileTweak` 才会在 App 运行时生效。安装和字段说明见 `docs/ROOTLESS_PROFILE_TWEAK_zh.md`。如果没有安装 tweak，App 数据清理和 keychain 清理仍然生效，但 IDFA/IDFV/Serial 等运行时伪装不会生效。

## 3. 还原指定 App

```bash
zsh scripts/app_restore.sh 2224 com.example.app app_backups/com.example.app/phone-01-20260506-120000-before-login.tar.gz --yes
```

可选参数：

```text
--yes              跳过确认
--no-relaunch      还原后不尝试重开 App
--respring         还原后 Restart SpringBoard
```

还原会先清理当前 App 数据，再恢复备份包中的：

- App data
- App Group data
- Preferences
- Keychain 子集
- App profile

还原时也会优先保留当前实例的容器 metadata，避免把另一个实例/旧 UUID 的 metadata 覆盖到当前容器。
如果之前用旧版脚本清理过，metadata 已经被删，脚本会回退使用备份 `manifest.env` 里的旧 data container 路径，并在日志里提示：

```text
current data container metadata is missing; using backup manifest path: ...
```

## 常见问题

### 1. 提示 SSH 连接失败

先确认实例已经通过 `launch_gui.command` 启动，并且脚本输出过 SSH 端口，例如：

```text
SSH:
  sshpass -p alpine ssh -p 2224 root@127.0.0.1
```

然后用对应端口执行脚本。

### 2. 备份里没有 keychain

脚本需要从 App 可执行文件 entitlements 中解析 `keychain-access-groups`。如果目标 App 没有 entitlements，或 guest 中没有 `ldid` / `sqlite3`，keychain 子集会跳过。

### 3. App Group 没有全部识别

脚本会优先读 entitlements 里的：

```text
com.apple.security.application-groups
com.apple.security.system-groups
```

如果解析失败，会回退到 metadata 里包含 bundle id 的 App Group。极少数 App 的 group 命名完全无关时，需要后续加手动 group id 参数。

### 4. 提示 `data container not found`

这个表示脚本没有在：

```text
/var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist
```

中找到目标 bundle id。

旧版脚本的一键新机曾经会把 data container / App Group container 根目录里的 metadata 一起删掉，导致后续无法再通过 bundle id 反查容器路径。新版已修复：清理和还原都会保留当前容器 metadata。

如果当前实例已经出现过这个问题，直接用新版 `app_restore.sh` 再还原一次即可；脚本会尽量使用备份 manifest 里的路径恢复数据和 metadata。

### 5. 提示 `app bundle not found`

先确认 bundle id 是否正确：

```bash
sshpass -p alpine ssh -p 2224 root@127.0.0.1 \
  'find /var/containers/Bundle/Application -maxdepth 3 -name Info.plist -type f -print | xargs grep -a -l "com.example.app"'
```

脚本已经兼容 guest 里没有 `plutil` / `awk` 的情况：

- App `Info.plist` 为 XML 时，用 `sed` 解析 `CFBundleIdentifier` / `CFBundleExecutable`。
- data container / App Group metadata 为 binary plist 时，用 `grep -a` 回退匹配 bundle id 或 group id。
- 下载/上传备份时会自动补齐 guest 的 `/var/jb/usr/bin`、`/iosbinpack64/usr/bin` PATH，避免 `tar: command not found`。

### 6. 这是完整 YOY 复刻吗？

不是。当前脚本实现的是底层可控的 MVP：

```text
备份 / 清理 / 还原 App 状态
```

运行时设备参数伪装已经开始由 `VPhoneProfileTweak` 承担。当前第一版已读取：

```text
/var/mobile/vphone_app_profiles/<bundle-id>.json
```

并 hook IDFA、IDFV、UIDevice、MobileGestalt、语言区域和时区等常见接口。后续可继续扩展位置、WebView 指纹、越狱检测绕过等。
