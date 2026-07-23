import AppKit

@MainActor
final class NotchFleetController {
    static let maximumNotches = 6

    private var models: [AppModel] = []
    private var panels: [NotchPanelController] = []
    private var anchorFraction = UserDefaults.standard.object(forKey: "CodexNotch.horizontalAnchor") as? Double ?? 0.5

    func start() {
        guard models.isEmpty else { return }
        addNotch(animated: false)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
    }

    func shutdown() {
        models.forEach { $0.shutdown() }
    }

    private func addNotch(animated: Bool = true) {
        guard models.count < Self.maximumNotches else { return }

        let model = AppModel(slot: models.count)
        model.onAddNotch = { [weak self] in
            self?.addNotch()
        }
        model.onCloseNotch = { [weak self, weak model] in
            guard let model else { return }
            self?.removeNotch(model)
        }
        let panel = NotchPanelController(model: model)
        panel.onCompactDrag = { [weak self] delta in
            self?.moveFleet(by: delta)
        }
        models.append(model)
        panels.append(panel)
        updateFleetState()
        layout(animated: animated)
        model.start()
    }

    private func updateFleetState() {
        let canAdd = models.count < Self.maximumNotches
        let canClose = models.count > 1
        for model in models {
            model.canAddNotch = canAdd
            model.canCloseNotch = canClose
            model.notchCount = models.count
        }
    }

    private func removeNotch(_ model: AppModel) {
        guard models.count > 1,
              let index = models.firstIndex(where: { $0 === model }) else { return }

        model.onAddNotch = nil
        model.onCloseNotch = nil
        model.shutdown()
        panels[index].closePanel()
        models.remove(at: index)
        panels.remove(at: index)
        updateFleetState()
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, !panels.isEmpty else { return }

        let count = CGFloat(panels.count)
        let collapsedWidth: CGFloat = 260
        let idealSpacing: CGFloat = 268
        let availableWidth = max(collapsedWidth, screen.visibleFrame.width - 24)
        let spacing: CGFloat
        if panels.count == 1 {
            spacing = 0
        } else {
            let fittingSpacing = (availableWidth - collapsedWidth) / (count - 1)
            spacing = min(idealSpacing, max(190, fittingSpacing))
        }

        let fleetWidth = collapsedWidth + spacing * (count - 1)
        let margin: CGFloat = 8
        let minimumCenter = screen.frame.minX + fleetWidth / 2 + margin
        let maximumCenter = screen.frame.maxX - fleetWidth / 2 - margin
        let desiredCenter = screen.frame.minX + screen.frame.width * anchorFraction
        let fleetCenter = min(max(desiredCenter, minimumCenter), maximumCenter)
        let firstCenter = fleetCenter - fleetWidth / 2 + collapsedWidth / 2

        for (index, panel) in panels.enumerated() {
            panel.setHorizontalCenter(firstCenter + CGFloat(index) * spacing, animated: animated)
        }
    }

    private func moveFleet(by delta: CGFloat) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, screen.frame.width > 0 else { return }
        anchorFraction = min(1, max(0, anchorFraction + Double(delta / screen.frame.width)))
        UserDefaults.standard.set(anchorFraction, forKey: "CodexNotch.horizontalAnchor")
        layout(animated: false)
    }
}
