import AppKit
import Combine

/// Единое хранилище состояния: проекты, заметки, открытые вкладки.
/// Все обращения — из главного потока.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var notes: [NoteMeta] = []

    @Published var openTabs: [UUID] = [] { didSet { persistTabs() } }
    @Published var activeTab: UUID? { didSet { persistTabs() } }
    @Published var selectedProject: UUID?
    @Published var expanded: Set<UUID> = []

    @Published var showSidebar = true
    /// true — проекты, помеченные «Скрываемый», скрыты (кнопка с глазом в боковой панели).
    @Published private(set) var hiddenMode = UserDefaults.standard.bool(forKey: "hiddenMode")
    /// Режим «не показывать устаревшие» (кнопка E).
    @Published private(set) var expiredMode = UserDefaults.standard.bool(forKey: "expiredMode")
    @Published var sidebarWidth: CGFloat = 270
    @Published var focusSearchTick = 0

    @Published var searchText = "" { didSet { runSearch() } }
    @Published private(set) var searchResults: [NoteMeta] = []

    let db: Database
    var sharingPicker: NSSharingServicePicker?
    private var sortCounter = 0

    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MyNotes", isDirectory: true).appendingPathComponent("mynotes.sqlite")
    }

    private init() {
        do {
            db = try Database(url: Store.databaseURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось открыть базу данных"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
        reload()
        restoreTabs()
    }

    // MARK: - Загрузка

    func reload() {
        attempt {
            let loadedProjects = try db.rows(
                "SELECT id, parent_id, name, sort, created, color, font_style, updated FROM projects ORDER BY sort, name COLLATE NOCASE"
            ) { (r: Row) -> Project? in
                guard let id = r.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
                return Project(
                    id: id,
                    parentID: r.text(1).flatMap(UUID.init(uuidString:)),
                    name: r.text(2) ?? "",
                    sort: Int(r.int(3)),
                    created: Date(timeIntervalSince1970: r.real(4)),
                    colorHex: r.text(5),
                    fontStyle: Int(r.int(6)),
                    updated: Date(timeIntervalSince1970: r.real(7))
                )
            }
            projects = loadedProjects.compactMap { $0 }
            sortCounter = projects.map(\.sort).max() ?? 0

            let loadedNotes = try db.rows(
                "SELECT id, project_id, title, created, updated, expired FROM notes ORDER BY created DESC"
            ) { (r: Row) -> NoteMeta? in
                guard let id = r.text(0).flatMap(UUID.init(uuidString:)) else { return nil }
                return NoteMeta(
                    id: id,
                    projectID: r.text(1).flatMap(UUID.init(uuidString:)),
                    title: r.text(2) ?? "",
                    created: Date(timeIntervalSince1970: r.real(3)),
                    updated: Date(timeIntervalSince1970: r.real(4)),
                    isExpired: r.int(5) != 0
                )
            }
            notes = loadedNotes.compactMap { $0 }
        }
        if !searchText.isEmpty { runSearch() }
    }

    func attempt(_ body: () throws -> Void) {
        do { try body() } catch {
            Dialogs.info(title: "Ошибка базы данных", message: error.localizedDescription)
        }
    }

    // MARK: - Вкладки

    private func persistTabs() {
        UserDefaults.standard.set(openTabs.map(\.uuidString), forKey: "openTabs")
        UserDefaults.standard.set(activeTab?.uuidString, forKey: "activeTab")
    }

    private func restoreTabs() {
        let known = Set(notes.filter { !isNoteHidden($0) }.map(\.id))
        let ids = (UserDefaults.standard.stringArray(forKey: "openTabs") ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter { known.contains($0) }
        openTabs = ids
        if let s = UserDefaults.standard.string(forKey: "activeTab"),
           let u = UUID(uuidString: s), ids.contains(u) {
            activeTab = u
        } else {
            activeTab = ids.last
        }
    }

    func openNote(_ id: UUID) {
        if NoteWindows.shared.focus(id) { return }
        guard let meta = notes.first(where: { $0.id == id }) else { return }
        if !openTabs.contains(id) { openTabs.append(id) }
        activeTab = id
        selectedProject = meta.projectID
    }

    func closeTab(_ id: UUID) {
        guard let idx = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: idx)
        if activeTab == id {
            activeTab = openTabs.isEmpty ? nil : openTabs[min(idx, openTabs.count - 1)]
        }
    }

    func closeActiveTab() {
        if let id = activeTab { closeTab(id) }
    }

    func closeOtherTabs(except id: UUID) {
        openTabs = [id]
        activeTab = id
    }

    func closeAllTabs() {
        openTabs = []
        activeTab = nil
    }

    func selectNextTab(_ step: Int) {
        guard let current = activeTab, let idx = openTabs.firstIndex(of: current), !openTabs.isEmpty else { return }
        let next = (idx + step + openTabs.count) % openTabs.count
        activeTab = openTabs[next]
    }

    func title(for id: UUID) -> String {
        let t = notes.first(where: { $0.id == id })?.title ?? "Заметка"
        return t.isEmpty ? "Новая заметка" : t
    }

    // MARK: - Проекты

    @discardableResult
    func insertProject(id: UUID = UUID(), name: String, parent: UUID?) throws -> UUID {
        sortCounter += 1
        try db.execute(
            "INSERT INTO projects (id, parent_id, name, sort, created, updated) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(id.uuidString), .uuid(parent), .text(name), .int(Int64(sortCounter)),
             .real(Date().timeIntervalSince1970), .real(Date().timeIntervalSince1970)]
        )
        return id
    }

    @discardableResult
    func addProject(name: String, parent: UUID?) -> UUID? {
        var created: UUID?
        attempt { created = try insertProject(name: name, parent: parent) }
        guard let id = created else { return nil }
        reload()
        if let parent { expanded.insert(parent) }
        selectedProject = id
        return id
    }

    func promptNewProject(parent: UUID?) {
        let title = parent == nil ? "Новый проект" : "Новый вложенный проект"
        let message = parent.map { "Внутри проекта «\(projectName($0))»" } ?? ""
        if let name = Dialogs.prompt(title: title, message: message, defaultValue: "", ok: "Создать") {
            addProject(name: name, parent: parent)
        }
    }

    func promptRename(project id: UUID) {
        guard let name = Dialogs.prompt(title: "Переименовать проект", defaultValue: projectName(id), ok: "Сохранить") else { return }
        attempt {
            try db.execute(
                "UPDATE projects SET name = ?, updated = ? WHERE id = ?",
                [.text(name), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
            )
        }
        reload()
    }

    /// Цвет названия проекта (hex вида #RRGGBB, nil — стандартный).
    /// Обновляет данные в памяти без полной перезагрузки, чтобы выбор в панели цветов не тормозил.
    func setProjectColor(_ id: UUID, hex: String?) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        projects[i].colorHex = hex
        projects[i].updated = now
        attempt {
            try db.execute(
                "UPDATE projects SET color = ?, updated = ? WHERE id = ?",
                [hex.map { DBValue.text($0) } ?? .null, .real(now.timeIntervalSince1970), .text(id.uuidString)]
            )
        }
    }

    /// Начертание названия проекта. nil оставляет соответствующий признак без изменений.
    func setProjectFontStyle(_ id: UUID, bold: Bool?, italic: Bool?) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        var style = projects[i].fontStyle
        if let bold { style = bold ? (style | 1) : (style & ~1) }
        if let italic { style = italic ? (style | 2) : (style & ~2) }
        let now = Date()
        projects[i].fontStyle = style
        projects[i].updated = now
        attempt {
            try db.execute(
                "UPDATE projects SET font_style = ?, updated = ? WHERE id = ?",
                [.int(Int64(style)), .real(now.timeIntervalSince1970), .text(id.uuidString)]
            )
        }
    }

    // MARK: - Скрытие проектов

    /// Проект скрыт, если включён режим скрытия и он (или любой его родитель) помечен «Скрываемый».
    func isProjectHidden(_ id: UUID?) -> Bool {
        guard hiddenMode || expiredMode else { return false }
        var current = id
        var steps = 0
        while let cid = current, steps < 64 {
            guard let p = projects.first(where: { $0.id == cid }) else { return false }
            if hiddenMode && p.isHideable { return true }
            if expiredMode && p.isExpired { return true }
            current = p.parentID
            steps += 1
        }
        return false
    }

    /// Заметка скрыта: скрыт её проект или она сама устарела при включённом режиме E.
    func isNoteHidden(_ note: NoteMeta) -> Bool {
        (expiredMode && note.isExpired) || isProjectHidden(note.projectID)
    }

    func toggleExpiredMode() {
        expiredMode.toggle()
        UserDefaults.standard.set(expiredMode, forKey: "expiredMode")
        afterHiddenChange()
    }

    func setNoteExpired(_ id: UUID, _ value: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].isExpired = value
        attempt {
            try db.execute("UPDATE notes SET expired = ? WHERE id = ?", [.int(value ? 1 : 0), .text(id.uuidString)])
        }
        afterHiddenChange()
    }

    func toggleHiddenMode() {
        hiddenMode.toggle()
        UserDefaults.standard.set(hiddenMode, forKey: "hiddenMode")
        afterHiddenChange()
    }

    func setProjectHideable(_ id: UUID, _ value: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let style = value ? (projects[i].fontStyle | 4) : (projects[i].fontStyle & ~4)
        let now = Date()
        projects[i].fontStyle = style
        projects[i].updated = now
        attempt {
            try db.execute(
                "UPDATE projects SET font_style = ?, updated = ? WHERE id = ?",
                [.int(Int64(style)), .real(now.timeIntervalSince1970), .text(id.uuidString)]
            )
        }
        afterHiddenChange()
    }

    /// Метка Expired у проекта или подпапки (красная плашка перед названием).
    func setProjectExpired(_ id: UUID, _ value: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let style = value ? (projects[i].fontStyle | 8) : (projects[i].fontStyle & ~8)
        let now = Date()
        projects[i].fontStyle = style
        projects[i].updated = now
        attempt {
            try db.execute(
                "UPDATE projects SET font_style = ?, updated = ? WHERE id = ?",
                [.int(Int64(style)), .real(now.timeIntervalSince1970), .text(id.uuidString)]
            )
        }
    }

    /// Скрытые заметки не должны оставаться открытыми во вкладках и в результатах поиска.
    private func afterHiddenChange() {
        guard hiddenMode || expiredMode else {
            if !searchText.isEmpty { runSearch() }
            return
        }
        for id in openTabs {
            if let note = notes.first(where: { $0.id == id }), isNoteHidden(note) {
                closeTab(id)
            }
        }
        if let selected = selectedProject, isProjectHidden(selected) { selectedProject = nil }
        if !searchText.isEmpty { runSearch() }
    }

    func projectName(_ id: UUID) -> String {
        projects.first(where: { $0.id == id })?.name ?? ""
    }

    func descendants(of id: UUID) -> Set<UUID> {
        var out: Set<UUID> = []
        var stack = [id]
        while let current = stack.popLast() {
            for p in projects where p.parentID == current {
                if out.insert(p.id).inserted { stack.append(p.id) }
            }
        }
        return out
    }

    func path(of id: UUID) -> String {
        var parts: [String] = []
        var current: UUID? = id
        var guardCount = 0
        while let c = current, let p = projects.first(where: { $0.id == c }), guardCount < 64 {
            parts.insert(p.name, at: 0)
            current = p.parentID
            guardCount += 1
        }
        return parts.joined(separator: " / ")
    }

    func confirmDeleteProject(_ id: UUID) {
        let all = descendants(of: id).union([id])
        let affected = notes.filter { n in n.projectID.map(all.contains) ?? false }
        let subCount = all.count - 1
        var details = "Будет удалено заметок: \(affected.count)."
        if subCount > 0 { details += " Вложенных проектов: \(subCount)." }
        details += " Это действие нельзя отменить."
        guard Dialogs.confirm(title: "Удалить проект «\(projectName(id))»?", message: details, ok: "Удалить") else { return }

        for n in affected { closeTab(n.id) }
        attempt { try db.execute("DELETE FROM projects WHERE id = ?", [.text(id.uuidString)]) }
        if let sel = selectedProject, all.contains(sel) { selectedProject = nil }
        expanded.subtract(all)
        reload()
    }

    @discardableResult
    func moveProject(_ id: UUID, to newParent: UUID?) -> Bool {
        if let newParent {
            if newParent == id || descendants(of: id).contains(newParent) { return false }
        }
        if projects.first(where: { $0.id == id })?.parentID == newParent { return false }
        attempt {
            try db.execute(
                "UPDATE projects SET parent_id = ?, updated = ? WHERE id = ?",
                [.uuid(newParent), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
            )
        }
        reload()
        return true
    }

    // MARK: - Заметки

    @discardableResult
    func insertNote(
        id: UUID = UUID(), project: UUID?, title: String = "Новая заметка", plain: String = "",
        body: Data? = nil, created: Date = Date(), updated: Date = Date()
    ) throws -> UUID {
        try db.execute(
            "INSERT INTO notes (id, project_id, title, body, plain, created, updated) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(id.uuidString), .uuid(project), .text(title), body.map { DBValue.blob($0) } ?? .null,
             .text(plain), .real(created.timeIntervalSince1970), .real(updated.timeIntervalSince1970)]
        )
        return id
    }

    @discardableResult
    func newNote(in project: UUID?) -> UUID? {
        var created: UUID?
        attempt { created = try insertNote(project: project) }
        guard let id = created else { return nil }
        reload()
        if let project { expanded.insert(project) }
        openNote(id)
        return id
    }

    func saveBody(id: UUID, data: Data, plain: String) {
        let title = TextTools.title(from: plain)
        let clean = plain.replacingOccurrences(of: "\u{FFFC}", with: " ")
        let now = Date()
        attempt {
            try db.execute(
                "UPDATE notes SET body = ?, plain = ?, title = ?, updated = ? WHERE id = ?",
                [.blob(data), .text(clean), .text(title), .real(now.timeIntervalSince1970), .text(id.uuidString)]
            )
        }
        if let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i].title = title
            notes[i].updated = now
        }
    }

    func body(for id: UUID) -> Data? {
        let result = try? db.rows("SELECT body FROM notes WHERE id = ?", [.text(id.uuidString)]) { (r: Row) -> Data? in r.blob(0) }
        return result?.first ?? nil
    }

    func confirmDeleteNote(_ id: UUID) {
        guard Dialogs.confirm(
            title: "Удалить заметку «\(title(for: id))»?",
            message: "Это действие нельзя отменить.", ok: "Удалить"
        ) else { return }
        NoteWindows.shared.close(id)
        closeTab(id)
        attempt { try db.execute("DELETE FROM notes WHERE id = ?", [.text(id.uuidString)]) }
        reload()
    }

    func moveNote(_ id: UUID, to project: UUID?) {
        // Перенос заметки — тоже изменение: обновляем метку, чтобы оно доехало при синхронизации.
        attempt {
            try db.execute(
                "UPDATE notes SET project_id = ?, updated = ? WHERE id = ?",
                [.uuid(project), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
            )
        }
        reload()
        if let project { expanded.insert(project) }
    }

    func duplicateNote(_ id: UUID) {
        guard let meta = notes.first(where: { $0.id == id }) else { return }
        let data = body(for: id)
        let plain = data.flatMap(BodyCodec.decode)?.string ?? ""
        var newID: UUID?
        attempt {
            newID = try insertNote(project: meta.projectID, title: meta.title + " (копия)", plain: plain, body: data)
        }
        reload()
        if let newID { openNote(newID) }
    }

    @discardableResult
    func handleDrop(_ items: [String], onto project: UUID?) -> Bool {
        var moved = false
        for s in items {
            if s.hasPrefix("note:"), let id = UUID(uuidString: String(s.dropFirst(5))) {
                moveNote(id, to: project)
                moved = true
            } else if s.hasPrefix("project:"), let id = UUID(uuidString: String(s.dropFirst(8))) {
                moved = moveProject(id, to: project) || moved
            }
        }
        if let project { expanded.insert(project) }
        return moved
    }

    // MARK: - Боковая панель и поиск

    func sidebarRows() -> [SidebarRow] {
        var out: [SidebarRow] = []
        let childProjects = Dictionary(grouping: projects, by: { $0.parentID })
        let projectNotes = Dictionary(grouping: notes, by: { $0.projectID })

        func walk(_ parent: UUID?, _ depth: Int) {
            for p in childProjects[parent] ?? [] {
                if hiddenMode && p.isHideable { continue }
                if expiredMode && p.isExpired { continue }
                out.append(.project(p, depth))
                if expanded.contains(p.id) { walk(p.id, depth + 1) }
            }
            for n in projectNotes[parent] ?? [] {
                if expiredMode && n.isExpired { continue }
                out.append(.note(n, depth))
            }
        }
        walk(nil, 0)
        return out
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        let hits = (try? db.rows("SELECT id, title, plain FROM notes") { (r: Row) -> (String, String, String) in
            (r.text(0) ?? "", r.text(1) ?? "", r.text(2) ?? "")
        }) ?? []
        let ids = Set(hits.filter {
            $0.1.localizedCaseInsensitiveContains(query) || $0.2.localizedCaseInsensitiveContains(query)
        }.map { $0.0 })
        searchResults = notes.filter { ids.contains($0.id.uuidString) && !isNoteHidden($0) }
    }

    func focusSearch() {
        showSidebar = true
        focusSearchTick += 1
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.databaseURL])
    }
}
