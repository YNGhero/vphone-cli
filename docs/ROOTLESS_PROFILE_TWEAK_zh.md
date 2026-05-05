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
zsh scripts/app_profile_set.sh 2224 com.burbn.instagram
```

指定部分字段：

```bash
zsh scripts/app_profile_set.sh 2224 com.burbn.instagram \
  --device-name 'iPhone' \
  --product-type iPhone17,3 \
  --locale en_US \
  --languages en \
  --timezone America/Los_Angeles
```

如果目标 App 需要读取序列号、Wi-Fi MAC、ProductType 等 MobileGestalt 字段，可以额外开启：

```bash
zsh scripts/app_profile_set.sh 2224 com.burbn.instagram --hook-mobilegestalt
```

`--hook-mobilegestalt` 会 hook `MGCopyAnswer`。默认不开启是为了兼容性；确认目标 App 稳定后再打开。

也可以上传自己准备好的 JSON：

```bash
zsh scripts/app_profile_set.sh 2224 com.burbn.instagram --from-json ./profile.json
```

## 3. 一键新机时自动生成 profile

`app_new_device.sh` 会自动生成新的 profile：

```bash
zsh scripts/app_new_device.sh 2224 com.burbn.instagram --backup-before --yes
```

新版生成的 `idfa` / `idfv` / `udid` 都是标准 UUID 格式。

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
  "systemName": "iOS",
  "systemVersion": "",
  "buildVersion": "",
  "localeIdentifier": "en_US",
  "preferredLanguages": ["en"],
  "timeZone": "America/Los_Angeles",
  "advertisingTrackingEnabled": true,
  "trackingAuthorized": true
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
