import AppKit

// MARK: - Standard AppKit Menus

enum VPhoneStandardMenus {
    @MainActor
    static func buildEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")

        menu.addItem(
            withTitle: "撤销",
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        )

        let redo = NSMenuItem(
            title: "重做",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "Z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: "剪切",
            action: NSSelectorFromString("cut:"),
            keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: "复制",
            action: NSSelectorFromString("copy:"),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "粘贴",
            action: NSSelectorFromString("paste:"),
            keyEquivalent: "v"
        )

        let pasteAndMatchStyle = NSMenuItem(
            title: "粘贴并匹配样式",
            action: NSSelectorFromString("pasteAsPlainText:"),
            keyEquivalent: "V"
        )
        pasteAndMatchStyle.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(pasteAndMatchStyle)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: "全选",
            action: NSSelectorFromString("selectAll:"),
            keyEquivalent: "a"
        )

        item.submenu = menu
        return item
    }
}
