import AppKit
import SwiftUI
import UtataneClaudeCode

struct ClaudeCodeSettingsView: View {
    @ObservedObject var settings: ClaudeCodeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code")
                    .font(.title2.weight(.semibold))
                Text("声でClaude Codeを操作するための設定。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Divider()

            Form {
                Section("音声操作") {
                    Toggle("音声入力を有効にする", isOn: $settings.voiceInputEnabled)
                    Text("オフの間は、マイクと音声認識の許可を要求せず、ホットキーも登録しない。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("復唱確認", isOn: $settings.readbackEnabled)
                    Picker("ホットキー", selection: $settings.hotkey) {
                        ForEach(ClaudeCodeHotkey.allCases) { hotkey in
                            Text(hotkey.displayName).tag(hotkey)
                        }
                    }
                }
                Section("実行") {
                    LabeledContent("claudeのパス") {
                        HStack {
                            if settings.executablePath.isEmpty {
                                Text("自動検出")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: settings.executablePath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Button("選択…") { chooseExecutable() }
                            Button("クリア") { settings.executablePath = "" }
                                .disabled(settings.executablePath.isEmpty)
                        }
                    }
                    LabeledContent("作業ディレクトリ") {
                        HStack {
                            if settings.workingDirectory.isEmpty {
                                Text("未選択")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: settings.workingDirectory)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Button("選択…") { chooseWorkingDirectory() }
                            Button("クリア") { settings.workingDirectory = "" }
                                .disabled(settings.workingDirectory.isEmpty)
                        }
                    }
                    TextField("モデル", text: $settings.model, prompt: Text("既定のモデル"))
                    Picker("権限モード", selection: $settings.permissionMode) {
                        Text("確認しながら").tag(ClaudeCodePermissionMode.default)
                        Text("編集を自動許可").tag(ClaudeCodePermissionMode.acceptEdits)
                    }
                    Text("「編集を自動許可」では、ファイルの編集を確認せずに許可します。どちらのモードでも、ユーザー設定（~/.claude/settings.json）の許可ルールやフックで許可された操作は、確認なしで実行されることがあります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.executablePath = url.path
        }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.workingDirectory = url.path
        }
    }
}
