<#
.SYNOPSIS
    CI およびローカル検証用のスクリプトチェックを実行します。
.DESCRIPTION
    UTF-8 BOM / CRLF、ASCII 安全性、PowerShell AST 構文解析、必須メタデータ、
    および -WhatIf 実行を検証します。
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$failures = New-Object -TypeName 'System.Collections.Generic.List[string]'

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

# 1. PowerShell scripts: UTF-8 BOM + CRLF + AST parse
$ps1Files = Get-ChildItem -Path $repoRoot -Filter '*.ps1' -Recurse -File
Assert-Condition -Condition ($ps1Files.Count -ge 2) -Message 'At least 2 .ps1 files exist in repository'

foreach ($file in $ps1Files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
    Assert-Condition -Condition $hasBom -Message "$($file.Name) has UTF-8 BOM"

    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    $hasBareLf = [regex]::IsMatch($text, '(?<!\r)\n')
    $hasCrLf = $text.Contains("`r`n")
    Assert-Condition -Condition ($hasCrLf -and (-not $hasBareLf)) -Message "$($file.Name) uses CRLF line endings exclusively"

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-Condition -Condition ($parseErrors.Count -eq 0) -Message "$($file.Name) parses without AST errors (errors: $($parseErrors.Count))"

    if ($file.Name -in @('optimize.ps1', 'restore.ps1')) {
        $requiresAdmin = ($null -ne $ast.ScriptRequirements) -and $ast.ScriptRequirements.IsElevationRequired
        Assert-Condition -Condition $requiresAdmin -Message "$($file.Name) declares #Requires -RunAsAdministrator"

        $hasShouldProcess = $false
        if ($null -ne $ast.ParamBlock) {
            foreach ($attr in $ast.ParamBlock.Attributes) {
                if ($attr.TypeName.Name -eq 'CmdletBinding') {
                    foreach ($namedArg in $attr.NamedArguments) {
                        if ($namedArg.ArgumentName -eq 'SupportsShouldProcess') {
                            $hasShouldProcess = $true
                        }
                    }
                }
            }
        }
        Assert-Condition -Condition $hasShouldProcess -Message "$($file.Name) declares [CmdletBinding(SupportsShouldProcess = `$true)]"

        $paramNames = @()
        if ($null -ne $ast.ParamBlock) {
            $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }

        $requiredParams = @(
            'SkipStickyKeys',
            'SkipPowerPlan',
            'SkipFastStartup',
            'SkipGameMode',
            'SkipVisualEffects',
            'SkipOneDrive',
            'SkipDownloadsRedirect',
            'BackupPath',
            'Pause'
        )
        if ($file.Name -eq 'optimize.ps1') {
            $requiredParams += @('DownloadsPath', 'ForceBackup')
        }

        foreach ($p in $requiredParams) {
            Assert-Condition -Condition ($paramNames -contains $p) -Message "$($file.Name) exposes -$p parameter"
        }

        $hasDoubleBackslashHive = [regex]::IsMatch($text, 'HK(?:CU|LM):\\\\')
        Assert-Condition -Condition (-not $hasDoubleBackslashHive) -Message "$($file.Name) has no redundant HKCU:\\ or HKLM:\\ double backslashes"
    }
}

# 2. Batch files: CRLF + ASCII-only + safe quoting + -Pause
$batFiles = Get-ChildItem -Path $repoRoot -Filter '*.bat' -File
Assert-Condition -Condition ($batFiles.Count -eq 2) -Message 'Both admin wrapper .bat files exist'

foreach ($bat in $batFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($bat.FullName)
    $isAscii = $true
    foreach ($b in $bytes) {
        if ($b -ge 0x80) {
            $isAscii = $false
            break
        }
    }
    Assert-Condition -Condition $isAscii -Message "$($bat.Name) contains ASCII-only characters"

    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $hasBareLf = [regex]::IsMatch($text, '(?<!\r)\n')
    $hasCrLf = $text.Contains("`r`n")
    Assert-Condition -Condition ($hasCrLf -and (-not $hasBareLf)) -Message "$($bat.Name) uses CRLF line endings exclusively"

    $hasBrokenEscape = $text.Contains('\\"')
    Assert-Condition -Condition (-not $hasBrokenEscape) -Message "$($bat.Name) does not contain broken double-escaping"

    $hasSafeSet = $text -match 'set "scriptPath=%~dp0(optimize|restore)\.ps1"'
    Assert-Condition -Condition $hasSafeSet -Message "$($bat.Name) uses quoted set scriptPath assignment"

    $passesPause = $text -match '-Pause'
    Assert-Condition -Condition $passesPause -Message "$($bat.Name) passes -Pause for interactive runs"
}

# 3. Runtime -WhatIf smoke tests (when running elevated on Windows)
$isWindowsHost = ($env:OS -eq 'Windows_NT')
if ($isWindowsHost) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName 'Security.Principal.WindowsPrincipal' -ArgumentList $identity
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        $tempBackup = Join-Path -Path $env:TEMP -ChildPath ("wo-ci-backup-" + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            & (Join-Path -Path $repoRoot -ChildPath 'optimize.ps1') -WhatIf -BackupPath $tempBackup
            Assert-Condition -Condition (-not (Test-Path -Path $tempBackup)) -Message 'optimize.ps1 -WhatIf does not create backup file'

            & (Join-Path -Path $repoRoot -ChildPath 'restore.ps1') -WhatIf -BackupPath $tempBackup
            Assert-Condition -Condition $true -Message 'restore.ps1 -WhatIf (fallback mode) completed without error'

            $syntheticBackup = [ordered]@{
                SchemaVersion = 1
                CapturedAt    = (Get-Date).ToString('o')
                StickyKeys    = [ordered]@{
                    StickyKeys       = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = '510'; Kind = 'String' }
                    KeyboardResponse = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = '126'; Kind = 'String' }
                    ToggleKeys       = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = '62'; Kind = 'String' }
                }
                PowerPlan     = [ordered]@{
                    ActiveSchemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
                }
                FastStartup   = [ordered]@{
                    HiberbootEnabled = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = 1; Kind = 'DWord' }
                    HibernateEnabled = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = 1; Kind = 'DWord' }
                }
                GameMode      = [ordered]@{
                    AllowAutoGameMode = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = 0; Kind = 'DWord' }
                }
                VisualEffects = [ordered]@{
                    MinAnimate         = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = '1'; Kind = 'String' }
                    EnableTransparency = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = 1; Kind = 'DWord' }
                }
                OneDrive      = [ordered]@{
                    RunOneDrive = [ordered]@{ KeyExists = $true; ValueExists = $false; Value = $null; Kind = $null }
                }
                Downloads     = [ordered]@{
                    UserShellFolders = [ordered]@{ KeyExists = $true; ValueExists = $true; Value = '%USERPROFILE%\Downloads'; Kind = 'ExpandString' }
                }
            } | ConvertTo-Json -Depth 6

            Set-Content -Path $tempBackup -Value $syntheticBackup -Encoding UTF8
            & (Join-Path -Path $repoRoot -ChildPath 'restore.ps1') -WhatIf -BackupPath $tempBackup
            Assert-Condition -Condition $true -Message 'restore.ps1 -WhatIf (backup snapshot mode) completed without error'
        } finally {
            if (Test-Path -Path $tempBackup) {
                Remove-Item -Path $tempBackup -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host 'INFO: Skipping elevated -WhatIf execution test (not running as Administrator).' -ForegroundColor Yellow
    }
}

if ($failures.Count -gt 0) {
    throw "Verification failed with $($failures.Count) error(s):`n - " + ($failures -join "`n - ")
}

Write-Host 'All verification checks passed!' -ForegroundColor Green
