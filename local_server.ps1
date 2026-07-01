param(
    [string]$Root = $PSScriptRoot,
    [switch]$ServerOnly,
    [hashtable]$TrayState = $null
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

$ErrorActionPreference = "Stop"
$Root = $Root.Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $PSScriptRoot
}
$RootPath = [System.IO.Path]::GetFullPath($Root)
$TrayIconPath = Join-Path $RootPath "tray.ico"
$TrayErrorIconPath = Join-Path $RootPath "tray-error.ico"
$LogPath = Join-Path $RootPath "server.log"

function Mask-SecretText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $Masked = $Text
    $Patterns = @(
        '(?i)(access[_-]?token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(refresh[_-]?token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(client[_-]?secret["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(api[_-]?key["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(authorization["''\s:=]+Bearer\s+)([^"&''\s,}]+)',
        '(?i)(code["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(password["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(Bearer\s+)([A-Za-z0-9._~+/=-]+)'
    )

    foreach ($Pattern in $Patterns) {
        $Masked = [System.Text.RegularExpressions.Regex]::Replace($Masked, $Pattern, '$1***')
    }

    return $Masked
}

function Limit-LogText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 1000
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    if ($Text.Length -le $MaxLength) {
        return $Text
    }

    return $Text.Substring(0, $MaxLength) + "...[truncated]"
}

function Initialize-AppLog {
    try {
        if (-not [System.IO.Directory]::Exists($RootPath)) {
            [System.IO.Directory]::CreateDirectory($RootPath) | Out-Null
        }
        if ([System.IO.File]::Exists($LogPath)) {
            $Info = [System.IO.FileInfo]::new($LogPath)
            if ($Info.Length -gt 1MB) {
                [System.IO.File]::Delete($LogPath)
            }
        }
        if (-not [System.IO.File]::Exists($LogPath)) {
            [System.IO.File]::WriteAllText($LogPath, "", [System.Text.UTF8Encoding]::new($true))
        }
    }
    catch {
        Write-Host "Log init failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-AppLog {
    param(
        [string]$Level = "INFO",
        [string]$Message = ""
    )

    try {
        $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $SafeMessage = Limit-LogText (Mask-SecretText $Message)
        $Line = "[$Timestamp] [$Level] $SafeMessage"
        [System.IO.File]::AppendAllText($LogPath, $Line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($true))
    }
    catch {
        Write-Host "Log write failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Set-CriticalServerError {
    param([string]$Message)

    Write-AppLog -Level "ERROR" -Message $Message
    if ($TrayState) {
        try {
            $TrayState.HasCriticalError = $true
            $TrayState.ErrorMessage = $Message
        } catch {}
    }
}

function Test-ServerStopRequested {
    if (-not $TrayState) { return $false }
    try { return [bool]$TrayState.StopRequested } catch { return $false }
}

Initialize-AppLog

$HostAddress = "127.0.0.1"
$Ports = @(5500)
$Listener = $null
$SelectedPort = 5500
$script:SelectedPort = $SelectedPort
$script:CurrentRequestOrigin = ""
$script:CurrentCorsOrigin = ""
$SiteUrl = "http://${HostAddress}:${SelectedPort}/koleso_papich.html?view=admin"
$script:AppBuildSha = "__APP_BUILD_SHA__"
$script:AppBuildVersion = "__APP_BUILD_VERSION__"
$script:AppReleaseUrl = "https://github.com/dentatli/koleso_papicha_release/releases/latest"
$InitialBuildSha = ([string]$script:AppBuildSha).Trim()
$InitialBuildVersion = ([string]$script:AppBuildVersion).Trim()

if (
    [string]::IsNullOrWhiteSpace($InitialBuildSha) -or
    $InitialBuildSha -eq "__APP_BUILD_SHA__" -or
    $InitialBuildSha -eq "dev"
) {
    $InitialBuildSha = ""
    $InitialBuildVersion = "dev"
}
elseif (
    [string]::IsNullOrWhiteSpace($InitialBuildVersion) -or
    $InitialBuildVersion -eq "__APP_BUILD_VERSION__"
) {
    $InitialBuildVersion = if ($InitialBuildSha.Length -le 7) {
        $InitialBuildSha
    }
    else {
        $InitialBuildSha.Substring(0, 7)
    }
}

$script:AppVersionStatus = [pscustomobject]@{
    ok = $true
    currentSha = $InitialBuildSha
    currentVersion = $InitialBuildVersion
    latestSha = ""
    latestVersion = ""
    updateAvailable = $false
    checkedAt = ""
    releaseUrl = $script:AppReleaseUrl
    error = ""
}

function Open-AppSite {
    try {
        Start-Process $SiteUrl
        Write-AppLog -Level "INFO" -Message "Open site requested: $SiteUrl"
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "Could not open site: $($_.Exception.Message)"
    }
}

function Open-AppLog {
    try {
        if (-not [System.IO.File]::Exists($LogPath)) {
            [System.IO.File]::WriteAllText($LogPath, "", [System.Text.UTF8Encoding]::new($true))
        }
        Start-Process "notepad.exe" -ArgumentList "`"$LogPath`""
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "Could not open log: $($_.Exception.Message)"
    }
}

function Get-TrayIcon {
    param(
        [string]$Path,
        [System.Drawing.Icon]$Fallback
    )

    try {
        if ([System.IO.File]::Exists($Path)) {
            return [System.Drawing.Icon]::new($Path)
        }
        Write-AppLog -Level "WARN" -Message "Tray icon not found: $Path"
    }
    catch {
        Write-AppLog -Level "WARN" -Message "Tray icon load failed: $Path; $($_.Exception.Message)"
    }
    return $Fallback
}

function Start-TrayApplication {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    Write-AppLog -Level "INFO" -Message "Application start"
    Write-AppLog -Level "INFO" -Message "Root: $Root"
    Write-AppLog -Level "INFO" -Message "RootPath: $RootPath"
    Write-AppLog -Level "INFO" -Message "LogPath: $LogPath"
    Write-AppLog -Level "INFO" -Message "TrayIconPath: $TrayIconPath"
    Write-AppLog -Level "INFO" -Message "TrayErrorIconPath: $TrayErrorIconPath"

    $State = [hashtable]::Synchronized(@{
        StopRequested = $false
        HasCriticalError = $false
        ErrorMessage = ""
        Started = $false
    })

    $DefaultIcon = [System.Drawing.SystemIcons]::Application
    $NormalIcon = Get-TrayIcon -Path $TrayIconPath -Fallback $DefaultIcon
    $ErrorIcon = Get-TrayIcon -Path $TrayErrorIconPath -Fallback $NormalIcon
    if (-not [System.IO.File]::Exists($TrayErrorIconPath)) {
        Write-AppLog -Level "WARN" -Message "Tray error icon not found: $TrayErrorIconPath"
    }
    $TooltipDash = [string][char]0x2014

    $NotifyIcon = [System.Windows.Forms.NotifyIcon]::new()
    $NotifyIcon.Icon = $NormalIcon
    $NotifyIcon.Text = "Papich Wheel $TooltipDash сервер работает"
    $NotifyIcon.Visible = $true

    $Menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $OpenSiteItem = [System.Windows.Forms.ToolStripMenuItem]::new("Открыть сайт")
    $OpenLogItem = [System.Windows.Forms.ToolStripMenuItem]::new("Открыть лог")
    $ExitItem = [System.Windows.Forms.ToolStripMenuItem]::new("Выйти")
    [void]$Menu.Items.Add($OpenSiteItem)
    [void]$Menu.Items.Add($OpenLogItem)
    [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    [void]$Menu.Items.Add($ExitItem)
    $NotifyIcon.ContextMenuStrip = $Menu

    $OpenSiteItem.add_Click({ Open-AppSite })
    $OpenLogItem.add_Click({ Open-AppLog })
    $NotifyIcon.add_DoubleClick({ Open-AppSite })
    $ExitItem.add_Click({
        Write-AppLog -Level "INFO" -Message "Exit requested from tray menu"
        $State.StopRequested = $true
        [System.Windows.Forms.Application]::ExitThread()
    })

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = "MTA"
    $Runspace.Open()
    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Runspace
    [void]$PowerShell.AddCommand($PSCommandPath)
    [void]$PowerShell.AddParameter("Root", $RootPath)
    [void]$PowerShell.AddParameter("ServerOnly", $true)
    [void]$PowerShell.AddParameter("TrayState", $State)
    $AsyncResult = $PowerShell.BeginInvoke()

    $UiTimer = [System.Windows.Forms.Timer]::new()
    $UiTimer.Interval = 1000
    $UiTimer.add_Tick({
        try {
            if ([bool]$State.HasCriticalError) {
                $NotifyIcon.Icon = $ErrorIcon
                $NotifyIcon.Text = "Papich Wheel $TooltipDash ошибка, откройте лог"
            }
            else {
                $NotifyIcon.Icon = $NormalIcon
                $NotifyIcon.Text = "Papich Wheel $TooltipDash сервер работает"
            }
        } catch {}
    })
    $UiTimer.Start()

    try {
        Open-AppSite
        [System.Windows.Forms.Application]::Run()
    }
    finally {
        Write-AppLog -Level "INFO" -Message "Tray application stopping"
        try { $State.StopRequested = $true } catch {}
        try { $UiTimer.Stop(); $UiTimer.Dispose() } catch {}
        try {
            if ($AsyncResult -and -not $AsyncResult.IsCompleted) {
                $WaitHandle = $AsyncResult.AsyncWaitHandle
                [void]$WaitHandle.WaitOne(5000)
            }
            if ($AsyncResult -and $AsyncResult.IsCompleted) {
                $PowerShell.EndInvoke($AsyncResult)
            }
        } catch {
            Write-AppLog -Level "ERROR" -Message "Server runspace stop error: $($_.Exception.Message)"
        }
        try { $PowerShell.Dispose() } catch {}
        try { $Runspace.Close(); $Runspace.Dispose() } catch {}
        try { $NotifyIcon.Visible = $false; $NotifyIcon.Dispose() } catch {}
        try { if ($NormalIcon -and -not [object]::ReferenceEquals($NormalIcon, $DefaultIcon)) { $NormalIcon.Dispose() } } catch {}
        try { if ($ErrorIcon -and -not [object]::ReferenceEquals($ErrorIcon, $NormalIcon) -and -not [object]::ReferenceEquals($ErrorIcon, $DefaultIcon)) { $ErrorIcon.Dispose() } } catch {}
        Write-AppLog -Level "INFO" -Message "Application stopped"
    }
}

if (-not $ServerOnly) {
    Start-TrayApplication
    return
}

$script:StateLock = [object]::new()
$script:CollectorEnabled = $false
$script:NextCollectorTickAt = Get-Date
$script:ServerState = @{
    SessionStartedAt = (Get-Date).ToUniversalTime().ToString("o")
    DonationsPending = [System.Collections.ArrayList]::new()
    SeenDonationKeys = @{}
    Integrations = @{
        DonatePay = @{
            Enabled = $false
            Region = "ru"
            AccessToken = ""
            UserId = ""
            Signature = ""
            LastSeenId = $null
            BaselineReady = $false
            Status = "disconnected"
            LastError = ""
            LastEventAt = ""
            BackoffUntil = $null
            LastPollAt = $null
            PollingIntervalSec = 15
        }
        DonationAlerts = @{
            Enabled = $false
            AppId = ""
            AccessToken = ""
            TokenType = "Bearer"
            UserId = ""
            Signature = ""
            LastSeenId = $null
            BaselineReady = $false
            Status = "disconnected"
            LastError = ""
            LastEventAt = ""
            BackoffUntil = $null
            LastPollAt = $null
            PollingIntervalSec = 10
        }
    }
}

function Get-ContentType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { return "text/html; charset=utf-8" }
        ".htm"  { return "text/html; charset=utf-8" }
        ".css"  { return "text/css; charset=utf-8" }
        ".js"   { return "application/javascript; charset=utf-8" }
        ".json" { return "application/json; charset=utf-8" }
        ".txt"  { return "text/plain; charset=utf-8" }
        ".svg"  { return "image/svg+xml" }
        ".png"  { return "image/png" }
        ".jpg"  { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".gif"  { return "image/gif" }
        ".webp" { return "image/webp" }
        ".ico"  { return "image/x-icon" }
        ".woff" { return "font/woff" }
        ".woff2" { return "font/woff2" }
        default { return "application/octet-stream" }
    }
}

function Get-AllowedCorsOrigin {
    param([string]$Origin)

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        return ""
    }

    $AllowedOrigins = @(
        "http://127.0.0.1:$script:SelectedPort",
        "http://localhost:$script:SelectedPort"
    )

    if ($AllowedOrigins -contains $Origin) {
        return $Origin
    }

    return $null
}

function Test-ApiRequestPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return $Path -eq "/api/health" -or $Path.StartsWith("/api/")
}

function Resolve-SafePath {
    param(
        [string]$RootPath,
        [string]$RelativePath
    )

    try {
        $RootFull = [System.IO.Path]::GetFullPath($RootPath).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ) + [System.IO.Path]::DirectorySeparatorChar

        $TargetFull = [System.IO.Path]::GetFullPath((Join-Path $RootFull $RelativePath))

        if (-not $TargetFull.StartsWith($RootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        return $TargetFull
    }
    catch {
        Write-AppLog -Level "WARN" -Message "Safe path resolve failed: $($_.Exception.Message)"
        return $null
    }
}

function Send-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$ContentType,
        [byte[]]$Body,
        [bool]$HeadOnly = $false
    )

    $CorsHeader = ""
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentCorsOrigin)) {
        $CorsHeader = "Access-Control-Allow-Origin: $script:CurrentCorsOrigin`r`n" +
                      "Vary: Origin`r`n"
    }

    $HeaderText = "HTTP/1.1 $StatusCode $StatusText`r`n" +
                  "Content-Type: $ContentType`r`n" +
                  "Content-Length: $($Body.Length)`r`n" +
                  "Cache-Control: no-cache`r`n" +
                  $CorsHeader +
                  "Access-Control-Allow-Headers: Content-Type, Authorization`r`n" +
                  "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
                  "Connection: close`r`n`r`n"
    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($HeaderText)
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
}

function Send-Json {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [object]$Data,
        [bool]$HeadOnly = $false
    )

    $StatusText = switch ($StatusCode) {
        200 { "OK" }
        204 { "No Content" }
        400 { "Bad Request" }
        403 { "Forbidden" }
        404 { "Not Found" }
        405 { "Method Not Allowed" }
        502 { "Bad Gateway" }
        default { "Internal Server Error" }
    }
    $Json = if ($null -eq $Data) { "" } else { $Data | ConvertTo-Json -Depth 20 -Compress }
    $Body = [System.Text.Encoding]::UTF8.GetBytes($Json)
    Send-Response $Stream $StatusCode $StatusText "application/json; charset=utf-8" $Body $HeadOnly
}

function Get-ShortSha {
    param([string]$Sha)

    $Clean = ([string]$Sha).Trim()
    if ([string]::IsNullOrWhiteSpace($Clean) -or $Clean -eq "__APP_BUILD_SHA__" -or $Clean -eq "__APP_BUILD_VERSION__") {
        return "dev"
    }
    if ($Clean.Length -le 7) {
        return $Clean
    }
    return $Clean.Substring(0, 7)
}

function Test-AppVersion {
    $Now = (Get-Date).ToUniversalTime().ToString("o")

    $CurrentSha = ([string]$script:AppBuildSha).Trim()
    $CurrentVersion = ([string]$script:AppBuildVersion).Trim()

    $IsDevBuild = (
        [string]::IsNullOrWhiteSpace($CurrentSha) -or
        $CurrentSha -eq "__APP_BUILD_SHA__" -or
        $CurrentSha -eq "dev"
    )

    if ($IsDevBuild) {
        $CurrentSha = ""
        $CurrentVersion = "dev"
    }
    elseif (
        [string]::IsNullOrWhiteSpace($CurrentVersion) -or
        $CurrentVersion -eq "__APP_BUILD_VERSION__"
    ) {
        $CurrentVersion = Get-ShortSha $CurrentSha
    }

    $script:AppVersionStatus = [pscustomobject]@{
        ok = $true
        currentSha = $CurrentSha
        currentVersion = $CurrentVersion
        latestSha = ""
        latestVersion = ""
        updateAvailable = $false
        checkedAt = $Now
        releaseUrl = $script:AppReleaseUrl
        error = ""
    }

    if ($IsDevBuild) {
        return
    }

    try {
        $RefData = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/dentatli/koleso_papicha_release/git/ref/tags/latest" `
            -Headers @{ "User-Agent" = "PapichWheelLocalServer" } `
            -TimeoutSec 5

        $RefType = [string]$RefData.object.type
        $RefSha = [string]$RefData.object.sha
        $LatestSha = ""

        if ([string]::IsNullOrWhiteSpace($RefSha)) {
            throw "GitHub latest ref returned empty sha"
        }

        if ($RefType -eq "commit") {
            $LatestSha = $RefSha
        }
        elseif ($RefType -eq "tag") {
            $TagData = Invoke-RestMethod `
                -Uri "https://api.github.com/repos/dentatli/koleso_papicha_release/git/tags/$RefSha" `
                -Headers @{ "User-Agent" = "PapichWheelLocalServer" } `
                -TimeoutSec 5

            $LatestSha = [string]$TagData.object.sha
            if ([string]::IsNullOrWhiteSpace($LatestSha)) {
                throw "GitHub annotated latest tag returned empty commit sha"
            }
        }
        else {
            throw "GitHub latest ref unsupported object type: $RefType"
        }

        $script:AppVersionStatus = [pscustomobject]@{
            ok = $true
            currentSha = $CurrentSha
            currentVersion = $CurrentVersion
            latestSha = $LatestSha
            latestVersion = (Get-ShortSha $LatestSha)
            updateAvailable = ($LatestSha -ne $CurrentSha)
            checkedAt = $Now
            releaseUrl = $script:AppReleaseUrl
            error = ""
        }
    }
    catch {
        $script:AppVersionStatus = [pscustomobject]@{
            ok = $true
            currentSha = $CurrentSha
            currentVersion = $CurrentVersion
            latestSha = ""
            latestVersion = ""
            updateAvailable = $false
            checkedAt = $Now
            releaseUrl = $script:AppReleaseUrl
            error = $_.Exception.Message
        }
    }
}

function Write-AppVersionLog {
    Write-Host "Version current: $($script:AppVersionStatus.currentVersion) $($script:AppVersionStatus.currentSha)" -ForegroundColor Yellow
    Write-Host "Version latest: $($script:AppVersionStatus.latestVersion) $($script:AppVersionStatus.latestSha)" -ForegroundColor Yellow
    Write-Host "Version updateAvailable: $($script:AppVersionStatus.updateAvailable)" -ForegroundColor Yellow
    Write-AppLog -Level "INFO" -Message "Version current: $($script:AppVersionStatus.currentVersion) $($script:AppVersionStatus.currentSha)"
    Write-AppLog -Level "INFO" -Message "Version latest: $($script:AppVersionStatus.latestVersion) $($script:AppVersionStatus.latestSha)"
    Write-AppLog -Level "INFO" -Message "Version updateAvailable: $($script:AppVersionStatus.updateAvailable)"
    if ($script:AppVersionStatus.error) {
        Write-Host "Version error: $($script:AppVersionStatus.error)" -ForegroundColor Yellow
        Write-AppLog -Level "WARN" -Message "Version error: $($script:AppVersionStatus.error)"
    }
}

function Get-AppVersionStatus {
    return $script:AppVersionStatus
}

function Read-JsonBody {
    param(
        [System.IO.StreamReader]$Reader,
        [int]$ContentLength
    )

    if ($ContentLength -le 0) {
        return $null
    }
    $Buffer = New-Object char[] $ContentLength
    $Offset = 0
    while ($Offset -lt $ContentLength) {
        $Read = $Reader.Read($Buffer, $Offset, $ContentLength - $Offset)
        if ($Read -le 0) { break }
        $Offset += $Read
    }
    if ($Offset -le 0) {
        return $null
    }
    $JsonText = -join $Buffer[0..($Offset - 1)]
    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return $null
    }
    return $JsonText | ConvertFrom-Json
}

function Get-FriendlyProxyError {
    param([System.Exception]$Error)

    if ($Error -is [System.Net.WebException]) {
        if ($Error.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
            return "DonationAlerts did not respond in time."
        }
        if ($Error.Status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
            return "Could not resolve DonationAlerts. Check the internet connection."
        }
        return "Could not connect to DonationAlerts."
    }
    return "DonationAlerts request failed."
}

function Get-FriendlyDonatePayProxyError {
    param([System.Exception]$Error)

    if ($Error -is [System.Net.WebException]) {
        if ($Error.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
            return "DonatePay did not respond in time."
        }
        if ($Error.Status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
            return "Could not resolve DonatePay. Check the internet connection."
        }
        return "Could not connect to DonatePay."
    }
    return "DonatePay request failed."
}

function Get-DonatePayHost {
    param([string]$Region)

    if ($Region -eq "eu") {
        return "donatepay.eu"
    }
    return "donatepay.ru"
}

function Add-QueryParam {
    param(
        [System.Collections.Generic.List[string]]$Parts,
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Value) {
        return
    }
    $Text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }
    $EncodedName = [System.Uri]::EscapeDataString($Name)
    $EncodedValue = [System.Uri]::EscapeDataString($Text)
    $Parts.Add("$EncodedName=$EncodedValue")
}

function Get-MaskedUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $Url
    }

    return Mask-SecretText $Url
}

function Get-MaskedText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    return Mask-SecretText $Text
}

function New-UpstreamError {
    param(
        [string]$Message,
        [string]$Endpoint,
        [string]$Method,
        [string]$UpstreamUrl,
        [System.Exception]$Error
    )

    $StatusCode = $null
    $Body = ""

    if ($Error.Response) {
        try { $StatusCode = [int]$Error.Response.StatusCode } catch {}
        try {
            $ResponseStream = $Error.Response.GetResponseStream()
            if ($ResponseStream) {
                $Reader = [System.IO.StreamReader]::new($ResponseStream)
                $Body = $Reader.ReadToEnd()
            }
        } catch {}
    }

    return [pscustomobject]@{
        ok = $false
        endpoint = $Endpoint
        method = $Method
        upstreamUrl = Get-MaskedUrl $UpstreamUrl
        upstreamStatus = $StatusCode
        upstreamBody = Limit-LogText (Get-MaskedText $Body)
        error = $Message
        exceptionMessage = Limit-LogText (Get-MaskedText $Error.Message)
        status = 500
    }
}

function Write-UpstreamErrorLog {
    param(
        [string]$Service,
        [object]$ErrorData
    )

    Write-Host "$Service proxy request failed." -ForegroundColor Yellow
    Write-AppLog -Level "ERROR" -Message "$Service proxy request failed."
    $SafeEndpoint = Limit-LogText (Mask-SecretText ([string]$ErrorData.endpoint))
    $SafeUrl = Limit-LogText (Mask-SecretText ([string]$ErrorData.upstreamUrl))
    $SafeBody = Limit-LogText (Mask-SecretText ([string]$ErrorData.upstreamBody))
    $SafeException = Limit-LogText (Mask-SecretText ([string]$ErrorData.exceptionMessage))

    if ($ErrorData.endpoint) { Write-Host "  endpoint: $SafeEndpoint" -ForegroundColor Yellow }
    if ($ErrorData.upstreamStatus) { Write-Host "  upstream status: $($ErrorData.upstreamStatus)" -ForegroundColor Yellow }
    if ($ErrorData.upstreamUrl) { Write-Host "  upstream url: $SafeUrl" -ForegroundColor Yellow }
    if ($ErrorData.upstreamBody) { Write-Host "  upstream body: $SafeBody" -ForegroundColor Yellow }
    if ($ErrorData.exceptionMessage) { Write-Host "  exception: $SafeException" -ForegroundColor Yellow }
    if ($ErrorData.endpoint) { Write-AppLog -Level "ERROR" -Message "  endpoint: $SafeEndpoint" }
    if ($ErrorData.upstreamStatus) { Write-AppLog -Level "ERROR" -Message "  upstream status: $($ErrorData.upstreamStatus)" }
    if ($ErrorData.upstreamUrl) { Write-AppLog -Level "ERROR" -Message "  upstream url: $SafeUrl" }
    if ($ErrorData.upstreamBody) { Write-AppLog -Level "ERROR" -Message "  upstream body: $SafeBody" }
    if ($ErrorData.exceptionMessage) { Write-AppLog -Level "ERROR" -Message "  exception: $SafeException" }
}

function Invoke-DonatePayApi {
    param(
        [string]$Region,
        [string]$Path,
        [object]$InputData,
        [string]$LocalEndpoint
    )

    $AccessToken = [string]$InputData.access_token
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw [System.ArgumentException]::new("Missing DonatePay access token.")
    }

    $HostName = Get-DonatePayHost $Region
    $QueryParts = [System.Collections.Generic.List[string]]::new()
    Add-QueryParam $QueryParts "access_token" $AccessToken

    if ($Path -eq "/api/v1/transactions" -or $Path -eq "/api/v1/notifications") {
        $Limit = if ($InputData.limit) { [string]$InputData.limit } else { "100" }
        Add-QueryParam $QueryParts "limit" $Limit
        $Order = if ($InputData.order) { [string]$InputData.order } else { "DESC" }
        Add-QueryParam $QueryParts "order" $Order
        Add-QueryParam $QueryParts "type" "donation"
        if ($Path -eq "/api/v1/transactions") {
            $Status = if ($InputData.status) { [string]$InputData.status } else { "success" }
            Add-QueryParam $QueryParts "status" $Status
        }
        Add-QueryParam $QueryParts "before" $InputData.before
        Add-QueryParam $QueryParts "after" $InputData.after
        Add-QueryParam $QueryParts "skip" $InputData.skip
    }
    $Url = "https://$HostName$Path"
    if ($QueryParts.Count -gt 0) {
        $Url = "$($Url)?$($QueryParts -join '&')"
    }

    try {
        return Invoke-RestMethod `
            -Uri $Url `
            -Method Get `
            -Headers @{ Accept = "application/json" } `
            -TimeoutSec 30
    }
    catch {
        $Friendly = Get-FriendlyDonatePayProxyError $_.Exception
        return New-UpstreamError $Friendly $LocalEndpoint "GET" $Url $_.Exception
    }
}


function Invoke-DonationAlertsApi {
    param(
        [string]$Url,
        [string]$AccessToken,
        [string]$LocalEndpoint
    )

    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw [System.ArgumentException]::new("Missing access token.")
    }

    try {
        return Invoke-RestMethod `
            -Uri $Url `
            -Method Get `
            -Headers @{
                Authorization = "Bearer $AccessToken"
                Accept = "application/json"
            } `
            -TimeoutSec 30
    }
    catch {
        $Friendly = Get-FriendlyProxyError $_.Exception
        return New-UpstreamError $Friendly $LocalEndpoint "GET" $Url $_.Exception
    }
}

function Get-NumericDonationId {
    param([object]$Value)

    if ($null -eq $Value) { return 0 }
    $Text = [string]$Value
    $Digits = [System.Text.RegularExpressions.Regex]::Replace($Text, "\D", "")
    if ([string]::IsNullOrWhiteSpace($Digits)) { return 0 }
    $Number = 0L
    if ([long]::TryParse($Digits, [ref]$Number)) { return $Number }
    return 0
}

function Convert-DonationDateToIso {
    param(
        [object]$Value,
        [string]$Source = ""
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return (Get-Date).ToUniversalTime().ToString("o")
    }

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime().ToString("o")
    }

    $Text = ([string]$Value).Trim()
    try {
        if ($Text -match '^\d+$') {
            $Unix = [long]$Text
            if ($Unix -lt 10000000000) {
                return [DateTimeOffset]::FromUnixTimeSeconds($Unix).UtcDateTime.ToString("o")
            }
            return [DateTimeOffset]::FromUnixTimeMilliseconds($Unix).UtcDateTime.ToString("o")
        }

        if ($Text -match '[zZ]$|[+-]\d{2}:?\d{2}$') {
            return ([DateTimeOffset]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString("o")
        }

        if ($Source -eq "donationalerts" -and $Text -match '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}') {
            $Normalized = $Text.Replace(" ", "T") + "Z"
            return ([DateTimeOffset]::Parse($Normalized, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString("o")
        }

        $LocalDate = [datetime]::Parse($Text.Replace(" ", "T"), [Globalization.CultureInfo]::InvariantCulture)
        return $LocalDate.ToUniversalTime().ToString("o")
    }
    catch {
        return (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Convert-ToUtcDateTimeOffset {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    $Text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $Styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
              [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $Parsed = [DateTimeOffset]::MinValue

    if ([DateTimeOffset]::TryParse(
        $Text,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $Styles,
        [ref]$Parsed
    )) {
        return $Parsed.ToUniversalTime()
    }

    return $null
}

function Get-ServerSessionStartedAtUtc {
    try {
        return [DateTimeOffset]::Parse(
            [string]$script:ServerState.SessionStartedAt,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
        ).ToUniversalTime()
    }
    catch {
        return [DateTimeOffset]::UtcNow
    }
}

function Get-ApiRows {
    param([object]$Payload)

    if ($null -eq $Payload) { return @() }
    if ($Payload -is [System.Array]) { return @($Payload) }
    if ($Payload.PSObject.Properties.Name -contains "data") {
        if ($Payload.data -is [System.Array]) { return @($Payload.data) }
        if ($null -ne $Payload.data) { return @($Payload.data) }
    }
    return @()
}

function Get-DonationKey {
    param(
        [string]$Source,
        [object]$ExternalId
    )
    return "$($Source):$([string]$ExternalId)"
}

function Get-FirstPresentValue {
    param([object[]]$Values)

    foreach ($Value in $Values) {
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
            return $Value
        }
    }
    return $null
}

function Get-LastSeenIdValue {
    param([hashtable]$ServiceState)

    if ($null -eq $ServiceState.LastSeenId) { return 0L }
    $Value = 0L
    if ([long]::TryParse([string]$ServiceState.LastSeenId, [ref]$Value)) { return $Value }
    return 0L
}

function Get-DonationAmountValue {
    param([object]$Value)

    $Amount = 0.0
    if ($null -eq $Value) { return 0.0 }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) {
        try { return [double]$Value } catch { return 0.0 }
    }
    $Text = ([string]$Value).Trim()
    if ([double]::TryParse($Text, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$Amount)) {
        return $Amount
    }
    if ([double]::TryParse($Text, [ref]$Amount)) {
        return $Amount
    }
    return 0.0
}

function Add-ServerDonation {
    param([hashtable]$Donation)

    $Source = [string]$Donation.source
    $ExternalId = [string]$Donation.externalId
    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($ExternalId)) {
        return $false
    }

    $Key = Get-DonationKey $Source $ExternalId
    $Amount = Get-DonationAmountValue $Donation.amount
    $DateValid = $false
    try {
        [void][DateTimeOffset]::Parse([string]$Donation.createdAt)
        $DateValid = $true
    } catch {}

    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        if ($script:ServerState.SeenDonationKeys.ContainsKey($Key)) {
            return $false
        }
        $script:ServerState.SeenDonationKeys[$Key] = $true
        if ([double]::IsNaN($Amount) -or $Amount -le 0 -or -not $DateValid) {
            Write-Host "[Collector] invalid donation skipped: $Key" -ForegroundColor Yellow
            Write-AppLog -Level "WARN" -Message "[Collector] invalid donation skipped: $Key"
            return $false
        }
        [void]$script:ServerState.DonationsPending.Add([pscustomobject]$Donation)
        Write-Host "[Collector] pending donations: $($script:ServerState.DonationsPending.Count)" -ForegroundColor DarkCyan
        Write-AppLog -Level "INFO" -Message "[Collector] pending donations: $($script:ServerState.DonationsPending.Count)"
        return $true
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
}

function Convert-DonationAlertsRow {
    param([object]$Raw)

    if ($null -eq $Raw -or $null -eq $Raw.id) { return $null }
    $Message = ""
    if ($Raw.message -and -not ($Raw.message -is [string])) {
        $Message = [string]$Raw.message.message
    }
    elseif ($Raw.message) {
        $Message = [string]$Raw.message
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = [string](Get-FirstPresentValue @($Raw.comment, $Raw.text, ""))
    }

    $Username = [string](Get-FirstPresentValue @($Raw.username, $Raw.name, $Raw.sender, $Raw.user.name, "Anonymous"))
    $Amount = Get-DonationAmountValue (Get-FirstPresentValue @($Raw.amount, $Raw.sum, $Raw.amount_in_user_currency, 0))
    $Currency = [string](Get-FirstPresentValue @($Raw.currency, $Raw.currency_code, "RUB"))
    $CreatedRaw = Get-FirstPresentValue @($Raw.created_at, $Raw.createdAt, $Raw.date, $Raw.message.created_at, $Raw.data.created_at)
    $ExternalId = [string]$Raw.id

    return @{
        id = "server-donationalerts-$ExternalId"
        source = "donationalerts"
        externalId = $ExternalId
        username = $Username
        amount = $Amount
        currency = $Currency
        message = $Message
        createdAt = Convert-DonationDateToIso $CreatedRaw "donationalerts"
        status = "pending"
        raw = $Raw
    }
}


function Convert-DonatePayNotificationRow {
    param([object]$Raw)

    if ($null -eq $Raw -or $null -eq $Raw.id) { return $null }
    if ([string]$Raw.type -ne "donation") { return $null }

    $ExternalId = [string]$Raw.id
    $CreatedRaw = Get-FirstPresentValue @($Raw.created_at, $Raw.createdAt, $Raw.date)
    return @{
        id = "server-donatepay-$ExternalId"
        source = "donatepay"
        externalId = $ExternalId
        username = [string](Get-FirstPresentValue @($Raw.vars.name, $Raw.name, $Raw.username, "Anonymous"))
        amount = Get-DonationAmountValue (Get-FirstPresentValue @($Raw.vars.sum, $Raw.sum, $Raw.amount, 0))
        currency = [string](Get-FirstPresentValue @($Raw.vars.currency, $Raw.currency, "RUB"))
        message = [string](Get-FirstPresentValue @($Raw.vars.comment, $Raw.comment, $Raw.text, ""))
        createdAt = Convert-DonationDateToIso $CreatedRaw "donatepay"
        status = "pending"
        raw = $Raw
    }
}

function Set-CollectorBackoff {
    param(
        [hashtable]$ServiceState,
        [object]$Result
    )

    $Status = 0
    try { $Status = [int]$Result.upstreamStatus } catch {}
    $DelaySec = if ($Status -eq 429) { 120 } else { 45 }
    $ServiceState.BackoffUntil = (Get-Date).AddSeconds($DelaySec).ToUniversalTime().ToString("o")
    $ServiceState.Status = "error"
    $ServiceState.LastError = [string](Get-FirstPresentValue @($Result.error, "Collector request failed."))
}

function Clear-CollectorBackoff {
    param([hashtable]$ServiceState)

    $ServiceState.BackoffUntil = $null
    $ServiceState.LastError = ""
}

function Test-CollectorBackoff {
    param([hashtable]$ServiceState)

    if ([string]::IsNullOrWhiteSpace([string]$ServiceState.BackoffUntil)) {
        return $false
    }
    try {
        return ([DateTimeOffset]::Parse([string]$ServiceState.BackoffUntil).UtcDateTime -gt (Get-Date).ToUniversalTime())
    }
    catch {
        return $false
    }
}


function Invoke-DonationAlertsCollectorPoll {
    $Service = $script:ServerState.Integrations.DonationAlerts
    if (-not $Service.Enabled -or [string]::IsNullOrWhiteSpace($Service.AccessToken)) { return }
    if (Test-CollectorBackoff $Service) { return }

    $Result = Invoke-DonationAlertsApi `
        "https://www.donationalerts.com/api/v1/alerts/donations" `
        ([string]$Service.AccessToken) `
        "/api/collector/donationalerts"

    if ($Result -and $Result.ok -eq $false) {
        Set-CollectorBackoff $Service $Result
        Write-UpstreamErrorLog "DonationAlerts collector" $Result
        return
    }

    $Rows = Get-ApiRows $Result
    $MaxId = Get-LastSeenIdValue $Service

    if (-not $Service.BaselineReady) {
        foreach ($Row in $Rows) {
            $Id = Get-NumericDonationId $Row.id
            if ($Id -gt $MaxId) { $MaxId = $Id }
        }
        $Service.LastSeenId = $MaxId
        $Service.BaselineReady = $true
        $Service.Status = "connected"
        $Service.LastEventAt = (Get-Date).ToUniversalTime().ToString("o")
        Clear-CollectorBackoff $Service
        Write-Host "[DonationAlerts] baseline ready, lastSeenId=$MaxId" -ForegroundColor Green
        Write-AppLog -Level "INFO" -Message "[DonationAlerts] baseline ready, lastSeenId=$MaxId"
        return
    }

    $NewRows = @($Rows | Sort-Object { Get-NumericDonationId $_.id } | Where-Object {
        (Get-NumericDonationId $_.id) -gt (Get-LastSeenIdValue $Service)
    })
    $Added = 0
    foreach ($Row in $NewRows) {
        $Donation = Convert-DonationAlertsRow $Row
        if ($Donation -and (Add-ServerDonation $Donation)) { $Added++ }
        $Id = Get-NumericDonationId $Row.id
        if ($Id -gt $MaxId) { $MaxId = $Id }
    }
    if ($MaxId -gt (Get-LastSeenIdValue $Service)) {
        $Service.LastSeenId = $MaxId
    }
    $Service.Status = "connected"
    $Service.LastEventAt = (Get-Date).ToUniversalTime().ToString("o")
    Clear-CollectorBackoff $Service
    if ($Added -gt 0) {
        Write-Host "[DonationAlerts] received $($Rows.Count), new $Added" -ForegroundColor DarkCyan
        Write-AppLog -Level "INFO" -Message "[DonationAlerts] received $($Rows.Count), new $Added"
    }
}


function Invoke-DonatePayRecoveryTransactions {
    param([object]$InputData)

    $After = 0L
    try { $After = [long]$InputData.after } catch {}
    $Limit = 100
    try {
        if ($InputData.limit) {
            $Limit = [Math]::Max(1, [Math]::Min(100, [int]$InputData.limit))
        }
    } catch {}

    $Payload = @{
        region = [string]$InputData.region
        access_token = [string]$InputData.access_token
        limit = $Limit
        order = "ASC"
        type = "donation"
    }
    if ($After -gt 0) {
        $Payload.after = $After
    }

    $Result = Invoke-DonatePayApi ([string]$InputData.region) "/api/v1/notifications" ([pscustomobject]$Payload) "/api/dp/recovery-transactions"
    if ($Result -and $Result.ok -eq $false) {
        if ([int]$Result.upstreamStatus -eq 429) {
            $Result.error = "DonatePay temporarily limited recovery requests."
        }
        return $Result
    }

    $Rows = Get-ApiRows $Result
    $Added = 0
    $MaxId = $After
    $SkippedOld = 0
    $SkippedInvalidDate = 0
    $SkippedNotDonation = 0
    $SessionStartedAtUtc = Get-ServerSessionStartedAtUtc
    $MinDonationTimeUtc = $SessionStartedAtUtc.AddMinutes(-2)

    foreach ($Row in @($Rows | Sort-Object { Get-NumericDonationId $_.id })) {
        $Id = Get-NumericDonationId $Row.id
        if ($Id -gt $MaxId) { $MaxId = $Id }
        if ($After -gt 0 -and $Id -gt 0 -and $Id -le $After) { continue }

        if ([string]$Row.type -ne "donation") {
            $SkippedNotDonation++
            continue
        }

        $CreatedRaw = Get-FirstPresentValue @($Row.created_at, $Row.createdAt, $Row.date)
        $CreatedAtUtc = Convert-ToUtcDateTimeOffset $CreatedRaw
        if ($null -eq $CreatedAtUtc) {
            $SkippedInvalidDate++
            continue
        }
        if ($CreatedAtUtc -lt $MinDonationTimeUtc) {
            $SkippedOld++
            continue
        }

        $Donation = Convert-DonatePayNotificationRow $Row
        if ($Donation -and (Add-ServerDonation $Donation)) { $Added++ }
    }

    return [pscustomobject]@{
        ok = $true
        received = @($Rows).Count
        added = $Added
        skippedOld = $SkippedOld
        skippedInvalidDate = $SkippedInvalidDate
        skippedNotDonation = $SkippedNotDonation
        lastSeenId = $MaxId
        sessionStartedAt = $SessionStartedAtUtc.ToString("o")
        minDonationTime = $MinDonationTimeUtc.ToString("o")
    }
}

function Invoke-CollectorTick {
    $Entered = [System.Threading.Monitor]::TryEnter($script:StateLock)
    if (-not $Entered) { return }
    try {
        $Now = Get-Date
        $DA = $script:ServerState.Integrations.DonationAlerts
        $RunDA = $DA.Enabled -and (
            -not $DA.LastPollAt -or
            ((New-TimeSpan -Start ([DateTimeOffset]::Parse([string]$DA.LastPollAt).DateTime) -End $Now).TotalSeconds -ge [int]$DA.PollingIntervalSec)
        )
        if ($RunDA) { $DA.LastPollAt = $Now.ToUniversalTime().ToString("o") }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }

    if ($RunDA) { Invoke-DonationAlertsCollectorPoll }
}

function Invoke-CollectorTickIfDue {
    if (-not $script:CollectorEnabled) {
        return
    }

    $Now = Get-Date
    if ($Now -lt $script:NextCollectorTickAt) {
        return
    }

    $script:NextCollectorTickAt = $Now.AddSeconds(5)

    try {
        Invoke-CollectorTick
    }
    catch {
        Write-Host "[Collector] tick error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-AppLog -Level "ERROR" -Message "[Collector] tick error: $($_.Exception.Message)"
    }
}

function Update-CollectorConfig {
    param([object]$InputData)

    $AnyConfigChanged = $false
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DPInput = $InputData.donatepay
        $DAInput = $InputData.donationalerts

        if ($DPInput) {
            $DP = $script:ServerState.Integrations.DonatePay
            $PreviousAccessToken = $DP.AccessToken
            $PreviousUserId = $DP.UserId
            $NewEnabled = [bool]$DPInput.enabled -and -not [string]::IsNullOrWhiteSpace([string]$DPInput.accessToken)
            $Signature = "$NewEnabled|$([string]$DPInput.region)|$([string]$DPInput.accessToken)|$([string]$DPInput.userId)"
            $Changed = $DP.Signature -ne $Signature
            $AnyConfigChanged = $AnyConfigChanged -or $Changed
            $DP.Enabled = $NewEnabled
            $DP.Region = if ([string]$DPInput.region -eq "eu") { "eu" } else { "ru" }
            $DP.AccessToken = [string]$DPInput.accessToken
            $DP.UserId = [string]$DPInput.userId
            $DP.Signature = $Signature
            $DP.PollingIntervalSec = 15
            if ($Changed) {
                $DP.LastSeenId = $null
                $DP.BaselineReady = $false
                $DP.BackoffUntil = $null
                $DP.LastPollAt = $null
                $DP.Status = if ($DP.Enabled) { "connecting" } else { "disconnected" }
                $DP.LastError = ""
            }
            else {
                $DP.AccessToken = $PreviousAccessToken
                $DP.UserId = $PreviousUserId
                if (-not $DP.Enabled) {
                    $DP.Status = "disconnected"
                    $DP.LastError = ""
                }
                elseif ($DP.Status -eq "disconnected") {
                    $DP.Status = "connecting"
                }
            }
        }

        if ($DAInput) {
            $DA = $script:ServerState.Integrations.DonationAlerts
            $PreviousAccessToken = $DA.AccessToken
            $PreviousTokenType = $DA.TokenType
            $Interval = 10
            try { $Interval = [Math]::Max(3, [int]$DAInput.pollingIntervalSec) } catch {}
            $NewEnabled = [bool]$DAInput.enabled -and -not [string]::IsNullOrWhiteSpace([string]$DAInput.accessToken)
            $Signature = "$NewEnabled|$([string]$DAInput.appId)|$([string]$DAInput.accessToken)|$([string]$DAInput.userId)|$Interval"
            $Changed = $DA.Signature -ne $Signature
            $AnyConfigChanged = $AnyConfigChanged -or $Changed
            $DA.Enabled = $NewEnabled
            $DA.AppId = [string]$DAInput.appId
            $DA.AccessToken = [string]$DAInput.accessToken
            $DA.TokenType = if ($DAInput.tokenType) { [string]$DAInput.tokenType } else { "Bearer" }
            $DA.UserId = [string]$DAInput.userId
            $DA.Signature = $Signature
            $DA.PollingIntervalSec = $Interval
            if ($Changed) {
                $DA.LastSeenId = $null
                $DA.BaselineReady = $false
                $DA.BackoffUntil = $null
                $DA.LastPollAt = $null
                $DA.Status = if ($DA.Enabled) { "connecting" } else { "disconnected" }
                $DA.LastError = ""
            }
            else {
                $DA.AccessToken = $PreviousAccessToken
                $DA.TokenType = $PreviousTokenType
                if (-not $DA.Enabled) {
                    $DA.Status = "disconnected"
                    $DA.LastError = ""
                }
                elseif ($DA.Status -eq "disconnected") {
                    $DA.Status = "connecting"
                }
            }
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }

    $script:CollectorEnabled = $true
    $script:NextCollectorTickAt = (Get-Date).AddMilliseconds(500)

    if ($AnyConfigChanged) {
        Write-Host "[Collector] config updated" -ForegroundColor Green
        Write-AppLog -Level "INFO" -Message "[Collector] config updated"
        if ($script:ServerState.Integrations.DonatePay.Enabled) { Write-Host "[Collector] DonatePay enabled" -ForegroundColor Green }
        if ($script:ServerState.Integrations.DonationAlerts.Enabled) { Write-Host "[Collector] DonationAlerts enabled" -ForegroundColor Green }
        if ($script:ServerState.Integrations.DonatePay.Enabled) { Write-AppLog -Level "INFO" -Message "[Collector] DonatePay enabled" }
        if ($script:ServerState.Integrations.DonationAlerts.Enabled) { Write-AppLog -Level "INFO" -Message "[Collector] DonationAlerts enabled" }
    }
}

function Get-CollectorStatus {
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DP = $script:ServerState.Integrations.DonatePay
        $DA = $script:ServerState.Integrations.DonationAlerts
        return [pscustomobject]@{
            ok = $true
            sessionStartedAt = $script:ServerState.SessionStartedAt
            services = [pscustomobject]@{
                donatepay = [pscustomobject]@{
                    enabled = [bool]$DP.Enabled
                    status = [string]$DP.Status
                    lastError = [string]$DP.LastError
                    lastEventAt = [string]$DP.LastEventAt
                    baselineReady = [bool]$DP.BaselineReady
                }
                donationalerts = [pscustomobject]@{
                    enabled = [bool]$DA.Enabled
                    status = [string]$DA.Status
                    lastError = [string]$DA.LastError
                    lastEventAt = [string]$DA.LastEventAt
                    baselineReady = [bool]$DA.BaselineReady
                }
            }
            pendingServerDonations = $script:ServerState.DonationsPending.Count
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
}

function Stop-CollectorRuntime {
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        foreach ($Service in @($script:ServerState.Integrations.DonatePay, $script:ServerState.Integrations.DonationAlerts)) {
            $Service.Enabled = $false
            $Service.AccessToken = ""
            $Service.Status = "disconnected"
            $Service.LastError = ""
            $Service.BackoffUntil = $null
            $Service.LastPollAt = $null
            $Service.LastSeenId = $null
            $Service.BaselineReady = $false
            $Service.Signature = ""
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    $script:CollectorEnabled = $false
    $script:NextCollectorTickAt = Get-Date
}

function Get-CollectorDonations {
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        return [pscustomobject]@{
            ok = $true
            pending = @($script:ServerState.DonationsPending)
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
}

function Ack-CollectorDonations {
    param([object]$InputData)

    $Ids = @($InputData.ids)
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        if ($Ids.Count -le 0) {
            return [pscustomobject]@{ ok = $true; removed = 0 }
        }
        $Before = $script:ServerState.DonationsPending.Count
        $Remaining = [System.Collections.ArrayList]::new()
        foreach ($Donation in $script:ServerState.DonationsPending) {
            if ($Ids -notcontains [string]$Donation.id) {
                [void]$Remaining.Add($Donation)
            }
        }
        $script:ServerState.DonationsPending = $Remaining
        return [pscustomobject]@{
            ok = $true
            removed = ($Before - $script:ServerState.DonationsPending.Count)
            pending = $script:ServerState.DonationsPending.Count
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
}

function Clear-CollectorDonations {
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $script:ServerState.DonationsPending.Clear()
        $script:ServerState.SeenDonationKeys.Clear()
        return [pscustomobject]@{ ok = $true }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
}

foreach ($Port in $Ports) {
    $Candidate = $null
    try {
        $Candidate = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Parse($HostAddress),
            $Port
        )
        $Candidate.Start()
        $Listener = $Candidate
        $SelectedPort = $Port
        $script:SelectedPort = $SelectedPort
        $SiteUrl = "http://${HostAddress}:${SelectedPort}/koleso_papich.html?view=admin"
        break
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "HTTP listener start failed on port ${Port}: $($_.Exception.Message)"
        if ($Candidate) {
            try { $Candidate.Stop() } catch {}
        }
    }
}

if (-not $Listener) {
    Set-CriticalServerError "Порт 5500 занят. Закройте другую копию приложения или освободите порт 5500."
    while (-not (Test-ServerStopRequested)) {
        Start-Sleep -Milliseconds 300
    }
    exit 1
}

Write-AppLog -Level "INFO" -Message "Server runtime start"
Write-AppLog -Level "INFO" -Message "Root: $Root"
Write-AppLog -Level "INFO" -Message "RootPath: $RootPath"
Write-AppLog -Level "INFO" -Message "LogPath: $LogPath"
Write-AppLog -Level "INFO" -Message "TrayIconPath: $TrayIconPath"
Write-AppLog -Level "INFO" -Message "TrayErrorIconPath: $TrayErrorIconPath"
Write-AppLog -Level "INFO" -Message "Port: $SelectedPort"
Write-AppLog -Level "INFO" -Message "SiteUrl: $SiteUrl"
Write-AppLog -Level "INFO" -Message "HTTP listener started"
if ($TrayState) {
    try { $TrayState.Started = $true } catch {}
}

Test-AppVersion
Write-AppVersionLog

try {
    while (-not (Test-ServerStopRequested)) {
        try {
            Invoke-CollectorTickIfDue

            if (-not $Listener.Pending()) {
                Start-Sleep -Milliseconds 100
                continue
            }

            $Client = $Listener.AcceptTcpClient()
            $Reader = $null
            $Stream = $null
            try {
            $Stream = $Client.GetStream()
            $Reader = [System.IO.StreamReader]::new(
                $Stream,
                [System.Text.Encoding]::UTF8,
                $false,
                4096,
                $true
            )
            $script:CurrentRequestOrigin = ""
            $script:CurrentCorsOrigin = ""

            $RequestLine = $Reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($RequestLine)) {
                continue
            }

            $Headers = @{}
            while ($true) {
                $HeaderLine = $Reader.ReadLine()
                if ([string]::IsNullOrEmpty($HeaderLine)) { break }
                $Separator = $HeaderLine.IndexOf(":")
                if ($Separator -gt 0) {
                    $Name = $HeaderLine.Substring(0, $Separator).Trim().ToLowerInvariant()
                    $Value = $HeaderLine.Substring($Separator + 1).Trim()
                    $Headers[$Name] = $Value
                }
            }

            $Parts = $RequestLine.Split(" ")
            if ($Parts.Length -lt 2) {
                Send-Json $Stream 400 @{ ok = $false; error = "Bad request."; status = 400 }
                continue
            }

            $Method = $Parts[0].ToUpperInvariant()
            $HeadOnly = $Method -eq "HEAD"
            $RawTarget = $Parts[1].Split("?")[0]
            $DecodedTarget = [System.Uri]::UnescapeDataString($RawTarget)
            $ContentLength = 0
            if ($Headers.ContainsKey("content-length")) {
                [void][int]::TryParse($Headers["content-length"], [ref]$ContentLength)
            }

            $script:CurrentRequestOrigin = if ($Headers.ContainsKey("origin")) { [string]$Headers["origin"] } else { "" }
            $script:CurrentCorsOrigin = Get-AllowedCorsOrigin $script:CurrentRequestOrigin
            $IsApiRequest = Test-ApiRequestPath $DecodedTarget

            if ($IsApiRequest -and -not [string]::IsNullOrWhiteSpace($script:CurrentRequestOrigin) -and $null -eq $script:CurrentCorsOrigin) {
                Write-AppLog -Level "WARN" -Message "Blocked API request from disallowed Origin: $script:CurrentRequestOrigin"
                Send-Json $Stream 403 @{ ok = $false; error = "Forbidden origin."; status = 403 } $HeadOnly
                continue
            }

            if ($Method -eq "OPTIONS") {
                Send-Json $Stream 204 $null
                continue
            }

            if ($DecodedTarget -eq "/api/health") {
                if ($Method -ne "GET") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                }
                else {
                    Send-Json $Stream 200 @{ ok = $true; server = "papich-wheel-local" } $HeadOnly
                }
                continue
            }

            if ($DecodedTarget -eq "/api/app/bootstrap") {
                if ($Method -ne "POST") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                }
                else {
                    $InputData = Read-JsonBody $Reader $ContentLength
                    if ($InputData -and $InputData.collector) {
                        Update-CollectorConfig $InputData.collector
                    }
                    Send-Json $Stream 200 ([pscustomobject]@{
                        ok = $true
                        health = [pscustomobject]@{
                            ok = $true
                            server = "papich-wheel-local"
                        }
                        version = Get-AppVersionStatus
                        collector = Get-CollectorStatus
                    }) $HeadOnly
                }
                continue
            }

            if ($DecodedTarget -eq "/api/app/version") {
                if ($Method -ne "GET") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                }
                else {
                    Send-Json $Stream 200 (Get-AppVersionStatus) $HeadOnly
                }
                continue
            }

            if ($DecodedTarget.StartsWith("/api/collector/")) {
                try {
                    switch ($DecodedTarget) {
                        "/api/collector/config" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            Update-CollectorConfig $InputData
                            Send-Json $Stream 200 (Get-CollectorStatus)
                        }
                        "/api/collector/status" {
                            if ($Method -ne "GET") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Get-CollectorStatus) $HeadOnly
                        }
                        "/api/collector/stop" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Stop-CollectorRuntime
                            Send-Json $Stream 200 @{ ok = $true }
                        }
                        "/api/collector/donations" {
                            if ($Method -ne "GET") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Get-CollectorDonations) $HeadOnly
                        }
                        "/api/collector/donations/ack" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            Send-Json $Stream 200 (Ack-CollectorDonations $InputData)
                        }
                        "/api/collector/donations/clear" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Clear-CollectorDonations)
                        }
                        default {
                            Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                        }
                    }
                }
                catch {
                    Write-Host "[Collector] request error: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-AppLog -Level "ERROR" -Message "[Collector] request error: $($_.Exception.Message)"
                    Send-Json $Stream 500 @{
                        ok = $false
                        error = "Collector request failed."
                        exceptionMessage = Get-MaskedText $_.Exception.Message
                        status = 500
                    }
                }
                continue
            }

            if ($DecodedTarget.StartsWith("/api/da/")) {
                if ($Method -ne "POST") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                    continue
                }

                try {
                    $InputData = Read-JsonBody $Reader $ContentLength
                    $ApiFound = $true
                    $Result = $null
                    switch ($DecodedTarget) {
                        "/api/da/token" {
                            $ApiFound = $false
                        }
                        "/api/da/refresh" {
                            $ApiFound = $false
                        }
                        "/api/da/user" {
                            $Result = Invoke-DonationAlertsApi `
                                "https://www.donationalerts.com/api/v1/user/oauth" `
                                ([string]$InputData.access_token) `
                                $DecodedTarget
                        }
                        "/api/da/donations" {
                            $Result = Invoke-DonationAlertsApi `
                                "https://www.donationalerts.com/api/v1/alerts/donations" `
                                ([string]$InputData.access_token) `
                                $DecodedTarget
                        }
                        default {
                            $ApiFound = $false
                        }
                    }
                    if ($ApiFound) {
                        if ($Result -and $Result.ok -eq $false) {
                            Write-UpstreamErrorLog "DonationAlerts" $Result
                            Send-Json $Stream 500 $Result
                        }
                        else {
                            Send-Json $Stream 200 $Result
                        }
                    }
                    else {
                        Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                    }
                }
                catch {
                    $FriendlyError = if ($_.Exception -is [System.ArgumentException]) {
                        $_.Exception.Message
                    } else {
                        Get-FriendlyProxyError $_.Exception
                    }
                    $ErrorData = [pscustomobject]@{
                        ok = $false
                        endpoint = $DecodedTarget
                        method = "POST"
                        upstreamUrl = ""
                        upstreamStatus = $null
                        upstreamBody = ""
                        error = $FriendlyError
                        exceptionMessage = Get-MaskedText $_.Exception.Message
                        status = 500
                    }
                    Write-UpstreamErrorLog "DonationAlerts" $ErrorData
                    Send-Json $Stream 500 $ErrorData
                }
                continue
            }

            if ($DecodedTarget.StartsWith("/api/dp/")) {
                if ($Method -ne "POST") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                    continue
                }

                try {
                    $InputData = Read-JsonBody $Reader $ContentLength
                    $ApiFound = $true
                    $Result = $null
                    $Region = [string]$InputData.region
                    switch ($DecodedTarget) {
                        "/api/dp/user" {
                            $Result = Invoke-DonatePayApi $Region "/api/v1/user" $InputData $DecodedTarget
                        }
                        "/api/dp/transactions" {
                            $Result = Invoke-DonatePayApi $Region "/api/v1/transactions" $InputData $DecodedTarget
                        }
                        "/api/dp/recovery-transactions" {
                            $Result = Invoke-DonatePayRecoveryTransactions $InputData
                        }
                        default {
                            $ApiFound = $false
                        }
                    }
                    if ($ApiFound) {
                        if ($Result -and $Result.ok -eq $false) {
                            Write-Host "DonatePay proxy request failed." -ForegroundColor Yellow
                            Write-AppLog -Level "ERROR" -Message "DonatePay proxy request failed."
                            Send-Json $Stream 500 $Result
                        }
                        else {
                            Send-Json $Stream 200 $Result
                        }
                    }
                    else {
                        Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                    }
                }
                catch {
                    $FriendlyError = if ($_.Exception -is [System.ArgumentException]) {
                        $_.Exception.Message
                    } else {
                        Get-FriendlyDonatePayProxyError $_.Exception
                    }
                    Write-Host "DonatePay proxy request failed." -ForegroundColor Yellow
                    Write-AppLog -Level "ERROR" -Message "DonatePay proxy request failed: $FriendlyError"
                    Send-Json $Stream 500 @{
                        ok = $false
                        endpoint = $DecodedTarget
                        method = "GET"
                        upstreamUrl = ""
                        upstreamStatus = $null
                        upstreamBody = ""
                        error = $FriendlyError
                        status = 500
                    }
                }
                continue
            }

            if ($Method -ne "GET" -and -not $HeadOnly) {
                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                continue
            }

            if ($DecodedTarget -eq "/") {
                $DecodedTarget = "/koleso_papich.html"
            }

            $RelativePath = $DecodedTarget.TrimStart([char]"/").Replace(
                [char]"/",
                [System.IO.Path]::DirectorySeparatorChar
            )
            $RequestedPath = Resolve-SafePath $RootPath $RelativePath

            if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
                Send-Json $Stream 403 @{ ok = $false; error = "Forbidden."; status = 403 } $HeadOnly
                continue
            }

            if (-not [System.IO.File]::Exists($RequestedPath)) {
                Send-Json $Stream 404 @{ ok = $false; error = "Not found."; status = 404 } $HeadOnly
                continue
            }

            $Body = [System.IO.File]::ReadAllBytes($RequestedPath)
            $ContentType = Get-ContentType $RequestedPath
            Send-Response $Stream 200 "OK" $ContentType $Body $HeadOnly
        }
            catch {
                Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-AppLog -Level "ERROR" -Message "Request error: $($_.Exception.Message)"
                if ($Stream) {
                    try {
                        Send-Json $Stream 500 @{ ok = $false; error = "Local server request failed."; status = 500 }
                    } catch {}
                }
            }
            finally {
                if ($Reader) { try { $Reader.Dispose() } catch {} }
                if ($Stream) { try { $Stream.Dispose() } catch {} }
                if ($Client) { try { $Client.Close() } catch {} }
            }
        }
        catch {
            Write-Host "Server loop error: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-AppLog -Level "ERROR" -Message "Server loop error: $($_.Exception.Message)"
            Start-Sleep -Milliseconds 300
            continue
        }
    }
}
finally {
    Write-AppLog -Level "INFO" -Message "Server runtime stopping"
    if ($Listener) {
        try { $Listener.Stop(); Write-AppLog -Level "INFO" -Message "HTTP listener stopped" } catch {
            Write-AppLog -Level "ERROR" -Message "HTTP listener stop error: $($_.Exception.Message)"
        }
    }
}
