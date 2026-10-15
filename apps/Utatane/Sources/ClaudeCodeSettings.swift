import Foundation
import SwiftUI
import UtataneClaudeCode

enum ClaudeCodeHotkey: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case rightOption
    case fn

    var id: String {
        rawValue
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .controlOptionSpace: "Control + Option + Space"
        case .rightOption: "右Option（長押し）"
        case .fn: "fn（長押し）"
        }
    }
}

@MainActor
final class ClaudeCodeSettings: ObservableObject {
    private let storage: ClaudeCodeSettingsStorage

    @Published var voiceInputEnabled: Bool {
        didSet { storage.voiceInputEnabled = voiceInputEnabled }
    }

    @Published var readbackEnabled: Bool {
        didSet { storage.readbackEnabled = readbackEnabled }
    }

    @Published var executablePath: String {
        didSet { storage.executablePath = executablePath }
    }

    @Published var workingDirectory: String {
        didSet { storage.workingDirectory = workingDirectory }
    }

    @Published var model: String {
        didSet { storage.model = model }
    }

    @Published var permissionMode: ClaudeCodePermissionMode {
        didSet { storage.permissionMode = permissionMode }
    }

    @Published var hotkey: ClaudeCodeHotkey {
        didSet { storage.hotkey = hotkey.rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        let storage = ClaudeCodeSettingsStorage(defaults: defaults)
        self.storage = storage
        voiceInputEnabled = storage.voiceInputEnabled
        readbackEnabled = storage.readbackEnabled
        executablePath = storage.executablePath
        workingDirectory = storage.workingDirectory
        model = storage.model
        permissionMode = storage.permissionMode
        hotkey = ClaudeCodeHotkey(rawValue: storage.hotkey) ?? .controlOptionSpace
    }

    /// The last Claude Code session id used in `workingDirectory`; not published, it is not a user setting.
    func sessionID(forWorkingDirectory workingDirectory: String) -> String? {
        storage.sessionID(forWorkingDirectory: workingDirectory)
    }

    func setSessionID(_ sessionID: String?, forWorkingDirectory workingDirectory: String) {
        storage.setSessionID(sessionID, forWorkingDirectory: workingDirectory)
    }
}
