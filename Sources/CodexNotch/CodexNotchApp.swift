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
    private var smokeStage = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        if smokeTerminal == nil {
            model.shutdown()
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
