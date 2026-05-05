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

如密码不是 `alpine`，可以临时指定：

```bash
VPHONE_SSH_PASSWORD='你的密码' zsh scripts/app_backup.sh 2224 com.example.app test
```

## 1. 备份指定 App

```bash
zsh scripts/app_backup.sh 2224 com.example.app before-login
```

输出示例：

```text
app_backups/com.example.app/20260506-120000-before-login.tar.gz
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
2. 清空 App data container。
3. 清空识别到的 App Group container。
4. 删除目标 App preferences。
5. 删除目标 App keychain access group 记录。
6. 生成新的 profile：

```text
/var/mobile/vphone_app_profiles/<bundle-id>.json
```

7. 清理 pasteboard，除非指定 `--no-pasteboard`。
8. 重启 `cfprefsd` / `securityd`。
9. 尝试重新打开目标 App。

注意：当前 profile 只是为后续自研 tweak 预留。没有安装对应 tweak 时，IDFA/IDFV/Serial 等运行时伪装不会自动生效，但 App 数据清理和 keychain 清理已经生效。

## 3. 还原指定 App

```bash
zsh scripts/app_restore.sh 2224 com.example.app app_backups/com.example.app/20260506-120000-before-login.tar.gz --yes
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

### 4. 提示 `app bundle not found`

先确认 bundle id 是否正确：

```bash
sshpass -p alpine ssh -p 2224 root@127.0.0.1 \
  'find /var/containers/Bundle/Application -maxdepth 3 -name Info.plist -type f -print | xargs grep -a -l "com.example.app"'
```

脚本已经兼容 guest 里没有 `plutil` / `awk` 的情况：

- App `Info.plist` 为 XML 时，用 `sed` 解析 `CFBundleIdentifier` / `CFBundleExecutable`。
- data container / App Group metadata 为 binary plist 时，用 `grep -a` 回退匹配 bundle id 或 group id。
- 下载/上传备份时会自动补齐 guest 的 `/var/jb/usr/bin`、`/iosbinpack64/usr/bin` PATH，避免 `tar: command not found`。

### 5. 这是完整 YOY 复刻吗？

不是。当前脚本实现的是底层可控的 MVP：

```text
备份 / 清理 / 还原 App 状态
```

YOY 里的运行时设备参数伪装，需要后续增加自研 rootless tweak 来读取：

```text
/var/mobile/vphone_app_profiles/<bundle-id>.json
```

然后对指定 bundle id hook IDFA、IDFV、MobileGestalt、位置等接口。
