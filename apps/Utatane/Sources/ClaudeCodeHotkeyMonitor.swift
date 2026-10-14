import AppKit
import Foundation

/// Hold-to-talk hotkey for Claude Code: `onPress` when the key goes down, `onRelease` when it comes up.
///
/// Modifier-only presets (right Option, fn) fire only after a short hold, and a hold is abandoned
/// when another key is typed meanwhile, so the key keeps working as an ordinary modifier.
/// Watching keys while another app is active requires the Accessibility permission.
@MainActor
final class ClaudeCodeHotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private static let spaceKeyCode: UInt16 = 49
    private static let rightOptionKeyCode: UInt16 = 61
    private static let fnKeyCode: UInt16 = 63
    /// `NX_DEVICERALTKEYMASK`: set only while the right Option key is down.
    private static let rightOptionDeviceFlag: UInt = 0x40
    private static let longPressDelay: Duration = .milliseconds(350)

    private let hotkey: ClaudeCodeHotkey
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// The physical key is down.
    private var isKeyDown = false
    /// `onPress` was delivered, so the matching `onRelease` is owed.
    private var isActive = false
    private var longPressTask: Task<Void, Never>?

    init(hotkey: ClaudeCodeHotkey) {
        self.hotkey = hotkey
    }

    /// Whether key events from other apps can be observed.
    static var canObserveOtherApps: Bool {
        AXIsProcessTrusted()
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let snapshot = KeySnapshot(event)
            MainActor.assumeIsolated { _ = self?.handle(snapshot) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let snapshot = KeySnapshot(event)
            let consumed = MainActor.assumeIsolated { self?.handle(snapshot) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        longPressTask?.cancel()
        longPressTask = nil
        isKeyDown = false
        if isActive {
            isActive = false
            onRelease?()
        }
    }

    /// Forgets a held key without calling `onRelease`, e.g. when a hold was ended because its key-up never came.
    func resetHold() {
        longPressTask?.cancel()
        longPressTask = nil
        isKeyDown = false
        isActive = false
    }

    /// Returns whether the event belongs to the hotkey and should not reach this app's views.
    private func handle(_ key: KeySnapshot) -> Bool {
        switch hotkey {
        case .controlOptionSpace:
            guard key.keyCode == Self.spaceKeyCode else { return false }
            if key.type == .keyDown {
                if isKeyDown { return true }
                let flags = key.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains([.control, .option]), !flags.contains(.command), !key.isRepeat else { return false }
                isKeyDown = true
                isActive = true
                onPress?()
                return true
            }
            if key.type == .keyUp, isKeyDown {
                keyWentUp()
                return true
            }
            return false
        case .rightOption:
            return handleModifierOnly(key, keyCode: Self.rightOptionKeyCode) {
                $0.modifierFlags.rawValue & Self.rightOptionDeviceFlag != 0
            }
        case .fn:
            return handleModifierOnly(key, keyCode: Self.fnKeyCode) {
                $0.modifierFlags.contains(.function)
            }
        }
    }

    private func handleModifierOnly(_ key: KeySnapshot, keyCode: UInt16, isDown: (KeySnapshot) -> Bool) -> Bool {
        switch key.type {
        case .flagsChanged where key.keyCode == keyCode:
            let down = isDown(key)
            if down, !isKeyDown {
                isKeyDown = true
                beginLongPress()
            } else if !down, isKeyDown {
                keyWentUp()
            }
        case .keyDown where isKeyDown && !isActive:
            // The key is being used as a modifier for typing, not held to talk.
            longPressTask?.cancel()
            longPressTask = nil
        default:
            break
        }
        return false
    }

    private func beginLongPress() {
        longPressTask?.cancel()
        longPressTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.longPressDelay)) != nil else { return }
            guard let self, self.isKeyDown, !self.isActive else { return }
            self.longPressTask = nil
            self.isActive = true
            self.onPress?()
        }
    }

    private func keyWentUp() {
        isKeyDown = false
        longPressTask?.cancel()
        longPressTask = nil
        guard isActive else { return }
        isActive = false
        onRelease?()
    }
}

/// The parts of an `NSEvent` the monitor needs, read before leaving the handler.
private struct KeySnapshot {
    let type: NSEvent.EventType
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let isRepeat: Bool

    init(_ event: NSEvent) {
        type = event.type
        keyCode = event.keyCode
        modifierFlags = event.modifierFlags
        // `isARepeat` raises for anything but key-down/up events.
        isRepeat = event.type == .keyDown || event.type == .keyUp ? event.isARepeat : false
    }
}
