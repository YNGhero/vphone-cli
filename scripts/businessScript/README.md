# businessScript 自动化脚本层

`businessScript` 是面向业务自动化测试的二开目录。这里的脚本不直接拼 `sshpass`、Unix socket JSON 或旧 shell 脚本，而是统一调用 `vphonekit`。

## Phase 1 目录

```text
scripts/businessScript/
├── vphone.py                         # 统一 CLI
├── vphone_automation_example.py      # 最小示例：打开 App / 点击 / 滑动 / Home / 关闭
├── vphonekit/                        # 通用能力库
│   ├── session.py                    # VPhoneSession 总入口
│   ├── instance.py                   # 实例解析
│   ├── hostctl.py                    # vphone.sock client
│   ├── ssh.py                        # SSH fallback
│   ├── legacy.py                     # 包装现有 scripts/*.sh
│   ├── screen.py                     # tap/swipe/key/screenshot/type
│   ├── ui.py                         # accessibility_tree 元素查询/精准点击（非 OCR）
│   ├── app.py                        # launch/terminate/open_url
│   ├── photos.py                     # import/delete-all，Phase 1 走 legacy
│   ├── app_state.py                  # backup/new/restore，Phase 1 走 legacy
│   ├── proxy.py                      # set/clear/test，Phase 1 走 legacy
│   ├── ocr.py                        # macOS Vision OCR：截图文字识别 + 文本坐标点击
│   ├── location.py                   # set/by-ip，走 socket
│   └── hooks.py                      # Hook 安装，Phase 1 走 legacy
└── instagram/                        # Instagram 业务脚本示例；其他 App 建同级目录
    ├── config.json
    └── smoke_test.py
```

## 代码里使用

```python
from vphonekit import VPhoneSession

with VPhoneSession("instagram-01", app="instagram", flow="smoke") as vp:
    vp.screen.show_window()
    vp.app.launch("com.burbn.instagram")
    # 有 accessibility label 时优先按元素点击；比固定坐标更稳。
    vp.ui.tap_text("Get started", bundle_id="com.burbn.instagram")
    # accessibility_tree 不稳定或 App 不暴露元素时，用 OCR 按屏幕文字点击。
    vp.ocr.tap_text("I already have a profile", timeout=15)
    # OCR 也不适合时，再 fallback 到固定坐标。
    vp.screen.tap(645, 1398)
    vp.screen.swipe(645, 2400, 645, 1200, ms=350)
    vp.screen.home()
    vp.app.terminate("com.burbn.instagram", process_name="Instagram")
```

## 统一 CLI 示例

```bash
# 唤起窗口
python3 scripts/businessScript/vphone.py screen show-window instagram-01

# 点击/滑动
python3 scripts/businessScript/vphone.py screen tap instagram-01 645,1398
python3 scripts/businessScript/vphone.py screen swipe instagram-01 645,2400,645,1200 --ms 350

# 打开/关闭 App
python3 scripts/businessScript/vphone.py app launch instagram-01 com.burbn.instagram
python3 scripts/businessScript/vphone.py app terminate instagram-01 com.burbn.instagram --process-name Instagram

# 照片
python3 scripts/businessScript/vphone.py photo import instagram-01 ./a.jpg --album VPhoneImports
python3 scripts/businessScript/vphone.py photo delete-all instagram-01 --yes

# App 状态
python3 scripts/businessScript/vphone.py app-state backup instagram-01 com.burbn.instagram --name before-login
python3 scripts/businessScript/vphone.py app-state new instagram-01 com.burbn.instagram --backup-before --yes
python3 scripts/businessScript/vphone.py app-state restore instagram-01 com.burbn.instagram ./backup.tar.gz --yes

# 代理
python3 scripts/businessScript/vphone.py proxy set instagram-01 http://user:pass@host:port --test
python3 scripts/businessScript/vphone.py proxy clear instagram-01 --yes

# 定位
python3 scripts/businessScript/vphone.py location set instagram-01 52.52 13.405
python3 scripts/businessScript/vphone.py location by-ip instagram-01 8.8.8.8

# Accessibility tree（非 OCR）
python3 scripts/businessScript/vphone.py ui tree instagram-01 --bundle-id com.burbn.instagram --max-nodes 80
python3 scripts/businessScript/vphone.py ui find instagram-01 "Get started" --bundle-id com.burbn.instagram
python3 scripts/businessScript/vphone.py ui bounds instagram-01 "Get started" --bundle-id com.burbn.instagram
python3 scripts/businessScript/vphone.py ui tap-text instagram-01 "Get started" --bundle-id com.burbn.instagram --screen

# OCR（AX 超时/找不到元素时使用；返回 center_pixels 可直接点击）
python3 scripts/businessScript/vphone.py ocr nodes instagram-01 --save-screenshot /tmp/ig.png
python3 scripts/businessScript/vphone.py ocr find instagram-01 "Log in"
python3 scripts/businessScript/vphone.py ocr bounds instagram-01 "Log in"
python3 scripts/businessScript/vphone.py ocr wait instagram-01 "I already have a profile" --timeout 15
python3 scripts/businessScript/vphone.py ocr tap-text instagram-01 "I already have a profile" --timeout 15

# Hook
python3 scripts/businessScript/vphone.py hook instagram-audit instagram-01 com.burbn.instagram
python3 scripts/businessScript/vphone.py hook profile instagram-01 com.burbn.instagram
```

## Transport 策略

- `--transport auto`：默认，socket 优先，失败 fallback 到 SSH/legacy。
- `--transport socket-only`：只允许 `vphone.sock`，适合验收新 host-control 能力。
- `--transport legacy`：直接走旧脚本/SSH，适合排障。

## 新业务脚本约定

- 新脚本放到 `scripts/businessScript/<app>/`。
- App 专属 bundle id、进程名、坐标、hook 配置放到 `config.json`。
- 不要在业务脚本里直接调用 `sshpass`、`socket.socket` 或 `scripts/*.sh`；统一走 `vphonekit`。
- UI 元素查询优先传 `bundle_id`，避免多个 App 同时运行时取错 accessibility tree。
