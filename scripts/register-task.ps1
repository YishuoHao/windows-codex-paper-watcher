param(
    [string]$TaskName = "Codex Paper Inbox Watcher",
    [string]$WatcherScript = (
        Join-Path $PSScriptRoot "watch-papers.ps1"
    ),
    [string]$Inbox = "D:\Papers\Inbox",
    [string]$CodexWorkspace = "",
    [string]$PromptFile = (
        Join-Path (Split-Path -Parent $PSScriptRoot) "config\paper-task.txt"
    ),
    [string]$StateDirectory = (
        Join-Path (Split-Path -Parent $PSScriptRoot) "runtime"
    ),
    [int]$MinimumAgeMinutes = 2,
    [int]$FallbackScanMinutes = 5,
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WatcherScript = [System.IO.Path]::GetFullPath($WatcherScript)
$Inbox = [System.IO.Path]::GetFullPath($Inbox)
$PromptFile = [System.IO.Path]::GetFullPath($PromptFile)
$StateDirectory = [System.IO.Path]::GetFullPath($StateDirectory)

if ([string]::IsNullOrWhiteSpace($CodexWorkspace)) {
    $CodexWorkspace = Split-Path -Parent $Inbox
}

$CodexWorkspace = [System.IO.Path]::GetFullPath($CodexWorkspace)

if (-not (Test-Path -LiteralPath $WatcherScript -PathType Leaf)) {
    throw "Watcher script not found: $WatcherScript"
}

if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
    throw "Prompt file not found: $PromptFile"
}

New-Item -ItemType Directory -Force -Path $Inbox | Out-Null
New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null

function Quote-TaskArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

$argumentParts = @(
    "-NoProfile"
    "-WindowStyle"
    "Hidden"
    "-ExecutionPolicy"
    "Bypass"
    "-File"
    (Quote-TaskArgument $WatcherScript)
    "-Inbox"
    (Quote-TaskArgument $Inbox)
    "-CodexWorkspace"
    (Quote-TaskArgument $CodexWorkspace)
    "-PromptFile"
    (Quote-TaskArgument $PromptFile)
    "-StateDirectory"
    (Quote-TaskArgument $StateDirectory)
    "-MinimumAgeMinutes"
    $MinimumAgeMinutes.ToString()
    "-FallbackScanMinutes"
    $FallbackScanMinutes.ToString()
)

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument ($argumentParts -join " ") `
    -WorkingDirectory (Split-Path -Parent $WatcherScript)

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Event-driven PDF inbox watcher that starts Codex only for eligible new papers."

Register-ScheduledTask `
    -TaskName $TaskName `
    -InputObject $task `
    -Force | Out-Null

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
}

[pscustomobject]@{
    TaskName = $TaskName
    User = $currentUser
    WatcherScript = $WatcherScript
    Inbox = $Inbox
    PromptFile = $PromptFile
    StateDirectory = $StateDirectory
    Started = [bool]$StartNow
} | Format-List
