import AppKit
import UniformTypeIdentifiers

extension Store {
    static var archiveType: UTType {
        UTType(filenameExtension: "mynotes") ?? .json
    }

    // MARK: - Область экспорта

    func currentScope() -> ExportScope {
        if let id = activeTab { return .note(id) }
        if let id = selectedProject { return .project(id) }
        return .all
    }

    func scopeTitle(_ scope: ExportScope) -> String {
        switch scope {
        case .all: return "Все заметки"
        case .project(let id): return projectName(id)
        case .note(let id): return title(for: id)
        }
    }

    // MARK: - Сборка и запись архива

    func buildArchive(_ scope: ExportScope) -> Archive {
        var projectIDs: Set<UUID> = []
        var noteIDs: Set<UUID> = []
        var rootProject: UUID?
        var flattenNotes = false

        switch scope {
        case .all:
            projectIDs = Set(projects.map(\.id))
            noteIDs = Set(notes.map(\.id))
        case .project(let id):
            rootProject = id
            projectIDs = descendants(of: id).union([id])
            noteIDs = Set(notes.filter { n in n.projectID.map(projectIDs.contains) ?? false }.map(\.id))
        case .note(let id):
            noteIDs = [id]
            flattenNotes = true
        }

        let archivedProjects = projects.filter { projectIDs.contains($0.id) }.map { p in
            ArchivedProject(
                id: p.id.uuidString,
                parentID: p.id == rootProject ? nil : p.parentID?.uuidString,
                name: p.name,
                sort: p.sort,
                color: p.colorHex,
                fontStyle: p.fontStyle,
                updated: p.updated
            )
        }
        let archivedNotes = notes.filter { noteIDs.contains($0.id) }.map { n in
            ArchivedNote(
                id: n.id.uuidString,
                projectID: flattenNotes ? nil : n.projectID?.uuidString,
                title: n.title,
                created: n.created,
                updated: n.updated,
                body: body(for: n.id)
            )
        }
        return Archive(projects: archivedProjects, notes: archivedNotes)
    }

    func writeArchive(_ scope: ExportScope, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(buildArchive(scope)).write(to: url, options: .atomic)
    }

    private func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(60)).isEmpty ? "Заметки" : String(cleaned.prefix(60))
    }

    // MARK: - Экспорт в файл

    func exportWithPanel(_ scope: ExportScope) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Store.archiveType]
        panel.nameFieldStringValue = "MyNotes — \(safeFileName(scopeTitle(scope))).mynotes"
        panel.message = "Файл можно открыть в другой копии MyNotes — заметки будут импортированы."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeArchive(scope, to: url)
        } catch {
            Dialogs.info(title: "Не удалось экспортировать", message: error.localizedDescription)
        }
    }

    // MARK: - AirDrop

    func shareViaAirDrop(_ scope: ExportScope) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotes-share", isDirectory: true)
        let url = dir.appendingPathComponent("MyNotes — \(safeFileName(scopeTitle(scope))).mynotes")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeArchive(scope, to: url)
        } catch {
            Dialogs.info(title: "Не удалось подготовить файл", message: error.localizedDescription)
            return
        }
        let items: [Any] = [url]
        if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: items) {
            service.perform(withItems: items)
        } else if let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView {
            let picker = NSSharingServicePicker(items: items)
            sharingPicker = picker
            let anchor = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    // MARK: - Слияние изменений (общее для импорта .mynotes и синхронизации по сети)
    //
    // Правила (устоявшаяся практика для офлайн-синхронизации без центрального сервера):
    //  • у каждой записи (проект, заметка) есть идентификатор UUID и время последнего изменения;
    //  • «побеждает последняя запись» (last-writer-wins) отдельно для каждой записи;
    //  • изменение применяется только если оно новее локального, поэтому слияние идемпотентно:
    //    повторная синхронизация тех же данных ничего не меняет;
    //  • всё применяется одной транзакцией: либо все изменения, либо ни одного;
    //  • защита от циклов во вложенности проектов (A внутри B, B внутри A);
    //  • удаления не переносятся: слияние только добавляет и обновляет, чтобы ничего не потерять.

    private struct MergeNode {
        var parent: String?
        var updated: Double
    }

    struct MergeReport {
        var addedProjects = 0
        var updatedProjects = 0
        var addedNotes = 0
        var updatedNotes = 0
        var unchangedNotes = 0

        var summary: String {
            "Новых проектов: \(addedProjects)\nИзменённых проектов: \(updatedProjects)\n"
                + "Новых заметок: \(addedNotes)\nОбновлённых заметок: \(updatedNotes)\nБез изменений: \(unchangedNotes)"
        }
    }

    func decodeArchive(at url: URL) throws -> Archive {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive = try decoder.decode(Archive.self, from: data)
        guard archive.format == "MyNotes" else { throw DBError(message: "Это не файл MyNotes.") }
        guard archive.version <= 2 else {
            throw DBError(message: "Данные созданы более новой версией MyNotes. Обновите приложение.")
        }
        return archive
    }

    private static func createsCycle(_ id: String, newParent: String?, tree: [String: MergeNode]) -> Bool {
        var cursor = newParent
        var hops = 0
        while let current = cursor, hops < 10_000 {
            if current == id { return true }
            cursor = tree[current]?.parent
            hops += 1
        }
        return false
    }

    func mergeArchive(_ archive: Archive) throws -> MergeReport {
        var report = MergeReport()

        try db.transaction {
            try db.script("PRAGMA defer_foreign_keys = ON;")

            var tree: [String: MergeNode] = [:]
            let existing = try db.rows("SELECT id, parent_id, updated FROM projects") { (r: Row) -> (String, String?, Double) in
                (r.text(0) ?? "", r.text(1), r.real(2))
            }
            for row in existing { tree[row.0] = MergeNode(parent: row.1, updated: row.2) }
            let allProjectIDs = Set(tree.keys).union(archive.projects.map(\.id))

            // 1) Новые проекты. Сначала без родителя, чтобы порядок вставки не имел значения.
            var inserted = Set<String>()
            for p in archive.projects where tree[p.id] == nil {
                let stamp = p.updated?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                try db.execute(
                    "INSERT INTO projects (id, parent_id, name, sort, created, color, font_style, updated) VALUES (?, NULL, ?, ?, ?, ?, ?, ?)",
                    [.text(p.id), .text(p.name), .int(Int64(p.sort)), .real(Date().timeIntervalSince1970),
                     p.color.map { DBValue.text($0) } ?? .null, .int(Int64(p.fontStyle ?? 0)), .real(stamp)]
                )
                tree[p.id] = MergeNode(parent: nil, updated: stamp)
                inserted.insert(p.id)
                report.addedProjects += 1
            }

            // 2) Изменения существующих проектов и расстановка родителей.
            for p in archive.projects {
                guard let node = tree[p.id] else { continue }
                let isNew = inserted.contains(p.id)
                let remoteStamp = p.updated?.timeIntervalSince1970 ?? 0
                guard isNew || remoteStamp > node.updated + 0.0005 else { continue }

                if !isNew {
                    try db.execute(
                        "UPDATE projects SET name = ?, sort = ?, color = ?, font_style = ?, updated = ? WHERE id = ?",
                        [.text(p.name), .int(Int64(p.sort)), p.color.map { DBValue.text($0) } ?? .null,
                         .int(Int64(p.fontStyle ?? 0)), .real(remoteStamp), .text(p.id)]
                    )
                    tree[p.id]?.updated = remoteStamp
                    report.updatedProjects += 1
                }

                let desiredParent = p.parentID.flatMap { allProjectIDs.contains($0) ? $0 : nil }
                if desiredParent != node.parent,
                   !Store.createsCycle(p.id, newParent: desiredParent, tree: tree) {
                    try db.execute(
                        "UPDATE projects SET parent_id = ? WHERE id = ?",
                        [desiredParent.map { DBValue.text($0) } ?? .null, .text(p.id)]
                    )
                    tree[p.id]?.parent = desiredParent
                }
            }

            // 3) Заметки: побеждает более поздняя правка.
            for n in archive.notes {
                let current = try db.rows("SELECT updated FROM notes WHERE id = ?", [.text(n.id)]) { (r: Row) -> Double in r.real(0) }
                let projectValue = n.projectID.flatMap { allProjectIDs.contains($0) ? $0 : nil }
                    .map { DBValue.text($0) } ?? .null
                let plain = n.body.flatMap(BodyCodec.decode)?.string.replacingOccurrences(of: "\u{FFFC}", with: " ") ?? ""
                let blob = n.body.map { DBValue.blob($0) } ?? .null

                if let localStamp = current.first {
                    if n.updated.timeIntervalSince1970 > localStamp + 0.0005 {
                        try db.execute(
                            "UPDATE notes SET project_id = ?, title = ?, body = ?, plain = ?, updated = ? WHERE id = ?",
                            [projectValue, .text(n.title), blob, .text(plain), .real(n.updated.timeIntervalSince1970), .text(n.id)]
                        )
                        report.updatedNotes += 1
                    } else {
                        report.unchangedNotes += 1
                    }
                } else {
                    try db.execute(
                        "INSERT INTO notes (id, project_id, title, body, plain, created, updated) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        [.text(n.id), projectValue, .text(n.title), blob, .text(plain),
                         .real(n.created.timeIntervalSince1970), .real(n.updated.timeIntervalSince1970)]
                    )
                    report.addedNotes += 1
                }
            }
        }

        reload()
        return report
    }

    /// Применяет пакет, полученный по сети. Возвращает отчёт и имя устройства-источника.
    func applySyncPackage(at url: URL) throws -> (report: MergeReport, deviceName: String?) {
        let archive = try decodeArchive(at: url)
        return (try mergeArchive(archive), archive.deviceName)
    }

    // MARK: - Импорт .mynotes

    func importArchiveWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Store.archiveType]
        panel.allowsMultipleSelection = true
        panel.message = "Выберите файлы .mynotes, экспортированные из MyNotes"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { importArchive(from: $0) }
    }

    func importArchive(from url: URL) {
        do {
            let archive = try decodeArchive(at: url)
            let report = try mergeArchive(archive)
            NSApp.activate(ignoringOtherApps: true)
            Dialogs.info(title: "Импорт завершён", message: "Файл: \(url.lastPathComponent)\n" + report.summary)
        } catch {
            Dialogs.info(title: "Не удалось импортировать «\(url.lastPathComponent)»", message: error.localizedDescription)
        }
    }

    // MARK: - Импорт из OneNote (через экспортированные файлы)

    final class ScanBox {
        var result: ScanResult?
        var finished = false
    }

    struct ImportReport {
        var notes = 0
        var projects = 0
        var skipped: [String] = []
        var failed: [String] = []
        var warnings: [String] = []
    }

    func importOneNoteWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Выберите файлы разделов OneNote (.one) или папки с ними. Раздел станет проектом, страница — заметкой. Также подойдут экспортированные .docx, .html, .rtf, .odt, .txt."
        panel.prompt = "Импортировать"
        guard panel.runModal() == .OK else { return }
        importOneNote(urls: panel.urls)
    }

    func importOneNote(urls: [URL]) {
        // 1. Обход папок в фоне, с ограничениями и кнопкой «Отмена»: приложение не зависает
        //    на недоступных, огромных или системных папках.
        let scanner = ImportScanner(supportedExtensions: Store.supportedImportExtensions.union(["one"]))
        let modal = ProgressModal(title: "Импорт из OneNote", message: "Просмотр выбранных файлов и папок…")
        let box = ScanBox()
        modal.onCancel = {
            scanner.cancel()
            if !box.finished { box.finished = true; modal.dismiss() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = scanner.scan(urls)
            DispatchQueue.main.async {
                guard !box.finished else { return }
                box.finished = true
                box.result = r
                modal.dismiss()
            }
        }
        // Запасной выход: если файловая система не отвечает, окно закрывается само.
        DispatchQueue.main.asyncAfter(deadline: .now() + ImportScanner.timeLimit + 5) {
            guard !box.finished else { return }
            box.finished = true
            scanner.cancel()
            modal.dismiss()
        }
        modal.present()

        guard let scan = box.result else {
            Dialogs.info(
                title: "Импорт из OneNote",
                message: "Просмотр папок отменён или занял слишком много времени. Выберите конкретные файлы .one или небольшую папку."
            )
            return
        }

        if scan.fileCount == 0 {
            var text = "Подходящих файлов не найдено."
            if !scan.rejected.isEmpty { text += "\n\n" + scan.rejected.prefix(5).joined(separator: "\n") }
            if !scan.unreadable.isEmpty { text += "\n\nНет доступа: " + scan.unreadable.prefix(8).joined(separator: ", ") }
            Dialogs.info(title: "Импорт из OneNote", message: text)
            return
        }
        if scan.fileCount > 200 {
            guard Dialogs.confirm(
                title: "Импортировать \(scan.fileCount) файлов?",
                message: "Импорт большого числа файлов может занять несколько минут.",
                ok: "Импортировать", destructive: false
            ) else { return }
        }

        // 2. Сам импорт.
        var report = ImportReport()
        var rootID: UUID?
        attempt {
            try db.transaction {
                if let existing = projects.first(where: { $0.parentID == nil && $0.name == "OneNote" }) {
                    rootID = existing.id
                } else {
                    rootID = try insertProject(name: "OneNote", parent: nil)
                }
                for node in scan.roots {
                    try importNode(node, into: rootID, report: &report)
                }
            }
        }
        reload()
        if let rootID { expanded.insert(rootID) }

        var text = "Импортировано заметок: \(report.notes)\nСоздано проектов: \(report.projects)"
        if !report.failed.isEmpty {
            text += "\n\nНе удалось прочитать: " + report.failed.prefix(8).joined(separator: ", ")
        }
        if !report.warnings.isEmpty {
            text += "\n\n" + report.warnings.prefix(8).joined(separator: "\n")
        }
        if !scan.rejected.isEmpty {
            text += "\n\nПропущено: " + scan.rejected.prefix(5).joined(separator: "; ")
        }
        if !scan.unreadable.isEmpty {
            text += "\n\nНет доступа к: " + scan.unreadable.prefix(8).joined(separator: ", ")
            text += "\nРазрешите доступ в Системные настройки → Конфиденциальность и безопасность → Файлы и папки."
        }
        if scan.truncated {
            text += "\n\nОбход остановлен по лимиту (глубина, число файлов или время): часть файлов не импортирована. Выберите папку поменьше."
        }
        if !scan.skipped.isEmpty {
            text += "\n\nПропущены: " + scan.skipped.prefix(8).joined(separator: ", ")
            if scan.skipped.contains(where: { $0.lowercased().contains(".onepkg") }) {
                text += "\nПакеты .onepkg не читаются напрямую — выберите отдельные файлы .one."
            }
        }
        Dialogs.info(title: "Импорт из OneNote", message: text)
    }

    private func importNode(_ node: ScanNode, into parent: UUID?, report: inout ImportReport) throws {
        if node.isDirectory {
            let projectID = try insertProject(name: node.url.lastPathComponent, parent: parent)
            report.projects += 1
            for child in node.children {
                try importNode(child, into: projectID, report: &report)
            }
        } else {
            try importFile(node.url, into: parent, report: &report)
        }
    }

    private func importFile(_ url: URL, into parent: UUID?, report: inout ImportReport) throws {
        let ext = url.pathExtension.lowercased()

        if ext == "one" {
            try importOneSection(url, into: parent, report: &report)
            return
        }

        guard Store.supportedImportExtensions.contains(ext) else {
            report.skipped.append(url.lastPathComponent)
            return
        }
        guard let attributed = loadAttributed(url) else {
            report.failed.append(url.lastPathComponent)
            return
        }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        TextTools.normalizeColors(mutable)
        let plain = mutable.string.replacingOccurrences(of: "\u{FFFC}", with: " ")
        var title = TextTools.title(from: plain)
        if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        try insertNote(
            project: parent, title: title, plain: plain,
            body: BodyCodec.encode(mutable), created: created, updated: Date()
        )
        report.notes += 1
    }

    static let supportedImportExtensions: Set<String> = [
        "docx", "doc", "odt", "rtf", "rtfd", "html", "htm", "webarchive", "txt", "md", "markdown"
    ]

    private func loadAttributed(_ url: URL) -> NSAttributedString? {
        let ext = url.pathExtension.lowercased()
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]

        switch ext {
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "webarchive": options[.documentType] = NSAttributedString.DocumentType.webArchive
        case "html", "htm":
            options[.documentType] = NSAttributedString.DocumentType.html
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        default:
            var encoding = String.Encoding.utf8
            guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, usedEncoding: &encoding)) else { return nil }
            return NSAttributedString(string: text, attributes: [.font: TextTools.defaultFont])
        }
        return try? NSAttributedString(url: url, options: options, documentAttributes: nil)
    }
}
