param(
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$HostAddress = "127.0.0.1"
$Ports = @(5500)
$Listener = $null
$SelectedPort = $null
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
        break
    }
    catch {
        if ($Candidate) {
            try { $Candidate.Stop() } catch {}
        }
    }
}

if (-not $Listener) {
    Write-Host "Порт 5500 занят. Закройте другую копию приложения или освободите порт 5500." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$Root = $Root.Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $PSScriptRoot
}
$RootPath = [System.IO.Path]::GetFullPath($Root)
$SiteUrl = "http://${HostAddress}:${SelectedPort}/koleso_papich.html?view=admin"

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

function Send-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$ContentType,
        [byte[]]$Body,
        [bool]$HeadOnly = $false
    )

    $HeaderText = "HTTP/1.1 $StatusCode $StatusText`r`n" +
                  "Content-Type: $ContentType`r`n" +
                  "Content-Length: $($Body.Length)`r`n" +
                  "Cache-Control: no-cache`r`n" +
                  "Access-Control-Allow-Origin: *`r`n" +
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
    $Masked = [System.Text.RegularExpressions.Regex]::Replace(
        $Url,
        "access_token=([^&]+)",
        "access_token=***"
    )
    $Masked = [System.Text.RegularExpressions.Regex]::Replace($Masked, "refresh_token=([^&]+)", "refresh_token=***")
    $Masked = [System.Text.RegularExpressions.Regex]::Replace($Masked, "client_secret=([^&]+)", "client_secret=***")
    $Masked = [System.Text.RegularExpressions.Regex]::Replace($Masked, "code=([^&]+)", "code=***")
    return $Masked
}

function Get-MaskedText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $Masked = $Text
    $Keys = @("access_token", "refresh_token", "client_secret", "code")
    foreach ($Key in $Keys) {
        $Masked = [System.Text.RegularExpressions.Regex]::Replace(
            $Masked,
            "(`"$Key`"\s*:\s*`")[^`"]+(`")",
            "`$1***`$2"
        )
        $Masked = [System.Text.RegularExpressions.Regex]::Replace(
            $Masked,
            "($Key=)[^&\s]+",
            "`$1***"
        )
    }
    $Masked = [System.Text.RegularExpressions.Regex]::Replace(
        $Masked,
        "(Bearer\s+)[A-Za-z0-9._~+/=-]+",
        "`$1***"
    )
    return $Masked
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
        upstreamBody = Get-MaskedText $Body
        error = $Message
        exceptionMessage = Get-MaskedText $Error.Message
        status = 500
    }
}

function Write-UpstreamErrorLog {
    param(
        [string]$Service,
        [object]$ErrorData
    )

    Write-Host "$Service proxy request failed." -ForegroundColor Yellow
    if ($ErrorData.endpoint) { Write-Host "  endpoint: $($ErrorData.endpoint)" -ForegroundColor Yellow }
    if ($ErrorData.upstreamStatus) { Write-Host "  upstream status: $($ErrorData.upstreamStatus)" -ForegroundColor Yellow }
    if ($ErrorData.upstreamUrl) { Write-Host "  upstream url: $($ErrorData.upstreamUrl)" -ForegroundColor Yellow }
    if ($ErrorData.upstreamBody) { Write-Host "  upstream body: $($ErrorData.upstreamBody)" -ForegroundColor Yellow }
    if ($ErrorData.exceptionMessage) { Write-Host "  exception: $($ErrorData.exceptionMessage)" -ForegroundColor Yellow }
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

function Invoke-DonationAlertsToken {
    param([object]$InputData, [string]$GrantType, [string]$LocalEndpoint)

    return [pscustomobject]@{
        ok = $false
        endpoint = $LocalEndpoint
        method = "POST"
        upstreamUrl = ""
        upstreamStatus = $null
        upstreamBody = ""
        error = "DonationAlerts authorization-code flow is disabled. Use implicit OAuth."
        exceptionMessage = ""
        status = 404
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
            return $false
        }
        [void]$script:ServerState.DonationsPending.Add([pscustomobject]$Donation)
        Write-Host "[Collector] pending donations: $($script:ServerState.DonationsPending.Count)" -ForegroundColor DarkCyan
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

function Convert-DonatePayTransactionRow {
    param([object]$Raw)

    if ($null -eq $Raw -or $null -eq $Raw.id) { return $null }
    $ExternalId = [string]$Raw.id
    $CreatedRaw = Get-FirstPresentValue @($Raw.created_at, $Raw.createdAt, $Raw.date)
    return @{
        id = "server-donatepay-$ExternalId"
        source = "donatepay"
        externalId = $ExternalId
        username = [string](Get-FirstPresentValue @($Raw.what, $Raw.name, $Raw.username, $Raw.vars.name, "Anonymous"))
        amount = Get-DonationAmountValue (Get-FirstPresentValue @($Raw.sum, $Raw.amount, $Raw.vars.sum, 0))
        currency = [string](Get-FirstPresentValue @($Raw.currency, $Raw.vars.currency, "RUB"))
        message = [string](Get-FirstPresentValue @($Raw.comment, $Raw.vars.comment, $Raw.text, ""))
        createdAt = Convert-DonationDateToIso $CreatedRaw "donatepay"
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

function Refresh-DonationAlertsCollectorToken {
    return $false
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
    }
}

function Invoke-DonatePayCollectorPoll {
    return
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
        if ($script:ServerState.Integrations.DonatePay.Enabled) { Write-Host "[Collector] DonatePay enabled" -ForegroundColor Green }
        if ($script:ServerState.Integrations.DonationAlerts.Enabled) { Write-Host "[Collector] DonationAlerts enabled" -ForegroundColor Green }
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

Write-Host ""
Write-Host "Papich Wheel is running:" -ForegroundColor Green
Write-Host $SiteUrl -ForegroundColor Cyan
Write-Host ""
Write-Host "Close this window or press Ctrl+C to stop the server."

try {
    Start-Process $SiteUrl
}
catch {
    Write-Host "Could not open the browser automatically. Open the URL manually." -ForegroundColor Yellow
}

try {
    while ($true) {
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
            $RequestedPath = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($RootPath, $RelativePath)
            )
            $RootPrefix = $RootPath.TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            ) + [System.IO.Path]::DirectorySeparatorChar

            if (-not $RequestedPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
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
            Start-Sleep -Milliseconds 300
            continue
        }
    }
}
finally {
    if ($Listener) {
        try { $Listener.Stop() } catch {}
    }
}
