# Claude Code 音声インターフェース Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ゴーストへ音声で話しかけると Claude Code に作業指示が送られ、進捗と要約をゴーストが発話し、書き込みと Bash を音声またはボタンで承認できるようにする。

**Architecture:** OS 非依存のロジック（イベント解析、状態機械、音声コマンド判定、承認ポリシー、プロセス起動引数）は新規パッケージ `packages/claude-code` に置き、テストで固める。`claude` は `-p --input-format stream-json --output-format stream-json` の常駐子プロセスとして起動する。権限確認は `--permission-prompt-tool` に既存 `utatane-mcp` の新ツール `approve` を指定し、既存の SSTP-over-HTTP ブリッジ（`127.0.0.1:9801`）の新コマンド `ApproveTool` でアプリへ問い合わせる。アプリ側は `ClaudeCodeController` が音声認識・ゴースト発話・transcript ウィンドウを結ぶ。

**Tech Stack:** Swift 6.2、SwiftUI/AppKit、Swift Testing（`@Test func \`name\`()` 形式）、Speech/AVFoundation（既存 `MacOSSpeechRecognizer`）、MCP（stdio JSON-RPC）。

**Spec:** `Design/superpowers/specs/2026-10-14-claude-code-voice-interface-design.md`

## Global Constraints

- OS 非依存の処理は `packages/`、アプリ固有の結線は `apps/Utatane/` に置く。AppKit/AVFoundation は `packages/platform-macos/` か `apps/` のみ。
- `Utatane.xcodeproj` は `project.yml` から生成する。直接編集しない。
- 利用者に見える変更は `CHANGELOG.md` の `Unreleased` に追記する。コミットは Conventional Commits。
- `UtataneApp.swift`（約 10,000 行）には新ロジックを書かない。新規ファイルへ置き、既存ファイルは最小の結線のみ変更する。
- 作者は `kawaiti <kawaiti@gmail.com>`（リポジトリのローカル設定済み）。
- 音声入力の設定既定値はオフ。オフ時はホットキーを登録せず、マイクと音声認識の権限を要求しない。
- 復唱確認の既定はオン。承認待ちのタイムアウトは 45 秒で拒否扱い。
- 読み取り系ツール（`Read,Glob,Grep,LS`）は自動許可。書き込みと Bash は承認必須。危険なコマンドは音声承認に加えて画面のボタン確認を必須にする。
- `--append-system-prompt` の文言: 「音声で読み上げられます。日本語で3文以内に要約して答えてください。詳細は画面に表示されます。」
- 検証は `swift test --package-path packages --filter <Suite>`。フィルタしたテストは 1 件以上実行されたことも確認する。固定時間の `Task.sleep` に依存しない。
- `claude` / `mise` / `xcodegen` はこの環境の PATH に無い。アプリのビルド（`mise run check`）は `brew install mise` 後に実施する。実機の音声認識、実際の `claude` 起動、画面表示は未確認として明記する。

## Review Focus

1. 認識結果が空白のみ → 何も送らず聞き返す（Task 2）。
2. stream-json に壊れた行・未知の `type` が混ざる → 無視してクラッシュしない（Task 1）。
3. 承認待ちでないのに「はい」、または同じ承認への二重応答 → 無視してクラッシュしない（Task 3）。
4. 作業中に新しい指示が来る → 「作業中です」で拒否し、「止めて」だけ通す（Task 2, 3）。
5. `ls && rm -rf x` のような複合コマンド、作業ディレクトリ不在 → 前者は危険判定、後者は起動前にエラー（Task 2, 3）。

---

## File Structure

```text
packages/claude-code/Sources/
  ClaudeCodeEvent.swift            イベント型と stream-json 解析
  VoiceCommandRouter.swift         認識テキストの振り分け
  ApprovalPolicy.swift             危険コマンド判定
  ClaudeCodeLaunchConfiguration.swift  起動引数の組み立て、claude 実行ファイル検出
  ClaudeCodeSession.swift          状態機械（actor）と ClaudeCodeProcessing protocol
  ClaudeCodeProcess.swift          Foundation.Process による実プロセス実装
packages/claude-code/Tests/        上記それぞれのテスト
packages/mcp-server/Sources/UtataneMCP.swift   approve ツールを追加
apps/Utatane/Sources/ClaudeCodeSettings.swift  設定ストア
apps/Utatane/Sources/ClaudeCodeSettingsView.swift  設定ページ
apps/Utatane/Sources/ClaudeCodeController.swift  音声・発話・承認の結線
apps/Utatane/Sources/ClaudeCodeTranscriptWindowController.swift  transcript ウィンドウ
```

---

### Task 1: パッケージ新設とイベント解析

**Files:**
- Create: `packages/claude-code/Sources/ClaudeCodeEvent.swift`
- Create: `packages/claude-code/Tests/ClaudeCodeEventParserTests.swift`
- Modify: `packages/Package.swift`（library `UtataneClaudeCode`、target `path: "claude-code/Sources"`、testTarget `UtataneClaudeCodeTests` `path: "claude-code/Tests"`。依存はどちらも `UtataneCore` 不要なら無し。Core の型を使わないので依存なし）

**Interfaces:**
- Produces:
  ```swift
  public enum ClaudeCodeEvent: Equatable, Sendable {
      case sessionStarted(id: String)
      case assistantText(String)
      case toolUse(id: String, name: String, command: String?)   // command は input.command があれば
      case toolResult(id: String, isError: Bool)
      case finished(result: String, isError: Bool, sessionID: String?)
  }
  public enum ClaudeCodeEventParser {
      public static func parse(line: String) -> [ClaudeCodeEvent]   // 1 行から 0 個以上
  }
  ```

- [ ] **Step 1: Write the failing tests** — `` `parses init, assistant text, tool use, tool result and result lines` ``: 次の行を与え、期待イベントを assert する。
  - `{"type":"system","subtype":"init","session_id":"s1"}` → `[.sessionStarted(id: "s1")]`
  - `{"type":"assistant","message":{"content":[{"type":"text","text":"読みます"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}` → `[.assistantText("読みます"), .toolUse(id: "t1", name: "Bash", command: "ls")]`
  - `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}` → `[.toolResult(id: "t1", isError: true)]`
  - `{"type":"result","subtype":"success","is_error":false,"result":"完了","session_id":"s1"}` → `[.finished(result: "完了", isError: false, sessionID: "s1")]`
  - `` `ignores malformed lines and unknown event types` ``: `""`、`"{not json"`、`{"type":"rate_limit_event"}`、`{"type":"assistant","message":{"content":[{"type":"thinking"}]}}` がすべて `[]`。
- [ ] **Step 2: Run to verify failure** — `swift test --package-path packages --filter UtataneClaudeCodeTests` → コンパイルエラー（型が未定義）。
- [ ] **Step 3: Implement** `ClaudeCodeEventParser.parse(line:)`。`JSONSerialization` で辞書化し、失敗・未知は `[]`。
- [ ] **Step 4: Run to verify pass** — 同コマンド → 2 テスト PASS（実行件数 2 を確認）。
- [ ] **Step 5: Commit** — `feat(claude-code): add package and stream-json event parser`

---

### Task 2: 音声コマンド判定と承認ポリシー

**Files:**
- Create: `packages/claude-code/Sources/VoiceCommandRouter.swift`, `packages/claude-code/Sources/ApprovalPolicy.swift`
- Test: `packages/claude-code/Tests/VoiceCommandRouterTests.swift`, `packages/claude-code/Tests/ApprovalPolicyTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum VoiceCommand: Equatable, Sendable {
      case approve            // 承認待ち/復唱確認への「はい」
      case deny               // 同「いいえ」
      case interrupt
      case instruction(String)
      case busy               // 作業中に来た指示
      case ignore             // 空白のみ
  }
  public struct VoiceCommandRouter: Sendable {
      public init()
      public func route(_ text: String, state: ClaudeCodeSessionState, awaitingReadback: Bool) -> VoiceCommand
  }
  public enum ApprovalPolicy {
      public static func isDangerous(toolName: String, command: String?) -> Bool
  }
  ```
  あわせて `packages/claude-code/Sources/ClaudeCodeSessionState.swift` に `public enum ClaudeCodeSessionState: Sendable { case idle, running, awaitingApproval }` を作成する（Task 3 の `ClaudeCodeSession` がこれを使う）。

- [ ] **Step 1: Write failing tests**
  - Router: `承認待ちで「はい」「許可」「OK」→ .approve`、`「いいえ」「拒否」「やめて」→ .deny`、`awaitingReadback で「はい。」→ .approve`（句読点を除去）、`idle で「テストを実行して」→ .instruction("テストを実行して")`、`idle で「止めて」「中断」→ .interrupt`、`running で「止めて」→ .interrupt`、`running で「別の作業をして」→ .busy`、`「  　」→ .ignore`（Review Focus 1, 4）、`idle で「やめて」→ .interrupt`。
  - Policy: `isDangerous("Bash", "rm -rf build")` / `"git push origin main"` / `"sudo ls"` / `"ls && rm -rf x"` / `"cat a | sh"` / `"git reset --hard"` が true、`isDangerous("Bash", "ls -la")` / `"git status"` / `isDangerous("Write", nil)` が false（Review Focus 5）。
- [ ] **Step 2: Run to verify failure** — `--filter UtataneClaudeCodeTests` → 未定義エラー。
- [ ] **Step 3: Implement** Router（前後空白と `。、.!！?？` を除去して語彙照合。承認語は はい/許可/OK/オーケー/いいよ/実行/お願いします、拒否語は いいえ/拒否/だめ/ダメ/やめて/キャンセル、中断語は 止めて/とめて/中断/ストップ。承認待ちまたは復唱確認中は承認語/拒否語を優先し、それ以外の語は承認待ちなら `.deny`ではなく `.ignore`）。Policy は `&& || ; |` と改行でコマンドを分割し、各片で先頭語/パターン（`rm`、`git push`、`git reset --hard`、`git clean`、`sudo`、`dd`、`mkfs`、`chmod -R`、パイプ先の `sh`/`bash`）を判定する。
- [ ] **Step 4: Run to verify pass** — 全 PASS、実行件数を確認。
- [ ] **Step 5: Commit** — `feat(claude-code): add voice command router and approval policy`

---

### Task 3: 起動設定とセッション状態機械

**Files:**
- Create: `packages/claude-code/Sources/ClaudeCodeLaunchConfiguration.swift`, `packages/claude-code/Sources/ClaudeCodeSession.swift`
- Test: `packages/claude-code/Tests/ClaudeCodeLaunchConfigurationTests.swift`, `packages/claude-code/Tests/ClaudeCodeSessionTests.swift`

**Interfaces:**
- Consumes: `ClaudeCodeEvent`, `ClaudeCodeEventParser`（Task 1）、`ClaudeCodeSessionState`（Task 2）
- Produces:
  ```swift
  public enum ClaudeCodePermissionMode: String, Sendable { case `default`, acceptEdits }
  public struct ClaudeCodeLaunchConfiguration: Sendable, Equatable {
      public var executable: URL
      public var workingDirectory: URL
      public var model: String?
      public var permissionMode: ClaudeCodePermissionMode
      public var mcpHelperPath: String                   // utatane-mcp の絶対パス
      public init(executable: URL, workingDirectory: URL, model: String?, permissionMode: ClaudeCodePermissionMode, mcpHelperPath: String)
      public func arguments(resume sessionID: String?) -> [String]
  }
  public enum ClaudeExecutableLocator {
      public static func locate(explicitPath: String?, home: URL, fileExists: (String) -> Bool) -> URL?
  }
  public protocol ClaudeCodeProcessing: Sendable {
      func start(_ configuration: ClaudeCodeLaunchConfiguration, resume sessionID: String?) async throws -> AsyncStream<String>
      func send(userMessage: String) async throws
      func interrupt() async
      func terminate() async
  }
  public enum ApprovalDecision: Equatable, Sendable { case allow, deny(reason: String) }
  public enum ClaudeCodeError: Error, Equatable { case busy, workingDirectoryMissing, executableNotFound }
  public actor ClaudeCodeSession {
      public init(configuration: ClaudeCodeLaunchConfiguration?, process: any ClaudeCodeProcessing,
                  approvalTimeout: Duration = .seconds(45), directoryExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
      public var state: ClaudeCodeSessionState { get }
      public var sessionID: String? { get }
      public func events() -> AsyncStream<ClaudeCodeEvent>
      public func submit(_ instruction: String) async throws
      public func requestApproval(toolName: String, command: String?) async -> ApprovalDecision
      public func resolveApproval(allow: Bool)
      public func interrupt() async
  }
  ```

- [ ] **Step 1: Write failing tests**
  - Launch: `arguments(resume: nil)` に `-p`、`--input-format`/`stream-json`、`--output-format`/`stream-json`、`--verbose`、`--permission-prompt-tool`/`mcp__utatane__approve`、`--allowedTools`/`Read,Glob,Grep,LS`、`--append-system-prompt`（Global Constraints の文言）、`--mcp-config`（`mcpServers.utatane.command == mcpHelperPath` の JSON 文字列）が含まれ、`--resume` は含まれない。`resume: "s1"` では `--resume s1` を含む。`model` が `nil` なら `--model` を含まない。
  - Locator: `explicitPath` が存在すればそれを返す。無ければ `~/.local/bin/claude`、`/opt/homebrew/bin/claude`、`/usr/local/bin/claude`、`~/.claude/local/claude` の順で最初に存在するもの。全部無ければ `nil`。
  - Session（偽 `ClaudeCodeProcessing` を注入）:
    - `submit` で `idle → running` となり、偽プロセスが `send` を受け取る。`init` 行の後 `sessionID` が更新される。`result` 行で `idle` に戻り `.finished` が流れる。
    - `running` 中の `submit` は `ClaudeCodeError.busy`（Review Focus 4）。
    - `directoryExists` が false なら `submit` は `.workingDirectoryMissing` を投げ、プロセスを起動しない（Review Focus 5）。`configuration == nil` なら `.executableNotFound`。
    - `requestApproval` は `awaitingApproval` で待機し、`resolveApproval(allow: true)` で `.allow`、状態は `running` に戻る。`approvalTimeout: .milliseconds(50)` では `.deny` を返す。
    - 承認待ちでない `resolveApproval` と二重の `resolveApproval` は何も起こさない（Review Focus 3）。
    - 偽プロセスの stdout ストリームが `result` なしで終了したら、`.finished(result: "プロセスが終了しました", isError: true, sessionID: …)` が流れ `idle` になる。
    - `interrupt()` が偽プロセスの `interrupt` を呼び、承認待ちなら `.deny` で解決する。
- [ ] **Step 2: Run to verify failure** — `--filter UtataneClaudeCodeTests` → 未定義エラー。
- [ ] **Step 3: Implement** 上記の型。`submit` は初回に `process.start(configuration, resume: sessionID)` を呼び、返った `AsyncStream<String>` を `Task` で消費して `ClaudeCodeEventParser.parse` → events へ yield する。二回目以降は `send` のみ（プロセス常駐）。`requestApproval` は `CheckedContinuation` と、同じ継続を二重に resume しないためのフラグ、およびタイムアウト用 `Task` を使う。
- [ ] **Step 4: Run to verify pass** — 全 PASS、実行件数を確認。
- [ ] **Step 5: Commit** — `feat(claude-code): add launch configuration and session state machine`

---

### Task 4: 実プロセス実装

**Files:**
- Create: `packages/claude-code/Sources/ClaudeCodeProcess.swift`
- Test: `packages/claude-code/Tests/ClaudeCodeProcessTests.swift`

**Interfaces:**
- Consumes: `ClaudeCodeProcessing`, `ClaudeCodeLaunchConfiguration`（Task 3）
- Produces: `public final class ClaudeCodeProcess: ClaudeCodeProcessing, @unchecked Sendable { public init() }`

- [ ] **Step 1: Write failing test** — `` `streams stdout lines and writes stream-json user messages to stdin` ``: `executable` に `/bin/cat` 相当ではなく、テスト内で一時ディレクトリに作る小さなシェルスクリプト（stdin の各行をそのまま stdout へ返す）を指定する。`start` → `send(userMessage: "こんにちは")` → ストリームから 1 行目を読み、`{"type":"user","message":{"role":"user","content":"こんにちは"}}` と JSON 等価であることを assert。`terminate()` でストリームが終了することも assert（条件待ち。固定 sleep は使わない）。
- [ ] **Step 2: Run to verify failure** — 未定義エラー。
- [ ] **Step 3: Implement** `Foundation.Process` で `executable`、`arguments(resume:)`、`currentDirectoryURL` を設定し、stdin/stdout `Pipe`。stdout を行単位で `AsyncStream<String>` に流す。`send` は JSON 1 行 + `\n` を書く。`interrupt` は `SIGINT`、`terminate` は stdin を閉じて終了を待つ。
- [ ] **Step 4: Run to verify pass** — PASS。
- [ ] **Step 5: Commit** — `feat(claude-code): add Process-backed Claude Code runner`

---

### Task 5: MCP `approve` ツールと SSTP `ApproveTool` ブリッジ

**Files:**
- Modify: `packages/mcp-server/Sources/UtataneMCP.swift`（`callTool` に `approve` ケース、`tools()` に定義、`UtataneBridgeClient.command` にタイムアウト指定）
- Modify: `packages/mcp-server/Tests/MCPServerTests.swift`（`tools/list` のツール集合に `approve` を追加、新テスト）

アプリ側の SSTP `ApproveTool` ケース追加は Task 7 で行う（コントローラが無いとコンパイルできないため）。

**Interfaces:**
- Produces（MCP 側）: ツール `approve`。引数 `tool_name: String`（必須）、`input: object`、`tool_use_id: String`。成功時のテキストは Claude Code の仕様どおり JSON 文字列 `{"behavior":"allow","updatedInput":<input>}` または `{"behavior":"deny","message":"<理由>"}`。
- Produces（ブリッジ側）: SSTP コマンド `ApproveTool`、Payload は base64 JSON `{tool_name, input, tool_use_id}`。応答のスクリプトは `{"allow":true}` または `{"allow":false,"reason":"…"}` の JSON。
- Consumes（Task 7）: `ClaudeCodeController.handleApproveTool(payload: [String: Any]) async -> SSTPResponse`

- [ ] **Step 1: Write failing tests** — `` `approve tool maps bridge allow and deny responses to permission JSON` ``: 偽 `send` が `Command: ApproveTool` を含むリクエストを受け、`Script: {"allow":true}` を返すと `tools/call` の結果テキストが `behavior == "allow"` と `updatedInput` を持つ JSON になる。`{"allow":false,"reason":"拒否"}` なら `behavior == "deny"` と `message == "拒否"`。`tool_name` 欠落は error（`MCPError.invalidArguments`）。Utatane へ接続できない場合は `deny`（`message` に接続不能の旨）を返し、エラーにしない。既存の `tools/list` テストの集合に `approve` を足す。
- [ ] **Step 2: Run to verify failure** — `swift test --package-path packages --filter UtataneMCPTests`。
- [ ] **Step 3: Implement** `approve` と、`approve` 呼び出し時の `URLRequest.timeoutInterval = 60`（承認タイムアウト 45 秒より長くする）。アプリ側は本タスクでは変更しない。
- [ ] **Step 4: Run to verify pass** — `UtataneMCPTests` 全 PASS（既存テストの退行なし、実行件数を確認）。
- [ ] **Step 5: Commit** — `feat(mcp): add approve tool for Claude Code permission prompts`

---

### Task 6: 設定ストアと設定ページ

**Files:**
- Create: `apps/Utatane/Sources/ClaudeCodeSettings.swift`, `apps/Utatane/Sources/ClaudeCodeSettingsView.swift`
- Modify: `apps/Utatane/Sources/UtataneSettings.swift`（`Pane` に `case claudeCode`（行 288 付近）、サイドバーの `Label("Claude Code", systemImage: "terminal").tag(...)`（行 913 付近）、`configurationHelpReferences` の switch（行 1348 付近。`("developer", "Claude Code")` を使う）、本文の switch（行 921 付近）に `ClaudeCodeSettingsView`）
- Modify: `apps/Utatane/Sources/UtataneApp.swift`（`ClaudeCodeSettings` の生成と `UtataneSettingsView` への受け渡し）

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class ClaudeCodeSettings: ObservableObject {
      @Published var voiceInputEnabled: Bool          // 既定 false
      @Published var readbackEnabled: Bool            // 既定 true
      @Published var executablePath: String           // 既定 ""（自動検出）
      @Published var workingDirectory: String         // 既定 ""
      @Published var model: String                    // 既定 ""
      @Published var permissionMode: ClaudeCodePermissionMode   // 既定 .default
      @Published var hotkey: ClaudeCodeHotkey         // 既定 .controlOptionSpace
      init(defaults: UserDefaults = .standard)
  }
  enum ClaudeCodeHotkey: String, CaseIterable, Identifiable { case controlOptionSpace, rightOption, fn }
  ```
  `UserDefaults` のキーは `claudeCode.` プレフィックス。`didSet` で保存する（`UtataneSettingsStore` の流儀）。

- [ ] **Step 1: Write failing test** — `apps/` はテストターゲットが無い。`ClaudeCodeSettings` の永続化ロジックを検証できるよう、永続化部分は `packages/claude-code/Sources/ClaudeCodeSettingsStorage.swift`（`UserDefaults` を受け取る純粋な読み書き型 `ClaudeCodeSettingsStorage`）に切り出し、`ClaudeCodeSettingsStorageTests` で「既定値が voiceInputEnabled=false / readbackEnabled=true」「書いた値が別インスタンスで読める」を検証する。`ClaudeCodeSettings` はその薄いラッパにする。
- [ ] **Step 2: Run to verify failure** — `--filter ClaudeCodeSettingsStorageTests` → 未定義エラー。
- [ ] **Step 3: Implement** ストレージ型、`ClaudeCodeSettings`、設定ページ（トグル「音声入力を有効にする」、復唱確認トグル、`claude` パス（「自動検出」表示と選択ボタン）、作業ディレクトリ選択、モデル、権限モード Picker、ホットキー Picker）。
- [ ] **Step 4: Run to verify pass** — パッケージテスト PASS。アプリのビルド（`mise run build`）は環境が整ってから実施し、未実施なら未確認と記す。
- [ ] **Step 5: Commit** — `feat(app): add Claude Code settings page`

---

### Task 7: コントローラ、transcript、結線

**Files:**
- Create: `apps/Utatane/Sources/ClaudeCodeController.swift`, `apps/Utatane/Sources/ClaudeCodeTranscriptWindowController.swift`
- Modify: `apps/Utatane/Sources/UtataneApp.swift`（コントローラ生成、メニュー項目「Claude Code…」で transcript を開く、`handleMCPBridgeCommand` に `case "ApproveTool": return await claudeCodeController.handleApproveTool(payload: arguments)`）
- Reference: `apps/Utatane/Sources/SystemInputEventMonitor.swift`（ホットキー監視の既存パターン。読んで、使えるなら再利用する）

**Interfaces:**
- Consumes: `ClaudeCodeSession`、`VoiceCommandRouter`、`ApprovalPolicy`、`ClaudeExecutableLocator`（Task 1〜3）、`ClaudeCodeSettings`（Task 6）、`MacOSSpeechRecognizer`（`packages/platform-macos`）
- Produces:
  ```swift
  @MainActor final class ClaudeCodeController {
      init(settings: ClaudeCodeSettings, speak: @escaping (String) -> Void)   // speak はゴースト発話（SakuraScript 化は呼び出し側）
      func startIfEnabled()          // voiceInputEnabled のときだけホットキー登録
      func submitText(_ text: String)  // transcript の入力欄から
      func handleApproveTool(payload: [String: Any]) async -> SSTPResponse
      func showTranscript()
  }
  ```
  `speak` の実装は `UtataneApp.swift` 側で `SakuraScript(rawValue: AIPersonalityEngine.escape(text))` を `scriptPlayer.play(_, balloon:)` に渡す（`UtataneApp.swift:7813` の `SakuraScript` ケースと同じ手順）。

- [ ] **Step 1: Write failing test** — コントローラの純粋に分離できる部分（イベント→発話文の変換）を `packages/claude-code/Sources/SpeechNarrator.swift` に切り出し、`SpeechNarratorTests` で検証する。`narrate(_ event: ClaudeCodeEvent) -> String?`: `.toolUse(name: "Read", …)` → `「ファイルを読んでいます」`、`.toolUse(name: "Bash", …)` → `「コマンドを実行しています」`、`.toolUse(name: "Edit"/"Write", …)` → `「ファイルを書き換えています」`、`.assistantText` と `.toolResult` は `nil`、`.finished(result:isError:false)` → 結果を 120 文字で切り詰めた文字列（超過分は `…`。全文は transcript のみ、Review Focus に準ずる長文対策）、`.finished(isError: true)` → `「うまくいきませんでした: <結果の先頭 60 文字>」`。
- [ ] **Step 2: Run to verify failure** — `--filter SpeechNarratorTests` → 未定義エラー。
- [ ] **Step 3: Implement** `SpeechNarrator`、`ClaudeCodeController`（ホットキー押下で `MacOSSpeechRecognizer.start`、離したら停止、`onFinalResult` を `VoiceCommandRouter` に通す。`.instruction` は復唱確認が有効なら `speak("『…』と指示します。よろしいですか?")` して保留、`.approve` で送信、`.deny` で破棄。`.interrupt` は `session.interrupt()`、`.busy` は `speak("作業中です")`、`.ignore` は `speak("聞き取れませんでした")`。`claude` 未検出・未ログイン・作業ディレクトリ不在は `ClaudeCodeError` を日本語で発話し設定ページを開く）、transcript ウィンドウ（指示・進捗・結果全文、許可/拒否ボタン、中断ボタン、テキスト入力欄）。`handleApproveTool` は `session.requestApproval` を待ち、危険なコマンド（`ApprovalPolicy.isDangerous`）の場合は音声承認を受け付けずボタン承認のみ有効にして画面にコマンドを表示する。許可は `{"allow":true}`、拒否・タイムアウトは `{"allow":false,"reason":…}` を `jsonSSTPResponse` で返す。`voiceInputEnabled == false` のときは `MacOSSpeechRecognizer` を生成せずホットキーも登録しない。`UtataneApp.swift` に最小の結線を入れる。
- [ ] **Step 4: Run to verify pass** — パッケージテスト全 PASS。`mise run build` が可能ならビルド成功も確認。
- [ ] **Step 5: Commit** — `feat(app): add Claude Code voice controller and transcript window`

---

### Task 8: ドキュメント、CHANGELOG、最終確認

**Files:**
- Create: `Docs/Guide/Claude-Code.md`（使い方、音声入力の設定、承認の仕方、権限の注意）
- Modify: `Docs/navigation.json`、`Docs/README.md`（新ページの登録）、`CHANGELOG.md`（`Unreleased` に追記）

- [ ] **Step 1: Write** ドキュメントと CHANGELOG を追記。互換性表は変更しない。
- [ ] **Step 2: Verify** — `swift test --package-path packages` 全体が PASS。環境が整っていれば `mise run check` と `cd website && bun run help && bun run check && bun run build && bun run test`。整っていなければ未実施として明記する。
- [ ] **Step 3: 手動確認の一覧を作業結果へ記載** — 未確認: 実機の音声認識（マイク・音声認識権限、ホットキーの Input Monitoring/Accessibility 権限）、実際の `claude` 起動と `--permission-prompt-tool` の応答形式（`{"behavior":"allow"|"deny"}`）が現行 CLI の仕様と一致すること、transcript とゴースト発話の画面表示、`--resume` による再開。
- [ ] **Step 4: Commit** — `docs: add Claude Code guide and changelog`

---

## Self-Review

- **Spec coverage:** パッケージの各型（Task 1〜4）、権限ブリッジ（Task 5）、設定と音声オン/オフ（Task 6）、コントローラ・transcript・復唱確認・ゴースト発話・エラー処理（Task 7）、CHANGELOG と運用（Task 8）に対応。`--resume` による再開は Task 3（`arguments(resume:)`、`sessionID` 保持）と Task 8 の手動確認。
- **Type consistency:** `ClaudeCodeSessionState` は Task 2 で先行定義し Task 3 で使う。`ApprovalDecision`、`ClaudeCodeError`、`handleApproveTool` の名前は Task 3/5/7 で一致。
- **未検証の前提:** stream-json の行形式と `--permission-prompt-tool` の入出力形式は、ローカルに `claude` が無いため公式ドキュメント記述に基づく。Task 1 のフィクスチャと Task 5 の応答 JSON は、実機で `claude` を入手できた時点で実出力と突き合わせること。
