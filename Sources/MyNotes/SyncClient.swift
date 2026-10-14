import AppKit
import Network
import CryptoKit
import Darwin

struct FoundDevice {
    let ip: String
    let name: String
    let id: String
}

/// Потокобезопасный флаг отмены.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - Сканирование локальной сети

enum LANScanner {
    private struct LocalNet {
        let address: UInt32
        let mask: UInt32
    }

    /// Адреса хостов в подсетях активных интерфейсов (только частные диапазоны,
    /// не больше /22, то есть до 1022 адресов на интерфейс).
    static func candidateHosts() -> [String] {
        var seen = Set<UInt32>()
        var result: [UInt32] = []

        for net in localNetworks() {
            let prefix = max(net.mask.nonzeroBitCount, 22)
            guard prefix < 31 else { continue }
            let hostBits = UInt32(32 - prefix)
            let netMask: UInt32 = ~UInt32(0) << hostBits
            let network = net.address & netMask
            let size = UInt32(1) << hostBits
            for i in 1..<(size - 1) {
                let ip = network + i
                if ip != net.address, seen.insert(ip).inserted { result.append(ip) }
            }
        }
        return result.map(string(from:))
    }

    private static func string(from ip: UInt32) -> String {
        "\((ip >> 24) & 255).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
    }

    private static func isPrivate(_ ip: UInt32) -> Bool {
        let a = (ip >> 24) & 255, b = (ip >> 16) & 255
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
    }

    private static func localNetworks() -> [LocalNet] {
        var list: [LocalNet] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return [] }
        defer { freeifaddrs(first) }

        let skipPrefixes = ["utun", "awdl", "llw", "ipsec", "gif", "stf", "ppp"]
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = entry.pointee.ifa_netmask else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if skipPrefixes.contains(where: { name.hasPrefix($0) }) { continue }

            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if isPrivate(address) { list.append(LocalNet(address: address, mask: mask)) }
        }
        return list
    }

    /// Ищет устройства с MyNotes, слушающие `port`. Прогресс 0…1.
    static func scan(port: UInt16, cancelled: CancelFlag, progress: @escaping (Double) -> Void) async -> [FoundDevice] {
        let hosts = candidateHosts()
        guard !hosts.isEmpty else { return [] }
        return await withCheckedContinuation { (cont: CheckedContinuation<[FoundDevice], Never>) in
            let job = ScanJob(hosts: hosts, port: port, cancelled: cancelled, progress: progress) { found in
                cont.resume(returning: found)
            }
            job.start()
        }
    }
}

/// Пул одновременных проб. Всё состояние изменяется только на `queue`.
private final class ScanJob {
    private let queue = DispatchQueue(label: "mynotes.sync.scan")
    private var pending: [String]
    private let total: Int
    private let port: UInt16
    private let cancelled: CancelFlag
    private let progress: (Double) -> Void
    private var completion: (([FoundDevice]) -> Void)?

    private var active = 0
    private var finished = 0
    private var found: [FoundDevice] = []
    private var selfReference: ScanJob?

    private static let maxParallel = 96

    init(hosts: [String], port: UInt16, cancelled: CancelFlag,
         progress: @escaping (Double) -> Void, completion: @escaping ([FoundDevice]) -> Void) {
        self.pending = hosts
        self.total = hosts.count
        self.port = port
        self.cancelled = cancelled
        self.progress = progress
        self.completion = completion
    }

    func start() {
        selfReference = self
        queue.async { self.pump() }
    }

    private func pump() {
        if cancelled.isSet { pending.removeAll() }

        while active < ScanJob.maxParallel, let ip = pending.popLast() {
            active += 1
            let probe = Probe(ip: ip, port: port, queue: queue)
            probe.start { [self] device in
                active -= 1
                finished += 1
                if let device { found.append(device) }
                if finished % 16 == 0 || finished == total { progress(Double(finished) / Double(total)) }
                pump()
            }
        }

        if active == 0 && pending.isEmpty, let done = completion {
            completion = nil
            selfReference = nil
            // Одно и то же устройство может отвечать с нескольких адресов.
            var unique: [String: FoundDevice] = [:]
            for device in found where unique[device.id] == nil { unique[device.id] = device }
            done(unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }
}

/// Одна проба: подключиться и спросить «ты MyNotes?».
private final class Probe {
    private let ip: String
    private let port: UInt16
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var framed: FramedConnection?
    private var completion: ((FoundDevice?) -> Void)?

    init(ip: String, port: UInt16, queue: DispatchQueue) {
        self.ip = ip
        self.port = port
        self.queue = queue
    }

    func start(completion: @escaping (FoundDevice?) -> Void) {
        self.completion = completion
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            finish(nil)
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
        connection = conn
        framed = FramedConnection(conn, queue: queue)

        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: sendHello()
            case .failed, .waiting, .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1.0) { [self] in finish(nil) }
    }

    private func sendHello() {
        guard let framed else { return }
        let hello = HelloMessage(
            app: SyncConst.app, proto: SyncConst.proto,
            deviceName: SyncIdentity.deviceName, deviceID: SyncIdentity.deviceID
        )
        framed.send(.hello, (try? JSONEncoder().encode(hello)) ?? Data()) { [self] error in
            if error != nil { finish(nil) }
        }
        framed.receiveFrame(maxLength: 4096) { [self] result in
            guard case .success((let type, let body)) = result, type == .hello,
                  let info = try? JSONDecoder().decode(HelloMessage.self, from: body),
                  info.app == SyncConst.app, info.proto == SyncConst.proto,
                  info.deviceID != SyncIdentity.deviceID else {
                finish(nil)
                return
            }
            finish(FoundDevice(ip: ip, name: SyncIdentity.sanitize(info.deviceName), id: info.deviceID))
        }
    }

    private func finish(_ device: FoundDevice?) {
        guard let done = completion else { return }
        completion = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        framed = nil
        done(device)
    }
}

// MARK: - Сторона, запрашивающая синхронизацию

final class SyncClient {
    static let shared = SyncClient()

    private(set) var isRunning = false
    private var cancelFlag = CancelFlag()
    private var currentConnection: FramedConnection?

    private struct Outcome {
        var title: String
        var message: String
    }

    /// Главный поток. Показывает окно прогресса, ищет устройства, отправляет запросы
    /// и применяет полученные изменения. Не блокирует главный поток.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Новый флаг на каждый запуск: иначе после «Отмена» повторная синхронизация сразу бы прерывалась.
        let flag = CancelFlag()
        cancelFlag = flag
        currentConnection = nil

        let modal = ProgressModal(
            title: "Синхронизация из локальной сети",
            message: "Поиск устройств в локальной сети…"
        )
        modal.onCancel = { [weak self] in
            flag.set()
            self?.currentConnection?.cancelByUser()
        }

        var outcome: Outcome?
        modal.onClosed = { [weak self] in
            self?.isRunning = false
            self?.currentConnection = nil
            if let outcome { Dialogs.info(title: outcome.title, message: outcome.message) }
        }

        modal.show()
        Task { @MainActor in
            outcome = await self.run(modal: modal)
            modal.dismiss()
        }
    }

    @MainActor
    private func run(modal: ProgressModal) async -> Outcome? {
        let port = UInt16(SyncService.shared.port)
        let flag = cancelFlag

        modal.update(message: "Поиск устройств в локальной сети (порт \(port))…", fraction: 0)
        let devices = await LANScanner.scan(port: port, cancelled: flag) { fraction in
            DispatchQueue.main.async { modal.update(fraction: fraction) }
        }
        if flag.isSet { return nil }

        guard !devices.isEmpty else {
            return Outcome(
                title: "Устройства не найдены",
                message: "В локальной сети не найдено ни одной копии MyNotes, слушающей порт \(port).\n\n"
                    + "Проверьте, что приложение запущено на другом устройстве, а порт в настройках одинаковый на обоих."
            )
        }

        var lines: [String] = []
        for device in devices {
            if flag.isSet { break }
            modal.update(
                message: "Запрос отправлен на устройство\n«\(device.name)»\nОжидание подтверждения на этом устройстве…",
                fraction: nil
            )
            do {
                let text = try await sync(with: device, port: port, modal: modal)
                lines.append("«\(device.name)»:\n\(text)")
            } catch {
                if error.isUserCancel { break }
                lines.append("«\(device.name)»: \(error.localizedDescription)")
            }
        }
        if lines.isEmpty { return nil }
        return Outcome(title: "Синхронизация", message: lines.joined(separator: "\n\n"))
    }

    @MainActor
    private func sync(with device: FoundDevice, port: UInt16, modal: ProgressModal) async throws -> String {
        let framed = try await FramedConnection.connect(host: device.ip, port: port, timeout: 5)
        currentConnection = framed
        defer {
            framed.close()
            currentConnection = nil
        }

        // 1. Запрос с именем нашего компьютера.
        let request = RequestMessage(
            app: SyncConst.app, proto: SyncConst.proto,
            deviceName: SyncIdentity.deviceName, deviceID: SyncIdentity.deviceID
        )
        try await framed.sendJSONAsync(.request, request)

        // 2. Ждём решения пользователя на другом устройстве (до 2 минут).
        framed.armTimeout(120)
        let (type, body) = try await framed.receiveAsync(maxLength: SyncConst.maxControlFrame)
        framed.disarmTimeout()
        if type == .error {
            throw SyncError.remote((try? JSONDecoder().decode(ErrorMessage.self, from: body))?.message ?? "неизвестная ошибка")
        }
        guard type == .reply, let reply = try? JSONDecoder().decode(ReplyMessage.self, from: body) else {
            throw SyncError.protocolViolation
        }
        switch reply.status {
        case "accepted": break
        case "denied": throw SyncError.denied
        case "busy": throw SyncError.busy
        default: throw SyncError.protocolViolation
        }

        // 3. Проверяем заголовок пакета.
        guard reply.totalBytes > 0, reply.totalBytes <= SyncConst.maxPackageBytes else { throw SyncError.tooLarge }
        guard (4096...(1 << 20)).contains(reply.chunkSize) else { throw SyncError.protocolViolation }

        let localPassphrase = SyncSecrets.passphrase
        guard reply.encrypted == !localPassphrase.isEmpty else { throw SyncError.passphraseMismatch }
        var key: SymmetricKey?
        if reply.encrypted {
            guard let salt = Data(base64Encoded: reply.salt), salt.count == 16 else { throw SyncError.protocolViolation }
            modal.update(message: "Проверка пароля синхронизации…", fraction: nil)
            let derived = SyncCrypto.deriveKey(passphrase: localPassphrase, salt: salt)
            guard SyncCrypto.verifyCheck(reply.check, key: derived) else { throw SyncError.wrongPassphrase }
            key = derived
        }

        // 4. Получаем пакет по кускам, считаем контрольную сумму, показываем проценты.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotes-recv-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let file = try FileHandle(forWritingTo: tempURL)

        let total = reply.totalBytes
        let chunkSize = Int64(reply.chunkSize)
        let chunkCount = UInt32((total + chunkSize - 1) / chunkSize)
        var hasher = SHA256()
        var received: Int64 = 0
        var index: UInt32 = 0
        var lastPercent = -1

        modal.update(message: "Получение проектов от «\(device.name)»", fraction: 0)

        do {
            while received < total {
                framed.armTimeout(30)
                let (frameType, frame) = try await framed.receiveAsync(maxLength: reply.chunkSize + 256)
                if frameType == .error {
                    throw SyncError.remote((try? JSONDecoder().decode(ErrorMessage.self, from: frame))?.message ?? "неизвестная ошибка")
                }
                guard frameType == .chunk, frame.count > 4, readBigEndian(frame) == index, index < chunkCount else {
                    throw SyncError.protocolViolation
                }
                var payload = Data(frame.dropFirst(4))
                if let key {
                    payload = try SyncCrypto.open(payload, key: key, aad: SyncCrypto.chunkAAD(index: index, total: chunkCount))
                }
                guard received + Int64(payload.count) <= total else { throw SyncError.protocolViolation }

                try file.write(contentsOf: payload)
                hasher.update(data: payload)
                received += Int64(payload.count)
                index += 1

                let fraction = Double(received) / Double(total)
                let percent = Int(fraction * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    modal.update(fraction: fraction)
                }
            }
            framed.disarmTimeout()
            try file.close()

            guard SyncCrypto.hex(hasher.finalize()) == reply.sha256 else { throw SyncError.integrity }
        } catch {
            // Сообщаем отправителю, почему приём не удался.
            try? file.close()
            try? await framed.sendJSONAsync(.error, ErrorMessage(message: error.localizedDescription))
            throw error
        }

        // 5. Применяем изменения (слияние одной транзакцией) и подтверждаем отправителю.
        modal.update(message: "Применение изменений…", fraction: 1)
        let merged = try Store.shared.applySyncPackage(at: tempURL)
        try? await framed.sendAsync(.ack)
        return merged.report.summary
    }
}
