import SwiftUI
import AppKit
import Combine

/// Содержимое отдельного окна заметки: панель форматирования и редактор.
struct NoteWindowView: View {
    let noteID: UUID
    @ObservedObject private var theme = Theme.shared

    var body: some View {
        VStack(spacing: 0) {
            FormatBar()
            Divider()
            EditorView(noteID: noteID)
        }
        .background(theme.backgroundColor ?? Color(nsColor: .textBackgroundColor))
    }
}

/// Отдельные окна заметок. Окон может быть сколько угодно, они не модальные:
/// можно работать с несколькими заметками одновременно, а главное окно остаётся доступным.
final class NoteWindows: NSObject, NSWindowDelegate {
    static let shared = NoteWindows()

    private var windows: [UUID: NSWindow] = [:]
    private var titleTokens: [UUID: AnyCancellable] = [:]
    private var cascadePoint = NSPoint.zero

    /// Если заметка уже открыта в отдельном окне, выводит его на передний план.
    @discardableResult
    func focus(_ id: UUID) -> Bool {
        guard let window = windows[id] else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func open(_ id: UUID) {
        if focus(id) { return }
        let store = Store.shared
        guard store.notes.contains(where: { $0.id == id }) else { return }

        // Заметка не должна одновременно редактироваться во вкладке и в окне: сохраняем и закрываем вкладку.
        EditorCoordinator.flushAll()
        store.closeTab(id)

        let host = NSHostingController(rootView: NoteWindowView(noteID: id))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = store.title(for: id)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.setContentSize(NSSize(width: 720, height: 600))
        window.appearance = Theme.shared.forcedAppearance
        window.delegate = self
        if windows.isEmpty {
            window.center()
            cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)

        windows[id] = window
        titleTokens[id] = store.$notes
            .receive(on: DispatchQueue.main)
            .sink { [weak window] _ in window?.title = store.title(for: id) }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: UUID) {
        windows[id]?.close()
    }

    func applyAppearance() {
        for window in windows.values { window.appearance = Theme.shared.forcedAppearance }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        EditorCoordinator.flushAll(noteID: id)
        windows[id] = nil
        titleTokens[id] = nil
    }
}
