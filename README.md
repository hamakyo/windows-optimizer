# Windows 最適化スクリプト

Windows のパフォーマンスおよび操作性を改善する最適化と、変更前スナップショットに基づく安全な復元を行う PowerShell スクリプト集です。

## 重要な注意事項

### セキュリティと権限
- **管理者権限が必須 (`#Requires -RunAsAdministrator`)**: レジストリや電源設定を変更するため、管理者として実行する必要があります。
- **ExecutionPolicy Bypass の利用**: `.bat` ラッパーは実行時のみ一時的に実行ポリシーを回避します。
- **企業・管理端末での利用**: 組織のセキュリティポリシーによっては実行できない場合があります。事前に管理者に確認してください。

### UAC 昇格とアカウントに関する注意
- 標準ユーザーから **別アカウントの管理者資格情報** で UAC 昇格した場合、ユーザー単位の設定（`HKCU` レジストリおよび `%LOCALAPPDATA%` 配下のバックアップ先）は **昇格先の管理者アカウント側** に適用されます。
- ログイン中のユーザー自身に設定を適用したい場合は、対象ユーザーが管理者グループに所属している状態で昇格してください。

### バックアップと復元
- `optimize.ps1` は変更を行う前に、現在の設定とレジストリ値型（`REG_EXPAND_SZ` / `REG_DWORD` / `REG_SZ` など）を `%LOCALAPPDATA%\windows-optimizer\backup.json` に保存します。
- 既にバックアップが存在する場合は、初回実行前の状態を保護するため上書きしません（上書きしたい場合のみ `-ForceBackup` を指定します）。
- `restore.ps1` はバックアップが存在すれば元の設定・型をそのまま復元し、バックアップが無い場合は警告を表示した上で安全な既定値へフォールバック復元します。

## 実行手順

### 1. ダブルクリックで実行する（推奨）
- **最適化**: `run_as_admin.bat` をダブルクリックし、UAC の確認で「はい」を選択します。完了後は結果を確認できるようキー入力待ちになります。
- **復元**: `run_restore_admin.bat` をダブルクリックし、UAC の確認で「はい」を選択します。

### 2. PowerShell からオプション指定で実行する（管理者 PowerShell）

事前に変更内容だけを確認する（ドライラン）:

```powershell
.\optimize.ps1 -WhatIf
.\restore.ps1 -WhatIf
```

一部の項目をスキップして実行する:

```powershell
.\optimize.ps1 -SkipOneDrive -SkipDownloadsRedirect
```

Downloads フォルダの移行先を明示指定して実行する:

```powershell
.\optimize.ps1 -DownloadsPath "E:\Downloads"
```

既存のバックアップを上書きして再取得する:

```powershell
.\optimize.ps1 -ForceBackup
```

## オプション一覧

| オプション | 対象 | 説明 |
| --- | --- | --- |
| `-WhatIf` | 両方 | 実際の変更やバックアップ書き込みを行わず、実行予定の操作を表示 |
| `-SkipStickyKeys` | 両方 | 固定キー設定の変更/復元をスキップ |
| `-SkipPowerPlan` | 両方 | 電源プランの変更/復元をスキップ |
| `-SkipFastStartup` | 両方 | 高速スタートアップ・休止状態の変更/復元をスキップ |
| `-SkipGameMode` | 両方 | ゲームモードの変更/復元をスキップ |
| `-SkipVisualEffects` | 両方 | 視覚効果（アニメーション・透過）の変更/復元をスキップ |
| `-SkipOneDrive` | 両方 | OneDrive 自動起動の変更/復元をスキップ |
| `-SkipDownloadsRedirect` | 両方 | Windows 標準 Downloads フォルダの変更/復元をスキップ |
| `-DownloadsPath <path>` | `optimize.ps1` | Downloads フォルダの移行先（既定: `D:\Downloads`） |
| `-BackupPath <path>` | 両方 | バックアップ JSON のパス（既定: `%LOCALAPPDATA%\windows-optimizer\backup.json`） |
| `-ForceBackup` | `optimize.ps1` | 既存バックアップがある場合も強制的に上書き保存 |
| `-Pause` | 両方 | 完了後に Enter キー待ちを行う（`.bat` 実行時は自動付与） |

## 最適化内容

1. **固定キー無効化**（ユーザー単位）
   - Shift キー 5 回連打のダイアログ（StickyKeys / Keyboard Response / ToggleKeys）を無効化します。
2. **電源プラン変更**（システム全体）
   - 「高パフォーマンス」プラン（`8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c`）へ切り替えます。一覧に無い場合は `powercfg /duplicatescheme` で複製を試みます。
   - **Modern Standby（S0ix）環境についての注意**: Modern Standby 対応端末では OS 仕様により高パフォーマンスプランが利用できない場合があります。その場合は警告を出してスキップし、他の最適化を続行します。
3. **高速スタートアップ無効化**（システム全体）
   - `HiberbootEnabled` を `0` に設定し、`powercfg /hibernate off` で休止状態を無効化します。
4. **ゲームモード有効化**（ユーザー単位）
   - `HKCU:\Software\Microsoft\GameBar` の `AllowAutoGameMode` を `1` に設定します。
5. **視覚効果無効化**（ユーザー単位）
   - ウィンドウアニメーション（`MinAnimate`）と透過効果（`EnableTransparency`）を無効化します。
6. **OneDrive 自動起動停止**（ユーザー単位）
   - 標準インストール先 3 箇所（`%LOCALAPPDATA%` / `Program Files` / `Program Files (x86)`）から `OneDrive.exe` を検出し、実行中なら終了してスタートアップ登録を削除します。
   - バックアップ無しで復元する場合は、サインイン時にウィンドウが開かないよう `/background` 付きで再登録します。
7. **Windows 標準 Downloads フォルダ変更**（ユーザー単位）
   - Chrome 専用ではなく **Windows 標準の Downloads 既知フォルダ**（`{374DE290-123F-4565-9164-39C4925E467B}`）を `SHSetKnownFolderPath` およびレジストリ経由で変更します（標準設定のブラウザも連動します）。
   - `-DownloadsPath` を明示指定せず、かつ `D:\` が存在しない場合はレジストリを変更せずスキップします。
   - 復元時は `%USERPROFILE%\Downloads` などの `REG_EXPAND_SZ` 型を保持したまま元に戻します。

## ファイル構成

- `optimize.ps1` - 最適化スクリプト（UTF-8 BOM / CRLF）
- `restore.ps1` - 復元スクリプト（UTF-8 BOM / CRLF）
- `run_as_admin.bat` - `optimize.ps1` 管理者実行ラッパー（ASCII / CRLF）
- `run_restore_admin.bat` - `restore.ps1` 管理者実行ラッパー（ASCII / CRLF）
- `PSScriptAnalyzerSettings.psd1` - PSScriptAnalyzer 設定
- `tests/Verify-Scripts.ps1` - エンコーディング・構文・メタデータ・`-WhatIf` 検証スクリプト
- `.github/workflows/ci.yml` - `windows-latest` 上で実行される CI ワークフロー

## 使用上の注意

- 自己責任で使用してください。
- 変更後はエクスプローラーの再起動、または Windows の再起動を推奨します。
- 不具合が生じた場合は `run_restore_admin.bat` または `restore.ps1` で元の状態へ戻してください。
