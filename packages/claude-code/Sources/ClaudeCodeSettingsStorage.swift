import Foundation

/// Reads and writes the Claude Code settings in `UserDefaults`.
/// Every key is prefixed with `claudeCode.`.
public struct ClaudeCodeSettingsStorage {
    public static let defaultHotkey = "controlOptionSpace"

    private enum Key {
        static let voiceInputEnabled = "claudeCode.voiceInputEnabled"
        static let readbackEnabled = "claudeCode.readbackEnabled"
        static let executablePath = "claudeCode.executablePath"
        static let workingDirectory = "claudeCode.workingDirectory"
        static let model = "claudeCode.model"
        static let permissionMode = "claudeCode.permissionMode"
        static let hotkey = "claudeCode.hotkey"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var voiceInputEnabled: Bool {
        get { defaults.object(forKey: Key.voiceInputEnabled) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.voiceInputEnabled) }
    }

    public var readbackEnabled: Bool {
        get { defaults.object(forKey: Key.readbackEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.readbackEnabled) }
    }

    public var executablePath: String {
        get { defaults.string(forKey: Key.executablePath) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.executablePath) }
    }

    public var workingDirectory: String {
        get { defaults.string(forKey: Key.workingDirectory) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.workingDirectory) }
    }

    public var model: String {
        get { defaults.string(forKey: Key.model) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.model) }
    }

    public var permissionMode: ClaudeCodePermissionMode {
        get {
            defaults.string(forKey: Key.permissionMode).flatMap(ClaudeCodePermissionMode.init(rawValue:)) ?? .default
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.permissionMode) }
    }

    /// Raw value of the app-side hotkey enum.
    public var hotkey: String {
        get { defaults.string(forKey: Key.hotkey) ?? Self.defaultHotkey }
        nonmutating set { defaults.set(newValue, forKey: Key.hotkey) }
    }
}
