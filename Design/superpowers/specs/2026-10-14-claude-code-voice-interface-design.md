# Claude Code 音声インターフェース 設計

日付: 2026-10-14
対象: Utatane の fork (`kawaiti/Utatane`)、ブランチ `feat/claude-code-voice-interface`

## 目的と前提

Utatane（macOS 向け伺かベースウェア）を土台に、ゴーストへ**音声で話しかけて Claude Code に作業指示を出せる**アプリにする。

前提（ユーザー確認済み）:
- Utatane を fork して改造する。
- 主な用途は音声での指示。進捗と結果はゴーストが発話し、詳細は画面に表示する。
- Claude Code の駆動は `claude -p --output-format stream-json` の子プロセス方式（方式 A）。

前提（仮定。違えば修正する）:
- Claude Code はローカルの Mac 上で動かす。作業ディレクトリはユーザーが設定で選ぶ。
- 危険な操作はゴーストが確認し、承認を得てから実行する。

成功基準:
- ホットキーを押しながら話した指示が Claude Code に送られ、進捗と完了要約がゴーストの発話で返る。
- 書き込みと Bash は承認なしに実行されない。
- 音声入力を設定でオフにでき、オフ時はマイクと音声認識の権限を要求しない。
- アプリ再起動後も `--resume` でセッションを継続できる。

## 非目標

- 常時待受（ウェイクワード）。
- Agent SDK / Node ランタイムの同梱。
- pty による対話 TUI のラップ。
- Windows / Linux 対応。
- Claude Code の API キー管理（Claude Code 自身の認証を使う）。

## アーキテクチャ

AGENTS.md の境界に従い、OS 非依存のロジックは `packages/`、アプリ固有の結線は `apps/Utatane/` に置く。

### 新規パッケージ `packages/claude-code`（`UtataneClaudeCode`）

依存は `UtataneCore` のみ。

- **`ClaudeCodeEvent`**: 開始（session_id）、assistant テキスト、tool 使用、tool 結果、最終結果、エラー。
- **`ClaudeCodeEventParser`**: stream-json の 1 行を `ClaudeCodeEvent` へ変換する純粋関数。
- **`ClaudeCodeProcess`**: `claude -p --input-format stream-json --output-format stream-json --verbose` を作業ディレクトリ指定で起動し、常駐させる。追加の指示は stdin へ流す。`--resume <session_id>` で再開する。`--append-system-prompt` で「音声向けに日本語で 3 文以内に要約する」と指示する。`--permission-prompt-tool` に承認ツールを指定する。プロセス操作は protocol 越しに注入でき、テストでは偽物に差し替える。
- **`ClaudeCodeSession`（actor）**: 状態 `idle → running → awaitingApproval → idle`。中断、再開、承認のタイムアウト（拒否扱い）を管理する。
- **`VoiceCommandRouter`**: 認識テキストを、承認待ちなら承認/拒否の判定、それ以外なら指示として振り分ける純粋関数。「はい/許可」「いいえ/やめて/拒否」「止めて」を扱う。

### 権限ブリッジ

既存 `packages/mcp-server`（`utatane-mcp`）に `approve` ツールを追加する。Claude Code が許可を求めると `approve` がローカルソケット経由でアプリに問い合わせ、アプリが allow/deny の JSON を返す。読み取り系ツールは自動許可し、書き込みと Bash は承認を求める。危険なコマンド（`rm`、`git push` など）は音声に加えて画面のボタンでの確認を必須にする。

### アプリ結線（`apps/Utatane`）

- **`ClaudeCodeController`**: セッション、音声認識（`platform-macos/SpeechServices.swift`）、ゴースト発話、transcript ウィンドウを結ぶ。
- イベント → 発話の変換: 進捗は短く（「ファイルを読んでいます」）、完了時は要約を話す。全文は transcript に表示する。
- **transcript ウィンドウ**: 指示、進捗、tool 使用、結果の全文、承認待ちの許可/拒否ボタン、中断ボタン、テキスト入力欄。

## 音声フロー

1. グローバルホットキーを押している間だけ音声認識する。
2. 認識結果を `VoiceCommandRouter` で振り分ける。
3. 指示は、復唱確認が有効（既定）なら「〜と指示します。よろしいですか」と確認してから送る。
4. 音声認識が失敗したら何も送らず聞き返す。

## 設定

本体設定に「Claude Code」ページを追加し、`UtataneSettings.swift` の流儀で保存する。

- **音声入力を有効にする**: オフならホットキーを登録せず、マイクと音声認識の権限を要求しない。テキスト入力のみで使える。
- ホットキー、復唱確認のオン/オフ（既定オン）。
- `claude` 実行ファイルのパス（自動検出と手動指定）。
- 作業ディレクトリ、モデル、権限モード。

## エラー処理

- `claude` が見つからない、または未ログイン: ゴーストが理由を話し、設定ページへ誘導する。
- プロセスの異常終了: `idle` に戻して通知し、次の指示で `--resume` により再開する。
- 承認待ちのタイムアウト: 拒否として扱う。

## テスト

- `ClaudeCodeEventParser`: stream-json フィクスチャによる単体テスト。
- `ClaudeCodeSession`: 偽のプロセスを注入し、状態遷移、承認、中断、再開、タイムアウトを検証する。
- `VoiceCommandRouter`: 承認の発話判定と復唱確認を純粋関数として検証する。
- フィルタしたテストは、対象テストが 1 件以上実行されたことも確認する。
- 実機の音声認識、実際の `claude` 起動、画面表示はビルドとテストでは確認できない。完了時に未確認の範囲として明記する。

## 開発環境メモ

この環境の PATH には `claude`、`mise`、`xcodegen` がない（Xcode 26.6、Swift 6.3 はある）。ビルド検証（`mise run check`）には `brew install mise xcodegen` などが必要になる可能性がある。実装計画で扱う。

## リポジトリ運用

- 利用者に見える変更は `CHANGELOG.md` の `Unreleased` に追記する。
- コミットは Conventional Commits 形式。
- `Utatane.xcodeproj` は `project.yml` から生成する。直接編集しない。
