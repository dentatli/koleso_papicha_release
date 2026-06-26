$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DistDir = Join-Path $RootDir "dist"
$OutputPath = Join-Path $DistDir "PapichWheel_Setup.bat"

$SourceFiles = @(
    "koleso_papich.html",
    "local_server.ps1",
    "start_koleso.bat"
)

foreach ($FileName in $SourceFiles) {
    $Path = Join-Path $RootDir $FileName
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file not found: $FileName"
    }
}

if (-not (Test-Path -LiteralPath $DistDir -PathType Container)) {
    New-Item -ItemType Directory -Path $DistDir | Out-Null
}

function Add-WrappedBase64 {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]] $Lines,

        [Parameter(Mandatory = $true)]
        [byte[]] $Bytes
    )

    $Base64 = [Convert]::ToBase64String($Bytes)

    for ($Index = 0; $Index -lt $Base64.Length; $Index += 76) {
        $Length = [Math]::Min(76, $Base64.Length - $Index)
        $Lines.Add($Base64.Substring($Index, $Length))
    }
}

$ExtractorScript = @'
$ErrorActionPreference = 'Stop'

$self = $env:PAPICH_SETUP_SELF
if ([string]::IsNullOrWhiteSpace($self) -or -not [System.IO.File]::Exists($self)) {
    throw 'Setup file not found.'
}

$out = Split-Path -Parent $self
$lines = [System.IO.File]::ReadAllLines($self, [System.Text.Encoding]::UTF8)
$payload = $false
$name = $null
$buf = [System.Text.StringBuilder]::new()

foreach ($line in $lines) {
    if ($line -eq '__PAPICH_PAYLOAD_BEGIN__') {
        $payload = $true
        continue
    }

    if (-not $payload) {
        continue
    }

    if ($line -eq '__PAPICH_PAYLOAD_END__') {
        break
    }

    if ($line.StartsWith('FILE:')) {
        $name = $line.Substring(5)
        [void] $buf.Clear()
        continue
    }

    if ($line -eq '__PAPICH_FILE_END__') {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Invalid payload.'
        }

        $bytes = [Convert]::FromBase64String($buf.ToString())
        $target = Join-Path $out $name
        [System.IO.File]::WriteAllBytes($target, $bytes)
        $name = $null
        [void] $buf.Clear()
        continue
    }

    if ($null -ne $name) {
        [void] $buf.Append($line.Trim())
    }
}
'@

$EncodedExtractorScript = [Convert]::ToBase64String(
    [System.Text.Encoding]::Unicode.GetBytes($ExtractorScript)
)

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.AddRange([string[]] @(
    "@echo off",
    "setlocal",
    "chcp 65001 >nul",
    'set "PAPICH_SETUP_SELF=%~f0"',
    "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $EncodedExtractorScript",
    "if errorlevel 1 (",
    "  echo Ошибка распаковки.",
    "  pause",
    "  exit /b 1",
    ")",
    "echo Файлы распакованы. Запустите start_koleso.bat для старта приложения.",
    'del /f /q "%~f0" >nul 2>nul',
    "exit /b 0",
    "__PAPICH_PAYLOAD_BEGIN__"
))

foreach ($FileName in $SourceFiles) {
    $Path = Join-Path $RootDir $FileName
    $Bytes = [System.IO.File]::ReadAllBytes($Path)

    $Lines.Add("FILE:$FileName")
    Add-WrappedBase64 -Lines $Lines -Bytes $Bytes
    $Lines.Add("__PAPICH_FILE_END__")
}

$Lines.Add("__PAPICH_PAYLOAD_END__")

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($OutputPath, (($Lines -join "`r`n") + "`r`n"), $Utf8NoBom)

$OutputItem = Get-Item -LiteralPath $OutputPath
if ($OutputItem.Length -le 0) {
    throw "Generated setup file is empty: $OutputPath"
}

Write-Host "Created $OutputPath ($($OutputItem.Length) bytes)"
