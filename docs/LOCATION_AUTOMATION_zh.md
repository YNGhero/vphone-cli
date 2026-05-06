# vphone 定位自动化脚本

本文档记录通过命令行调用 vphone-cli 自带定位模拟能力的方法。

## 脚本

```bash
scripts/set_location_by_ip.sh
```

该脚本会：

1. 请求 `https://ipapi.co/<目标IP>/json/`
2. 读取返回里的 `latitude` / `longitude`
3. 通过目标实例目录里的本地 host-control socket：

```text
<实例目录>/vphone.sock
```

把坐标发送给当前运行中的 vphone 实例。

## 使用示例

指定实例目录：

```bash
zsh scripts/set_location_by_ip.sh vm.instances/phone-01 8.8.8.8
```

指定实例名：

```bash
zsh scripts/set_location_by_ip.sh trollstore-clone-20260505-182858 8.8.8.8
```

使用 `--vm`：

```bash
zsh scripts/set_location_by_ip.sh 8.8.8.8 --vm trollstore-clone-20260505-182858
```

不指定实例时，脚本会尝试选择最近一个存在 `vphone.sock` 的运行中实例：

```bash
zsh scripts/set_location_by_ip.sh 8.8.8.8
```

## 可选参数

```text
--screen            设置后请求返回小截图
--delay <ms>        截图延迟，默认 200
--wait <seconds>    等待 host-control / guest location 能力 ready，默认 30
--alt <meters>      海拔，默认 0
--hacc <meters>     水平精度，默认 1000
--vacc <meters>     垂直精度，默认 50
--speed <m/s>       速度，默认 0
--course <degrees>  方向，默认 -1
```

示例：

```bash
zsh scripts/set_location_by_ip.sh 8.8.8.8 --vm phone-01 --hacc 100 --wait 60
```

## 通过 GUI 使用

该功能也已接入 GUI：

- 多开管理器：右键实例 -> `按 IP 定位`
- 实例窗口：右侧快捷栏 -> `按 IP 定位`

GUI 会弹出 IP 输入框，默认值为上一次输入的 IP；首次默认为：

```text
8.8.8.8
```

多开管理器里，实例未启动或 `vphone.sock` 未 ready 时，`按 IP 定位` 会置灰不可选。
实例窗口右侧按钮会在 guest connected 后启用。

## 注意事项

- 目标实例必须已经启动，并且 GUI/control socket 已 ready。
- 如果提示 `guest not connected`，等待 `launch_gui.command` 输出 `instance ready` 后重试。
- 该功能使用的是 vphone-cli/vphoned 自带的 location simulation capability；如果 guest 不支持，会提示 `guest does not support location simulation`。
- 如果你打开了“同步宿主机定位”，脚本执行时会停止当前 host location forwarding，避免宿主机定位马上覆盖手动定位。
