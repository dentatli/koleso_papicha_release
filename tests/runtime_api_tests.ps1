param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$ServerPath = Join-Path $Root 'local_server.ps1'
$Base = 'http://127.0.0.1:5500'
$RuntimeDataDir = Join-Path ([System.IO.Path]::GetTempPath()) "PapichWheelRuntimeTests-$([Guid]::NewGuid().ToString('N'))"
$ServerStdOut = Join-Path $RuntimeDataDir 'server-stdout.log'
$ServerStdErr = Join-Path $RuntimeDataDir 'server-stderr.log'
$ServerProcess = $null
$PreviousLocalAppData = $env:LOCALAPPDATA

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-JsonPost {
    param(
        [string]$Path,
        [object]$Body,
        [hashtable]$Headers
    )

    return Invoke-RestMethod `
        -Uri "$Base$Path" `
        -Method Post `
        -Headers $Headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ($Body | ConvertTo-Json -Depth 20 -Compress) `
        -TimeoutSec 10
}

function Get-HttpErrorPayload {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    if ([string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) { return $null }
    try { return [string]$ErrorRecord.ErrorDetails.Message | ConvertFrom-Json }
    catch { return $null }
}

try {
    [System.IO.Directory]::CreateDirectory($RuntimeDataDir) | Out-Null
    $env:LOCALAPPDATA = $RuntimeDataDir
    $PowerShellExe = (Get-Process -Id $PID).Path
    $ServerProcess = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$ServerPath`"",
            '-ServerOnly',
            '-SkipStartupNetwork'
        ) `
        -RedirectStandardOutput $ServerStdOut `
        -RedirectStandardError $ServerStdErr `
        -PassThru

    $Ready = $false
    $Deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $Deadline -and -not $ServerProcess.HasExited) {
        try {
            $Health = Invoke-RestMethod -Uri "$Base/api/health" -TimeoutSec 1
            if ($Health.ok -and $Health.server -eq 'papich-wheel-local') {
                $Ready = $true
                break
            }
        }
        catch {}
        Start-Sleep -Milliseconds 200
    }
    if (-not $Ready) {
        $SafeError = if (Test-Path -LiteralPath $ServerStdErr) { [string](Get-Content -LiteralPath $ServerStdErr -Raw) } else { '' }
        throw "Local server did not become ready. $SafeError"
    }

    $Forbidden = 0
    try { [void](Invoke-WebRequest -UseBasicParsing -Uri "$Base/api/currency/status" -TimeoutSec 5) }
    catch { $Forbidden = [int]$_.Exception.Response.StatusCode.value__ }
    Assert-True ($Forbidden -eq 403) 'Sensitive endpoint did not reject a request without X-Local-App-Token.'

    $Html = (Invoke-WebRequest -UseBasicParsing -Uri "$Base/koleso_papich.html?view=admin" -TimeoutSec 10).Content
    $TokenMatch = [regex]::Match($Html, 'const LOCAL_APP_TOKEN = "([^"]+)";')
    Assert-True $TokenMatch.Success 'Served HTML did not contain the per-process local token.'
    $Headers = @{ 'X-Local-App-Token' = $TokenMatch.Groups[1].Value }

    $Bootstrap = Invoke-JsonPost '/api/app/bootstrap' @{ collector = $null } $Headers
    $Generation = [long]$Bootstrap.collector.llm.auctionGeneration
    Assert-True ($Bootstrap.ok -and $Generation -ge 1) 'Bootstrap did not expose a valid auction generation.'
    Assert-True (-not $Bootstrap.integrations.openrouter.configured) 'Isolated runtime unexpectedly reused OpenRouter secrets.'

    $Paused = Invoke-JsonPost '/api/collector/pause' @{} $Headers
    Assert-True $Paused.pausedPreserveCursor 'Collector pause contract failed.'
    $PauseStatus = Invoke-RestMethod -Uri "$Base/api/collector/status" -Headers $Headers -TimeoutSec 5
    Assert-True $PauseStatus.pausedPreserveCursor 'Collector status did not preserve pause state.'
    $Resumed = Invoke-JsonPost '/api/collector/resume' @{} $Headers
    Assert-True (-not $Resumed.pausedPreserveCursor) 'Collector resume contract failed.'

    $StaleStatus = 0
    $StaleBody = $null
    try {
        [void](Invoke-JsonPost '/api/llm/jobs' @{
            analysisKey = 'manual_test:runtime-stale'
            auctionGeneration = $Generation + 1
            donation = @{ id = 'runtime-stale'; source = 'manual_test'; externalId = 'runtime-stale'; amount = 1; currency = 'RUB'; message = 'test' }
            entries = @()
            settings = @{}
        } $Headers)
    }
    catch {
        $StaleStatus = [int]$_.Exception.Response.StatusCode.value__
        $StaleBody = Get-HttpErrorPayload $_
    }
    Assert-True ($StaleStatus -eq 409) 'Stale AI job generation was not rejected with HTTP 409.'
    Assert-True ($StaleBody.code -eq 'AUCTION_GENERATION_MISMATCH') 'Stale AI job response lost its stable error code.'
    Assert-True ([long]$StaleBody.currentAuctionGeneration -eq $Generation) 'Stale AI job response returned the wrong current generation.'

    $Clear = Invoke-JsonPost '/api/llm/auction/clear' @{
        donatePayCursor = 0
        clearStartedAt = [DateTimeOffset]::UtcNow.ToString('o')
    } $Headers
    Assert-True ([long]$Clear.auctionGeneration -eq ($Generation + 1)) 'New auction did not atomically increment generation.'

    $OldStatus = 0
    try {
        [void](Invoke-JsonPost '/api/llm/jobs' @{
            analysisKey = 'manual_test:runtime-old'
            auctionGeneration = $Generation
            donation = @{ id = 'runtime-old'; source = 'manual_test'; externalId = 'runtime-old'; amount = 1; currency = 'RUB'; message = 'test' }
            entries = @()
            settings = @{}
        } $Headers)
    }
    catch { $OldStatus = [int]$_.Exception.Response.StatusCode.value__ }
    Assert-True ($OldStatus -eq 409) 'Old admin generation could create an AI job after auction clear.'

    $Reset = Invoke-JsonPost '/api/app/reset' @{} $Headers
    Assert-True ($Reset.ok -and -not [string]::IsNullOrWhiteSpace([string]$Reset.resetEpoch)) 'Full reset did not publish a durable reset epoch.'
    $AfterReset = Invoke-JsonPost '/api/app/bootstrap' @{ collector = $null } $Headers
    Assert-True `
        ([string]$AfterReset.resetEpoch -eq [string]$Reset.resetEpoch) `
        'Bootstrap did not expose the completed reset epoch.'
    Assert-True ([long]$AfterReset.collector.llm.auctionGeneration -eq 1) 'Full reset did not reset AI auction storage.'
    Assert-True ([int]$AfterReset.collector.pendingServerDonations -eq 0) 'Full reset left server donations pending.'

    Write-Host 'Runtime API contract tests ok'
}
finally {
    $env:LOCALAPPDATA = $PreviousLocalAppData
    if ($ServerProcess -and -not $ServerProcess.HasExited) {
        Stop-Process -Id $ServerProcess.Id -Force -ErrorAction SilentlyContinue
        try { [void]$ServerProcess.WaitForExit(5000) } catch {}
    }
    try {
        if ([System.IO.Directory]::Exists($RuntimeDataDir)) {
            [System.IO.Directory]::Delete($RuntimeDataDir, $true)
        }
    }
    catch {}
}
