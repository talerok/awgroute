import AppKit
import SwiftUI
import Combine
import AwgDomain

/// Иконка в menu bar с цветовой индикацией и быстрым меню.
@MainActor
public final class MenuBarController: ObservableObject {
    public init() {}

    private var statusItem: NSStatusItem?
    private weak var tunnel: TunnelStore?
    private weak var profiles: ProfileStore?
    private var cancellables: Set<AnyCancellable> = []

    public func install(tunnel: TunnelStore, profiles: ProfileStore) {
        // Защита от повторной установки: WindowGroup.onAppear может выстрелить
        // несколько раз (например, при переключении Spaces или sleep/wake).
        // Без этого получится несколько NSStatusItem'ов (дублирующиеся иконки)
        // и накопление подписок Combine.
        if statusItem != nil {
            self.tunnel = tunnel
            self.profiles = profiles
            updateIcon()
            rebuildMenu()
            return
        }
        self.tunnel = tunnel
        self.profiles = profiles
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        rebuildMenu()
        updateIcon()

        tunnel.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.rebuildMenu() }
            .store(in: &cancellables)
        profiles.$activeID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let item = statusItem, let tunnel else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let symbolName = "circle.fill"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AwgRoute status")?
            .withSymbolConfiguration(cfg)
        image?.isTemplate = false
        let tinted = image?.tinted(with: color(for: tunnel.status))
        item.button?.image = tinted
        item.button?.toolTip = "AwgRoute — \(tunnel.status.label)"
    }

    private func color(for status: TunnelStatus) -> NSColor {
        switch status {
        case .stopped:           return .systemGray
        case .starting, .stopping: return .systemYellow
        case .running:             return .systemGreen
        case .failed:              return .systemRed
        }
    }

    private func rebuildMenu() {
        guard let item = statusItem, let tunnel else { return }
        let menu = NSMenu()
        menu.addItem(.disabled("AwgRoute — \(tunnel.status.label)"))
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
        guard let tunnel else { return "Connect" }
        switch tunnel.status {
        case .running:   return "Disconnect"
        case .starting:  return "Connecting…"
        case .stopping:  return "Stopping…"
        default:         return "Connect"
        }
    }
    private func canToggle() -> Bool {
        guard let tunnel, tunnel.backendAvailable, !tunnel.status.isTransitioning else { return false }
        return profiles?.activeProfile != nil
    }

    @objc private func toggleConnect() {
        guard let tunnel, let profiles else { return }
        Task {
            if tunnel.status.isRunning { await tunnel.disconnect() }
            else { await tunnel.connect(profile: profiles.activeProfile) }
        }
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Сначала пробуем поднять существующее окно — фильтруем служебные NSStatusBar/NSPanel.
        for w in NSApp.windows where w.canBecomeKey && w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        // Все окна закрыты (LSUIElement=false + пользователь нажал ⌘W).
        // Re-open через NSWorkspace — macOS обнаружит уже работающий процесс,
        // вызовет applicationShouldHandleReopen и SwiftUI пересоздаст WindowGroup.
        NSWorkspace.shared.open(Bundle.main.bundleURL)
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
    public func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}
