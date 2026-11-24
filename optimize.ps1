#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows のパフォーマンスおよび操作性を改善する最適化スクリプト（管理者権限必須）。
.DESCRIPTION
    変更前に現在の設定を JSON スナップショットとして保存し、各最適化項目を適用します。
    -WhatIf によるドライランや、-Skip* スイッチによる項目ごとのスキップに対応しています。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipStickyKeys,
    [switch]$SkipPowerPlan,
    [switch]$SkipFastStartup,
    [switch]$SkipGameMode,
    [switch]$SkipVisualEffects,
    [switch]$SkipOneDrive,
    [switch]$SkipDownloadsRedirect,
    [string]$DownloadsPath = 'D:\Downloads',
    [string]$BackupPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'windows-optimizer\backup.json'),
    [switch]$ForceBackup,
    [switch]$Pause
)

Set-StrictMode -Version Latest

$downloadsGuid = '{374DE290-123F-4565-9164-39C4925E467B}'
$highPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$downloadsPathExplicit = $PSBoundParameters.ContainsKey('DownloadsPath')

function Get-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('HKCU', 'HKLM')]
        [string]$Hive,

        [Parameter(Mandatory = $true)]
        [string]$SubKey,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $baseKey = if ($Hive -eq 'HKCU') {
        [Microsoft.Win32.Registry]::CurrentUser
    } else {
        [Microsoft.Win32.Registry]::LocalMachine
    }

    $regKey = $null
    try {
        $regKey = $baseKey.OpenSubKey($SubKey, $false)
        if ($null -eq $regKey) {
            return [ordered]@{
                KeyExists   = $false
                ValueExists = $false
                Value       = $null
                Kind        = $null
            }
        }

        $valueNames = $regKey.GetValueNames()
        if ($valueNames -notcontains $Name) {
            return [ordered]@{
                KeyExists   = $true
                ValueExists = $false
                Value       = $null
                Kind        = $null
            }
        }

        $rawValue = $regKey.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $regKey.GetValueKind($Name).ToString()

        return [ordered]@{
            KeyExists   = $true
            ValueExists = $true
            Value       = $rawValue
            Kind        = $kind
        }
    } finally {
        if ($null -ne $regKey) {
            $regKey.Close()
        }
    }
}

function Set-RegistryValueSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')]
        [string]$Type
    )

    if (-not (Test-Path -Path $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'レジストリキーを作成')) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess("$Path\$Name", "レジストリ値 ($Type) を '$Value' に設定")) {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    }
}

function Get-ActivePowerPlanGuid {
    $output = (& powercfg /getactivescheme 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $match = [regex]::Match($output, '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
    if ($match.Success) {
        return $match.Value.ToLowerInvariant()
    }

    return $null
}

function Get-OneDriveExecutablePath {
    $candidates = New-Object -TypeName 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\OneDrive\OneDrive.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft OneDrive\OneDrive.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Microsoft OneDrive\OneDrive.exe'))
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Set-KnownFolderDownloadPath {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (-not ('WindowsOptimizer.KnownFolderNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WindowsOptimizer
{
    public static class KnownFolderNative
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SHSetKnownFolderPath(
            [MarshalAs(UnmanagedType.LPStruct)] Guid rfid,
            uint dwFlags,
            IntPtr hToken,
            string pszPath);
    }
}
'@ -ErrorAction Stop
    }

    $expandedTarget = [Environment]::ExpandEnvironmentVariables($TargetPath)
    $folderGuid = [Guid]'374DE290-123F-4565-9164-39C4925E467B'

    if ($PSCmdlet.ShouldProcess($expandedTarget, 'SHSetKnownFolderPath で Windows Downloads 既知フォルダを変更')) {
        $hr = [WindowsOptimizer.KnownFolderNative]::SHSetKnownFolderPath($folderGuid, 0, [IntPtr]::Zero, $expandedTarget)
        return ($hr -eq 0)
    }

    return $true
}

function Save-OptimizationBackup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Force
    )

    if ((Test-Path -Path $Path) -and (-not $Force)) {
        Write-Host "ℹ️ 既存のバックアップが既に存在するため上書きしません: $Path" -ForegroundColor Cyan
        Write-Host '   上書きする場合は -ForceBackup を指定してください。' -ForegroundColor DarkGray
        return
    }

    $snapshot = [ordered]@{
        SchemaVersion = 1
        CapturedAt    = (Get-Date).ToString('o')
        UserName      = $env:USERNAME
        ComputerName  = $env:COMPUTERNAME
        StickyKeys    = [ordered]@{
            StickyKeys       = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Control Panel\Accessibility\StickyKeys' -Name 'Flags'
            KeyboardResponse = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Control Panel\Accessibility\Keyboard Response' -Name 'Flags'
            ToggleKeys       = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Control Panel\Accessibility\ToggleKeys' -Name 'Flags'
        }
        PowerPlan     = [ordered]@{
            ActiveSchemeGuid = Get-ActivePowerPlanGuid
        }
        FastStartup   = [ordered]@{
            HiberbootEnabled = Get-RegistryValueSnapshot -Hive 'HKLM' -SubKey 'SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled'
            HibernateEnabled = Get-RegistryValueSnapshot -Hive 'HKLM' -SubKey 'SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
        }
        GameMode      = [ordered]@{
            AllowAutoGameMode = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Software\Microsoft\GameBar' -Name 'AllowAutoGameMode'
        }
        VisualEffects = [ordered]@{
            MinAnimate         = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate'
            EnableTransparency = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency'
        }
        OneDrive      = [ordered]@{
            RunOneDrive = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive'
        }
        Downloads     = [ordered]@{
            UserShellFolders = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name $downloadsGuid
        }
    }

    $backupDir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($backupDir) -and (-not (Test-Path -Path $backupDir))) {
        if ($PSCmdlet.ShouldProcess($backupDir, 'バックアップディレクトリを作成')) {
            New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        }
    }

    $json = $snapshot | ConvertTo-Json -Depth 6
    if ($PSCmdlet.ShouldProcess($Path, '変更前設定のバックアップを保存')) {
        Set-Content -Path $Path -Value $json -Encoding UTF8 -ErrorAction Stop
        Write-Host "💾 変更前の設定をバックアップしました: $Path" -ForegroundColor Cyan
    }
}

Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Windows 最適化スクリプトを実行します' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# 0. 変更前スナップショットの保存
try {
    Save-OptimizationBackup -Path $BackupPath -Force:$ForceBackup
} catch {
    Write-Host "⚠️ バックアップの保存に失敗しました: $_" -ForegroundColor Yellow
}

# 1. 固定キー（Shiftキー5回連打）無効化設定
if ($SkipStickyKeys) {
    Write-Host '⏭️ [1/7] 固定キー無効化をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Accessibility\StickyKeys' -Name 'Flags' -Value '506' -Type 'String'
        Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Accessibility\Keyboard Response' -Name 'Flags' -Value '122' -Type 'String'
        Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Accessibility\ToggleKeys' -Name 'Flags' -Value '58' -Type 'String'
        Write-Host '✅ [1/7] 固定キー無効化が完了しました。' -ForegroundColor Green
    } catch {
        Write-Host "❌ [1/7] 固定キーの無効化に失敗しました: $_" -ForegroundColor Red
    }
}

# 2. 電源プランを「高パフォーマンス」に切り替え
if ($SkipPowerPlan) {
    Write-Host '⏭️ [2/7] 電源プランの変更をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        $powerList = (& powercfg /list 2>&1) -join "`n"
        $targetGuid = $null

        if ($LASTEXITCODE -eq 0 -and $powerList -match [regex]::Escape($highPerformanceGuid)) {
            $targetGuid = $highPerformanceGuid
        } else {
            Write-Host 'ℹ️ 高パフォーマンス電源プランが見つからないため複製を試みます...' -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess($highPerformanceGuid, 'powercfg /duplicatescheme で高パフォーマンスプランを複製')) {
                $dupOutput = (& powercfg /duplicatescheme $highPerformanceGuid 2>&1) -join "`n"
                if ($LASTEXITCODE -eq 0) {
                    $dupMatch = [regex]::Match($dupOutput, '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
                    if ($dupMatch.Success) {
                        $targetGuid = $dupMatch.Value.ToLowerInvariant()
                    }
                } else {
                    Write-Host "⚠️ [2/7] 高パフォーマンス電源プランを作成できませんでした（Modern Standby / S0ix 環境では非対応の場合があります）。スキップします。詳細: $dupOutput" -ForegroundColor Yellow
                }
            } else {
                # -WhatIf 実行時
                $targetGuid = $highPerformanceGuid
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($targetGuid)) {
            if ($PSCmdlet.ShouldProcess($targetGuid, 'powercfg /setactive で高パフォーマンス電源プランを有効化')) {
                $setResult = (& powercfg /setactive $targetGuid 2>&1) -join "`n"
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✅ [2/7] 電源プランを高パフォーマンス ($targetGuid) に切り替えました。" -ForegroundColor Green
                } else {
                    Write-Host "⚠️ [2/7] 電源プランの切り替えをスキップしました: $setResult" -ForegroundColor Yellow
                }
            }
        }
    } catch {
        Write-Host "❌ [2/7] 電源プランの切り替えに失敗しました: $_" -ForegroundColor Red
    }
}

# 3. 高速スタートアップを無効化
if ($SkipFastStartup) {
    Write-Host '⏭️ [3/7] 高速スタートアップ無効化をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        Set-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -Type 'DWord'

        if ($PSCmdlet.ShouldProcess('Hibernate', 'powercfg /hibernate off で休止状態を無効化')) {
            $hibernateResult = (& powercfg /hibernate off 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "⚠️ hibernate の無効化で警告: $hibernateResult" -ForegroundColor Yellow
            }
        }

        Write-Host '✅ [3/7] 高速スタートアップの無効化が完了しました。' -ForegroundColor Green
    } catch {
        Write-Host "❌ [3/7] 高速スタートアップの無効化に失敗しました: $_" -ForegroundColor Red
    }
}

# 4. ゲームモードを有効化
if ($SkipGameMode) {
    Write-Host '⏭️ [4/7] ゲームモード有効化をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value 1 -Type 'DWord'
        Write-Host '✅ [4/7] ゲームモード有効化が完了しました。' -ForegroundColor Green
    } catch {
        Write-Host "❌ [4/7] ゲームモードの有効化に失敗しました: $_" -ForegroundColor Red
    }
}

# 5. ウィンドウのアニメーションと透過効果を無効化
if ($SkipVisualEffects) {
    Write-Host '⏭️ [5/7] 視覚効果の無効化をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -Type 'String'
        Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0 -Type 'DWord'
        Write-Host '✅ [5/7] アニメーションと透過効果の無効化が完了しました。' -ForegroundColor Green
    } catch {
        Write-Host "❌ [5/7] アニメーションと透過効果の無効化に失敗しました: $_" -ForegroundColor Red
    }
}

# 6. OneDrive の自動起動停止（サインイン時）
if ($SkipOneDrive) {
    Write-Host '⏭️ [6/7] OneDrive 自動起動停止をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        $oneDrivePath = Get-OneDriveExecutablePath
        if ($null -ne $oneDrivePath) {
            $running = Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue
            if ($null -ne $running) {
                if ($PSCmdlet.ShouldProcess($oneDrivePath, 'OneDrive プロセスを /shutdown で終了')) {
                    Start-Process -FilePath $oneDrivePath -ArgumentList '/shutdown' -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                    Write-Host '📴 OneDrive プロセスを終了しました。' -ForegroundColor Yellow
                }
            }
        }

        $runRegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $oneDriveSnapshot = Get-RegistryValueSnapshot -Hive 'HKCU' -SubKey 'Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive'
        if ($oneDriveSnapshot.ValueExists) {
            if ($PSCmdlet.ShouldProcess("$runRegPath\OneDrive", 'OneDrive 自動起動エントリを削除')) {
                Remove-ItemProperty -Path $runRegPath -Name 'OneDrive' -Force -ErrorAction Stop
            }
            Write-Host '✅ [6/7] OneDrive 自動起動停止が完了しました。' -ForegroundColor Green
        } else {
            Write-Host '✅ [6/7] OneDrive の自動起動は既に無効化されています。' -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ [6/7] OneDrive 自動起動停止に失敗しました: $_" -ForegroundColor Red
    }
}

# 7. Windows 標準の Downloads 既知フォルダを変更
#    （ブラウザが Windows 標準の Downloads フォルダを参照している場合は連動して切り替わります）
if ($SkipDownloadsRedirect) {
    Write-Host '⏭️ [7/7] Downloads フォルダの変更をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        if ((-not $downloadsPathExplicit) -and (-not (Test-Path -Path 'D:\'))) {
            Write-Host '⚠️ [7/7] D ドライブが存在しないため、Downloads フォルダの変更をスキップしました（レジストリは変更しません）。' -ForegroundColor Yellow
        } else {
            $expandedDownloads = [Environment]::ExpandEnvironmentVariables($DownloadsPath)
            $pathRoot = [System.IO.Path]::GetPathRoot($expandedDownloads)

            if ([string]::IsNullOrWhiteSpace($pathRoot) -or (-not (Test-Path -Path $pathRoot))) {
                Write-Host "⚠️ [7/7] 指定されたドライブ/ルート ($pathRoot) が存在しないため、Downloads フォルダの変更をスキップしました。" -ForegroundColor Yellow
            } else {
                if (-not (Test-Path -Path $expandedDownloads)) {
                    if ($PSCmdlet.ShouldProcess($expandedDownloads, 'Downloads ディレクトリを作成')) {
                        New-Item -ItemType Directory -Path $expandedDownloads -Force -ErrorAction Stop | Out-Null
                        Write-Host "📁 ディレクトリを作成しました: $expandedDownloads" -ForegroundColor Green
                    }
                }

                $shellApiUpdated = $false
                try {
                    $shellApiUpdated = Set-KnownFolderDownloadPath -TargetPath $DownloadsPath
                } catch {
                    Write-Host "⚠️ SHSetKnownFolderPath の呼び出しに失敗したためレジストリ直接更新にフォールバックします: $_" -ForegroundColor Yellow
                }

                $regValueType = if ($DownloadsPath -like '*%*') { 'ExpandString' } else { 'String' }
                $userShellFoldersPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
                if (-not $shellApiUpdated -or $regValueType -eq 'ExpandString') {
                    Set-RegistryValueSafe -Path $userShellFoldersPath -Name $downloadsGuid -Value $DownloadsPath -Type $regValueType
                }

                Write-Host "✅ [7/7] Windows 標準の Downloads フォルダを $DownloadsPath に変更しました。" -ForegroundColor Cyan
            }
        }
    } catch {
        Write-Host "❌ [7/7] Downloads フォルダの変更に失敗しました: $_" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '✅ 最適化スクリプトの実行が完了しました。' -ForegroundColor Green

if ($Pause) {
    Write-Host ''
    Read-Host -Prompt '終了するには Enter キーを押してください' | Out-Null
}
