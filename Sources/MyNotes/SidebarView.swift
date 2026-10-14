import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// Область, за которую можно перетаскивать окно (заголовок скрыт).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: Store
    @ObservedObject private var theme = Theme.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Строка со светофором окна и кнопкой скрытия панели
            HStack {
                Spacer()
                Button {
                    store.showSidebar = false
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Скрыть боковую панель (⌥⌘S)")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(WindowDragArea())

            header
            searchField

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(store.sidebarRows()) { row in
                            switch row {
                            case .project(let p, let depth):
                                ProjectRowView(store: store, project: p, depth: depth)
                            case .note(let n, let depth):
                                NoteRowView(store: store, note: n, depth: depth, showPath: false)
                            }
                        }
                        if store.projects.isEmpty && store.notes.isEmpty {
                            Text("Пока пусто.\nСоздайте проект или заметку кнопками выше.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    } else {
                        if store.searchResults.isEmpty {
                            Text("Ничего не найдено")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                        ForEach(store.searchResults) { n in
                            NoteRowView(store: store, note: n, depth: 0, showPath: true)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            // Перетаскивание на пустое место — перемещение на верхний уровень
            .dropDestination(for: String.self) { items, _ in
                store.handleDrop(items, onto: nil)
            }
        }
        .background {
            if let color = theme.sidebarColor {
                color
            } else {
                VisualEffectView(material: .sidebar)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Проекты")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.toggleHiddenMode() } label: {
                Image(systemName: store.hiddenMode ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(store.hiddenMode
                  ? "Скрываемые проекты скрыты. Нажмите, чтобы показать"
                  : "Скрываемые проекты показаны. Нажмите, чтобы скрыть")

            Button { store.promptNewProject(parent: nil) } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Новый проект (⇧⌘N)")

            Button { store.newNote(in: store.selectedProject) } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Новая заметка (⌘N)")

            Menu {
                Button("Импорт из OneNote…") { store.importOneNoteWithPanel() }
                Button("Импорт из файла MyNotes…") { store.importArchiveWithPanel() }
                Divider()
                Button("Экспорт выбранного…") { store.exportWithPanel(store.currentScope()) }
                Button("Экспорт всех заметок…") { store.exportWithPanel(.all) }
                Button("Поделиться через AirDrop…") { store.shareViaAirDrop(store.currentScope()) }
                Divider()
                Button("Показать папку с данными") { store.revealDataFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Поиск по заметкам", text: $store.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    store.searchText = ""
                    searchFocused = false
                }
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: store.focusSearchTick) {
            searchFocused = true
        }
    }
}

// MARK: - Строка проекта

struct ProjectRowView: View {
    @ObservedObject var store: Store
    let project: Project
    let depth: Int
    @State private var hover = false

    private var isExpanded: Bool { store.expanded.contains(project.id) }
    private var isSelected: Bool { store.selectedProject == project.id }
    private var hasChildren: Bool {
        store.projects.contains { $0.parentID == project.id } || store.notes.contains { $0.projectID == project.id }
    }

    private var nameColor: Color {
        project.colorHex.flatMap { NSColor(hex: $0) }.map { Color(nsColor: $0) } ?? Color.primary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14, height: 20)
                .opacity(hasChildren ? 0.6 : 0)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }

            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
            Text(project.name)
                .italic(project.isItalic)
                .fontWeight(project.isBold ? .bold : .regular)
                .lineLimit(1)
                .foregroundStyle(nameColor)
            Spacer(minLength: 4)

            if hover {
                Menu {
                    Button("Новая заметка") { store.newNote(in: project.id) }
                    Button("Новый вложенный проект") { store.promptNewProject(parent: project.id) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.22) : (hover ? Color.primary.opacity(0.06) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedProject = project.id
            toggle()
        }
        .onHover { hover = $0 }
        .draggable("project:" + project.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, onto: project.id)
        }
        .contextMenu {
            Button("Новая заметка") { store.newNote(in: project.id) }
            Button("Новый вложенный проект") { store.promptNewProject(parent: project.id) }
            Divider()
            Button("Переименовать…") { store.promptRename(project: project.id) }
            Menu("Цвет названия") {
                Button("По умолчанию") { store.setProjectColor(project.id, hex: nil) }
                Divider()
                ForEach(Palette.presets) { preset in
                    Button {
                        store.setProjectColor(project.id, hex: preset.hex)
                    } label: {
                        Label {
                            Text(preset.name)
                        } icon: {
                            Image(nsImage: ColorSwatch.image(preset.color))
                        }
                    }
                }
                Divider()
                Button("Другой цвет…") {
                    let id = project.id
                    ColorPanelHelper.shared.present(initial: project.colorHex.flatMap { NSColor(hex: $0) }) { color in
                        store.setProjectColor(id, hex: color.hexString)
                    }
                }
            }
            Menu("Начертание названия") {
                Toggle("Жирный", isOn: Binding(
                    get: { project.isBold },
                    set: { store.setProjectFontStyle(project.id, bold: $0, italic: nil) }
                ))
                Toggle("Курсив", isOn: Binding(
                    get: { project.isItalic },
                    set: { store.setProjectFontStyle(project.id, bold: nil, italic: $0) }
                ))
                Divider()
                Button("Обычный") { store.setProjectFontStyle(project.id, bold: false, italic: false) }
            }
            Toggle("Скрываемый", isOn: Binding(
                get: { project.isHideable },
                set: { store.setProjectHideable(project.id, $0) }
            ))
            Menu("Переместить в") {
                Button("Верхний уровень") { store.moveProject(project.id, to: nil) }
                let blocked = store.descendants(of: project.id).union([project.id])
                ForEach(store.projects.filter { !blocked.contains($0.id) }) { target in
                    Button(store.path(of: target.id)) { store.moveProject(project.id, to: target.id) }
                }
            }
            Divider()
            Button("Экспортировать…") { store.exportWithPanel(.project(project.id)) }
            Button("Поделиться через AirDrop…") { store.shareViaAirDrop(.project(project.id)) }
            Divider()
            Button("Удалить…", role: .destructive) { store.confirmDeleteProject(project.id) }
        }
    }

    private func toggle() {
        if isExpanded { store.expanded.remove(project.id) } else { store.expanded.insert(project.id) }
    }
}

// MARK: - Строка заметки

struct NoteRowView: View {
    @ObservedObject var store: Store
    let note: NoteMeta
    let depth: Int
    let showPath: Bool
    @State private var hover = false

    private var isActive: Bool { store.activeTab == note.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(note.title.isEmpty ? "Новая заметка" : note.title)
                    .lineLimit(1)
                if showPath, let pid = note.projectID {
                    Text(store.path(of: pid))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .frame(height: showPath ? 36 : 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Color.accentColor.opacity(0.22) : (hover ? Color.primary.opacity(0.06) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { store.openNote(note.id) }
        .onHover { hover = $0 }
        .draggable("note:" + note.id.uuidString)
        .contextMenu {
            Button("Открыть") { store.openNote(note.id) }
            Button("Дублировать") { store.duplicateNote(note.id) }
            Menu("Переместить в") {
                Button("Верхний уровень") { store.moveNote(note.id, to: nil) }
                ForEach(store.projects) { target in
                    Button(store.path(of: target.id)) { store.moveNote(note.id, to: target.id) }
                }
            }
            Divider()
            Button("Экспортировать…") { store.exportWithPanel(.note(note.id)) }
            Button("Поделиться через AirDrop…") { store.shareViaAirDrop(.note(note.id)) }
            Divider()
            Button("Удалить…", role: .destructive) { store.confirmDeleteNote(note.id) }
        }
    }
}
