import Foundation
import Testing
@testable import UtataneClaudeCode

private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "ClaudeCodeSettingsStorageTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
}

@Test func `defaults are voice off and readback on`() {
    withIsolatedDefaults { defaults in
        let storage = ClaudeCodeSettingsStorage(defaults: defaults)
        #expect(storage.voiceInputEnabled == false)
        #expect(storage.readbackEnabled == true)
        #expect(storage.executablePath == "")
        #expect(storage.workingDirectory == "")
        #expect(storage.model == "")
        #expect(storage.permissionMode == .default)
        #expect(storage.hotkey == "controlOptionSpace")
    }
}

@Test func `values written by one instance are read by another`() {
    withIsolatedDefaults { defaults in
        let writer = ClaudeCodeSettingsStorage(defaults: defaults)
        writer.voiceInputEnabled = true
        writer.readbackEnabled = false
        writer.executablePath = "/usr/local/bin/claude"
        writer.workingDirectory = "/tmp/work"
        writer.model = "opus"
        writer.permissionMode = .acceptEdits
        writer.hotkey = "rightOption"

        let reader = ClaudeCodeSettingsStorage(defaults: defaults)
        #expect(reader.voiceInputEnabled == true)
        #expect(reader.readbackEnabled == false)
        #expect(reader.executablePath == "/usr/local/bin/claude")
        #expect(reader.workingDirectory == "/tmp/work")
        #expect(reader.model == "opus")
        #expect(reader.permissionMode == .acceptEdits)
        #expect(reader.hotkey == "rightOption")
        #expect(defaults.string(forKey: "claudeCode.permissionMode") == "acceptEdits")
    }
}

@Test func `unknown stored permission mode falls back to default`() {
    withIsolatedDefaults { defaults in
        defaults.set("bypassEverything", forKey: "claudeCode.permissionMode")
        let storage = ClaudeCodeSettingsStorage(defaults: defaults)
        #expect(storage.permissionMode == .default)
    }
}
