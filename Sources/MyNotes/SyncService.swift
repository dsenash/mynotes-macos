import AppKit
import Network
import CryptoKit

/// Принимающая сторона: слушает порт, показывает запрос и, если пользователь разрешил,
/// отправляет все проекты и заметки одним пакетом.
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published private(set) var port: Int
    @Published private(set) var enabled: Bool
    @Published private(set) var status: String = ""

    let queue = DispatchQueue(label: "mynotes.sync.server")

    private var listener: NWListener?
    private var activeConnections = 0
    /// true, пока показан запрос или идёт передача (только главный поток).
    private var busy = false

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "sync.port")
        port = (1024...65535).contains(saved) ? saved : SyncConst.defaultPort
        enabled = UserDefaults.standard.object(forKey: "sync.enabled") as? Bool ?? true
    }

    // MARK: - Управление

    func start() {
        restart()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    @discardableResult
    func apply(port newPort: Int) -> Bool {
        guard (1024...65535).contains(newPort) else { return false }
        UserDefaults.standard.set(newPort, forKey: "sync.port")
        port = newPort
        restart()
        return true
    }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "sync.enabled")
        enabled = value
        restart()
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    private func restart() {
        listener?.cancel()
        listener = nil
        guard enabled else {
            setStatus("Приём запросов отключён")
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            setStatus("Некорректный порт")
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: parameters, on: nwPort)
            let currentPort = port
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.setStatus("Слушаю порт \(currentPort)")
                case .failed(let error):
                    self?.setStatus("Не удалось открыть порт \(currentPort): \(error.localizedDescription)")
                    newListener.cancel()
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.start(queue: queue)
            listener = newListener
            setStatus("Запуск…")
        } catch {
            setStatus("Не удалось открыть порт \(port): \(error.localizedDescription)")
        }
    }

    // MARK: - Входящие соединения

    private func accept(_ connection: NWConnection) {
        // Не принимаем лавину соединений: сканер подсети открывает по одному на устройство.
        if activeConnections >= 32 {
            connection.cancel()
            return
        }
        activeConnections += 1
        Task.detached { [weak self] in
            guard let self else { return }
            await self.serve(connection)
            self.queue.async { self.activeConnections -= 1 }
        }
    }

    private func serve(_ connection: NWConnection) async {
        let framed = FramedConnection(connection, queue: queue)
        framed.start()
        defer { framed.close() }
        framed.armTimeout(15)

        do {
            while true {
                let (type, body) = try await framed.receiveAsync(maxLength: SyncConst.maxControlFrame)
                switch type {
                case .hello:
                    // Сканирование: сообщаем, что здесь MyNotes.
                    let info = HelloMessage(
                        app: SyncConst.app, proto: SyncConst.proto,
                        deviceName: SyncIdentity.deviceName, deviceID: SyncIdentity.deviceID
                    )
                    try await framed.sendJSONAsync(.hello, info)
                    framed.armTimeout(15)

                case .request:
                    framed.disarmTimeout()
                    guard let request = try? JSONDecoder().decode(RequestMessage.self, from: body),
                          request.app == SyncConst.app, request.proto == SyncConst.proto else {
                        throw SyncError.protocolViolation
                    }
                    await handle(request: request, on: framed)
                    return

                default:
                    throw SyncError.protocolViolation
                }
            }
        } catch {
            // Зонды сканера и обрывы соединения — штатная ситуация, пользователю не показываем.
        }
    }

    // MARK: - Запрос на синхронизацию

    private enum Decision { case accepted, denied, busy }

    private struct Package {
        let url: URL
        let bytes: Int64
        let sha256: String
        let projects: Int
        let notes: Int
    }

    private func handle(request: RequestMessage, on framed: FramedConnection) async {
        let name = SyncIdentity.sanitize(request.deviceName)

        let decision = await MainActor.run { self.askUser(name: name) }
        guard decision == .accepted else {
            if decision == .denied { await MainActor.run { self.busy = false } }
            let reply = ReplyMessage(status: decision == .busy ? "busy" : "denied", deviceName: SyncIdentity.deviceName)
            try? await framed.sendJSONAsync(.reply, reply)
            return
        }

        // Разрешено: собираем пакет (все проекты и заметки одним файлом).
        let package: Package
        do {
            package = try await MainActor.run { try self.makePackage() }
        } catch {
            try? await framed.sendJSONAsync(.error, ErrorMessage(message: error.localizedDescription))
            await MainActor.run {
                Dialogs.info(title: "Синхронизация не выполнена", message: error.localizedDescription)
                self.busy = false
            }
            return
        }
        defer { try? FileManager.default.removeItem(at: package.url) }

        // Модальное окно с процентами.
        let modal = await MainActor.run { () -> ProgressModal in
            let m = ProgressModal(title: "Синхронизация проектов", message: "Отправка проектов на устройство\n«\(name)»")
            m.onCancel = { framed.cancelByUser() }
            m.update(fraction: 0)
            m.show()
            return m
        }

        do {
            try await stream(package, to: framed, modal: modal)
            await MainActor.run {
                self.busy = false
                modal.onClosed = {
                    Dialogs.info(
                        title: "Синхронизация завершена",
                        message: "Устройству «\(name)» передано проектов: \(package.projects), заметок: \(package.notes)."
                    )
                }
                modal.dismiss()
            }
        } catch {
            try? await framed.sendJSONAsync(.error, ErrorMessage(message: error.localizedDescription))
            await MainActor.run {
                self.busy = false
                if !error.isUserCancel {
                    modal.onClosed = {
                        Dialogs.info(title: "Синхронизация не выполнена", message: error.localizedDescription)
                    }
                }
                modal.dismiss()
            }
        }
    }

    /// Главный поток. Показывает модальный вопрос; по умолчанию (Enter) выбрано «Нет».
    private func askUser(name: String) -> Decision {
        if busy { return .busy }
        busy = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Получен запрос на синхронизацию проектов от : \(name)"
        alert.informativeText = "Разрешить синхронизацию?"
        alert.addButton(withTitle: "Да")
        alert.addButton(withTitle: "Нет")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn ? .accepted : .denied
    }

    /// Главный поток. Собирает все проекты и заметки в один файл.
    private func makePackage() throws -> Package {
        var archive = Store.shared.buildArchive(.all)
        archive.deviceName = SyncIdentity.deviceName
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(archive)
        guard Int64(data.count) <= SyncConst.maxPackageBytes else { throw SyncError.tooLarge }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotes-sync-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return Package(
            url: url, bytes: Int64(data.count),
            sha256: SyncCrypto.hex(SHA256.hash(data: data)),
            projects: archive.projects.count, notes: archive.notes.count
        )
    }

    private func stream(_ package: Package, to framed: FramedConnection, modal: ProgressModal) async throws {
        let chunkSize = SyncConst.chunkSize
        let chunkCount = UInt32((package.bytes + Int64(chunkSize) - 1) / Int64(chunkSize))

        // Необязательное шифрование паролем из настроек.
        let passphrase = SyncSecrets.passphrase
        var key: SymmetricKey?
        var reply = ReplyMessage(status: "accepted", deviceName: SyncIdentity.deviceName)
        reply.totalBytes = package.bytes
        reply.chunkSize = chunkSize
        reply.sha256 = package.sha256
        reply.projects = package.projects
        reply.notes = package.notes
        if !passphrase.isEmpty {
            let salt = SyncCrypto.randomBytes(16)
            let derived = SyncCrypto.deriveKey(passphrase: passphrase, salt: salt)
            key = derived
            reply.encrypted = true
            reply.salt = salt.base64EncodedString()
            reply.check = try SyncCrypto.makeCheck(key: derived)
        }

        framed.armTimeout(30)
        try await framed.sendJSONAsync(.reply, reply)

        let handle = try FileHandle(forReadingFrom: package.url)
        defer { try? handle.close() }

        var index: UInt32 = 0
        var sent: Int64 = 0
        var lastShownPercent = -1

        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            var payload = data
            if let key {
                payload = try SyncCrypto.seal(data, key: key, aad: SyncCrypto.chunkAAD(index: index, total: chunkCount))
            }
            try await framed.sendAsync(.chunk, bigEndian(index) + payload)
            framed.armTimeout(30)

            sent += Int64(data.count)
            index += 1

            let fraction = Double(sent) / Double(package.bytes)
            let percent = Int(fraction * 100)
            if percent != lastShownPercent {
                lastShownPercent = percent
                await MainActor.run { modal.update(fraction: fraction) }
            }
        }

        // Ждём подтверждение, что получатель принял и проверил данные.
        framed.armTimeout(30)
        let (type, body) = try await framed.receiveAsync(maxLength: SyncConst.maxControlFrame)
        framed.disarmTimeout()
        switch type {
        case .ack:
            await MainActor.run { modal.update(fraction: 1) }
        case .error:
            let text = (try? JSONDecoder().decode(ErrorMessage.self, from: body))?.message ?? "неизвестная ошибка"
            throw SyncError.remote(text)
        default:
            throw SyncError.protocolViolation
        }
    }
}
