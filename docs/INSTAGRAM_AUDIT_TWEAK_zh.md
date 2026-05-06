# InstagramAuditTweak：抓取 Instagram Cookie / UA / 设备信息（JSONL）

`InstagramAuditTweak` 是一个 rootless iOS tweak，用于在 **不修改任何值** 的前提下，审计 Instagram App 运行时：

- 请求 URL / Method
- 请求头（含 `User-Agent`、`Cookie`、`Authorization`、`X-IG-*`、`IG-U-*`、`X-MID`）
- Cookie 写入 / 删除 / 响应 `Set-Cookie`
- 常见设备信息读取（`UIDevice` / `IDFA` / `IDFV` / `Locale` / `TimeZone` / `MGCopyAnswer`）

输出格式为：**单个 JSON 文件**。  
每抓到一个字段，就把字段写回同一个账号 JSON，不再追加事件流。

文件在 guest 内：

```text
/tmp/instagram_account.json
```

---

## 1. 安装 tweak 到实例

默认安装到 Instagram：

```bash
zsh scripts/install_instagram_audit_tweak_to_instance.sh 2224
```

显式指定 bundle：

```bash
zsh scripts/install_instagram_audit_tweak_to_instance.sh 2224 com.burbn.instagram
```

安装位置：

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/InstagramAuditTweak.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/InstagramAuditTweak.plist
```

安装脚本会顺手清空旧输出：

```text
rm -f /tmp/instagram_account.json
```

安装后需要：

- 关闭 Instagram
- 重新打开 Instagram

或者直接 kill 再重开。

---

## 2. 当前会抓哪些内容

### 请求层

- `-[NSMutableURLRequest setValue:forHTTPHeaderField:]`
- `-[NSMutableURLRequest addValue:forHTTPHeaderField:]`
- `-[NSMutableURLRequest setAllHTTPHeaderFields:]`
- `-[NSURLSessionConfiguration setHTTPAdditionalHeaders:]`
- `-[NSURLSession dataTaskWithRequest:completionHandler:]`
- `-[NSURLSession uploadTaskWithRequest:fromData:completionHandler:]`
- `-[NSURLSession downloadTaskWithRequest:completionHandler:]`

重点可见：

- `User-Agent`
- `Cookie`
- `Authorization`
- `X-IG-*`
- `IG-U-*`
- `X-MID`
- 最终请求 URL / Method

### Cookie 层

- `-[NSHTTPCookieStorage setCookie:]`
- `-[NSHTTPCookieStorage deleteCookie:]`
- `-[NSHTTPCookieStorage cookiesForURL:]`
- `+[NSHTTPCookie cookiesWithResponseHeaderFields:forURL:]`

常见可抓字段：

- `sessionid`
- `csrftoken`
- `ds_user_id`
- `mid`
- `rur`
- `shbid`
- `shbts`

### 设备信息层

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
- `MGCopyAnswer`

---

## 3. 查看账号 JSON

```bash
sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2224 root@127.0.0.1 'cat /tmp/instagram_account.json'
```

导出到宿主机：

```bash
sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2224 root@127.0.0.1 'cat /tmp/instagram_account.json' > instagram_account.json
```

---

## 4. 日志格式示例

### 请求事件

```json
{"ts":"2026-05-06T16:10:00.123Z","type":"request","bundle_id":"com.burbn.instagram","pid":1234,"source":"dataTaskWithRequest:completionHandler:","method":"POST","url":"https://i.instagram.com/api/v1/accounts/login/","headers":{"User-Agent":"...","Cookie":"..."},"interesting_headers":{"User-Agent":"...","Cookie":"...","X-IG-App-ID":"..."}}
```

### Header 变更事件

```json
{"ts":"2026-05-06T16:10:00.100Z","type":"request_header_mutation","field":"User-Agent","value":"Instagram 123.0 ...","method":"POST","url":"https://i.instagram.com/..."}
```

### Cookie 事件

```json
{"ts":"2026-05-06T16:10:01.000Z","type":"set_cookie","name":"sessionid","value":"...","domain":".instagram.com","path":"/"}
```

### 设备读取事件

```json
{"ts":"2026-05-06T16:10:02.000Z","type":"device_read","api":"UIDevice.identifierForVendor","value":"XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"}
```

说明：

- `device_read` 默认按 **API + 返回值** 去重，避免日志刷爆。
- 请求和 Cookie 相关事件默认不去重，保留时序。

---

## 5. 推荐抓取流程

1. 安装 tweak
2. 清空旧日志
3. 杀掉 Instagram
4. 重开 Instagram
5. 执行登录 / 刷首页 / 打开发帖页等动作
6. `cat /tmp/instagram_account.json`

重开 App：

```bash
sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2224 root@127.0.0.1 'export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH; killall Instagram 2>/dev/null || true'
```

---

## 6. 注意事项

- 这是 **审计型 tweak**，不会修改任何 Header / Cookie / 设备值。
- 当前默认只针对 `com.burbn.instagram` 使用；安装脚本可改为其它 bundle。
- `NSURLSession` / `NSMutableURLRequest` 能覆盖大部分 App API 请求，但如果目标请求走更底层自定义网络栈，可能需要后续补 hook 点。
- `MGCopyAnswer` 使用 `MSHookFunction`；前提是实例里的 JB basebin / substrate 环境正常。
- 如果想把抓到的数据进一步回传到宿主机数据库或按会话切分，可在后续再做 host 侧收集脚本。
