import Foundation

// MARK: - Menu Text

enum VPhoneMenuText {
    enum App {
        static let quit = "退出 vphone"
    }

    enum Connect {
        static let menu = "连接"
        static let fileBrowser = "文件管理器"
        static let keychainBrowser = "钥匙串"
        static let developerModeStatus = "开发者模式状态"
        static let ping = "Ping"
        static let guestVersion = "Guest 版本"
        static let getClipboard = "读取剪贴板"
        static let setClipboard = "设置剪贴板文本..."
        static let readSetting = "读取设置..."
        static let writeSetting = "写入设置..."
    }

    enum Keys {
        static let menu = "按键"
        static let home = "主屏幕"
        static let power = "电源"
        static let volumeUp = "音量+"
        static let volumeDown = "音量-"
        static let spotlight = "Spotlight（Cmd+Space）"
        static let typeASCII = "从剪贴板输入 ASCII"
        static let touchIDForwarding = "Touch ID 转发 Home"
    }

    enum Apps {
        static let menu = "应用"
        static let browser = "App 管理器"
        static let openURL = "打开 URL..."
        static let installPackage = "安装 IPA/TIPA..."
    }

    enum Record {
        static let menu = "录制/截图"
        static let start = "开始录屏"
        static let stop = "停止录屏"
        static let copyScreenshot = "复制截图到剪贴板"
        static let saveScreenshot = "保存截图到文件"
    }

    enum Instance {
        static let menu = "实例管理"
        static let manager = "多开管理器..."
        static let installPackage = "安装 IPA/TIPA..."
        static let appBackup = "备份 App..."
        static let appNewDevice = "一键新机..."
        static let appRestore = "还原 App..."
        static let importPhoto = "导入图片到相册..."
        static let deletePhotos = "清空相册..."
        static let reboot = "一键重启"
        static let respring = "Restart SpringBoard"
        static let showConnectionInfo = "查看连接信息"
        static let copyIdentity = "复制 UDID/ECID"
        static let openInstanceDirectory = "打开实例目录"
        static let openLogDirectory = "打开日志目录"
    }

    enum Window {
        static let menu = "窗口"
        static let close = "关闭"
        static let minimize = "最小化"
    }

    enum Location {
        static let menu = "定位"
        static let syncHost = "同步宿主机定位"
        static let preset = "预设定位"
        static let startReplay = "开始路线模拟"
        static let stopReplay = "停止路线模拟"
    }

    enum Battery {
        static let menu = "电池"
        static let syncHost = "同步宿主机电池"
        static let charging = "充电中"
        static let disconnected = "未充电"
    }
}
