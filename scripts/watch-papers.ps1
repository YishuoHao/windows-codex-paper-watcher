param(
    [string]$Inbox = "D:\Papers\Inbox",
    [string]$CodexWorkspace = "",
    [string]$PromptFile = (
        Join-Path (Split-Path -Parent $PSScriptRoot) "config\paper-task.txt"
    ),
    [string]$StateDirectory = (
        Join-Path (Split-Path -Parent $PSScriptRoot) "runtime"
    ),
    [int]$MinimumAgeMinutes = 2,
    [int]$FallbackScanMinutes = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 defaults to a legacy encoding for native-process
# pipelines. Codex expects UTF-8 on stdin and emits UTF-8 JSONL.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom

$Inbox = [System.IO.Path]::GetFullPath($Inbox)
$PromptFile = [System.IO.Path]::GetFullPath($PromptFile)
$StateDirectory = [System.IO.Path]::GetFullPath($StateDirectory)

if ([string]::IsNullOrWhiteSpace($CodexWorkspace)) {
    $CodexWorkspace = Split-Path -Parent $Inbox
}

$CodexWorkspace = [System.IO.Path]::GetFullPath($CodexWorkspace)

if ($MinimumAgeMinutes -lt 1) {
    throw "MinimumAgeMinutes must be at least 1."
}

if ($FallbackScanMinutes -lt 1) {
    throw "FallbackScanMinutes must be at least 1."
}

$workspacePrefix = $CodexWorkspace.TrimEnd('\') + '\'

if (-not $Inbox.StartsWith(
    $workspacePrefix,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Inbox must be located inside CodexWorkspace."
}

$LogFile = Join-Path $StateDirectory "watcher.log"
$LastMessageFile = Join-Path $StateDirectory "last-result.txt"
$MinimumAge = [TimeSpan]::FromMinutes($MinimumAgeMinutes)
$FallbackScanMilliseconds = $FallbackScanMinutes * 60 * 1000

New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null

function Write-Log {
    param([string]$Message)

    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Resolve-CodexExecutable {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -ne $command) {
        return $command.Source
    }

    $binRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    $candidate = Get-ChildItem `
        -LiteralPath $binRoot `
        -Filter "codex.exe" `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "Cannot find codex.exe. Install Codex and sign in first."
    }

    return $candidate.FullName
}

function Test-FileUnlocked {
    param([string]$Path)

    $stream = $null

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-EligiblePdfs {
    $cutoff = [DateTime]::UtcNow.Subtract($MinimumAge)

    return @(
        Get-ChildItem -LiteralPath $Inbox -Filter "*.pdf" -File |
            Where-Object {
                $txtPath = [System.IO.Path]::ChangeExtension(
                    $_.FullName,
                    ".txt"
                )

                $_.LastWriteTimeUtc -le $cutoff -and
                -not (Test-Path -LiteralPath $txtPath -PathType Leaf) -and
                (Test-FileUnlocked -Path $_.FullName)
            }
    )
}

function Add-DiagnosticLine {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $compact = (($Text -replace "[\r\n]+", " ") -replace "\s{2,}", " ").Trim()

    if ($compact.Length -gt 1000) {
        $compact = $compact.Substring(0, 1000) + "..."
    }

    [void]$List.Add($compact)
}

function Invoke-CodexIfNeeded {
    $eligiblePdfs = @(Get-EligiblePdfs)

    if ($eligiblePdfs.Count -eq 0) {
        return
    }

    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        Write-Log "Failed: prompt file not found: $PromptFile"
        return
    }

    $codexExecutable = Resolve-CodexExecutable
    $basePrompt = [System.IO.File]::ReadAllText(
        $PromptFile,
        [System.Text.Encoding]::UTF8
    )
    $basePrompt = $basePrompt.Replace("{{INBOX}}", $Inbox)
    $basePrompt = $basePrompt.Replace(
        "{{MINIMUM_AGE_MINUTES}}",
        $MinimumAgeMinutes.ToString()
    )

    $fileList = (
        $eligiblePdfs |
            ForEach-Object { "- $($_.FullName)" }
    ) -join [Environment]::NewLine

    $fullPrompt = @"
$basePrompt

The local Windows preflight found these candidate PDF files:
$fileList

Recheck every safety condition from the task instructions, then process all
files that still qualify in a single run.
"@

    Write-Log "Starting Codex; preflight file count: $($eligiblePdfs.Count)"

    # --ask-for-approval is a global option, so it must appear before exec.
    # The prompt is sent through stdin (the final '-') to avoid Windows
    # PowerShell 5.1 multiline argument corruption and mojibake.
    $codexArguments = @(
        "--search"
        "--ask-for-approval"
        "never"
        "exec"
        "--json"
        "--color"
        "never"
        "-C"
        $CodexWorkspace
        "--skip-git-repo-check"
        "--sandbox"
        "workspace-write"
        "--output-last-message"
        $LastMessageFile
        "-"
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $exitCode = -1
    $diagnosticLines = New-Object System.Collections.Generic.List[string]

    try {
        # Windows PowerShell 5.1 turns native stderr into ErrorRecord objects.
        # Codex may use stderr for normal status, so Stop cannot be active here.
        $ErrorActionPreference = "Continue"

        $fullPrompt |
            & $codexExecutable @codexArguments 2>&1 |
                ForEach-Object {
                    $rawEvent = $_.ToString()
                    $event = $null

                    try {
                        $event = $rawEvent |
                            ConvertFrom-Json -ErrorAction Stop
                    }
                    catch {
                        Add-DiagnosticLine `
                            -List $diagnosticLines `
                            -Text $rawEvent
                    }

                    if (
                        $null -ne $event -and
                        $event.type -eq "item.completed" -and
                        $event.PSObject.Properties.Name -contains "item" -and
                        $event.item.PSObject.Properties.Name -contains "type" -and
                        $event.item.type -eq "agent_message" -and
                        $event.item.PSObject.Properties.Name -contains "text"
                    ) {
                        $message = [string]$event.item.text

                        if (-not [string]::IsNullOrWhiteSpace($message)) {
                            $compactMessage = (
                                ($message -replace "[\r\n]+", " ") `
                                    -replace "\s{2,}", " "
                            ).Trim()

                            Write-Log "Agent: $compactMessage"
                        }
                    }
                    elseif (
                        $null -ne $event -and
                        $event.type -in @("error", "turn.failed")
                    ) {
                        Add-DiagnosticLine `
                            -List $diagnosticLines `
                            -Text $rawEvent
                    }
                }

        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -eq 0) {
        Write-Log "Codex completed successfully."
    }
    else {
        Write-Log "Codex failed with exit code $exitCode."

        $diagnosticLines |
            Select-Object -Last 5 |
                ForEach-Object {
                    Write-Log "Diagnostic: $_"
                }
    }
}

if (-not (Test-Path -LiteralPath $Inbox -PathType Container)) {
    throw "Inbox does not exist: $Inbox"
}

if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
    throw "Prompt file does not exist: $PromptFile"
}

$mutex = New-Object System.Threading.Mutex(
    $false,
    "Local\CodexPaperInboxWatcher"
)
$ownsMutex = $false
$watcher = $null

try {
    try {
        $ownsMutex = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }

    if (-not $ownsMutex) {
        Write-Log "Another watcher is already running; this process exits."
        exit 0
    }

    $watcher = New-Object System.IO.FileSystemWatcher(
        $Inbox,
        "*.pdf"
    )
    $watcher.IncludeSubdirectories = $false
    $watcher.NotifyFilter =
        [System.IO.NotifyFilters]::FileName -bor
        [System.IO.NotifyFilters]::LastWrite -bor
        [System.IO.NotifyFilters]::Size

    Write-Log "Watcher started: $Inbox; PID=$PID"

    # Startup catch-up: handles PDFs added while the watcher was offline.
    Invoke-CodexIfNeeded

    while ($true) {
        $change = $watcher.WaitForChanged(
            [System.IO.WatcherChangeTypes]::All,
            $FallbackScanMilliseconds
        )

        if (-not $change.TimedOut) {
            Write-Log "PDF change detected: $($change.ChangeType) $($change.Name)"
            Start-Sleep -Seconds (($MinimumAgeMinutes * 60) + 10)
        }

        # A timeout performs only a local catch-up scan. Codex is not called
        # unless an eligible PDF without a same-stem TXT actually exists.
        Invoke-CodexIfNeeded
    }
}
catch {
    Write-Log "Watcher error: $($_.Exception.Message)"
    throw
}
finally {
    if ($null -ne $watcher) {
        $watcher.Dispose()
    }

    if ($ownsMutex) {
        $mutex.ReleaseMutex()
    }

    $mutex.Dispose()
    Write-Log "Watcher stopped: PID=$PID"
}
