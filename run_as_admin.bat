@echo off
setlocal
rem Launch optimize.ps1 with Administrator privileges and pause before closing.

set "scriptPath=%~dp0optimize.ps1"
set "extraArgs=%*"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q = [char]34; $argList = '-NoProfile -ExecutionPolicy Bypass -File ' + $q + $env:scriptPath + $q; if ($env:extraArgs -notmatch '(?i)(?:^|\s)-Pause(?:\s|$)') { $argList += ' -Pause' }; if (-not [string]::IsNullOrWhiteSpace($env:extraArgs)) { $argList += ' ' + $env:extraArgs }; Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs"

endlocal
