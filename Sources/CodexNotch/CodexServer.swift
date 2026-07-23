import Foundation

final class CodexServer {
    enum ServerError: LocalizedError {
        case executableMissing
        case notRunning
        case invalidResponse
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .executableMissing: return "The Codex CLI could not be found."
            case .notRunning: return "The Codex service is not running."
            case .invalidResponse: return "Codex returned an invalid response."
            case .rpc(let message): return message
            }
        }
    }

    var onEvent: (([String: Any]) -> Void)?
    var onTermination: ((String) -> Void)?

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let queue = DispatchQueue(label: "com.carsk8.codex-notch.protocol")
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var nextID = 1
    private var callbacks: [String: (Result<[String: Any], Error>) -> Void] = [:]

    func start() throws {
        guard let executable = Self.codexExecutable() else { throw ServerError.executableMissing }
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeOutput(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.errorBuffer.append(data) }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.outputPipe.fileHandleForReading.readabilityHandler = nil
            self.errorPipe.fileHandleForReading.readabilityHandler = nil
            let details = self.queue.sync { String(data: self.errorBuffer, encoding: .utf8) ?? "" }
            DispatchQueue.main.async {
                let suffix = details.trimmingCharacters(in: .whitespacesAndNewlines)
                self.onTermination?(suffix.isEmpty ? "Codex stopped with code \(process.terminationStatus)." : suffix)
            }
        }
        try process.run()
    }

    func stop() {
        guard process.isRunning else { return }
        inputPipe.fileHandleForWriting.closeFile()
        process.terminate()
    }

    func notify(method: String, params: [String: Any] = [:]) {
        send(["method": method, "params": params])
    }

    @discardableResult
    func request(
        method: String,
        params: [String: Any],
        completion: ((Result<[String: Any], Error>) -> Void)? = nil
    ) -> Int {
        queue.sync {
            let id = nextID
            nextID += 1
            if let completion { callbacks[String(id)] = completion }
            sendLocked(["id": id, "method": method, "params": params])
            return id
        }
    }

    func respond(id: Any, result: [String: Any]) {
        send(["id": id, "result": result])
    }

    private func send(_ object: [String: Any]) {
        queue.async { [weak self] in self?.sendLocked(object) }
    }

    private func sendLocked(_ object: [String: Any]) {
        guard process.isRunning,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onTermination?(error.localizedDescription) }
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line),
                  let message = json as? [String: Any] else { continue }
            route(message)
        }
    }

    private func route(_ message: [String: Any]) {
        // JSON-RPC request IDs are scoped to their sender. A server-initiated
        // question can legally reuse one of our numeric IDs, so method-bearing
        // messages must be routed as requests/notifications before responses.
        if message["method"] != nil {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(message) }
            return
        }
        if let id = message["id"] {
            let key = String(describing: id)
            if let callback = callbacks.removeValue(forKey: key) {
                let result: Result<[String: Any], Error>
                if let error = message["error"] as? [String: Any] {
                    result = .failure(ServerError.rpc(error["message"] as? String ?? "Unknown Codex error"))
                } else if let payload = message["result"] as? [String: Any] {
                    result = .success(payload)
                } else {
                    result = .failure(ServerError.invalidResponse)
                }
                DispatchQueue.main.async { callback(result) }
                return
            }
        }
    }

    private static func codexExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
}
