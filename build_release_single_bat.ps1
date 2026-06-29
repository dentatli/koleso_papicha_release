$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DistDir = Join-Path $RootDir "dist"
$OutputPath = Join-Path $DistDir "PapichWheel_Setup.bat"

function Resolve-HeadShaFromGitDir {
    param([string]$GitDir)

    try {
        $HeadPath = Join-Path $GitDir "HEAD"
        if (-not (Test-Path -LiteralPath $HeadPath -PathType Leaf)) {
            return ""
        }

        $HeadValue = ([string](Get-Content -LiteralPath $HeadPath -Raw)).Trim()
        if ($HeadValue -match '^[0-9a-fA-F]{40}$') {
            return $HeadValue
        }

        if ($HeadValue.StartsWith("ref:")) {
            $RefName = $HeadValue.Substring(4).Trim()
            $RefPath = Join-Path $GitDir ($RefName -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $RefPath -PathType Leaf) {
                $RefValue = ([string](Get-Content -LiteralPath $RefPath -Raw)).Trim()
                if ($RefValue -match '^[0-9a-fA-F]{40}$') {
                    return $RefValue
                }
            }
        }
    }
    catch {}

    return ""
}

$BuildSha = [string]$env:GITHUB_SHA
if ([string]::IsNullOrWhiteSpace($BuildSha)) {
    try {
        $BuildSha = ([string](& git rev-parse HEAD 2>$null)).Trim()
    }
    catch {
        $BuildSha = ""
    }
}
if ([string]::IsNullOrWhiteSpace($BuildSha)) {
    $BuildSha = Resolve-HeadShaFromGitDir (Join-Path $RootDir ".git")
}
if ([string]::IsNullOrWhiteSpace($BuildSha)) {
    try {
        $PapichGitDir = Join-Path $RootDir ".papich_git"
        $BuildSha = ([string](& git "--git-dir=$PapichGitDir" "--work-tree=$RootDir" rev-parse HEAD 2>$null)).Trim()
    }
    catch {
        $BuildSha = ""
    }
}
if ([string]::IsNullOrWhiteSpace($BuildSha)) {
    $BuildSha = Resolve-HeadShaFromGitDir (Join-Path $RootDir ".papich_git")
}
if ([string]::IsNullOrWhiteSpace($BuildSha)) {
    $BuildSha = "dev"
}
if ($BuildSha -eq "dev") {
    $BuildVersion = "dev"
}
else {
    $BuildVersion = $BuildSha.Substring(0, [Math]::Min(7, $BuildSha.Length))
}

$ReleaseFiles = @(
    @{ Source = "koleso_papich.html"; Target = "assets/koleso_papich.html"; InjectBuildSha = $true },
    @{ Source = "local_server.ps1"; Target = "assets/local_server.ps1"; InjectBuildSha = $true },
    @{ Source = "tray.ico"; Target = "assets/tray.ico"; InjectBuildSha = $false },
    @{ Source = "tray-error.ico"; Target = "assets/tray-error.ico"; InjectBuildSha = $false },
    @{ Source = "start_koleso.bat"; Target = "start_koleso.bat"; InjectBuildSha = $false }
)

foreach ($File in $ReleaseFiles) {
    $Path = Join-Path $RootDir ([string]$File.Source)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file not found: $($File.Source)"
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
        $targetDir = Split-Path -Parent $target
        if (-not [string]::IsNullOrWhiteSpace($targetDir) -and -not [System.IO.Directory]::Exists($targetDir)) {
            [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
        }
        if ((Split-Path -Leaf $name) -eq 'local_server.ps1') {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $utf8Bom = [System.Text.UTF8Encoding]::new($true)
            [System.IO.File]::WriteAllText($target, $text, $utf8Bom)
        }
        else {
            [System.IO.File]::WriteAllBytes($target, $bytes)
        }
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

function Get-ReleaseFileBytes {
    param([hashtable]$File)

    $Path = Join-Path $RootDir ([string]$File.Source)
    if ($File.InjectBuildSha) {
        $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $SourceName = [string]$File.Source

        if ($SourceName -eq "local_server.ps1") {
            $Text = $Text -replace '(?m)^\$script:AppBuildSha\s*=\s*"[^"]*"', "`$script:AppBuildSha = `"$BuildSha`""
            $Text = $Text -replace '(?m)^\$script:AppBuildVersion\s*=\s*"[^"]*"', "`$script:AppBuildVersion = `"$BuildVersion`""
        }
        elseif ($SourceName -eq "koleso_papich.html") {
            $Text = $Text -replace '(?m)^\s*window\.APP_BUILD_SHA\s*=\s*"[^"]*";', "    window.APP_BUILD_SHA = `"$BuildSha`";"
            $Text = $Text -replace '(?m)^\s*window\.APP_BUILD_VERSION\s*=\s*"[^"]*";', "    window.APP_BUILD_VERSION = `"$BuildVersion`";"
        }

        return ,([System.Text.Encoding]::UTF8.GetBytes($Text))
    }

    if ([System.IO.Path]::GetExtension([string]$File.Source).ToLowerInvariant() -eq ".bat") {
        $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $Text = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
        return ,([System.Text.Encoding]::UTF8.GetBytes($Text))
    }

    return ,([System.IO.File]::ReadAllBytes($Path))
}

foreach ($File in $ReleaseFiles) {
    $Bytes = Get-ReleaseFileBytes $File
    $Target = [string]$File.Target

    $Lines.Add("FILE:$Target")
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

Write-Host "Created $OutputPath ($($OutputItem.Length) bytes, build $BuildVersion)"
