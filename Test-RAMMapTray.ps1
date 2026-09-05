# RAMMapTray self-check: does not start the tray app or execute cleanup.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root 'RAMMapTray.ps1'
$configPath = Join-Path $root 'rammap_tray_config.json'

$errors = @()
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) { $errors += "PowerShell syntax error: $($parseErrors[0].Message)" }

try {
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in @('intervalMinutes','checkIntervalMinutes','memThresholdPercent','skipBelowPercent')) {
        if ($null -eq $config.$key -or -not ($config.$key -is [int] -or $config.$key -is [long])) {
            $errors += "Missing numeric config field: $key"
        }
    }
    if ($config.rammapDir) {
        $rammapDir = [Environment]::ExpandEnvironmentVariables([string]$config.rammapDir)
        $rammapExe = @((Join-Path $rammapDir 'RAMMap64.exe'), (Join-Path $rammapDir 'RAMMap.exe')) |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $rammapExe) { $errors += "No RAMMap executable found: $rammapDir" }
    }
} catch { $errors += "Cannot read config JSON: $($_.Exception.Message)" }

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output 'RAMMapTray self-check passed.'
Write-Output "Script: $scriptPath"
Write-Output "Config: $configPath"
if ($rammapExe) { Write-Output "RAMMap: $rammapExe" }
