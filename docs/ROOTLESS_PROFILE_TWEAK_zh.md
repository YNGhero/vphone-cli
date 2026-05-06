# VPhoneProfileTweak：指定 App 设备信息伪装

`VPhoneProfileTweak` 是一个 rootless iOS tweak，用于让指定 App 在运行时读取到每个 App 专属的设备 profile。

它配合 App 状态脚本使用：

```text
/var/mobile/vphone_app_profiles/<bundle-id>.json
```

例如：

```text
/var/mobile/vphone_app_profiles/com.burbn.instagram.json
```

## 1. 安装 tweak 到实例

对 SSH 端口 `2224` 的 Instagram 启用：

```bash
zsh scripts/install_profile_tweak_to_instance.sh instagram-01 com.burbn.instagram
```

也支持直接传实例目录或 SSH 端口：

```bash
zsh scripts/install_profile_tweak_to_instance.sh vm.instances/instagram-01 com.burbn.instagram
zsh scripts/install_profile_tweak_to_instance.sh 2224 com.burbn.instagram
```

安装位置：

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/VPhoneProfileTweak.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/VPhoneProfileTweak.plist
```

安装后需要重启/重开目标 App 才会注入。

## 2. 生成或指定设备 profile

随机生成一个 profile，不清理 App 数据：

```bash
zsh scripts/app_profile_set.sh instagram-01 com.burbn.instagram
```

默认会动态生成：

- `idfa`
- `idfv`
- `udid` / `oudid`
- `serial`
- `wifiAddress`
- `bluetoothAddress`
- 英文地区 `localeIdentifier`，例如 `en_US` / `en_GB` / `en_CA` / `en_AU`
- 与地区匹配的 `timeZone`

默认固定为：

- `preferredLanguages`: `["en"]`
- `systemName`: `iOS`
- `model` / `localizedModel`: `iPhone`
- `productType`: `iPhone17,3`
- `spoofProductType`: `true`
- `hookMobileGestalt`: `false`

说明：`UIDevice.systemName` 和 `UIDevice.model` 在真实 iPhone 上本来就是稳定值，默认不乱随机；`systemVersion` / `buildVersion` 默认留空并回退到系统真实值，避免和真实运行环境不一致。`spoofProductType=true` 走 ObjC 层改写 Instagram UA / 请求头中的机型标识，避免 UA 暴露虚拟机底层的 `iPhone99,11`。旧 profile 里缺少 `spoofProductType` 字段时，tweak 也会按 `true` 处理；如需关闭请显式写入 `false`。

指定部分字段：

```bash
zsh scripts/app_profile_set.sh instagram-01 com.burbn.instagram \
  --device-name 'iPhone' \
  --product-type iPhone17,3 \
  --locale en_US \
  --languages en \
  --timezone America/Los_Angeles
```

如果需要临时关闭底层机型标识伪装：

```bash
zsh scripts/app_profile_set.sh instagram-01 com.burbn.instagram --no-spoof-product-type
```

如果目标 App 需要读取序列号、Wi-Fi MAC、ProductType 等 MobileGestalt 字段，可以额外开启：

```bash
zsh scripts/app_profile_set.sh instagram-01 com.burbn.instagram --hook-mobilegestalt
```

`--hook-mobilegestalt` 会 hook `MGCopyAnswer`。默认不开启是为了兼容性；确认目标 App 稳定后再打开。

如果只是想确认目标 App 启动时读取了哪些设备参数，先用安全审计模式：

```bash
zsh scripts/app_profile_set.sh instagram-01 com.burbn.instagram \
  --audit-reads
```

然后重开 App，查看：

```bash
sshpass -p alpine ssh -p 2224 root@127.0.0.1 \
  'export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH; cat /tmp/vphone_profile_tweak.log'
```

审计模式说明：

- `auditReads=true`：记录 Objective-C 层读取，例如 `UIDevice.identifierForVendor`、`ASIdentifierManager.advertisingIdentifier`、语言、时区等。
- `auditMobileGestalt=true`：只记录 `MGCopyAnswer:<key>`，默认不改返回值；这是实验模式，Instagram 上可能触发启动 watchdog，先不要默认开启。
- `auditMobileGestalt=true` 且 `hookMobileGestalt=false` 时，MobileGestalt 只是 log-only，用来判断是否读取 UDID/序列号/MAC 等底层字段。
- `hookMobileGestalt=true` 时，才会真正返回 profile 里的 UDID/序列号/MAC 等值。
- `spoofProductType=true` 不等同于 `hookMobileGestalt=true`：它只处理 Instagram UA / 请求头中可见的机型字符串，不会默认改 UDID、序列号、Wi-Fi MAC，也不会默认 hook 全局 `uname` / `sysctl`。

如果要低风险判断目标包里是否显式引用 MobileGestalt/UDID 字符串，可以先做静态扫描：

```bash
sshpass -p alpine ssh -p 2224 root@127.0.0.1 '
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH
app=$(find /var/containers/Bundle/Application /private/var/containers/Bundle/Application -maxdepth 3 -path "*.app/Info.plist" -type f 2>/dev/null | while read p; do grep -a -q "com.burbn.instagram" "$p" && dirname "$p" && break; done)
for pat in MGCopyAnswer MobileGestalt UniqueDeviceID UniqueDeviceIDString OpaqueDeviceID SerialNumber WifiAddress WiFiAddress BluetoothAddress; do
  c=$(grep -aRIl -- "$pat" "$app" 2>/dev/null | wc -l | tr -d " ")
  echo "$pat $c"
done
'
```

也可以上传自己准备好的 JSON：

```bash
zsh scripts/app_profile_set.sh instagram-01 com.burbn.instagram --from-json ./profile.json
```

## 3. 一键新机时自动生成 profile

`app_new_device.sh` 会自动生成新的 profile：

```bash
zsh scripts/app_new_device.sh 2224 com.burbn.instagram --backup-before --yes
```

新版生成的 `idfa` / `idfv` / `udid` 都是标准 UUID 格式，并且默认语言列表为 `["en"]`，地区/时区会在英语地区中随机选择。
同时 profile 默认写入 `spoofProductType=true`，重开 App 后 Instagram UA 中的机型应从虚拟机底层 `iPhone99,11` 变成 profile 的 `productType`（默认 `iPhone17,3`，可通过 `VPHONE_PROFILE_PRODUCT_TYPE` 指定）。

## 4. 当前已 hook 的接口

### Objective-C API

- `UIDevice.name`
- `UIDevice.model`
- `UIDevice.localizedModel`
- `UIDevice.systemName`
- `UIDevice.systemVersion`
- `UIDevice.identifierForVendor`
- `ASIdentifierManager.advertisingIdentifier`
- `ASIdentifierManager.isAdvertisingTrackingEnabled`
- `ATTrackingManager.trackingAuthorizationStatus`
- `NSLocale.currentLocale`
- `NSLocale.autoupdatingCurrentLocale`
- `NSLocale.preferredLanguages`
- `NSTimeZone.localTimeZone`
- `NSTimeZone.systemTimeZone`
- `NSTimeZone.defaultTimeZone`
- `NSUserDefaults objectForKey:` 中的 `AppleLanguages` / `AppleLocale`

### UA / 请求头机型标识

当 profile 中 `spoofProductType=true` 时覆盖：

- Instagram `IGUserAgent` 返回的 `APIRequestString` / `staticAPIRequestString` / `commonHeaders`
- `NSMutableURLRequest` 的 `User-Agent` 请求头写入
- `NSURLSessionConfiguration.HTTPAdditionalHeaders` 中的 `User-Agent`

默认不再全局 hook `uname` / `sysctl hw.machine`，避免 Instagram 启动 watchdog。确实需要底层 C API 机型覆盖时，可在自定义 profile 中显式加 `"hookHardwareIdentity": true`；需要只覆盖 `MGCopyAnswer` 的 ProductType 时，可显式加 `"hookProductTypeMobileGestalt": true`。

### MobileGestalt

通过 ElleKit/Substrate 的 `MSHookFunction` hook：

- `MGCopyAnswer`

说明：`MGCopyAnswerWithError` 暂不 hook。它在不同 iOS 版本上的私有签名不稳定，错误 hook 可能导致目标 App 启动 watchdog 卡死。

当前覆盖的 key 包括：

```text
DeviceName
UserAssignedDeviceName
SerialNumber
UniqueDeviceID
UniqueDeviceIDString
OpaqueDeviceID
WiFiAddress
BluetoothAddress
ProductType
HWModelStr
ProductVersion
BuildVersion
MarketingProductName
RegionCode
RegionInfo
```

## 5. profile 字段

示例：

```json
{
  "enabled": true,
  "bundle_id": "com.burbn.instagram",
  "idfa": "CE6EAE7C-1C07-4EA2-B00E-A1D39B7EFBF9",
  "idfv": "837FFAF6-6949-4070-8470-D501FAFADAB2",
  "udid": "1317727A-0EA9-489C-90DC-234FB557D33F",
  "oudid": "1317727A-0EA9-489C-90DC-234FB557D33F",
  "serial": "VP17780192621453",
  "wifiAddress": "02:35:7b:1b:65:18",
  "bluetoothAddress": "02:0a:8c:90:23:ad",
  "deviceName": "iPhone",
  "model": "iPhone",
  "localizedModel": "iPhone",
  "productType": "iPhone17,3",
  "spoofProductType": true,
  "systemName": "iOS",
  "systemVersion": "",
  "buildVersion": "",
  "localeIdentifier": "en_US",
  "preferredLanguages": ["en"],
  "timeZone": "America/Los_Angeles",
  "advertisingTrackingEnabled": true,
  "trackingAuthorized": true,
  "hookMobileGestalt": false,
  "auditReads": false,
  "auditMobileGestalt": false
}
```

## 6. 验证 tweak 是否注入

重开目标 App 后查看：

```bash
sshpass -p alpine ssh -p 2224 root@127.0.0.1 'cat /tmp/vphone_profile_tweak.log'
```

看到类似内容表示已注入：

```text
[VPhoneProfile] enabled bundle=com.burbn.instagram profile=/var/mobile/vphone_app_profiles/com.burbn.instagram.json
```

## 7. 注意

- 修改 profile 后，需要重开目标 App 才会重新读取。
- 当前是第一版运行时 hook，主要覆盖常见设备信息接口。
- APNs token、服务端账号风控、网络 IP、WebView 指纹、越狱检测等不属于这个 tweak 的第一版范围。
