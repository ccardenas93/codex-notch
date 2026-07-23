import Darwin
import Foundation
import PTYShim

final class TerminalSession {
    var onOutput: ((String) -> Void)?
    var onCommandStarted: ((String) -> Void)?
    var onCommandFinished: ((Int32) -> Void)?
    var onDirectoryChanged: ((String) -> Void)?
    var onTermination: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.carsk8.codex-notch.terminal")
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var buffer = ""
    private var currentCommand: String?
    private let promptPrefix = "__CODEX_NOTCH_PROMPT_"
    private let promptSuffix = "__"
    private var waitingForStartup = true
    private var stopping = false

    func start() throws {
        var fd: Int32 = -1
        var pid: pid_t = -1
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = "/bin/zsh".withCString { shell in
            home.withCString { directory in
                codex_notch_spawn_pty(shell, directory, &fd, &pid)
            }
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        masterFD = fd
        childPID = pid
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var size = winsize(ws_row: 32, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &size)

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.drainOutput() }
        reader.setCancelHandler { close(fd) }
        readSource = reader
        reader.resume()

        let watcher = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: queue
        )
        watcher.setEventHandler { [weak self] in self?.childExited() }
        processSource = watcher
        watcher.resume()

        // Keep the PTY output clean while retaining a real interactive shell.
        sendInput(
            "stty -echo; unsetopt ZLE PROMPT_SP 2>/dev/null; " +
            "PROMPT=$'\\n\(promptPrefix)%?|%/\(promptSuffix)\\n'; RPROMPT=''\n"
        )
    }

    func run(_ command: String) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0, self.currentCommand == nil else { return }
            self.currentCommand = command
            DispatchQueue.main.async { self.onCommandStarted?(command) }
            self.write(command + "\n")
        }
    }

    func sendInput(_ input: String) {
        queue.async { [weak self] in self?.write(input) }
    }

    func interrupt() {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var interruptByte: UInt8 = 3
            _ = Darwin.write(self.masterFD, &interruptByte, 1)
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.masterFD, TIOCSWINSZ, &size)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.stopping = true
            if self.childPID > 0 {
                _ = Darwin.kill(self.childPID, SIGHUP)
            }
            self.finishSources()
        }
    }

    private func write(_ text: String) {
        guard masterFD >= 0, let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(masterFD, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func drainOutput() {
        guard masterFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = Darwin.read(masterFD, &bytes, bytes.count)
            if count > 0 {
                consume(Data(bytes[0..<count]))
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else if errno != EINTR {
                break
            }
        }
    }

    private func childExited() {
        var rawStatus: Int32 = 0
        _ = waitpid(childPID, &rawStatus, 0)
        let exitCode: Int32
        if rawStatus & 0x7f == 0 {
            exitCode = (rawStatus >> 8) & 0xff
        } else {
            exitCode = 128 + (rawStatus & 0x7f)
        }

        finishSources()
        guard !stopping else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onTermination?("Shell exited with code \(exitCode)")
        }
    }

    private func finishSources() {
        readSource?.cancel()
        readSource = nil
        processSource?.cancel()
        processSource = nil
        masterFD = -1
        childPID = -1
    }

    private func consume(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        buffer += stripANSI(text)

        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prompt = parsePrompt(trimmed) {
                DispatchQueue.main.async { [weak self] in
                    self?.onDirectoryChanged?(prompt.directory)
                }
                if waitingForStartup {
                    waitingForStartup = false
                } else if currentCommand != nil {
                    currentCommand = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onCommandFinished?(prompt.status)
                    }
                }
                continue
            }

            if waitingForStartup {
                continue
            }

            if trimmed == currentCommand {
                continue
            } else {
                emit(line)
            }
        }
    }

    private func emit(_ text: String) {
        let cleaned = text
            .replacingOccurrences(of: "\u{0007}", with: "")
            .trimmingCharacters(in: .controlCharacters)
        guard !cleaned.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onOutput?(cleaned) }
    }

    private func parsePrompt(_ line: String) -> (status: Int32, directory: String)? {
        guard line.hasPrefix(promptPrefix), line.hasSuffix(promptSuffix) else { return nil }
        let start = line.index(line.startIndex, offsetBy: promptPrefix.count)
        let end = line.index(line.endIndex, offsetBy: -promptSuffix.count)
        guard start <= end else { return nil }
        let payload = line[start..<end]
        guard let separator = payload.firstIndex(of: "|"),
              let status = Int32(payload[..<separator]) else { return nil }
        let directory = String(payload[payload.index(after: separator)...])
        return (status, directory)
    }

    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }
}
