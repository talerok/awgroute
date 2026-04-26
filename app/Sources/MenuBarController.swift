import AppKit
import SwiftUI
import Combine

/// Иконка в menu bar с цветовой индикацией и быстрым меню.
@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private weak var backend: BackendController?
    private weak var profiles: ProfileStore?
    private weak var rules: RulesStore?
    private var cancellables: Set<AnyCancellable> = []

    func install(backend: BackendController, profiles: ProfileStore, rules: RulesStore) {
        self.backend = backend
        self.profiles = profiles
        self.rules = rules
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        rebuildMenu()
        updateIcon()

        backend.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.rebuildMenu() }
            .store(in: &cancellables)
        profiles.$activeID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let item = statusItem, let backend else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let symbolName = "circle.fill"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AwgRoute status")?
            .withSymbolConfiguration(cfg)
        image?.isTemplate = false
        let tinted = image?.tinted(with: color(for: backend.status))
        item.button?.image = tinted
        item.button?.toolTip = "AwgRoute — \(backend.status.label)"
    }

    private func color(for status: BackendController.Status) -> NSColor {
        switch status {
        case .stopped:           return .systemGray
        case .starting, .stopping: return .systemYellow
        case .running:           return .systemGreen
        case .error:             return .systemRed
        }
    }

    private func rebuildMenu() {
        guard let item = statusItem, let backend else { return }
        let menu = NSMenu()
        menu.addItem(.disabled("AwgRoute — \(backend.status.label)"))
        if let active = profiles?.activeProfile {
            menu.addItem(.disabled("Profile: \(active.name)"))
        } else {
            menu.addItem(.disabled("No active profile"))
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: toggleTitle(),
                                action: #selector(toggleConnect),
                                keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = canToggle()
        menu.addItem(toggle)

        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)

        let quit = NSMenuItem(title: "Quit AwgRoute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
    }

    private func toggleTitle() -> String {
        guard let backend else { return "Connect" }
        switch backend.status {
        case .running:   return "Disconnect"
        case .starting:  return "Connecting…"
        case .stopping:  return "Stopping…"
        default:         return "Connect"
        }
    }
    private func canToggle() -> Bool {
        guard let backend else { return false }
        if !backend.binaryFound { return false }
        switch backend.status {
        case .stopped, .error, .running: return profiles?.activeProfile != nil
        case .starting, .stopping: return false
        }
    }

    @objc private func toggleConnect() {
        guard let backend, let profiles, let rules else { return }
        let coord = ConnectionCoordinator(profiles: profiles, backend: backend, rules: rules)
        Task {
            switch backend.status {
            case .running: await coord.disconnect()
            default:       await coord.connect()
            }
        }
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Поднять первое окно приложения
        for w in NSApp.windows where w.title.contains("AwgRoute") || w.contentViewController != nil {
            w.makeKeyAndOrderFront(nil)
            return
        }
    }
}

private extension NSMenuItem {
    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

private extension NSImage {
    /// Перекрасить SF-symbol в нужный цвет.
    func tinted(with color: NSColor) -> NSImage {
        guard let copy = self.copy() as? NSImage else { return self }
        copy.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: copy.size)
        rect.fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
