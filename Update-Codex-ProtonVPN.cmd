@echo off
setlocal DisableDelayedExpansion
set "CODEX_PROTON_SELF=%~f0"
set "CODEX_PROTON_PREVIEW="
set "CODEX_PROTON_NOPAUSE="
set "CODEX_PROTON_COREONLY="
set "CODEX_PROTON_SETTINGSPATH="
:parse_arguments
if "%~1"=="" goto run_embedded_script
if /i "%~1"=="-Preview" (
    set "CODEX_PROTON_PREVIEW=1"
    shift
    goto parse_arguments
)
if /i "%~1"=="-NoPause" (
    set "CODEX_PROTON_NOPAUSE=1"
    shift
    goto parse_arguments
)
if /i "%~1"=="-CoreOnly" (
    set "CODEX_PROTON_COREONLY=1"
    shift
    goto parse_arguments
)
if /i "%~1"=="-SettingsPath" (
    if "%~2"=="" (
        echo Missing value for -SettingsPath.
        exit /b 2
    )
    set "CODEX_PROTON_SETTINGSPATH=%~2"
    shift
    shift
    goto parse_arguments
)
echo Unsupported argument: "%~1"
exit /b 2
:run_embedded_script
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$text=[IO.File]::ReadAllText($env:CODEX_PROTON_SELF,[Text.Encoding]::UTF8); $marker=':__CODEX_PROTON_POWERSHELL__'; $offset=$text.LastIndexOf($marker); if ($offset -lt 0) { throw 'Embedded script missing.' }; $parameters=@{}; if ($env:CODEX_PROTON_PREVIEW) { $parameters.Preview=$true }; if ($env:CODEX_PROTON_NOPAUSE) { $parameters.NoPause=$true }; if ($env:CODEX_PROTON_COREONLY) { $parameters.CoreOnly=$true }; if ($env:CODEX_PROTON_SETTINGSPATH) { $parameters.SettingsPath=$env:CODEX_PROTON_SETTINGSPATH }; & ([scriptblock]::Create($text.Substring($offset+$marker.Length))) @parameters"
exit /b %errorlevel%
:__CODEX_PROTON_POWERSHELL__
#requires -Version 5.1
<#
.SYNOPSIS
    Updates Codex executable paths in Proton VPN's included-apps JSON list.
.DESCRIPTION
    Detects running Codex executables and the installed desktop app, replaces
    outdated Codex entries, and preserves all other settings. A timestamped
    backup is created next to the settings file before every actual update.
    If running, only the current session's Proton VPN client is restarted.
.EXAMPLE
    .\Get-CodexPath.ps1
.EXAMPLE
    .\Get-CodexPath.ps1 -Preview -NoPause
#>
[CmdletBinding()]
param(
    [switch]$CoreOnly,
    [switch]$Preview,
    [switch]$NoPause,
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'

function Get-CodexExecutablePaths {
    param([switch]$CoreOnly)

    $localRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '(?i)codex|chatgpt'
    })
    foreach ($process in $processes) {
        $candidate = $process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($CoreOnly -and [IO.Path]::GetFileName($candidate) -ine 'codex.exe') { continue }
        if ($candidate -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\' -or
            $candidate.StartsWith($localRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $paths.Add($candidate) }
        }
    }

    if (-not $CoreOnly) {
        $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
            Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        if ($package) {
            foreach ($relativePath in @('app\ChatGPT.exe', 'app\Codex.exe', 'app\resources\codex.exe')) {
                $candidate = Join-Path $package.InstallLocation $relativePath
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $paths.Add($candidate) }
            }
        }
    }

    # The core may not be running yet. Use the newest installed bin directory.
    $hasCore = @($paths | Where-Object {
        $_.StartsWith($localRoot + '\bin\', [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($_) -ieq 'codex.exe'
    }).Count -gt 0
    if (-not $hasCore) {
        $binRoot = Join-Path $localRoot 'bin'
        if (Test-Path -LiteralPath $binRoot -PathType Container) {
            $core = Get-ChildItem -LiteralPath $binRoot -Directory |
                ForEach-Object {
                    $candidate = Join-Path $_.FullName 'codex.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        Get-Item -LiteralPath $candidate
                    }
                } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($core) { $paths.Add($core.FullName) }
        }
    }
    $result = @($paths | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
    if ($result.Count -eq 0) { throw '找不到 Codex 程式路徑，請先開啟 Codex 再執行。' }
    return $result
}

function Resolve-ProtonSettingsPath {
    param([string]$RequestedPath)
    if ($RequestedPath) {
        $resolved = (Resolve-Path -LiteralPath $RequestedPath).ProviderPath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw '指定的設定檔不是檔案。'
        }
        return $resolved
    }
    $storage = Join-Path $env:LOCALAPPDATA 'Proton\Proton VPN\Storage'
    $files = @(Get-ChildItem -LiteralPath $storage -Filter 'UserSettings*.json' -File)
    if ($files.Count -eq 0) { throw '找不到 Proton VPN 的 UserSettings JSON。請先登入 Proton VPN。' }
    if ($files.Count -gt 1) { throw '找到多個帳號設定檔，請使用 -SettingsPath 指定要更新的檔案。' }
    return $files[0].FullName
}

function Test-CodexAppEntry {
    param($Entry)
    # Older manually edited entries may contain repeated path separators.
    $allPaths = @($Entry.AppFilePath)
    foreach ($appPath in $allPaths) {
        $normalized = ([string]$appPath) -replace '\\{2,}', '\'
        if ($normalized -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\' -or
            $normalized -match '(?i)\\AppData\\Local\\OpenAI\\Codex\\') {
            return $true
        }
    }
    return $false
}

function New-ProtonSettingsUpdate {
    param([string]$OriginalText, [string[]]$ExecutablePaths)
    if (-not $OriginalText.TrimStart().StartsWith('{')) {
        throw '設定檔的最外層必須是 JSON 物件。'
    }
    $settings = ConvertFrom-Json -InputObject $OriginalText
    if ($settings -isnot [pscustomobject]) {
        throw '設定檔的最外層必須是 JSON 物件。'
    }
    $key = 'SplitTunnelingInverseAppsList'
    $oldListText = $settings.$key
    $oldApps = @()
    if ($null -ne $oldListText -and -not [string]::IsNullOrWhiteSpace([string]$oldListText)) {
        if ($oldListText -isnot [string] -or -not $oldListText.TrimStart().StartsWith('[')) {
            throw '包含清單格式不正確：必須是儲存 JSON 陣列的字串。'
        }
        $decodedApps = ConvertFrom-Json -InputObject $oldListText
        $oldApps = @($decodedApps)
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $removed = 0
    foreach ($entry in $oldApps) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.AppFilePath)) {
            throw '包含清單有無效項目，已停止以避免遺失資料。'
        }
        if (Test-CodexAppEntry -Entry $entry) { $removed++; continue }
        $entries.Add($entry)
    }
    foreach ($exePath in @($ExecutablePaths | Sort-Object -Unique)) {
        if (-not [IO.Path]::IsPathRooted($exePath) -or [IO.Path]::GetExtension($exePath) -ine '.exe') {
            throw ('無效的程式路徑：' + $exePath)
        }
        $entries.Add([pscustomobject][ordered]@{
            AppFilePath = $exePath
            AlternateAppFilePaths = @()
            IsActive = $true
        })
    }
    if ($ExecutablePaths.Count -eq 0) { throw '程式清單為空，已停止修改。' }
    $newListText = ConvertTo-Json -InputObject @($entries.ToArray()) -Depth 50 -Compress
    $oldCanonical = ConvertTo-Json -InputObject @($oldApps) -Depth 50 -Compress
    $changed = $oldCanonical -cne $newListText
    if ($settings.PSObject.Properties.Name -contains $key) {
        $settings.$key = $newListText
    } else {
        $settings | Add-Member -NotePropertyName $key -NotePropertyValue $newListText
    }
    $outputText = ConvertTo-Json -InputObject $settings -Depth 100
    # Verify both layers of JSON before writing anything.
    $roundTrip = ConvertFrom-Json -InputObject $outputText
    $decodedVerifiedApps = ConvertFrom-Json -InputObject $roundTrip.$key
    $verifiedApps = @($decodedVerifiedApps)
    if ($verifiedApps.Count -ne $entries.Count) { throw 'JSON 驗證失敗，未修改檔案。' }
    return [pscustomobject]@{
        OriginalText = $OriginalText
        UpdatedText = $outputText + [Environment]::NewLine
        Changed = $changed
        RemovedCount = $removed
        Entries = @($entries.ToArray())
        Mode = $settings.SplitTunnelingMode
        Enabled = $settings.IsSplitTunnelingEnabled
    }
}

function Write-ProtonSettingsUpdate {
    param([string]$Path, $Update)
    if (-not $Update.Changed) { return $null }
    $currentText = [IO.File]::ReadAllText($Path)
    if ($currentText -cne $Update.OriginalText) {
        throw '設定檔已被其他程式更新，未寫入。請再執行一次。'
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupPath = $Path + '.bak-' + $stamp + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $tempPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tempPath, $Update.UpdatedText, (New-Object Text.UTF8Encoding($false)))
        # Same-directory atomic replacement also backs up the exact original bytes.
        [IO.File]::Replace($tempPath, $Path, $backupPath)
        $writtenText = [IO.File]::ReadAllText($Path)
        if ($writtenText -cne $Update.UpdatedText) { throw '寫入後內容驗證失敗。' }
        return $backupPath
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

$protonRestartPath = $null
$restartNeeded = $false
$scriptFailed = $false
try {
    $exePaths = @(Get-CodexExecutablePaths -CoreOnly:$CoreOnly)
    $targetPath = Resolve-ProtonSettingsPath -RequestedPath $SettingsPath
    $update = New-ProtonSettingsUpdate -OriginalText ([IO.File]::ReadAllText($targetPath)) -ExecutablePaths $exePaths
    Write-Host '偵測到的 Codex 程式：' -ForegroundColor Cyan
    foreach ($exePath in $exePaths) { Write-Host ('  ' + $exePath) }
    Write-Host ('設定檔：' + $targetPath)
    if ($Preview) {
        Write-Host '預覽完成，未修改設定，也未重新啟動 Proton VPN。' -ForegroundColor Yellow
    }
    elseif (-not $update.Changed) {
        Write-Host '包含清單已是目前版本，不需要修改。' -ForegroundColor Green
    }
    else {
        $currentSession = (Get-Process -Id $PID).SessionId
        $protonClients = @(Get-Process -Name 'ProtonVPN.Client' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $currentSession })
        if ($protonClients.Count -gt 0) {
            $protonRestartPath = $protonClients[0].Path
            if ([string]::IsNullOrWhiteSpace($protonRestartPath) -or
                -not (Test-Path -LiteralPath $protonRestartPath -PathType Leaf)) {
                throw '無法取得 Proton VPN 的重新啟動路徑，未修改設定。'
            }
            Write-Host '正在關閉 Proton VPN 介面，以避免舊設定覆蓋新清單……' -ForegroundColor Yellow
            $restartNeeded = $true
            foreach ($client in $protonClients) {
                Stop-Process -Id $client.Id -Force
                if (-not $client.WaitForExit(10000)) { throw 'Proton VPN 介面未能關閉，未修改設定。' }
            }
        }
        # Re-read after closing the client so any last settings changes are preserved.
        $update = New-ProtonSettingsUpdate -OriginalText ([IO.File]::ReadAllText($targetPath)) -ExecutablePaths $exePaths
        $backup = Write-ProtonSettingsUpdate -Path $targetPath -Update $update
        Write-Host ('已更新包含清單，共加入 ' + $exePaths.Count + ' 個 Codex 程式。') -ForegroundColor Green
        if ($backup) { Write-Host ('原始設定備份：' + $backup) }
        Write-Host ('分隔通道開關：' + $update.Enabled + '；模式：' + $update.Mode)
        Write-Host '若要立即套用新清單，請在 Proton VPN 重新連線。'
    }
}
catch {
    $scriptFailed = $true
    Write-Host ('更新失敗：' + $_.Exception.Message) -ForegroundColor Red
}
finally {
    if ($restartNeeded -and $protonRestartPath) {
        try {
            if (-not (Get-Process -Name 'ProtonVPN.Client' -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -eq $currentSession })) {
                Start-Process -FilePath $protonRestartPath -WorkingDirectory (Split-Path -Parent $protonRestartPath) -WindowStyle Hidden | Out-Null
            }
            Write-Host '已重新開啟 Proton VPN 介面。'
        }
        catch {
            $scriptFailed = $true
            Write-Host ('請手動開啟 Proton VPN：' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if (-not $NoPause) { [void](Read-Host '按 Enter 關閉') }
}
if ($scriptFailed) { exit 1 }
