import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var appearanceObservation: NSKeyValueObservation?
    private var themeCancellable: AnyCancellable?
    private var pendingURLs: [URL] = []
    private let store = Store.shared

    // MARK: - Жизненный цикл

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            NSApp.applicationIconImage = GothicN.appIconImage(size: 512)
        }
        NSApp.mainMenu = buildMenu()
        makeWindow()
        setupTheme()
        setupStatusItem()
        SyncService.shared.start()
        showMainWindow()

        let urls = pendingURLs
        pendingURLs = []
        urls.forEach(handleOpen)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard window != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        showMainWindow()
        urls.forEach(handleOpen)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SyncService.shared.stop()
        EditorController.shared.flushCurrent()
    }

    private func handleOpen(_ url: URL) {
        if url.pathExtension.lowercased() == "mynotes" {
            store.importArchive(from: url)
        }
    }

    // MARK: - Окно

    private func makeWindow() {
        let host = NSHostingController(rootView: RootView())
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "MyNotes"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 480)
        if !w.setFrameUsingName("MyNotesMainWindow") {
            w.setContentSize(NSSize(width: 1100, height: 720))
            w.center()
        }
        w.setFrameAutosaveName("MyNotesMainWindow")
        window = w
    }

    // MARK: - Тема и настройки

    /// Следит за системной темой и за выбранными цветами, переключая вид главного окна при необходимости.
    private func setupTheme() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            let isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DispatchQueue.main.async {
                Theme.shared.systemIsDark = isDark
                self?.applyThemeAppearance()
            }
        }
        themeCancellable = Theme.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange срабатывает до смены значения — читаем уже новое на следующем цикле.
            DispatchQueue.main.async { self?.applyThemeAppearance() }
        }
        applyThemeAppearance()
    }

    private func applyThemeAppearance() {
        window?.appearance = Theme.shared.forcedAppearance
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MyNotes",
            .applicationIcon: GothicN.appIconImage(size: 256),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Dmitry Senashenko Oct 2026"
        ])
    }

    @objc private func syncFromLAN() {
        showMainWindow()
        SyncClient.shared.start()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = "Настройки MyNotes"
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Значок в трее

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = GothicN.trayImage()
            button.toolTip = "MyNotes"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(item("Открыть MyNotes", #selector(openMainFromTray)))
            menu.addItem(item("Новая заметка", #selector(newNoteFromTray)))
            menu.addItem(item("Синхронизироваться из локальной сети", #selector(syncFromLAN)))
            menu.addItem(item("Настройки…", #selector(openSettings)))
            menu.addItem(.separator())
            menu.addItem(std("Выйти из MyNotes", #selector(NSApplication.terminate(_:)), "q"))
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            showMainWindow()
        }
    }

    @objc private func openMainFromTray() { showMainWindow() }

    @objc private func newNoteFromTray() {
        showMainWindow()
        store.newNote(in: store.selectedProject)
    }

    // MARK: - Главное меню

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.target = self
        return i
    }

    /// Пункт без явной цели — действие уходит по цепочке ответчиков.
    private func std(_ title: String, _ action: Selector?, _ key: String = "",
                     _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for i in items { menu.addItem(i) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        // MyNotes
        main.addItem(submenu("MyNotes", [
            item("О программе MyNotes", #selector(showAbout)),
            .separator(),
            item("Настройки…", #selector(openSettings), ","),
            item("Синхронизироваться из локальной сети", #selector(syncFromLAN)),
            .separator(),
            item("Показать папку с данными", #selector(revealData)),
            .separator(),
            std("Скрыть MyNotes", #selector(NSApplication.hide(_:)), "h"),
            std("Скрыть остальные", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            std("Показать все", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            std("Завершить MyNotes", #selector(NSApplication.terminate(_:)), "q")
        ]))

        // Файл
        main.addItem(submenu("Файл", [
            item("Новая заметка", #selector(newNote), "n"),
            item("Новый проект", #selector(newProject), "n", [.command, .shift]),
            item("Новый вложенный проект", #selector(newNestedProject), "n", [.command, .option]),
            .separator(),
            item("Закрыть вкладку", #selector(closeTab), "w"),
            std("Закрыть окно", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            submenu("Импорт", [
                item("Из OneNote…", #selector(importOneNote)),
                item("Из файла MyNotes…", #selector(importMyNotes))
            ]),
            submenu("Экспорт", [
                item("Выбранное…", #selector(exportSelected)),
                item("Все заметки…", #selector(exportAll))
            ]),
            item("Поделиться через AirDrop…", #selector(shareAirDrop))
        ]))

        // Правка
        let find = std("Найти в заметке…", #selector(NSTextView.performFindPanelAction(_:)), "f")
        find.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        let findNext = std("Найти далее", #selector(NSTextView.performFindPanelAction(_:)), "g")
        findNext.tag = Int(NSTextFinder.Action.nextMatch.rawValue)
        let findPrev = std("Найти ранее", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift])
        findPrev.tag = Int(NSTextFinder.Action.previousMatch.rawValue)

        main.addItem(submenu("Правка", [
            std("Отменить", Selector(("undo:")), "z"),
            std("Повторить", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            std("Вырезать", #selector(NSText.cut(_:)), "x"),
            std("Скопировать", #selector(NSText.copy(_:)), "c"),
            std("Вставить", #selector(NSText.paste(_:)), "v"),
            std("Вставить без форматирования", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            std("Выбрать все", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find, findNext, findPrev,
            .separator(),
            item("Поиск по всем заметкам", #selector(focusSearch), "f", [.command, .option])
        ]))

        // Формат
        let fonts = NSMenuItem(title: "Шрифты", action: #selector(NSFontManager.orderFrontFontPanel(_:)), keyEquivalent: "t")
        fonts.target = NSFontManager.shared
        main.addItem(submenu("Формат", [
            item("Жирный", #selector(fmtBold), "b"),
            item("Курсив", #selector(fmtItalic), "i"),
            item("Подчёркнутый", #selector(fmtUnderline), "u"),
            item("Зачёркнутый", #selector(fmtStrike), "x", [.command, .shift]),
            .separator(),
            item("Заголовок", #selector(fmtTitle), "1", [.command, .option]),
            item("Подзаголовок", #selector(fmtHeading), "2", [.command, .option]),
            item("Малый заголовок", #selector(fmtSubheading), "3", [.command, .option]),
            item("Основной текст", #selector(fmtBody), "0", [.command, .option]),
            .separator(),
            item("Маркированный список", #selector(fmtBullets), "8", [.command, .shift]),
            item("Список задач", #selector(fmtChecklist), "7", [.command, .shift]),
            .separator(),
            item("По левому краю", #selector(fmtAlignLeft)),
            item("По центру", #selector(fmtAlignCenter)),
            item("По правому краю", #selector(fmtAlignRight)),
            .separator(),
            item("Ссылка…", #selector(fmtLink), "k"),
            item("Вставить изображение…", #selector(fmtImage), "i", [.command, .shift]),
            item("Вложить файл…", #selector(fmtFile), "a", [.command, .shift]),
            item("Нарисовать рисунок…", #selector(fmtDrawing), "d", [.command, .option]),
            .separator(),
            fonts,
            std("Цвета", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift])
        ]))

        // Вид
        let rightArrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let leftArrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        main.addItem(submenu("Вид", [
            item("Показать/скрыть боковую панель", #selector(toggleSidebar), "s", [.command, .option]),
            .separator(),
            item("Следующая вкладка", #selector(nextTab), rightArrow, [.command, .option]),
            item("Предыдущая вкладка", #selector(prevTab), leftArrow, [.command, .option]),
            .separator(),
            std("Во весь экран", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        ]))

        // Окно
        let windowMenuItem = submenu("Окно", [
            std("Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m"),
            std("Увеличить", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Открыть главное окно MyNotes", #selector(openMainFromTray)),
            std("Все окна — на передний план", #selector(NSApplication.arrangeInFront(_:)))
        ])
        main.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenuItem.submenu

        return main
    }

    // MARK: - Действия меню

    @objc private func newNote() { showMainWindow(); store.newNote(in: store.selectedProject) }
    @objc private func newProject() { showMainWindow(); store.promptNewProject(parent: nil) }
    @objc private func newNestedProject() {
        guard let id = store.selectedProject else { return }
        store.promptNewProject(parent: id)
    }
    @objc private func closeTab() { store.closeActiveTab() }
    @objc private func importOneNote() { showMainWindow(); store.importOneNoteWithPanel() }
    @objc private func importMyNotes() { showMainWindow(); store.importArchiveWithPanel() }
    @objc private func exportSelected() { store.exportWithPanel(store.currentScope()) }
    @objc private func exportAll() { store.exportWithPanel(.all) }
    @objc private func shareAirDrop() { store.shareViaAirDrop(store.currentScope()) }
    @objc private func revealData() { store.revealDataFolder() }
    @objc private func focusSearch() { showMainWindow(); store.focusSearch() }
    @objc private func toggleSidebar() { store.showSidebar.toggle() }
    @objc private func nextTab() { store.selectNextTab(1) }
    @objc private func prevTab() { store.selectNextTab(-1) }

    private var editor: EditorController { EditorController.shared }
    @objc private func fmtBold() { editor.toggleBold() }
    @objc private func fmtItalic() { editor.toggleItalic() }
    @objc private func fmtUnderline() { editor.toggleUnderline() }
    @objc private func fmtStrike() { editor.toggleStrikethrough() }
    @objc private func fmtTitle() { editor.setStyle(.title) }
    @objc private func fmtHeading() { editor.setStyle(.heading) }
    @objc private func fmtSubheading() { editor.setStyle(.subheading) }
    @objc private func fmtBody() { editor.setStyle(.body) }
    @objc private func fmtBullets() { editor.toggleBullets() }
    @objc private func fmtChecklist() { editor.toggleChecklist() }
    @objc private func fmtAlignLeft() { editor.alignLeft() }
    @objc private func fmtAlignCenter() { editor.alignCenter() }
    @objc private func fmtAlignRight() { editor.alignRight() }
    @objc private func fmtLink() { editor.insertLink() }
    @objc private func fmtImage() { editor.insertImages() }
    @objc private func fmtFile() { editor.insertFiles() }
    @objc private func fmtDrawing() { editor.insertDrawing() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(closeTab), #selector(nextTab), #selector(prevTab):
            return store.activeTab != nil
        case #selector(newNestedProject):
            return store.selectedProject != nil
        case #selector(syncFromLAN):
            return !SyncClient.shared.isRunning
        case #selector(fmtBold), #selector(fmtItalic), #selector(fmtUnderline), #selector(fmtStrike),
             #selector(fmtTitle), #selector(fmtHeading), #selector(fmtSubheading), #selector(fmtBody),
             #selector(fmtBullets), #selector(fmtChecklist), #selector(fmtAlignLeft), #selector(fmtAlignCenter),
             #selector(fmtAlignRight), #selector(fmtLink), #selector(fmtImage), #selector(fmtFile), #selector(fmtDrawing):
            return store.activeTab != nil
        default:
            return true
        }
    }
}
