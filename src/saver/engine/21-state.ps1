$tracked = @{}
$script:observationBusy = $false
$script:observationCursor = 0
$dashboardIssues = @{}
$trimCount = 0
$cpuThreads = [Math]::Max(1, [int][Environment]::ProcessorCount)
$warnings = @{}
$clock = [Diagnostics.Stopwatch]::StartNew()
$nextStatus = 0.0
$maxBytes = [uint64]$MaxRamMB * 1MB
# HARDWS_MIN_DISABLE (2), HARDWS_MAX_ENABLE (4) / DISABLE (8).
$limitFlags = [uint32]6
if ($SoftLimit) { $limitFlags = [uint32]10 }

$sessionStart = Get-Date
$sessionTag = $sessionStart.ToString('yyyyMMdd-HHmmss') + '-' + $PID
$logWriter = $null
$logPath = ''
$logPart = 0
$logFailed = $false
# A failed log write pauses logging this long, then a new part is opened (see Write-Diagnostic).
$LogRetrySec = 5; $logRetryUtc = $null; $logFailureCount = 0
$nextLogSample = 0.0
$nextEventCheck = 0.0
$seenEventIds = @{}
$systemMemory = $null
$pagefileStatus = $null
$nextPagefileCheck = 0.0
$updateAvailableStatus = $null
$nextUpdateCheck = 15.0
$updateCheckInterval = 1800.0
$nextHealthSample = 0.0
$nextVoltCheck = 0.0
$nextNativeCheck = 0.0
$voltStatus = [pscustomobject]@{ safeToRecycle = $false; reason = 'Not checked' }
$voltParents = @{}
$voltPath = Join-Path $env:LOCALAPPDATA 'Volt\tauri-app.exe'
$lastGlobalTrim = -1e6
$recoveryAttempts = @()
$recoveryStatePath = Join-Path $DataDirectory 'recovery-state.json'
$recoveryJournalHealthy = $false # Initialized only while owning the controller lock.
$recoveryJournalCorrupt = $false
$recoveryPending = @{}; $suspendedAccounts = @{}; $launchAttempts = @()
$sessionObservedAccounts = @{}
$saverSessionStartEpochMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$voltControlStatus = [pscustomobject]@{available=$false;accounts=@();relaunchDelayMs=0}
$voltControlCheckedUtc = [datetime]::MinValue
$nextOutcomeCheck = 0.0; $nextPolicyCheck = 0.0; $nextRuntimeHeartbeat = 0.0
$quarantinedAccounts = @{}; $pendingLiveSettings = $null; $lastTotals = $null; $trimPlan = $null
$trimNowSignalPath = Join-Path $DataDirectory 'trim-now.signal'
try { $totalPhysicalMB = [math]::Round([double](Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory -OperationTimeoutSec 5 -ErrorAction Stop).TotalPhysicalMemory / 1MB, 1) }
catch { $totalPhysicalMB = 0 } # Adaptive trimming then keeps the configured interval.
$controllerStartTicks = ([Diagnostics.Process]::GetCurrentProcess()).StartTime.ToUniversalTime().Ticks
if (-not $StopFile -and -not $MonitorOnly) { $StopFile = Join-Path $DataDirectory 'controller.stop' }
$controllerMutex = $null
$ownsControllerMutex = $false

