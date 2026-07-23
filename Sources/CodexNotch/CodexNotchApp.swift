import AppKit
import SwiftUI

@main
struct CodexNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var panelController: NotchPanelController?
    private var smokeTerminal: TerminalSession?
    private var smokeServer: CodexServer?
    private var smokeStage = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--model-catalog-smoke-test") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            runModelCatalogSmokeTest()
            return
        }

        if CommandLine.arguments.contains("--pty-smoke-test") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            runPTYSmokeTest()
            return
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        panelController = NotchPanelController(model: model)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeTerminal?.stop()
        smokeServer?.stop()
        if smokeTerminal == nil, smokeServer == nil {
            model.shutdown()
        }
    }

    private func runModelCatalogSmokeTest() {
        let server = CodexServer()
        smokeServer = server
        server.onTermination = { reason in
            print("TERMINATED:\(reason)")
            NSApplication.shared.terminate(nil)
        }

        do {
            try server.start()
            server.request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_notch_smoke_test",
                        "title": "Codex Notch Smoke Test",
                        "version": "0.1.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ]
            ) { result in
                guard case .success = result else {
                    print("INITIALIZE_ERROR")
                    NSApplication.shared.terminate(nil)
                    return
                }
                server.notify(method: "initialized")
                server.request(
                    method: "model/list",
                    params: ["includeHidden": false, "limit": 100]
                ) { result in
                    guard case .success(let payload) = result,
                          let models = payload["data"] as? [[String: Any]] else {
                        print("MODEL_LIST_ERROR")
                        NSApplication.shared.terminate(nil)
                        return
                    }
                    print("MODEL_COUNT:\(models.count)")
                    for model in models {
                        let name = model["displayName"] as? String ?? "unknown"
                        let efforts = (model["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                            .compactMap { $0["reasoningEffort"] as? String }
                            .joined(separator: ",")
                        print("MODEL:\(name)|EFFORTS:\(efforts)")
                    }
                    NSApplication.shared.terminate(nil)
                }
            }
        } catch {
            print("START_ERROR:\(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
        }
    }

    private func runPTYSmokeTest() {
        let terminal = TerminalSession()
        smokeTerminal = terminal
        terminal.onOutput = { line in print("OUTPUT:\(line)") }
        terminal.onTermination = { reason in
            print("TERMINATED:\(reason)")
            NSApplication.shared.terminate(nil)
        }
        terminal.onCommandFinished = { [weak self, weak terminal] status in
            guard let self, let terminal else { return }
            if self.smokeStage == 0 {
                self.smokeStage = 1
                print("PERSISTENCE_STATUS:\(status)")
                terminal.run("read -r answer; printf 'INPUT:%s\\n' \"$answer\"")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    terminal.sendInput("hello-from-pty\n")
                }
            } else if self.smokeStage == 1 {
                print("INTERACTIVE_STATUS:\(status)")
                self.smokeStage = 2
                terminal.run("sleep 5")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    terminal.interrupt()
                }
            } else {
                print("INTERRUPT_STATUS:\(status)")
                NSApplication.shared.terminate(nil)
            }
        }

        do {
            try terminal.start()
            terminal.run("cd /private/tmp && printf 'PWD:%s\\n' \"$PWD\"")
        } catch {
            print("START_ERROR:\(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
        }
    }
}
