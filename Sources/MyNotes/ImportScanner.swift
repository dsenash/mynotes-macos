import Foundation

/// Безопасный обход папок перед импортом: ограничения по глубине, числу записей и времени,
/// пропуск ссылок, пакетов, системных и недоступных папок. Работает в фоновом потоке.
final class ScanNode {
    let url: URL
    let isDirectory: Bool
    var children: [ScanNode] = []

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

struct ScanResult {
    var roots: [ScanNode] = []
    var fileCount = 0
    var unreadable: [String] = []
    var rejected: [String] = []
    var skipped: [String] = []
    var truncated = false
}

final class ImportScanner {
    static let maxDepth = 8
    static let maxVisited = 20_000
    static let maxFiles = 2_000
    static let maxFileSize = 200 * 1024 * 1024
    static let timeLimit: TimeInterval = 20

    private let lock = NSLock()
    private var cancelled = false
    private var visited = 0
    private var deadline = Date()
    private var result = ScanResult()
    private let extensions: Set<String>
    private let reportedExtensions: Set<String> = ["onepkg", "mht", "pdf"]

    init(supportedExtensions: Set<String>) {
        extensions = supportedExtensions
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || Date() > deadline
    }

    func scan(_ urls: [URL]) -> ScanResult {
        deadline = Date().addingTimeInterval(ImportScanner.timeLimit)
        for url in urls {
            if isCancelled { result.truncated = true; break }
            if let reason = ImportScanner.tooBroadReason(url) {
                result.rejected.append("\(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent) — \(reason)")
                continue
            }
            if let node = visit(url, depth: 0) {
                result.roots.append(node)
            }
        }
        return result
    }

    private func visit(_ url: URL, depth: Int) -> ScanNode? {
        if isCancelled { result.truncated = true; return nil }
        visited += 1
        if visited > ImportScanner.maxVisited { result.truncated = true; return nil }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
            result.unreadable.append(url.lastPathComponent)
            return nil
        }
        if values.isSymbolicLink == true { return nil }

        let ext = url.pathExtension.lowercased()
        let isDir = values.isDirectory == true
        let isPackage = values.isPackage == true

        // Папка-документ .rtfd читается как один файл.
        if isDir && (isPackage || ext == "rtfd") {
            if ext == "rtfd" { return fileNode(url, ext: ext, size: 0) }
            return nil
        }

        if !isDir {
            return fileNode(url, ext: ext, size: values.fileSize ?? 0)
        }

        if depth >= ImportScanner.maxDepth { result.truncated = true; return nil }

        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            result.unreadable.append(url.lastPathComponent)
            return nil
        }
        let node = ScanNode(url: url, isDirectory: true)
        let sorted = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for item in sorted {
            if isCancelled { result.truncated = true; break }
            if result.fileCount >= ImportScanner.maxFiles { result.truncated = true; break }
            if let child = visit(item, depth: depth + 1) { node.children.append(child) }
        }
        // Папки без подходящих файлов в проекты не превращаются.
        return node.children.isEmpty ? nil : node
    }

    private func fileNode(_ url: URL, ext: String, size: Int) -> ScanNode? {
        guard extensions.contains(ext) else {
            if reportedExtensions.contains(ext) { result.skipped.append(url.lastPathComponent) }
            return nil
        }
        if size > ImportScanner.maxFileSize {
            result.skipped.append("\(url.lastPathComponent) (слишком большой файл)")
            return nil
        }
        result.fileCount += 1
        return ScanNode(url: url, isDirectory: false)
    }

    /// Папки, которые нельзя импортировать целиком: корень диска, домашняя папка, системные каталоги.
    static func tooBroadReason(_ url: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let exact: Set<String> = [
            "/", "/Users", "/Volumes", "/Applications", "/Library", "/System", "/private", "/usr",
            "/bin", "/sbin", "/opt", "/etc", "/var", "/dev", "/cores", home, home + "/Library"
        ]
        if exact.contains(path) {
            return "слишком широкая папка, выберите конкретную папку с файлами OneNote"
        }
        let systemPrefixes = ["/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/private/", "/dev/", "/etc/", "/var/",
                              "/Applications/", home + "/Library/"]
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) {
            return "системная папка"
        }
        return nil
    }
}
