param(
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$HostAddress = "127.0.0.1"
$Ports = 5500..5503
$Listener = $null
$SelectedPort = $null

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
    Write-Host "Could not start the server: ports 5500-5503 are in use." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$Root = $Root.Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $PSScriptRoot
}
$RootPath = [System.IO.Path]::GetFullPath($Root)
$SiteUrl = "http://${HostAddress}:${SelectedPort}/koleso_papich.html?view=wheel"

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
    return [System.Text.RegularExpressions.Regex]::Replace(
        $Url,
        "access_token=([^&]+)",
        "access_token=***"
    )
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
        upstreamBody = $Body
        error = $Message
        status = 500
    }
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

    if ($Path -eq "/api/v1/transactions") {
        $Limit = if ($InputData.limit) { [string]$InputData.limit } else { "100" }
        Add-QueryParam $QueryParts "limit" $Limit
        Add-QueryParam $QueryParts "order" "DESC"
        Add-QueryParam $QueryParts "type" "donation"
        Add-QueryParam $QueryParts "status" $InputData.status
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
    param(
        [object]$InputData,
        [string]$GrantType
    )

    if ($GrantType -eq "authorization_code") {
        if (
            [string]::IsNullOrWhiteSpace([string]$InputData.client_id) -or
            [string]::IsNullOrWhiteSpace([string]$InputData.client_secret) -or
            [string]::IsNullOrWhiteSpace([string]$InputData.redirect_uri) -or
            [string]::IsNullOrWhiteSpace([string]$InputData.code)
        ) {
            throw [System.ArgumentException]::new("Missing OAuth token exchange fields.")
        }
        $Body = @{
            grant_type = "authorization_code"
            client_id = [string]$InputData.client_id
            client_secret = [string]$InputData.client_secret
            redirect_uri = [string]$InputData.redirect_uri
            code = [string]$InputData.code
        }
    }
    else {
        if (
            [string]::IsNullOrWhiteSpace([string]$InputData.client_id) -or
            [string]::IsNullOrWhiteSpace([string]$InputData.client_secret) -or
            [string]::IsNullOrWhiteSpace([string]$InputData.refresh_token)
        ) {
            throw [System.ArgumentException]::new("Missing OAuth refresh fields.")
        }
        $Body = @{
            grant_type = "refresh_token"
            client_id = [string]$InputData.client_id
            client_secret = [string]$InputData.client_secret
            refresh_token = [string]$InputData.refresh_token
            scope = "oauth-user-show oauth-donation-index"
        }
    }

    return Invoke-RestMethod `
        -Uri "https://www.donationalerts.com/oauth/token" `
        -Method Post `
        -Body $Body `
        -ContentType "application/x-www-form-urlencoded" `
        -TimeoutSec 30
}

function Invoke-DonationAlertsApi {
    param(
        [string]$Url,
        [string]$AccessToken
    )

    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw [System.ArgumentException]::new("Missing access token.")
    }

    return Invoke-RestMethod `
        -Uri $Url `
        -Method Get `
        -Headers @{
            Authorization = "Bearer $AccessToken"
            Accept = "application/json"
        } `
        -TimeoutSec 30
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
                            $Result = Invoke-DonationAlertsToken $InputData "authorization_code"
                        }
                        "/api/da/refresh" {
                            $Result = Invoke-DonationAlertsToken $InputData "refresh_token"
                        }
                        "/api/da/user" {
                            $Result = Invoke-DonationAlertsApi `
                                "https://www.donationalerts.com/api/v1/user/oauth" `
                                ([string]$InputData.access_token)
                        }
                        "/api/da/donations" {
                            $Result = Invoke-DonationAlertsApi `
                                "https://www.donationalerts.com/api/v1/alerts/donations" `
                                ([string]$InputData.access_token)
                        }
                        default {
                            $ApiFound = $false
                        }
                    }
                    if ($ApiFound) {
                        Send-Json $Stream 200 $Result
                    }
                    else {
                        Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                    }
                }
                catch {
                    $UpstreamStatus = $null
                    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                        try {
                            $UpstreamStatus = [int]$_.Exception.Response.StatusCode
                        } catch {}
                    }
                    $FriendlyError = if ($_.Exception -is [System.ArgumentException]) {
                        $_.Exception.Message
                    } else {
                        Get-FriendlyProxyError $_.Exception
                    }
                    Write-Host "DonationAlerts proxy request failed." -ForegroundColor Yellow
                    Send-Json $Stream 500 @{
                        ok = $false
                        error = $FriendlyError
                        status = 500
                        upstream_status = $UpstreamStatus
                    }
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
            if ($Reader) { $Reader.Dispose() }
            if ($Stream) { $Stream.Dispose() }
            $Client.Close()
        }
    }
}
finally {
    $Listener.Stop()
}
