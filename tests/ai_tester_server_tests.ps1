param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$TesterRoot = Join-Path $Root 'tools\ai_tester'
$ServerPath = Join-Path $TesterRoot 'ai_tester_server.ps1'
$BatPath = Join-Path $TesterRoot 'start_ai_tester.bat'
$Base = 'http://127.0.0.1:5501'
$RuntimeDataDir = Join-Path ([System.IO.Path]::GetTempPath()) "PapichWheelAiTester-$([Guid]::NewGuid().ToString('N'))"
$StdOut = Join-Path $RuntimeDataDir 'stdout.log'
$StdErr = Join-Path $RuntimeDataDir 'stderr.log'
$Process = $null
$PreviousLocalAppData = $env:LOCALAPPDATA

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-HttpStatus {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode.value__ } catch { return 0 }
}

try {
    $Tokens = $null
    $Errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($ServerPath, [ref]$Tokens, [ref]$Errors)
    Assert-True ($Errors.Count -eq 0) "AI tester server has PowerShell parse errors: $($Errors | ForEach-Object Message)"

    $Bat = [System.IO.File]::ReadAllText($BatPath, [System.Text.Encoding]::UTF8)
    Assert-True $Bat.Contains('%~dp0ai_tester_server.ps1') 'Starter does not support paths with spaces via %~dp0.'
    Assert-True $Bat.Contains('-NoProfile') 'Starter does not isolate the PowerShell profile.'

    [System.IO.Directory]::CreateDirectory($RuntimeDataDir) | Out-Null
    $env:LOCALAPPDATA = $RuntimeDataDir
    $PowerShellExe = (Get-Process -Id $PID).Path

    & $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ServerPath -SelfTest
    Assert-True ($LASTEXITCODE -eq 0) 'AI tester server self-test failed.'

    try {
        $Existing = Invoke-RestMethod -Uri "$Base/api/health" -TimeoutSec 1
        if ($Existing.server -eq 'papich-wheel-ai-tester') { throw 'Port 5501 is already occupied by another AI tester process.' }
        throw 'Port 5501 is already occupied.'
    }
    catch {
        if ($_.Exception.Message -like 'Port 5501*') { throw }
    }

    $Process = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ServerPath`"", '-NoOpenBrowser') `
        -RedirectStandardOutput $StdOut `
        -RedirectStandardError $StdErr `
        -PassThru

    $Ready = $false
    $Deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $Deadline -and -not $Process.HasExited) {
        try {
            $Health = Invoke-RestMethod -Uri "$Base/api/health" -TimeoutSec 1
            if ($Health.ok -and $Health.server -eq 'papich-wheel-ai-tester' -and $Health.port -eq 5501) { $Ready = $true; break }
        }
        catch {}
        Start-Sleep -Milliseconds 150
    }
    if (-not $Ready) {
        $ErrorText = if (Test-Path -LiteralPath $StdErr) { [string](Get-Content -LiteralPath $StdErr -Raw) } else { '' }
        throw "AI tester did not start on 127.0.0.1:5501. $ErrorText"
    }

    $ForbiddenStatus = 0
    try { [void](Invoke-WebRequest -UseBasicParsing -Uri "$Base/api/status" -TimeoutSec 3) }
    catch { $ForbiddenStatus = Get-HttpStatus $_ }
    Assert-True ($ForbiddenStatus -eq 403) 'Protected tester API did not reject a request without its process token.'

    $Html = (Invoke-WebRequest -UseBasicParsing -Uri "$Base/" -TimeoutSec 5).Content
    $TokenMatch = [regex]::Match($Html, 'const AI_TESTER_TOKEN = ''([0-9a-f]{64})'';')
    Assert-True $TokenMatch.Success 'Served tester HTML did not contain a per-process tester token.'
    $Headers = @{ 'X-AI-Tester-Token' = $TokenMatch.Groups[1].Value }
    $Status = Invoke-RestMethod -Uri "$Base/api/status" -Headers $Headers -TimeoutSec 5
    Assert-True ($Status.ok -and -not $Status.openrouterConfigured) 'Isolated test runtime unexpectedly reused a secret outside its temporary LOCALAPPDATA.'
    Assert-True ($Status.prompt.characterCount -gt 100 -and -not [string]::IsNullOrWhiteSpace([string]$Status.prompt.fingerprint)) 'Prompt metadata is missing.'

    $CyrillicText = -join @([char]0x0422, [char]0x0435, [char]0x0441, [char]0x0442, ' ', [char]0x0451)
    $PromptBody = @{ text = "Version: runtime-test`n$CyrillicText" } | ConvertTo-Json
    $Saved = Invoke-RestMethod -Uri "$Base/api/prompt/save" -Method Post -Headers $Headers -ContentType 'application/json; charset=utf-8' -Body $PromptBody -TimeoutSec 5
    Assert-True ($Saved.ok -and $Saved.prompt.customized) 'Prompt was not saved in isolated tester storage.'
    Assert-True ([string]$Saved.prompt.text -eq "Version: runtime-test`n$CyrillicText") 'Strict UTF-8 prompt round-trip changed Cyrillic text.'
    Assert-True (Test-Path -LiteralPath (Join-Path $RuntimeDataDir 'PapichWheel\ai-tester\experimental_prompt.txt')) 'Prompt was written outside the expected isolated tester directory.'
    $Reset = Invoke-RestMethod -Uri "$Base/api/prompt/reset" -Method Post -Headers $Headers -ContentType 'application/json; charset=utf-8' -Body '{}' -TimeoutSec 5
    Assert-True ($Reset.ok -and -not $Reset.prompt.customized) 'Prompt reset did not restore the bundled prompt.'

    $MissingKeyStatus = 0
    $MissingKeyPayload = $null
    try {
        [void](Invoke-RestMethod -Uri "$Base/api/analyze" -Method Post -Headers $Headers -ContentType 'application/json; charset=utf-8' -Body (@{
            model = 'google/gemini-2.5-flash-lite'
            donation = @{ name = 'Synthetic'; amount = 1; currency = 'RUB'; message = 'Synthetic message' }
        } | ConvertTo-Json -Depth 5) -TimeoutSec 5)
    }
    catch {
        $MissingKeyStatus = Get-HttpStatus $_
        try { $MissingKeyPayload = [string]$_.ErrorDetails.Message | ConvertFrom-Json } catch {}
    }
    Assert-True ($MissingKeyStatus -eq 503) 'Missing OpenRouter key did not produce a terminal service error.'
    Assert-True ($MissingKeyPayload.error.code -eq 'OPENROUTER_KEY_MISSING' -and $MissingKeyPayload.error.critical) 'Missing-key response is not marked critical for queue stop.'

    Write-Host 'AI tester server runtime tests ok'
}
finally {
    $env:LOCALAPPDATA = $PreviousLocalAppData
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        try { [void]$Process.WaitForExit(5000) } catch {}
    }
    try { if ([System.IO.Directory]::Exists($RuntimeDataDir)) { [System.IO.Directory]::Delete($RuntimeDataDir, $true) } } catch {}
}
