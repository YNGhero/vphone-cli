# vphone 实例级 MAC 与代理配置

本文档记录本地多开环境里的实例级网络隔离能力：

1. 每个实例拥有独立、持久的虚拟网卡 MAC。
2. 每个已启动实例可以单独写入 guest 的 HTTP / SOCKS5 系统代理。
3. 对 SOCKS5 代理自动补 HTTP/HTTPS 兼容层：上游端口若也支持 HTTP CONNECT，就同时写入 HTTP/HTTPS 代理；否则在 macOS NAT 网关上启动轻量 HTTP CONNECT bridge 转发到 SOCKS5。

> 当前方案仍是 **guest SystemConfiguration 代理**，不是 TUN/VPN 透明代理。Safari、NSURLSession/CFNetwork 以及遵循系统 HTTP/HTTPS 代理的 App 会生效；完全自建网络栈或显式绕过系统代理的 App 仍需要 TUN/VPN 或 app hook。

## 1. 实例 MAC 地址

新建 VM 时，`config.plist` 会自动写入：

```text
networkConfig.macAddress = 02:xx:xx:xx:xx:xx
```

特性：

- 使用本地管理、单播 MAC（首字节会强制设置 local bit，并清除 multicast bit）。
- 同一个实例后续启动保持不变。
- 克隆实例时会重新生成 MAC，并清空 `machineIdentifier`，让克隆体在首次启动时生成新的 ECID/UDID。
- 老实例如果 `macAddress` 为空，首次用新版 `vphone-cli` 启动时会自动补写到 `config.plist`。

查看某个实例 MAC：

```bash
/usr/libexec/PlistBuddy -c 'Print :networkConfig:macAddress' \
  vm.instances/<实例名>/config.plist
```

手动指定 MAC 创建 VM：

```bash
VPHONE_MAC_ADDRESS=02:11:22:33:44:55 \
  zsh scripts/vm_create.sh --dir vm.instances/test-mac --disk-size 32
```

如果使用 `create_trollstore_instance.command` / `scripts/create_trollstore_instance.sh` 一次创建多个实例，脚本会自动忽略固定 `VPHONE_MAC_ADDRESS`，避免多台实例共用同一个 MAC。

重置已有实例的 ECID/UDID 与 MAC（实例必须先停止）：

```bash
zsh scripts/reset_vphone_identity.sh vm.instances/<实例名> --yes
```

## 2. 实例级代理脚本

脚本：

```bash
scripts/set_instance_proxy.sh
```

格式：

```bash
zsh scripts/set_instance_proxy.sh <实例目录|SSH端口> <proxy-url|clear|test> [options]
```

支持的代理 URL：

```text
user:pass@1.2.3.4:8080        # 省略协议时默认按 http:// 处理
1.2.3.4:8080                  # 省略协议时默认按 http:// 处理
http://user:pass@1.2.3.4:8080
https://1.2.3.4:8443
socks5://user:pass@1.2.3.4:1080
socks5h://1.2.3.4:1080
```

常用示例：

```bash
# 给指定实例设置 SOCKS5 代理，并测试出口 IP
zsh scripts/set_instance_proxy.sh vm.instances/phone-01 socks5://1.2.3.4:1080 --test

# 通过 SSH 端口设置代理，同时指定实例目录，方便写回 instance.env
zsh scripts/set_instance_proxy.sh 2224 http://1.2.3.4:8080 --vm-dir vm.instances/phone-01

# 不写协议时默认补 http://
zsh scripts/set_instance_proxy.sh vm.instances/phone-01 user:pass@1.2.3.4:8080 --test

# 强制用 host HTTP CONNECT bridge 暴露给 guest（SOCKS-only 上游排障时使用）
zsh scripts/set_instance_proxy.sh vm.instances/phone-01 socks5://1.2.3.4:1080 --force-bridge

# 清除代理
zsh scripts/set_instance_proxy.sh vm.instances/phone-01 clear --yes

# 测试当前直连/代理出口 IP
zsh scripts/set_instance_proxy.sh vm.instances/phone-01 test
```

脚本会做这些事：

1. 通过实例 SSH 转发连接 guest（默认 `root/alpine`）。
2. 下载 guest 的：

```text
/var/preferences/SystemConfiguration/preferences.plist
```

3. 修改 `NetworkServices/*/Proxies` 和 `Sets/*/Network/Service/*/Proxies`。
   - 未写协议：自动补成 `http://...`。
   - `http://` / `https://`：写入 HTTP/HTTPS 代理键；如果 URL 带用户名/密码，默认用 host bridge 隐藏上游认证，避免部分 App 不处理 `Proxy-Authorization` 后出现无网络。
   - `socks5://` / `socks5h://`：写入 SOCKS 键；同时自动检测该端口是否也接受 HTTP CONNECT，如果接受则额外写入 HTTP/HTTPS 键。
   - SOCKS-only 上游：自动启动 `scripts/vphone_proxy_bridge.py`，让 guest 通过 `http://<macOS NAT gateway>:<port>` 使用 HTTP CONNECT，再由 bridge 转发到上游 SOCKS5。
4. 上传并覆盖 preferences，同时备份为：

```text
/var/preferences/SystemConfiguration/preferences.plist.vphone-proxy.bak.<时间>
```

5. 写入状态文件：

```text
/var/mobile/Library/Preferences/vphone_instance_proxy.json
```

6. 重启/刷新 `configd`、`cfprefsd`、`mDNSResponder`。
7. 更新本地实例的 `instance.env`：

```text
VPHONE_PROXY_URL=...
VPHONE_PROXY_MODE=...
VPHONE_PROXY_HOST=...
VPHONE_PROXY_PORT=...
VPHONE_PROXY_HTTP_URL=...       # 存在时代表额外 HTTP/HTTPS 兼容层
VPHONE_PROXY_HTTP_SOURCE=...    # direct-http-connect 或 host-bridge
```

多开管理器会读取这些字段并在卡片/列表中显示当前代理。

## 3. GUI 使用入口

已经接入以下位置：

- 多开管理器：右键实例卡片/列表行 -> `设置代理...` / `清除代理` / `测试出口 IP`
- 实例窗口：右侧快捷栏 -> `设置实例代理`
- 实例菜单栏：`实例管理` -> `设置实例代理...` / `清除实例代理` / `测试出口 IP`

使用条件：

1. 目标实例必须已经启动。
2. `launch_gui.command` 需要完成 SSH 转发，即 `instance.env` 中存在 `SSH_LOCAL_PORT`。
3. 设置代理后脚本默认会测试一次直连 IP 和代理 IP，结果写入实例日志：

```text
vm.instances/<实例名>/logs/manager-actions.log
vm.instances/<实例名>/logs/gui-actions.log
```

## 4. 注意事项

- 该方案用于本地小规模多开，目标是让不同实例使用不同 HTTP/SOCKS 出口。
- NAT 模式下每台实例仍共享宿主机虚拟网络；代理是写在 guest 系统配置里的。
- Instagram 这类 App 可能不读取 iOS 的 SOCKS 键，旧脚本只写 SOCKS 时会出现 “Safari 出口正确、App 仍走 Mac 出口”。新版会为 SOCKS5 自动补 HTTP/HTTPS 兼容层；设置后请关闭并重新打开目标 App，避免复用旧连接。
- 对带账号密码的 HTTP 代理，Safari 可能正常，但 Instagram 可能因为代理认证处理不完整而显示无网络。新版默认会给认证 HTTP 代理也启用 host bridge：guest 侧看到无认证的 `http://<macOS NAT gateway>:<port>`，bridge 再向上游补 `Proxy-Authorization`。
- 如果某个 App 连 HTTP/HTTPS 系统代理也不遵循，需要再做更底层的透明代理/TUN/VPN/app hook。
- 代理账号密码会写入 guest preferences 和本地 `instance.env`，只建议用于本地受控环境。
- 清除代理会移除 `VPHONE_PROXY_*` 本地记录，并关闭 guest preferences 中的 HTTP/HTTPS/SOCKS 代理开关。
