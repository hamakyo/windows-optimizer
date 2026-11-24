#Requires -RunAsAdministrator
<#
.SYNOPSIS
    最適化スクリプトの変更を元に戻す復元スクリプト（管理者権限必須）。
.DESCRIPTION
    optimize.ps1 が保存したバックアップ JSON を読み込み、変更前の設定とレジストリ型を復元します。
    バックアップが存在しない場合は警告を表示し、安全な既定値へフォールバック復元します。
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
    [string]$BackupPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'windows-optimizer\backup.json'),
    [switch]$Pause
)

Set-StrictMode -Version Latest

$downloadsGuid = '{374DE290-123F-4565-9164-39C4925E467B}'
$balancedPlanGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
$defaultDownloadsRaw = '%USERPROFILE%\Downloads'

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

function Remove-RegistryValueSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -Path $Path)) {
        return
    }

    $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if ($PSCmdlet.ShouldProcess("$Path\$Name", '変更前に存在しなかったレジストリ値を削除')) {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop
        }
    }
}

function Restore-RegistryValueFromSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [psobject]$Entry,

        [Parameter(Mandatory = $true)]
        [ValidateSet('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')]
        [string]$FallbackType
    )

    if ($Entry.ValueExists) {
        $kind = if (-not [string]::IsNullOrWhiteSpace([string]$Entry.Kind)) {
            [string]$Entry.Kind
        } else {
            $FallbackType
        }
        Set-RegistryValueSafe -Path $Path -Name $Name -Value $Entry.Value -Type $kind
    } else {
        Remove-RegistryValueSafe -Path $Path -Name $Name
    }
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

    if ($PSCmdlet.ShouldProcess($expandedTarget, 'SHSetKnownFolderPath で Windows Downloads 既知フォルダを復元')) {
        $hr = [WindowsOptimizer.KnownFolderNative]::SHSetKnownFolderPath($folderGuid, 0, [IntPtr]::Zero, $expandedTarget)
        return ($hr -eq 0)
    }

    return $true
}

Write-Host '========================================' -ForegroundColor Yellow
Write-Host 'Windows 復元スクリプトを実行します' -ForegroundColor Yellow
Write-Host '========================================' -ForegroundColor Yellow

$backup = $null
if (Test-Path -Path $BackupPath) {
    try {
        $rawJson = Get-Content -Path $BackupPath -Raw -Encoding UTF8 -ErrorAction Stop
        $backup = $rawJson | ConvertFrom-Json -ErrorAction Stop
        Write-Host "📂 バックアップを読み込みました: $BackupPath" -ForegroundColor Cyan
    } catch {
        Write-Host "⚠️ バックアップの読み込みに失敗しました ($BackupPath)。既定値へフォールバックします: $_" -ForegroundColor Yellow
        $backup = $null
    }
} else {
    Write-Host "⚠️ バックアップが見つかりません ($BackupPath)。安全な既定値へフォールバック復元します。" -ForegroundColor Yellow
}

# 1. 固定キー設定の復元
if ($SkipStickyKeys) {
    Write-Host '⏭️ [1/7] 固定キー設定の復元をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        if ($null -ne $backup -and $null -ne $backup.StickyKeys) {
            Restore-RegistryValueFromSnapshot -Path 'HKCU:\Control Panel\Accessibility\StickyKeys' -Name 'Flags' -Entry $backup.StickyKeys.StickyKeys -FallbackType 'String'
            Restore-RegistryValueFromSnapshot -Path 'HKCU:\Control Panel\Accessibility\Keyboard Response' -Name 'Flags' -Entry $backup.StickyKeys.KeyboardResponse -FallbackType 'String'
            Restore-RegistryValueFromSnapshot -Path 'HKCU:\Control Panel\Accessibility\ToggleKeys' -Name 'Flags' -Entry $backup.StickyKeys.ToggleKeys -FallbackType 'String'
            Write-Host '✅ [1/7] 固定キー設定をバックアップから復元しました。' -ForegroundColor Green
        } else {
            Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Accessibility\StickyKeys' -Name 'Flags' -Value '510' -Type 'String'
            Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Accessibility\Keyboard Response' -Name 'Flags' -Value '126' -Type 'String'
            Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Accessibility\ToggleKeys' -Name 'Flags' -Value '62' -Type 'String'
            Write-Host '✅ [1/7] 固定キー設定を既定値に戻しました。' -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ [1/7] 固定キー設定の復元に失敗しました: $_" -ForegroundColor Red
    }
}

# 2. 電源プランの復元
if ($SkipPowerPlan) {
    Write-Host '⏭️ [2/7] 電源プランの復元をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        $restoredGuid = $null
        if ($null -ne $backup -and $null -ne $backup.PowerPlan -and (-not [string]::IsNullOrWhiteSpace([string]$backup.PowerPlan.ActiveSchemeGuid))) {
            $restoredGuid = [string]$backup.PowerPlan.ActiveSchemeGuid
        }

        if ($null -ne $restoredGuid) {
            if ($PSCmdlet.ShouldProcess($restoredGuid, 'powercfg /setactive でバックアップ時の電源プランを復元')) {
                $res = (& powercfg /setactive $restoredGuid 2>&1) -join "`n"
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✅ [2/7] 電源プランをバックアップ時の状態 ($restoredGuid) に復元しました。" -ForegroundColor Green
                } else {
                    Write-Host "⚠️ バックアップ時の電源プラン ($restoredGuid) を有効化できませんでした ($res)。バランスへフォールバックします。" -ForegroundColor Yellow
                    $fallbackRes = (& powercfg /setactive $balancedPlanGuid 2>&1) -join "`n"
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host '✅ [2/7] 電源プランをバランスに戻しました。' -ForegroundColor Green
                    } else {
                        Write-Host "⚠️ [2/7] 電源プランの復元に失敗しました: $fallbackRes" -ForegroundColor Yellow
                    }
                }
            }
        } else {
            if ($PSCmdlet.ShouldProcess($balancedPlanGuid, 'powercfg /setactive でバランス電源プランを設定')) {
                $res = (& powercfg /setactive $balancedPlanGuid 2>&1) -join "`n"
                if ($LASTEXITCODE -eq 0) {
                    Write-Host '✅ [2/7] 電源プランをバランスに戻しました。' -ForegroundColor Green
                } else {
                    Write-Host "⚠️ [2/7] 電源プランの変更で警告: $res" -ForegroundColor Yellow
                }
            }
        }
    } catch {
        Write-Host "❌ [2/7] 電源プランの復元に失敗しました: $_" -ForegroundColor Red
    }
}

# 3. 高速スタートアップ / 休止状態の復元
if ($SkipFastStartup) {
    Write-Host '⏭️ [3/7] 高速スタートアップの復元をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        if ($null -ne $backup -and $null -ne $backup.FastStartup) {
            $hibEntry = $backup.FastStartup.HibernateEnabled
            if ($null -ne $hibEntry -and $hibEntry.ValueExists) {
                $hibAction = if ([int]$hibEntry.Value -eq 1) { 'on' } else { 'off' }
                if ($PSCmdlet.ShouldProcess('Hibernate', "powercfg /hibernate $hibAction で休止状態を復元")) {
                    $hibRes = (& powercfg /hibernate $hibAction 2>&1) -join "`n"
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "⚠️ hibernate ($hibAction) の復元で警告: $hibRes" -ForegroundColor Yellow
                    }
                }
            }

            if ($null -ne $backup.FastStartup.HiberbootEnabled) {
                Restore-RegistryValueFromSnapshot -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Entry $backup.FastStartup.HiberbootEnabled -FallbackType 'DWord'
            }
            Write-Host '✅ [3/7] 高速スタートアップ設定をバックアップから復元しました。' -ForegroundColor Green
        } else {
            if ($PSCmdlet.ShouldProcess('Hibernate', 'powercfg /hibernate on で休止状態を有効化')) {
                $hibRes = (& powercfg /hibernate on 2>&1) -join "`n"
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "⚠️ hibernate の有効化で警告: $hibRes" -ForegroundColor Yellow
                }
            }
            Set-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 1 -Type 'DWord'
            Write-Host '✅ [3/7] 高速スタートアップを既定値（有効）に戻しました。' -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ [3/7] 高速スタートアップの復元に失敗しました: $_" -ForegroundColor Red
    }
}

# 4. ゲームモードの復元
if ($SkipGameMode) {
    Write-Host '⏭️ [4/7] ゲームモードの復元をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        if ($null -ne $backup -and $null -ne $backup.GameMode -and $null -ne $backup.GameMode.AllowAutoGameMode) {
            Restore-RegistryValueFromSnapshot -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Entry $backup.GameMode.AllowAutoGameMode -FallbackType 'DWord'
            Write-Host '✅ [4/7] ゲームモードをバックアップから復元しました。' -ForegroundColor Green
        } else {
            Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value 0 -Type 'DWord'
            Write-Host '✅ [4/7] ゲームモードを既定値に戻しました。' -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ [4/7] ゲームモードの復元に失敗しました: $_" -ForegroundColor Red
    }
}

# 5. 視覚効果（アニメーション・透過効果）の復元
if ($SkipVisualEffects) {
    Write-Host '⏭️ [5/7] 視覚効果の復元をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        if ($null -ne $backup -and $null -ne $backup.VisualEffects) {
            Restore-RegistryValueFromSnapshot -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Entry $backup.VisualEffects.MinAnimate -FallbackType 'String'
            Restore-RegistryValueFromSnapshot -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Entry $backup.VisualEffects.EnableTransparency -FallbackType 'DWord'
            Write-Host '✅ [5/7] 視覚効果をバックアップから復元しました。' -ForegroundColor Green
        } else {
            Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '1' -Type 'String'
            Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 1 -Type 'DWord'
            Write-Host '✅ [5/7] アニメーションと透過効果を既定値（有効）に戻しました。' -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ [5/7] 視覚効果の復元に失敗しました: $_" -ForegroundColor Red
    }
}

# 6. OneDrive 自動起動の復元
if ($SkipOneDrive) {
    Write-Host '⏭️ [6/7] OneDrive 自動起動の復元をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        $runRegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if ($null -ne $backup -and $null -ne $backup.OneDrive -and $null -ne $backup.OneDrive.RunOneDrive) {
            Restore-RegistryValueFromSnapshot -Path $runRegPath -Name 'OneDrive' -Entry $backup.OneDrive.RunOneDrive -FallbackType 'String'
            Write-Host '✅ [6/7] OneDrive 自動起動設定をバックアップから復元しました。' -ForegroundColor Green
        } else {
            $oneDrivePath = Get-OneDriveExecutablePath
            if ($null -ne $oneDrivePath) {
                $commandValue = "`"$oneDrivePath`" /background"
                Set-RegistryValueSafe -Path $runRegPath -Name 'OneDrive' -Value $commandValue -Type 'String'
                Write-Host '✅ [6/7] OneDrive 自動起動を /background 付きで有効化しました。' -ForegroundColor Green
            } else {
                Write-Host '⚠️ [6/7] OneDrive が見つかりません。必要に応じて手動で自動起動を設定してください。' -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "❌ [6/7] OneDrive 自動起動の復元に失敗しました: $_" -ForegroundColor Red
    }
}

# 7. Windows 標準の Downloads 既知フォルダを復元
if ($SkipDownloadsRedirect) {
    Write-Host '⏭️ [7/7] Downloads フォルダの復元をスキップしました。' -ForegroundColor DarkGray
} else {
    try {
        $userShellFoldersPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $targetRawValue = $defaultDownloadsRaw
        $targetKind = 'ExpandString'
        $shouldRemoveValue = $false

        if ($null -ne $backup -and $null -ne $backup.Downloads -and $null -ne $backup.Downloads.UserShellFolders) {
            $dlEntry = $backup.Downloads.UserShellFolders
            if ($dlEntry.ValueExists -and (-not [string]::IsNullOrWhiteSpace([string]$dlEntry.Value))) {
                $targetRawValue = [string]$dlEntry.Value
                $targetKind = if (-not [string]::IsNullOrWhiteSpace([string]$dlEntry.Kind)) {
                    [string]$dlEntry.Kind
                } else {
                    'ExpandString'
                }
            } elseif (-not $dlEntry.ValueExists) {
                $shouldRemoveValue = $true
            }
        }

        if ($shouldRemoveValue) {
            Remove-RegistryValueSafe -Path $userShellFoldersPath -Name $downloadsGuid
            Write-Host '✅ [7/7] Downloads フォルダのレジストリ設定をバックアップ時の状態（未設定）に戻しました。' -ForegroundColor Cyan
        } else {
            $expandedPath = [Environment]::ExpandEnvironmentVariables($targetRawValue)
            if (-not (Test-Path -Path $expandedPath)) {
                if ($PSCmdlet.ShouldProcess($expandedPath, 'Downloads ディレクトリを作成')) {
                    New-Item -ItemType Directory -Path $expandedPath -Force -ErrorAction Stop | Out-Null
                }
            }

            try {
                Set-KnownFolderDownloadPath -TargetPath $targetRawValue | Out-Null
            } catch {
                Write-Host "⚠️ SHSetKnownFolderPath の呼び出しに失敗したためレジストリ直接復元を続行します: $_" -ForegroundColor Yellow
            }

            # REG_EXPAND_SZ (%USERPROFILE%\Downloads 等) を確実に保持するため明示的に書き戻す
            Set-RegistryValueSafe -Path $userShellFoldersPath -Name $downloadsGuid -Value $targetRawValue -Type $targetKind
            Write-Host "✅ [7/7] Downloads フォルダを復元しました ($targetRawValue, $targetKind)。" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "❌ [7/7] Downloads フォルダの復元に失敗しました: $_" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '💡 変更を確実に反映させるため、エクスプローラーの再起動または Windows の再起動をお勧めします。' -ForegroundColor Yellow
Write-Host '✅ 復元スクリプトの実行が完了しました。' -ForegroundColor Green

if ($Pause) {
    Write-Host ''
    Read-Host -Prompt '終了するには Enter キーを押してください' | Out-Null
}
