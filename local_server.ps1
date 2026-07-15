param(
    [string]$Root = $PSScriptRoot,
    [switch]$ServerOnly,
    [switch]$LlmWorkerOnly,
    [switch]$DonationAlertsPollWorkerOnly,
    [AllowNull()][object]$DonationAlertsPollInput = $null,
    [switch]$DonatePayRecoveryWorkerOnly,
    [AllowNull()][object]$DonatePayRecoveryWorkerInput = $null,
    [switch]$SkipStartupNetwork,
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
$LocalAppDataPath = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppDataPath)) {
    $LocalAppDataPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
}
if ([string]::IsNullOrWhiteSpace($LocalAppDataPath)) {
    $LocalAppDataPath = $RootPath
}
$script:SecretsDir = Join-Path $LocalAppDataPath "PapichWheel"
$script:SecretsPath = Join-Path $script:SecretsDir "secrets.json"
$script:ResetEpochPath = Join-Path $script:SecretsDir "reset_epoch.txt"
$script:CacheDir = Join-Path $script:SecretsDir "cache"
$script:SteamSearchCachePath = Join-Path $script:CacheDir "steam_search_cache.json"
$script:AnimeSearchCachePath = Join-Path $script:CacheDir "anime_search_cache.json"
$script:LlmJobsPath = Join-Path $script:CacheDir "llm_jobs.json"
$script:CollectorStatePath = Join-Path $script:CacheDir "collector_state.json"
$script:CurrencyRatesCachePath = Join-Path $script:CacheDir "currency_rates.json"
$script:LlmJobsMutexName = "PapichWheelLlmJobs"
$script:CollectorStateMutexName = "PapichWheelCollectorState"
$script:CacheMutexName = "PapichWheelSearchCache"
$script:CurrencyRatesMutexName = "PapichWheelCurrencyRates"
$script:SecretsMutexName = "PapichWheelSecrets"
$script:CurrencyRatesInitialized = $false
$script:CurrencyRatesLoadCount = 0
$script:CurrencyRateSnapshot = $null
$script:MaxRequestLineChars = 8192
$script:MaxRequestHeaderChars = 32768
$script:MaxRequestHeaderCount = 100
$script:MaxRequestBodyBytes = 4MB
$script:ClientIoTimeoutMs = 15000
$script:LlmPipelineVersion = 8
$script:DefaultLlmModel = "google/gemini-3-flash-preview"
$script:LlmExistingSelectionThreshold = 0.90
$script:LlmMaxItems = 5
$script:LlmMaxSearchQueriesPerItem = 4
$script:LlmMaxCandidatesPerItem = 5

function Mask-SecretText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $Masked = $Text
    $Masked = [System.Text.RegularExpressions.Regex]::Replace(
        $Masked,
        '(?i)(https?://[^/\s:@]+:)([^@\s/]+)(@)',
        '$1***$3'
    )
    $Patterns = @(
        '(?i)(access[_-]?token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(refresh[_-]?token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(client[_-]?secret["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(api[_-]?key["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(x-local-app-token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(local[_-]?app[_-]?token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(app[_-]?token["''\s:=]+)([^"&''\s,}]+)',
        '(?i)(authorization["''\s:=]+Bearer\s+)([^"&''\s,}]+)',
        '(?i)([?&]code=)([^&#\s]+)',
        '(?i)((?:authorizationCode|oauthCode)["''\s:=]+)([^"&''\s,}]+)',
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

function New-LocalAppToken {
    $Bytes = New-Object byte[] 32
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $Rng.GetBytes($Bytes)
    }
    finally {
        if ($Rng) { $Rng.Dispose() }
    }
    return [System.BitConverter]::ToString($Bytes).Replace("-", "").ToLowerInvariant()
}

$script:LocalAppToken = New-LocalAppToken

function New-LocalScriptNonce {
    $Bytes = New-Object byte[] 16
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $Rng.GetBytes($Bytes)
    }
    finally {
        if ($Rng) { $Rng.Dispose() }
    }
    return [Convert]::ToBase64String($Bytes)
}

$script:LocalScriptNonce = New-LocalScriptNonce

function Ensure-SecretsDirectory {
    try {
        if (-not [System.IO.Directory]::Exists($script:SecretsDir)) {
            [System.IO.Directory]::CreateDirectory($script:SecretsDir) | Out-Null
        }
        return $true
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "Secrets directory init failed: $($_.Exception.Message)"
        return $false
    }
}

function Ensure-CacheDirectory {
    try {
        if (-not [System.IO.Directory]::Exists($script:CacheDir)) {
            [System.IO.Directory]::CreateDirectory($script:CacheDir) | Out-Null
        }
        return $true
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "Cache directory init failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-AppResetEpoch {
    try {
        if (-not [System.IO.File]::Exists($script:ResetEpochPath)) { return "" }
        return ([System.IO.File]::ReadAllText($script:ResetEpochPath, [System.Text.Encoding]::UTF8)).Trim()
    }
    catch {
        Write-AppLog -Level "WARN" -Message "Reset epoch read failed: $($_.Exception.Message)"
        return ""
    }
}

function Set-NewAppResetEpoch {
    if (-not (Ensure-SecretsDirectory)) {
        throw "Reset epoch directory is unavailable."
    }
    $Epoch = "reset-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())-$([Guid]::NewGuid().ToString('N'))"
    $TempPath = "$($script:ResetEpochPath).tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($TempPath, $Epoch, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($script:ResetEpochPath)) {
            try {
                [System.IO.File]::Replace($TempPath, $script:ResetEpochPath, $null)
            }
            catch {
                Move-Item -LiteralPath $TempPath -Destination $script:ResetEpochPath -Force
            }
        }
        else {
            [System.IO.File]::Move($TempPath, $script:ResetEpochPath)
        }
        return $Epoch
    }
    finally {
        if ([System.IO.File]::Exists($TempPath)) {
            try { [System.IO.File]::Delete($TempPath) } catch {}
        }
    }
}

function Protect-SecretString {
    param([AllowNull()][string]$PlainText)

    if ([string]::IsNullOrEmpty($PlainText)) {
        return ""
    }
    $Secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $Secure
}

function Unprotect-SecretString {
    param([AllowNull()][string]$ProtectedText)

    if ([string]::IsNullOrWhiteSpace($ProtectedText)) {
        return ""
    }
    $Secure = ConvertTo-SecureString -String $ProtectedText
    return [System.Net.NetworkCredential]::new("", $Secure).Password
}

function New-EmptySecretsData {
    return [pscustomobject]@{
        version = 1
        integrations = [pscustomobject]@{}
    }
}

function Read-SecretsFile {
    try {
        if (-not [System.IO.File]::Exists($script:SecretsPath)) {
            return New-EmptySecretsData
        }
        $Raw = [System.IO.File]::ReadAllText($script:SecretsPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return New-EmptySecretsData
        }
        $Parsed = $Raw | ConvertFrom-Json
        if (-not $Parsed.integrations) {
            $Parsed | Add-Member -NotePropertyName integrations -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        return $Parsed
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "Secrets file read failed; starting with empty secrets. $($_.Exception.Message)"
        return New-EmptySecretsData
    }
}

function Write-SecretsFile {
    param([object]$Secrets)

    if (-not (Ensure-SecretsDirectory)) {
        return $false
    }
    $TempPath = "$($script:SecretsPath).tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $Json = $Secrets | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($TempPath, $Json, [System.Text.UTF8Encoding]::new($true))
        if ([System.IO.File]::Exists($script:SecretsPath)) {
            try {
                [System.IO.File]::Replace($TempPath, $script:SecretsPath, $null)
            }
            catch {
                Move-Item -LiteralPath $TempPath -Destination $script:SecretsPath -Force
            }
        }
        else {
            [System.IO.File]::Move($TempPath, $script:SecretsPath)
        }
        return $true
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "Secrets file write failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ([System.IO.File]::Exists($TempPath)) {
            try { [System.IO.File]::Delete($TempPath) } catch {}
        }
    }
}

function Get-IntegrationSecretNode {
    param(
        [object]$Secrets,
        [string]$Service
    )

    if (-not $Secrets.integrations) {
        $Secrets | Add-Member -NotePropertyName integrations -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $Secrets.integrations.PSObject.Properties[$Service]) {
        $Secrets.integrations | Add-Member -NotePropertyName $Service -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $Secrets.integrations.$Service
}

function Get-IntegrationSecret {
    param(
        [string]$Service,
        [string]$Name
    )

    $Secrets = Read-SecretsFile
    $Node = $Secrets.integrations.$Service
    if (-not $Node) { return "" }
    $Protected = [string]$Node.$Name
    if ([string]::IsNullOrWhiteSpace($Protected)) { return "" }
    try {
        return Unprotect-SecretString $Protected
    }
    catch {
        Write-AppLog -Level "ERROR" -Message "Secret decrypt failed for ${Service}.${Name}: $($_.Exception.Message)"
        return ""
    }
}

function Set-IntegrationSecret {
    param(
        [string]$Service,
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    $Secrets = Read-SecretsFile
    $Secrets | Add-Member -NotePropertyName version -NotePropertyValue 1 -Force
    $Node = Get-IntegrationSecretNode $Secrets $Service
    $Node | Add-Member -NotePropertyName $Name -NotePropertyValue (Protect-SecretString $Value) -Force
    $Node | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    return Write-SecretsFile $Secrets
}

function Remove-IntegrationSecret {
    param(
        [string]$Service,
        [string]$Name
    )

    $Secrets = Read-SecretsFile
    $Node = $Secrets.integrations.$Service
    if ($Node -and $Node.PSObject.Properties[$Name]) {
        $Node.PSObject.Properties.Remove($Name)
        $Node | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
    }
    return Write-SecretsFile $Secrets
}

function Get-MaskedSecret {
    param([AllowNull()][string]$PlainText)

    if ([string]::IsNullOrEmpty($PlainText)) { return "" }
    if ($PlainText.Length -le 4) { return "****" }
    return "****" + $PlainText.Substring($PlainText.Length - 4)
}

function Get-MaskedProxyUrl {
    param([AllowNull()][string]$ProxyUrl)

    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { return "" }
    try {
        $Uri = [System.Uri]::new($ProxyUrl)
        $UserInfo = if ([string]::IsNullOrWhiteSpace($Uri.UserInfo)) { "" } else { "***@" }
        return "$($Uri.Scheme)://$UserInfo$($Uri.Host):$($Uri.Port)"
    }
    catch {
        return "***"
    }
}

function Get-DonationAlertsStoredToken {
    return Get-IntegrationSecret "donationalerts" "accessToken"
}

function Get-DonatePayStoredToken {
    return Get-IntegrationSecret "donatepay" "accessToken"
}

function Get-OpenRouterStoredApiKey {
    return Get-IntegrationSecret "openrouter" "apiKey"
}

function Get-OpenRouterStoredProxyUrl {
    $ProxyUrl = Get-IntegrationSecret "openrouter" "proxyUrl"
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
        $ProxyUrl = [string]$env:PAPICH_OPENROUTER_PROXY
    }
    return $ProxyUrl
}

function Get-DonationAlertsTokenFingerprint {
    param([AllowNull()][string]$AccessToken)

    if ([string]::IsNullOrWhiteSpace($AccessToken)) { return "" }
    $Sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($AccessToken)
        $Hex = ([System.BitConverter]::ToString($Sha256.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
        return $Hex.Substring(0, 24)
    }
    finally { $Sha256.Dispose() }
}

function Set-DonationAlertsStoredTokenAndResetCurrency {
    param(
        [string]$AccessToken,
        [switch]$UpdateRuntime,
        [AllowNull()][scriptblock]$WriteOperation = $null
    )

    if ([string]::IsNullOrWhiteSpace($AccessToken)) { return $false }
    $Mutex = Enter-NamedMutex $script:SecretsMutexName
    try {
        $Secrets = Read-SecretsFile
        $Secrets | Add-Member -NotePropertyName version -NotePropertyValue 1 -Force
        $Node = Get-IntegrationSecretNode $Secrets "donationalerts"
        $Node | Add-Member -NotePropertyName accessToken -NotePropertyValue (Protect-SecretString $AccessToken) -Force
        foreach ($Name in @("userCurrency", "userCurrencyTokenFingerprint")) {
            if ($Node.PSObject.Properties[$Name]) { $Node.PSObject.Properties.Remove($Name) }
        }
        $Node | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
        $Saved = if ($WriteOperation) { [bool](& $WriteOperation $Secrets) } else { Write-SecretsFile $Secrets }
        if (-not $Saved) { return $false }
        if ($UpdateRuntime -and $script:StateLock -and $script:ServerState) {
            [System.Threading.Monitor]::Enter($script:StateLock)
            try {
                $Runtime = $script:ServerState.Integrations.DonationAlerts
                $Runtime.AccessToken = $AccessToken
                $Runtime.UserCurrency = ""
                $Runtime.Signature = ""
            }
            finally { [System.Threading.Monitor]::Exit($script:StateLock) }
        }
        return $true
    }
    finally { Exit-NamedMutex $Mutex }
}

function Set-DonatePayStoredToken {
    param([string]$AccessToken)

    return Set-IntegrationSecret "donatepay" "accessToken" $AccessToken
}

function Set-OpenRouterStoredApiKey {
    param([string]$ApiKey)

    return Set-IntegrationSecret "openrouter" "apiKey" $ApiKey
}

function Set-OpenRouterStoredProxyUrl {
    param([string]$ProxyUrl)

    return Set-IntegrationSecret "openrouter" "proxyUrl" $ProxyUrl
}

function Get-DonationAlertsStoredUserCurrency {
    $Mutex = Enter-NamedMutex $script:SecretsMutexName
    try {
        $Secrets = Read-SecretsFile
        $Node = $Secrets.integrations.donationalerts
        if (-not $Node) { return "" }
        $ProtectedToken = [string]$Node.accessToken
        $ProtectedCurrency = [string]$Node.userCurrency
        $StoredFingerprint = [string]$Node.userCurrencyTokenFingerprint
        if (
            [string]::IsNullOrWhiteSpace($ProtectedToken) -or
            [string]::IsNullOrWhiteSpace($ProtectedCurrency) -or
            [string]::IsNullOrWhiteSpace($StoredFingerprint)
        ) { return "" }
        try {
            $AccessToken = Unprotect-SecretString $ProtectedToken
            $Currency = Normalize-CurrencyCode (Unprotect-SecretString $ProtectedCurrency)
        }
        catch { return "" }
        $CurrentFingerprint = Get-DonationAlertsTokenFingerprint $AccessToken
        if ($StoredFingerprint -cne $CurrentFingerprint) { return "" }
        return $Currency
    }
    finally { Exit-NamedMutex $Mutex }
}

function Set-DonationAlertsStoredUserCurrencyForToken {
    param(
        [string]$Currency,
        [string]$AccessToken,
        [AllowNull()][string]$ExpectedTokenFingerprint = "",
        [switch]$UpdateRuntime,
        [AllowNull()][scriptblock]$WriteOperation = $null
    )

    $Normalized = Normalize-CurrencyCode $Currency
    $RequestFingerprint = Get-DonationAlertsTokenFingerprint $AccessToken
    if (
        [string]::IsNullOrWhiteSpace($Normalized) -or
        [string]::IsNullOrWhiteSpace($RequestFingerprint) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedTokenFingerprint) -and $ExpectedTokenFingerprint -cne $RequestFingerprint)
    ) { return $false }

    $Mutex = Enter-NamedMutex $script:SecretsMutexName
    try {
        $Secrets = Read-SecretsFile
        $Node = $Secrets.integrations.donationalerts
        if (-not $Node -or [string]::IsNullOrWhiteSpace([string]$Node.accessToken)) { return $false }
        try { $CurrentToken = Unprotect-SecretString ([string]$Node.accessToken) }
        catch { return $false }
        if ((Get-DonationAlertsTokenFingerprint $CurrentToken) -cne $RequestFingerprint) { return $false }

        $Node | Add-Member -NotePropertyName userCurrency -NotePropertyValue (Protect-SecretString $Normalized) -Force
        $Node | Add-Member -NotePropertyName userCurrencyTokenFingerprint -NotePropertyValue $RequestFingerprint -Force
        $Node | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
        $Saved = if ($WriteOperation) { [bool](& $WriteOperation $Secrets) } else { Write-SecretsFile $Secrets }
        if (-not $Saved) { return $false }

        if ($UpdateRuntime -and $script:StateLock -and $script:ServerState) {
            [System.Threading.Monitor]::Enter($script:StateLock)
            try {
                $Runtime = $script:ServerState.Integrations.DonationAlerts
                $RuntimeFingerprint = Get-DonationAlertsTokenFingerprint ([string]$Runtime.AccessToken)
                if ([string]::IsNullOrWhiteSpace([string]$Runtime.AccessToken) -or $RuntimeFingerprint -ceq $RequestFingerprint) {
                    $Runtime.UserCurrency = $Normalized
                }
            }
            finally { [System.Threading.Monitor]::Exit($script:StateLock) }
        }
        return $true
    }
    finally { Exit-NamedMutex $Mutex }
}

function Remove-DonationAlertsStoredToken {
    $Mutex = Enter-NamedMutex $script:SecretsMutexName
    try {
        $Secrets = Read-SecretsFile
        $Node = $Secrets.integrations.donationalerts
        if ($Node) {
            foreach ($Name in @("accessToken", "userCurrency", "userCurrencyTokenFingerprint")) {
                if ($Node.PSObject.Properties[$Name]) { $Node.PSObject.Properties.Remove($Name) }
            }
            $Node | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
        }
        return Write-SecretsFile $Secrets
    }
    finally { Exit-NamedMutex $Mutex }
}

function Remove-DonatePayStoredToken {
    return Remove-IntegrationSecret "donatepay" "accessToken"
}

function Remove-OpenRouterStoredProxyUrl {
    return Remove-IntegrationSecret "openrouter" "proxyUrl"
}

function Remove-OpenRouterStoredConfiguration {
    $Mutex = Enter-NamedMutex $script:SecretsMutexName
    try {
        $Secrets = Read-SecretsFile
        $Node = $Secrets.integrations.openrouter
        if ($Node) {
            foreach ($Name in @("apiKey", "proxyUrl")) {
                if ($Node.PSObject.Properties[$Name]) { $Node.PSObject.Properties.Remove($Name) }
            }
            $Node | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
        }
        return Write-SecretsFile $Secrets
    }
    finally { Exit-NamedMutex $Mutex }
}

function Get-IntegrationSecretStatus {
    param([string]$Service)

    $Secrets = Read-SecretsFile
    $Node = $Secrets.integrations.$Service
    $HasToken = $false
    $UpdatedAt = ""
    $Masked = ""

    if ($Node -and -not [string]::IsNullOrWhiteSpace([string]$Node.accessToken)) {
        $HasToken = $true
        $UpdatedAt = [string]$Node.updatedAt
        try {
            $Masked = Get-MaskedSecret (Unprotect-SecretString ([string]$Node.accessToken))
        } catch {
            $Masked = ""
        }
    }

    return [pscustomobject]@{
        ok = $true
        service = $Service
        connected = $HasToken
        hasAccessToken = $HasToken
        maskedAccessToken = $Masked
        updatedAt = $UpdatedAt
    }
}

function Get-ApiKeySecretStatus {
    param([string]$Service)

    $Secrets = Read-SecretsFile
    $Node = $Secrets.integrations.$Service
    $HasKey = $false
    $UpdatedAt = ""
    $Masked = ""

    if ($Node -and -not [string]::IsNullOrWhiteSpace([string]$Node.apiKey)) {
        $HasKey = $true
        $UpdatedAt = [string]$Node.updatedAt
        try {
            $Masked = Get-MaskedSecret (Unprotect-SecretString ([string]$Node.apiKey))
        } catch {
            $Masked = ""
        }
    }

    $State = if ($HasKey) { "configured" } else { "not_configured" }
    return [pscustomobject]@{
        ok = $true
        service = $Service
        configured = $HasKey
        masked = $Masked
        status = $State
        updatedAt = $UpdatedAt
    }
}

function Get-DonationAlertsSecretStatus {
    return Get-IntegrationSecretStatus "donationalerts"
}

function Get-DonatePaySecretStatus {
    return Get-IntegrationSecretStatus "donatepay"
}

function Get-OpenRouterSecretStatus {
    $Status = Get-ApiKeySecretStatus "openrouter"
    $ProxyUrl = Get-OpenRouterStoredProxyUrl
    $Status | Add-Member -NotePropertyName proxyConfigured -NotePropertyValue (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) -Force
    $Status | Add-Member -NotePropertyName maskedProxyUrl -NotePropertyValue (Get-MaskedProxyUrl $ProxyUrl) -Force
    return $Status
}

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
$script:CollectorPausedPreserveCursor = $false
$script:CollectorRuntimeGeneration = 1L
$script:NextCollectorTickAt = Get-Date
$script:DonationAlertsPollHandle = $null
$script:DonatePayRecoveryHandle = $null
$script:DonatePayRecoveryCompleted = $null
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
            UserCurrency = ""
            Signature = ""
            LastSeenId = $null
            BaselineReady = $false
            Status = "disconnected"
            LastError = ""
            LastEventAt = ""
            BackoffUntil = $null
            LastPollAt = $null
            PollingIntervalSec = 10
            ConsecutiveFailures = 0
            FirstFailureAt = ""
            LastFailureAt = ""
            LastFailureKind = ""
            LastFailureMessageSafe = ""
            LastSuccessAt = ""
            Degraded = $false
            NextPollAt = ""
            RecoveryLogged = $true
            FailureEscalated = $false
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

    return $Path -eq "/api/health" -or $Path.StartsWith("/api/") -or $Path -eq "/centrifuge/subscribe"
}

function Test-AllowedStaticPath {
    param([string]$Path)

    return @(
        "/",
        "/koleso_papich.html",
        "/centrifuge.min.js"
    ) -contains [string]$Path
}

function Test-AllowedHostHeader {
    param(
        [AllowNull()][string]$HostHeader,
        [int]$Port
    )

    $Value = ([string]$HostHeader).Trim()
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return @(
        "127.0.0.1:$Port",
        "localhost:$Port",
        "127.0.0.1",
        "localhost"
    ) -contains $Value.ToLowerInvariant()
}

function Test-RequestContentLengthAllowed {
    param(
        [long]$ContentLength,
        [long]$MaxBytes = 4MB
    )

    return $ContentLength -ge 0 -and $ContentLength -le $MaxBytes
}

function Test-SensitiveLocalApiPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if ($Path -eq "/api/health") {
        return $false
    }
    return $Path.StartsWith("/api/") -or $Path -eq "/centrifuge/subscribe"
}

function Get-RequestHeaderValue {
    param(
        [hashtable]$Headers,
        [string]$Name
    )

    if (-not $Headers -or [string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $LowerName = $Name.ToLowerInvariant()
    if ($Headers.ContainsKey($LowerName)) {
        return [string]$Headers[$LowerName]
    }
    if ($Headers.ContainsKey($Name)) {
        return [string]$Headers[$Name]
    }

    foreach ($Key in $Headers.Keys) {
        if ([string]::Equals([string]$Key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$Headers[$Key]
        }
    }

    return ""
}

function Test-LocalAppToken {
    param([hashtable]$Headers)

    $Provided = Get-RequestHeaderValue $Headers "X-Local-App-Token"
    if ([string]::IsNullOrWhiteSpace($Provided)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($script:LocalAppToken)) {
        return $false
    }

    return [string]::Equals($Provided.Trim(), [string]$script:LocalAppToken, [System.StringComparison]::Ordinal)
}

function Require-LocalAppToken {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [hashtable]$Headers,
        [bool]$HeadOnly = $false
    )

    if (Test-LocalAppToken $Headers) {
        return $true
    }

    Send-Json $Stream 403 @{ ok = $false; error = "Forbidden"; status = 403 } $HeadOnly
    return $false
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

function Get-ContentSecurityPolicyHeader {
    $Nonce = [string]$script:LocalScriptNonce
    $Policy = "default-src 'self'; " +
              "base-uri 'self'; " +
              "form-action 'self'; " +
              "object-src 'none'; " +
              "frame-ancestors 'none'; " +
              "script-src 'self' 'nonce-$Nonce'; " +
              "style-src 'self' 'unsafe-inline'; " +
              "img-src 'self' data: blob: https:; " +
              "connect-src 'self' http://127.0.0.1:* http://localhost:* ws://127.0.0.1:* ws://localhost:* wss://centrifugo.donatepay.ru:* wss://centrifugo.donatepay.eu:*"

    return "Content-Security-Policy: $Policy`r`n" +
           "X-Frame-Options: DENY`r`n"
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
    $SecurityHeaders = "X-Content-Type-Options: nosniff`r`n" +
                       "Referrer-Policy: no-referrer`r`n" +
                       "Permissions-Policy: camera=(), microphone=(), geolocation=()`r`n"
    if ($ContentType -like "text/html*") {
        $SecurityHeaders += Get-ContentSecurityPolicyHeader
    }

    $HeaderText = "HTTP/1.1 $StatusCode $StatusText`r`n" +
                  "Content-Type: $ContentType`r`n" +
                  "Content-Length: $($Body.Length)`r`n" +
                  "Cache-Control: no-store, max-age=0`r`n" +
                  "Pragma: no-cache`r`n" +
                  $CorsHeader +
                  $SecurityHeaders +
                  "Access-Control-Allow-Headers: Content-Type, X-Requested-With, X-Local-App-Token`r`n" +
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
        401 { "Unauthorized" }
        403 { "Forbidden" }
        404 { "Not Found" }
        405 { "Method Not Allowed" }
        409 { "Conflict" }
        413 { "Payload Too Large" }
        431 { "Request Header Fields Too Large" }
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

function Normalize-LlmText {
    param([AllowNull()][string]$Text)

    $Value = ([string]$Text).ToLowerInvariant()
    $Value = [System.Text.RegularExpressions.Regex]::Replace($Value, '[^\p{L}\p{Nd}\s]+', ' ')
    $Value = [System.Text.RegularExpressions.Regex]::Replace($Value, '\s+', ' ').Trim()
    $StopWords = @('донат на', 'голосую', 'добавь', 'поставь', 'кинь', 'за', 'на')
    foreach ($Word in $StopWords) {
        $Value = [System.Text.RegularExpressions.Regex]::Replace($Value, "(^|\s)$([System.Text.RegularExpressions.Regex]::Escape($Word))(\s|$)", ' ')
    }
    return [System.Text.RegularExpressions.Regex]::Replace($Value, '\s+', ' ').Trim()
}

function Normalize-LotTitle {
    param([AllowNull()][string]$Text)

    $Value = ([string]$Text).ToLowerInvariant().Replace([char]0x0451, [char]0x0435)
    $Value = [System.Text.RegularExpressions.Regex]::Replace($Value, '[^\p{L}\p{Nd}\s]+', ' ')
    return [System.Text.RegularExpressions.Regex]::Replace($Value, '\s+', ' ').Trim()
}

function Get-LotTitleTokens {
    param(
        [AllowNull()][string]$Text,
        [switch]$IgnoreSafeArticles
    )

    $Tokens = @((Normalize-LotTitle $Text) -split '\s+' | Where-Object { $_ })
    if ($IgnoreSafeArticles) {
        $Tokens = @($Tokens | Where-Object { @('the', 'a', 'an') -notcontains $_ })
    }
    return $Tokens
}

function Test-ValidRomanNumeral {
    param([AllowNull()][string]$Token)

    $Value = ([string]$Token).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^(?=[MDCLXVI]+$)M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$') {
        return $false
    }

    $Map = @{ I = 1; V = 5; X = 10; L = 50; C = 100; D = 500; M = 1000 }
    $Total = 0
    $Previous = 0
    for ($Index = $Value.Length - 1; $Index -ge 0; $Index--) {
        $Current = [int]$Map[[string]$Value[$Index]]
        if ($Current -lt $Previous) { $Total -= $Current } else { $Total += $Current; $Previous = $Current }
    }
    # Номера частей в названиях обычно малы. Ограничение не даёт словам вроде MIX считаться числом.
    return $Total -ge 1 -and $Total -le 50
}

function Test-LotVariantToken {
    param([AllowNull()][string]$Token)

    $Value = ([string]$Token).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '^\d+$' -or (Test-ValidRomanNumeral $Value)) { return $true }
    return @(
        'season', 'part', 'chapter', 'episode', 'final', 'movie', 'special', 'remake', 'remaster',
        'remastered', 'dlc', 'shippuden', 'brotherhood', 'sequel', 'prequel', 'volume', 'vol',
        'сезон', 'часть', 'глава', 'эпизод', 'финал', 'фильм', 'спешл', 'ремейк', 'ремастер',
        'продолжение'
    ) -contains $Value
}

function Normalize-LotCategory {
    param([AllowNull()][string]$Category)

    $Value = ([string]$Category).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'unknown') { return '' }
    return $Value
}

function Test-LotCategoriesCompatible {
    param(
        [AllowNull()][string]$ExpectedCategory,
        [AllowNull()][string]$EntryCategory
    )

    $Expected = Normalize-LotCategory $ExpectedCategory
    $Existing = Normalize-LotCategory $EntryCategory
    return [string]::IsNullOrWhiteSpace($Expected) -or
        [string]::IsNullOrWhiteSpace($Existing) -or
        $Expected -eq $Existing
}

function Get-LotVariantTokens {
    param([AllowNull()][string]$Text)

    return @(Get-LotTitleTokens $Text -IgnoreSafeArticles | Where-Object { Test-LotVariantToken $_ } | Select-Object -Unique)
}

function Get-NormalizedEditSimilarity {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    $A = [string]$Left
    $B = [string]$Right
    if ($A -eq $B) { return 1.0 }
    if ($A.Length -eq 0 -or $B.Length -eq 0) { return 0.0 }

    $Previous = New-Object int[] ($B.Length + 1)
    $Current = New-Object int[] ($B.Length + 1)
    for ($J = 0; $J -le $B.Length; $J++) { $Previous[$J] = $J }
    for ($I = 1; $I -le $A.Length; $I++) {
        $Current[0] = $I
        for ($J = 1; $J -le $B.Length; $J++) {
            $Cost = if ($A[$I - 1] -eq $B[$J - 1]) { 0 } else { 1 }
            $Current[$J] = [Math]::Min(
                [Math]::Min($Current[$J - 1] + 1, $Previous[$J] + 1),
                $Previous[$J - 1] + $Cost
            )
        }
        $Swap = $Previous
        $Previous = $Current
        $Current = $Swap
    }
    $Distance = $Previous[$B.Length]
    return [Math]::Max(0.0, 1.0 - ([double]$Distance / [double][Math]::Max($A.Length, $B.Length)))
}

function Compare-LotTitles {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    $LeftTokens = @(Get-LotTitleTokens $Left -IgnoreSafeArticles)
    $RightTokens = @(Get-LotTitleTokens $Right -IgnoreSafeArticles)
    $LeftComparable = $LeftTokens -join ' '
    $RightComparable = $RightTokens -join ' '
    if ([string]::IsNullOrWhiteSpace($LeftComparable) -or [string]::IsNullOrWhiteSpace($RightComparable)) {
        return [pscustomobject]@{ exact = $false; score = 0.0; hasVariantConflict = $false; extraSignificantTokens = @() }
    }

    $Exact = $LeftComparable -eq $RightComparable
    $LeftSet = @{}
    $RightSet = @{}
    foreach ($Token in $LeftTokens) { $LeftSet[$Token] = $true }
    foreach ($Token in $RightTokens) { $RightSet[$Token] = $true }
    $LeftOnly = @($LeftSet.Keys | Where-Object { -not $RightSet.ContainsKey($_) })
    $RightOnly = @($RightSet.Keys | Where-Object { -not $LeftSet.ContainsKey($_) })
    $VariantDifference = @(
        @($LeftOnly + $RightOnly) |
            Where-Object { Test-LotVariantToken $_ } |
            Select-Object -Unique
    )
    $OneSideExtendsOther = ($LeftOnly.Count -eq 0 -and $RightOnly.Count -gt 0) -or
        ($RightOnly.Count -eq 0 -and $LeftOnly.Count -gt 0)
    $ExtraSignificantTokens = if ($OneSideExtendsOther) {
        @($LeftOnly + $RightOnly | Select-Object -Unique)
    } else {
        $VariantDifference
    }
    $HasVariantConflict = -not $Exact -and ($VariantDifference.Count -gt 0 -or $OneSideExtendsOther)

    $Hits = 0
    foreach ($Token in $RightTokens) {
        if ($LeftSet.ContainsKey($Token)) { $Hits++ }
    }
    $TokenScore = [double]$Hits / [double][Math]::Max($LeftTokens.Count, $RightTokens.Count)
    $EditScore = Get-NormalizedEditSimilarity $LeftComparable $RightComparable
    $Score = if ($Exact) { 1.0 } else { [Math]::Max($TokenScore, $EditScore) }

    return [pscustomobject]@{
        exact = $Exact
        score = [Math]::Round([Math]::Max(0.0, [Math]::Min(1.0, $Score)), 4)
        hasVariantConflict = $HasVariantConflict
        extraSignificantTokens = @($ExtraSignificantTokens)
    }
}

function Get-LlmTitleInformation {
    param([AllowNull()][string]$Text)

    $Raw = ([string]$Text).Trim()
    $Normalized = Normalize-LotTitle $Raw
    $Comparable = @(Get-LotTitleTokens $Raw -IgnoreSafeArticles) -join ' '
    $LetterCount = [System.Text.RegularExpressions.Regex]::Matches($Raw, '\p{L}').Count
    $Placeholder = @('test', 'тест', 'lot', 'лот', 'game', 'игра', 'item', 'entry', 'unknown') -contains $Comparable
    $Reason = if ([string]::IsNullOrWhiteSpace($Raw) -or [string]::IsNullOrWhiteSpace($Normalized)) { 'empty_title' }
        elseif ($LetterCount -lt 2) { 'low_information_title' }
        elseif ($Placeholder) { 'placeholder_title' }
        else { '' }
    return [pscustomobject]@{
        usable = [string]::IsNullOrWhiteSpace($Reason)
        normalized = $Normalized
        letterCount = [int]$LetterCount
        reason = $Reason
    }
}

function Normalize-LlmDisplayTitle {
    param([AllowNull()][string]$Text)

    $Value = Limit-LogText ([string]$Text) 200
    $Value = [System.Text.RegularExpressions.Regex]::Replace($Value, '\p{Cc}', ' ')
    return [System.Text.RegularExpressions.Regex]::Replace($Value, '\s+', ' ').Trim()
}

function Get-LlmManualLotSuggestion {
    param(
        [AllowNull()][string]$DisplayTitle,
        [AllowNull()][string]$Category,
        [AllowNull()][string]$OriginalLanguage = 'unknown'
    )

    $Title = Normalize-LlmDisplayTitle $DisplayTitle
    $TitleInfo = Get-LlmTitleInformation $Title
    if (-not $TitleInfo.usable) { return $null }
    if ($Title -match '(?i)(?:https?://|www\.)') { return $null }
    $ServiceText = @(
        'неизвестно', 'название неизвестно', 'не определено', 'без названия',
        'unknown title', 'not specified', 'n a'
    )
    if ($ServiceText -contains $TitleInfo.normalized) { return $null }

    $AllowedCategories = @('game', 'anime', 'movie', 'tv_show', 'cartoon', 'other')
    $SafeCategory = ([string]$Category).Trim().ToLowerInvariant()
    if ($AllowedCategories -notcontains $SafeCategory) { $SafeCategory = 'other' }
    $AllowedLanguages = @('ru', 'en', 'ja', 'ko', 'zh', 'other', 'unknown')
    $SafeLanguage = ([string]$OriginalLanguage).Trim().ToLowerInvariant()
    if ($AllowedLanguages -notcontains $SafeLanguage) { $SafeLanguage = 'unknown' }
    return [pscustomobject]@{
        kind = 'manual_lot'
        title = $Title
        category = $SafeCategory
        originalLanguage = $SafeLanguage
        source = 'llm_manual'
        externalId = ''
        sourceUrl = ''
        catalogConfirmed = $false
    }
}

function Get-LlmExistingSelectionEvidence {
    param(
        [AllowNull()][string]$Query,
        [AllowNull()][object]$Entry,
        [AllowNull()][string]$TrustedSource = '',
        [AllowNull()][string]$TrustedExternalId = ''
    )

    if (-not $Entry -or [bool]$Entry.eliminated) {
        return [pscustomobject]@{ safe = $false; matchKind = ''; reason = 'entry_unavailable'; comparison = $null }
    }
    $EntryInfo = Get-LlmTitleInformation ([string]$Entry.name)
    if (-not $EntryInfo.usable) {
        return [pscustomobject]@{ safe = $false; matchKind = ''; reason = 'opaque_entry_name'; comparison = $null }
    }
    $QueryInfo = Get-LlmTitleInformation $Query
    if (-not $QueryInfo.usable) {
        return [pscustomobject]@{ safe = $false; matchKind = ''; reason = 'low_information_query'; comparison = $null }
    }
    if (
        -not [string]::IsNullOrWhiteSpace($TrustedSource) -and
        -not [string]::IsNullOrWhiteSpace($TrustedExternalId) -and
        [string]$Entry.source -eq $TrustedSource -and
        [string]$Entry.externalId -eq $TrustedExternalId
    ) {
        return [pscustomobject]@{ safe = $true; matchKind = 'exact_external_identity'; reason = ''; comparison = $null }
    }
    $Comparison = Compare-LotTitles $Query ([string]$Entry.name)
    if ($Comparison.exact) {
        return [pscustomobject]@{ safe = $true; matchKind = 'exact_title'; reason = ''; comparison = $Comparison }
    }
    return [pscustomobject]@{
        safe = $false
        matchKind = ''
        reason = if ($Comparison.hasVariantConflict) { 'variant_conflict' } else { 'semantic_mismatch' }
        comparison = $Comparison
    }
}

function Get-TokenSimilarity {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    $A = @(Get-LotTitleTokens $Left -IgnoreSafeArticles)
    $B = @(Get-LotTitleTokens $Right -IgnoreSafeArticles)
    if ($A.Count -eq 0 -or $B.Count -eq 0) { return 0.0 }
    $SetA = @{}
    foreach ($Item in $A) { $SetA[$Item] = $true }
    $Hits = 0
    foreach ($Item in $B) {
        if ($SetA.ContainsKey($Item)) { $Hits += 1 }
    }
    return [double]$Hits / [double]([Math]::Max($A.Count, $B.Count))
}

function Get-SafeEntriesForLlm {
    param([object]$Entries)

    $Items = @()
    if ($Entries -is [System.Array]) { $Items = $Entries }
    elseif ($Entries) { $Items = @($Entries) }

    return @($Items | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id
            name = (Limit-LogText ([string]$_.name) 200)
            category = [string]$_.category
            source = [string]$_.source
            externalId = [string]$_.externalId
            sourceUrl = (Limit-LogText ([string]$_.sourceUrl) 500)
            eliminated = [bool]$_.eliminated
        }
    })
}

function Get-ActiveEntriesForLlmIntent {
    param([object]$Entries)

    return @(
        Get-SafeEntriesForLlm $Entries |
            Where-Object {
                -not [bool]$_.eliminated -and
                -not [string]::IsNullOrWhiteSpace([string]$_.id) -and
                -not [string]::IsNullOrWhiteSpace([string]$_.name)
            } |
            Select-Object -First 200 |
            ForEach-Object {
                [pscustomobject]@{
                    id = Limit-LogText ([string]$_.id) 300
                    name = Limit-LogText ([string]$_.name) 200
                    category = Limit-LogText ([string]$_.category) 40
                    source = Limit-LogText ([string]$_.source) 40
                    externalId = Limit-LogText ([string]$_.externalId) 200
                }
            }
    )
}

function Find-ExistingEntryMatch {
    param(
        [AllowNull()][string]$Text,
        [object[]]$Entries,
        [AllowNull()][string]$ExpectedCategory = ''
    )

    $Query = Normalize-LotTitle $Text
    if ([string]::IsNullOrWhiteSpace($Query)) { return $null }

    foreach ($Entry in @($Entries)) {
        if (-not $Entry -or [bool]$Entry.eliminated -or [string]::IsNullOrWhiteSpace([string]$Entry.id)) { continue }
        if (-not (Test-LotCategoriesCompatible $ExpectedCategory ([string]$Entry.category))) { continue }
        $Name = [string]$Entry.name
        $Normalized = Normalize-LotTitle $Name
        if ([string]::IsNullOrWhiteSpace($Normalized)) { continue }

        $Comparison = Compare-LotTitles $Query $Normalized
        if ($Comparison.exact) {
            return [pscustomobject]@{
                entry = $Entry
                confidence = 1.0
                matchedBy = "exact_entry_name"
                comparison = $Comparison
            }
        }

    }
    return $null
}

function Get-EntryFingerprint {
    param([AllowNull()][object]$Entry)

    if (-not $Entry) { return $null }
    return [pscustomobject]@{
        normalizedName = Normalize-LotTitle ([string]$Entry.name)
        source = Limit-LogText ([string]$Entry.source) 40
        externalId = Limit-LogText ([string]$Entry.externalId) 200
    }
}

function Find-EliminatedEntryMatch {
    param(
        [AllowNull()][string]$Text,
        [object[]]$Entries,
        [AllowNull()][string]$ExpectedCategory = ''
    )

    $ActiveCopies = @($Entries | Where-Object { $_ -and [bool]$_.eliminated } | ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id
            name = [string]$_.name
            source = [string]$_.source
            externalId = [string]$_.externalId
            category = [string]$_.category
            eliminated = $false
        }
    })
    return Find-ExistingEntryMatch $Text $ActiveCopies $ExpectedCategory
}

function ConvertTo-LlmResult {
    param(
        [string]$Action,
        [string]$Category = "unknown",
        [double]$IntentConfidence = 0,
        [double]$CandidateScore = 0,
        [double]$SelectionConfidence = 0,
        [double]$FinalConfidence = 0,
        [string]$Query = "",
        [string]$MatchedBy = "none",
        [string]$ExistingMatchKind = "",
        [string]$EntryId = "",
        [AllowNull()][object]$EntryFingerprint = $null,
        [AllowNull()][object]$Candidate = $null,
        [object[]]$Candidates = @(),
        [object[]]$Items = @(),
        [string]$Reason = ""
    )

    return [pscustomobject]@{
        action = $Action
        entryId = $EntryId
        entryFingerprint = $EntryFingerprint
        category = $Category
        intentConfidence = [Math]::Max(0.0, [Math]::Min(1.0, [double]$IntentConfidence))
        candidateScore = [Math]::Max(0.0, [Math]::Min(1.0, [double]$CandidateScore))
        selectionConfidence = [Math]::Max(0.0, [Math]::Min(1.0, [double]$SelectionConfidence))
        finalConfidence = [Math]::Max(0.0, [Math]::Min(1.0, [double]$FinalConfidence))
        query = Limit-LogText $Query 200
        matchedBy = $MatchedBy
        existingMatchKind = if (@('exact_title', 'exact_external_identity') -contains $ExistingMatchKind) { $ExistingMatchKind } else { '' }
        candidate = $Candidate
        candidates = @($Candidates | Select-Object -First 5)
        items = @($Items | Select-Object -First $script:LlmMaxItems)
        reason = Limit-LogText $Reason 400
    }
}

function Get-LlmItemCatalog {
    param(
        [AllowNull()][string]$Catalog,
        [AllowNull()][string]$Category
    )

    $Value = ([string]$Catalog).Trim().ToLowerInvariant()
    if (@('steam', 'anime', 'none') -contains $Value) { return $Value }
    if ([string]$Category -eq 'game') { return 'steam' }
    if ([string]$Category -eq 'anime') { return 'anime' }
    return 'none'
}

function Get-LlmItemSearchQueries {
    param(
        [AllowNull()][object]$Item,
        [int]$Limit = 4
    )

    if (-not $Item) { return @() }
    $Values = New-Object System.Collections.Generic.List[string]
    foreach ($Value in @(
        [string]$Item.officialTitleGuess,
        [string]$Item.displayTitle,
        [string]$Item.mentionedTitle
    ) + @($Item.searchQueries)) {
        $Text = Limit-LogText ([string]$Value) 160
        if ([string]::IsNullOrWhiteSpace($Text)) { continue }
        $Text = $Text.Trim()
        $Key = Normalize-LotTitle $Text
        if ([string]::IsNullOrWhiteSpace($Key)) { continue }
        $AlreadyPresent = $false
        foreach ($Existing in $Values) {
            if ((Normalize-LotTitle $Existing) -eq $Key) {
                $AlreadyPresent = $true
                break
            }
        }
        if (-not $AlreadyPresent) { $Values.Add($Text) }
        if ($Values.Count -ge [Math]::Max(1, $Limit)) { break }
    }
    return @($Values | ForEach-Object { $_ })
}

function Get-LlmIntentItemRejectionReason {
    param([AllowNull()][object]$ErrorRecord)

    $Message = if ($ErrorRecord -and $ErrorRecord.Exception) {
        [string]$ErrorRecord.Exception.Message
    } else {
        [string]$ErrorRecord
    }
    $AllowedReasons = @(
        'invalid_item_shape',
        'invalid_item_confidence',
        'invalid_existing_confidence',
        'unknown_existing_entry',
        'invalid_none_confidence',
        'empty_item_titles'
    )
    if ($AllowedReasons -contains $Message) { return $Message }
    return 'invalid_item'
}

function Write-LlmIntentItemRejection {
    param(
        [int]$ItemIndex,
        [string]$Reason,
        [int]$ReceivedCount,
        [int]$AcceptedCount,
        [int]$ActiveEntryCount,
        [AllowNull()][string]$ResponseFingerprint = ''
    )

    $SafeReason = Get-LlmIntentItemRejectionReason $Reason
    $SafeFingerprint = if ([string]$ResponseFingerprint -match '^[0-9a-fA-F]{16,24}$') {
        ([string]$ResponseFingerprint).ToLowerInvariant()
    } else {
        'unavailable'
    }
    $Message = "AI intent item rejected: code=LLM_SCHEMA_VALIDATION_ERROR itemIndex=$ItemIndex reason=$SafeReason receivedItems=$ReceivedCount acceptedItems=$AcceptedCount activeEntries=$ActiveEntryCount responseFingerprint=$SafeFingerprint"
    if (Get-Command -Name Write-AppLog -ErrorAction SilentlyContinue) {
        Write-AppLog -Level 'WARN' -Message $Message
    }
}

function Resolve-LlmIntentItems {
    param(
        [AllowNull()][object]$Result,
        [object[]]$Entries,
        [AllowNull()][string]$ResponseFingerprint = ''
    )

    if (-not $Result -or -not $Result.PSObject.Properties['items']) {
        Throw-LlmError 'LLM_SCHEMA_VALIDATION_ERROR' 'OpenRouter intent response did not contain items.'
    }
    $ActiveEntries = @(Get-ActiveEntriesForLlmIntent $Entries)
    $HasActiveEntries = $ActiveEntries.Count -gt 0
    $AllowedCategories = @('game', 'anime', 'movie', 'tv_show', 'cartoon', 'other', 'unknown')
    $AllowedCatalogs = @('steam', 'anime', 'none')
    $AllowedLanguages = @('ru', 'en', 'ja', 'ko', 'zh', 'other', 'unknown')
    $Resolved = New-Object System.Collections.Generic.List[object]
    $RawItems = @($Result.items | Select-Object -First $script:LlmMaxItems)
    $Index = 0
    foreach ($RawItem in $RawItems) {
        $Index++
        try {
            if (
                -not $RawItem -or
                -not $RawItem.PSObject.Properties['category'] -or
                -not $RawItem.PSObject.Properties['catalog'] -or
                -not $RawItem.PSObject.Properties['mentionedTitle'] -or
                -not $RawItem.PSObject.Properties['displayTitle'] -or
                -not $RawItem.PSObject.Properties['officialTitleGuess'] -or
                -not $RawItem.PSObject.Properties['searchQueries'] -or
                -not $RawItem.PSObject.Properties['originalLanguage'] -or
                -not $RawItem.PSObject.Properties['confidence'] -or
                -not $RawItem.PSObject.Properties['reason'] -or
                ($HasActiveEntries -and -not $RawItem.PSObject.Properties['existingEntryId']) -or
                ($HasActiveEntries -and -not $RawItem.PSObject.Properties['existingSelectionConfidence']) -or
                $AllowedCategories -notcontains [string]$RawItem.category -or
                $AllowedCatalogs -notcontains [string]$RawItem.catalog -or
                $AllowedLanguages -notcontains [string]$RawItem.originalLanguage -or
                [string]::IsNullOrWhiteSpace([string]$RawItem.reason)
            ) { throw 'invalid_item_shape' }

            $Confidence = ConvertTo-LlmConfidence $RawItem.confidence
            if ($null -eq $Confidence) { throw 'invalid_item_confidence' }
            $ExistingConfidence = 0.0
            $ExistingEntryId = ''
            if ($HasActiveEntries) {
                $ExistingConfidenceValue = ConvertTo-LlmConfidence $RawItem.existingSelectionConfidence
                if ($null -eq $ExistingConfidenceValue) { throw 'invalid_existing_confidence' }
                $ExistingConfidence = [double]$ExistingConfidenceValue
                $ProviderEntryId = Limit-LogText ([string]$RawItem.existingEntryId) 300
                if ($ProviderEntryId -ne '__none__') {
                    $SelectedEntry = @($ActiveEntries | Where-Object { [string]$_.id -eq $ProviderEntryId } | Select-Object -First 1)[0]
                    if (-not $SelectedEntry) { throw 'unknown_existing_entry' }
                    $ExistingEntryId = $ProviderEntryId
                }
                elseif ($ExistingConfidence -ne 0.0) { throw 'invalid_none_confidence' }
            }

            $SearchQueries = @(Get-LlmItemSearchQueries $RawItem $script:LlmMaxSearchQueriesPerItem)
            $MentionedTitle = Limit-LogText ([string]$RawItem.mentionedTitle) 200
            $DisplayTitle = Normalize-LlmDisplayTitle ([string]$RawItem.displayTitle)
            $OfficialTitleGuess = Limit-LogText ([string]$RawItem.officialTitleGuess) 200
            if (
                [string]::IsNullOrWhiteSpace($MentionedTitle) -and
                [string]::IsNullOrWhiteSpace($OfficialTitleGuess) -and
                $SearchQueries.Count -eq 0
            ) { throw 'empty_item_titles' }

            $Resolved.Add([pscustomobject]@{
                itemId = "item-$Index"
                category = [string]$RawItem.category
                catalog = [string]$RawItem.catalog
                mentionedTitle = $MentionedTitle
                displayTitle = $DisplayTitle
                officialTitleGuess = $OfficialTitleGuess
                originalLanguage = [string]$RawItem.originalLanguage
                searchQueries = $SearchQueries
                confidence = [double]$Confidence
                existingEntryId = $ExistingEntryId
                existingSelectionConfidence = [double]$ExistingConfidence
                reason = Limit-LogText ([string]$RawItem.reason) 400
            })
        }
        catch {
            # A malformed entity must not discard other valid entities from the
            # same strictly structured response. The rejection reason is a
            # fixed allowlisted code; no raw model text or entry ID is logged.
            Write-LlmIntentItemRejection `
                -ItemIndex $Index `
                -Reason (Get-LlmIntentItemRejectionReason $_) `
                -ReceivedCount $RawItems.Count `
                -AcceptedCount $Resolved.Count `
                -ActiveEntryCount $ActiveEntries.Count `
                -ResponseFingerprint $ResponseFingerprint
            continue
        }
    }
    if ($RawItems.Count -gt 0 -and $Resolved.Count -eq 0) {
        Throw-LlmError 'LLM_SCHEMA_VALIDATION_ERROR' 'OpenRouter intent response did not contain a valid item.'
    }
    return @($Resolved | ForEach-Object { $_ })
}

function Resolve-LlmNormalizedIntentItems {
    param(
        [object[]]$Items,
        [object[]]$Entries,
        [AllowNull()][string]$ResponseFingerprint = ''
    )

    $ActiveEntries = @(Get-ActiveEntriesForLlmIntent $Entries)
    $AllowedCategories = @('game', 'anime', 'movie', 'tv_show', 'cartoon', 'other', 'unknown')
    $AllowedCatalogs = @('steam', 'anime', 'none')
    $AllowedLanguages = @('ru', 'en', 'ja', 'ko', 'zh', 'other', 'unknown')
    $Resolved = New-Object System.Collections.Generic.List[object]
    $RawItems = @($Items | Select-Object -First $script:LlmMaxItems)
    $Index = 0
    foreach ($RawItem in $RawItems) {
        $Index++
        try {
            if (
                -not $RawItem -or
                -not $RawItem.PSObject.Properties['category'] -or
                -not $RawItem.PSObject.Properties['catalog'] -or
                -not $RawItem.PSObject.Properties['mentionedTitle'] -or
                -not $RawItem.PSObject.Properties['displayTitle'] -or
                -not $RawItem.PSObject.Properties['officialTitleGuess'] -or
                -not $RawItem.PSObject.Properties['searchQueries'] -or
                -not $RawItem.PSObject.Properties['originalLanguage'] -or
                -not $RawItem.PSObject.Properties['confidence'] -or
                -not $RawItem.PSObject.Properties['existingEntryId'] -or
                -not $RawItem.PSObject.Properties['existingSelectionConfidence'] -or
                -not $RawItem.PSObject.Properties['reason'] -or
                $AllowedCategories -notcontains [string]$RawItem.category -or
                $AllowedCatalogs -notcontains [string]$RawItem.catalog -or
                $AllowedLanguages -notcontains [string]$RawItem.originalLanguage -or
                [string]::IsNullOrWhiteSpace([string]$RawItem.reason)
            ) { throw 'invalid_item_shape' }

            $Confidence = ConvertTo-LlmConfidence $RawItem.confidence
            if ($null -eq $Confidence) { throw 'invalid_item_confidence' }
            $ExistingConfidence = ConvertTo-LlmConfidence $RawItem.existingSelectionConfidence
            if ($null -eq $ExistingConfidence) { throw 'invalid_existing_confidence' }

            $ExistingEntryId = Limit-LogText ([string]$RawItem.existingEntryId) 300
            if ([string]::IsNullOrWhiteSpace($ExistingEntryId)) {
                $ExistingEntryId = ''
                if ([double]$ExistingConfidence -ne 0.0) { throw 'invalid_none_confidence' }
            }
            else {
                $SelectedEntry = @($ActiveEntries | Where-Object { [string]$_.id -eq $ExistingEntryId } | Select-Object -First 1)[0]
                if (-not $SelectedEntry) { throw 'unknown_existing_entry' }
            }

            $SearchQueries = @(Get-LlmItemSearchQueries $RawItem $script:LlmMaxSearchQueriesPerItem)
            $MentionedTitle = Limit-LogText ([string]$RawItem.mentionedTitle) 200
            $DisplayTitle = Normalize-LlmDisplayTitle ([string]$RawItem.displayTitle)
            $OfficialTitleGuess = Limit-LogText ([string]$RawItem.officialTitleGuess) 200
            if (
                [string]::IsNullOrWhiteSpace($MentionedTitle) -and
                [string]::IsNullOrWhiteSpace($OfficialTitleGuess) -and
                $SearchQueries.Count -eq 0
            ) { throw 'empty_item_titles' }

            $ItemId = Limit-LogText ([string]$RawItem.itemId) 80
            if ([string]::IsNullOrWhiteSpace($ItemId)) { $ItemId = "item-$Index" }
            $Resolved.Add([pscustomobject]@{
                itemId = $ItemId
                category = [string]$RawItem.category
                catalog = [string]$RawItem.catalog
                mentionedTitle = $MentionedTitle
                displayTitle = $DisplayTitle
                officialTitleGuess = $OfficialTitleGuess
                originalLanguage = [string]$RawItem.originalLanguage
                searchQueries = $SearchQueries
                confidence = [double]$Confidence
                existingEntryId = $ExistingEntryId
                existingSelectionConfidence = [double]$ExistingConfidence
                reason = Limit-LogText ([string]$RawItem.reason) 400
            })
        }
        catch {
            Write-LlmIntentItemRejection `
                -ItemIndex $Index `
                -Reason (Get-LlmIntentItemRejectionReason $_) `
                -ReceivedCount $RawItems.Count `
                -AcceptedCount $Resolved.Count `
                -ActiveEntryCount $ActiveEntries.Count `
                -ResponseFingerprint $ResponseFingerprint
            continue
        }
    }
    if ($RawItems.Count -gt 0 -and $Resolved.Count -eq 0) {
        Throw-LlmError 'LLM_SCHEMA_VALIDATION_ERROR' 'OpenRouter intent response did not contain a valid item.'
    }
    return @($Resolved | ForEach-Object { $_ })
}

function ConvertTo-LlmNormalizedIntentEnvelope {
    param(
        [AllowNull()][object]$ProviderResult,
        [object[]]$Entries,
        [AllowNull()][object]$Diagnostics = $null
    )

    $Fingerprint = if ($Diagnostics -and $Diagnostics.PSObject.Properties['contentFingerprint']) {
        Limit-LogText ([string]$Diagnostics.contentFingerprint) 24
    } else { '' }
    $Items = @(Resolve-LlmIntentItems $ProviderResult $Entries $Fingerprint)
    return [pscustomobject]@{
        intentItemsContract = 'normalized_intent_items_v1'
        responseFingerprint = $Fingerprint
        items = $Items
    }
}

function ConvertTo-LlmIntentItems {
    param(
        [AllowNull()][object]$Result,
        [object[]]$Entries
    )

    if (
        $Result -and
        $Result.PSObject.Properties['intentItemsContract'] -and
        [string]$Result.intentItemsContract -eq 'normalized_intent_items_v1' -and
        $Result.PSObject.Properties['items']
    ) {
        $Fingerprint = if ($Result.PSObject.Properties['responseFingerprint']) {
            Limit-LogText ([string]$Result.responseFingerprint) 24
        } else { '' }
        return @(Resolve-LlmNormalizedIntentItems @($Result.items) $Entries $Fingerprint)
    }

    if ($Result -and $Result.PSObject.Properties['items']) {
        return @(Resolve-LlmIntentItems $Result $Entries)
    }

    # Internal compatibility for tests and persisted single-item analyzers.
    # New provider responses always use items[].
    if (
        $Result -and
        $Result.PSObject.Properties['decision'] -and
        [string]$Result.decision -ne 'select_existing' -and
        $Result.PSObject.Properties['entryId'] -and
        [string]::IsNullOrWhiteSpace([string]$Result.entryId) -and
        @(Get-ActiveEntriesForLlmIntent $Entries).Count -gt 0
    ) {
        $Result.entryId = '__none__'
        if ($Result.PSObject.Properties['existingSelectionConfidence']) {
            $Result.existingSelectionConfidence = 0.0
        }
    }
    $Legacy = Resolve-LlmIntentDecision $Result $Entries
    $Catalog = Get-LlmItemCatalog '' ([string]$Legacy.category)
    $EntryId = if ([string]$Legacy.decision -eq 'select_existing') { [string]$Legacy.entryId } else { '' }
    return @([pscustomobject]@{
        itemId = 'item-1'
        category = [string]$Legacy.category
        catalog = $Catalog
        mentionedTitle = Limit-LogText ([string]$Legacy.query) 200
        displayTitle = Normalize-LlmDisplayTitle ([string]$Legacy.query)
        officialTitleGuess = Limit-LogText ([string]$Legacy.query) 200
        originalLanguage = 'unknown'
        searchQueries = @(Get-LlmItemSearchQueries ([pscustomobject]@{
            officialTitleGuess = [string]$Legacy.query
            mentionedTitle = [string]$Legacy.query
            searchQueries = @([string]$Legacy.query)
        }) $script:LlmMaxSearchQueriesPerItem)
        confidence = [double]$Legacy.intentConfidence
        existingEntryId = $EntryId
        existingSelectionConfidence = if ($EntryId) { [double]$Legacy.existingSelectionConfidence } else { 0.0 }
        reason = Limit-LogText ([string]$Legacy.reason) 400
    })
}

function Resolve-LlmIntentDecision {
    param(
        [AllowNull()][object]$Result,
        [object[]]$Entries
    )

    $ActiveEntries = @(Get-ActiveEntriesForLlmIntent $Entries)
    $HasActiveEntries = $ActiveEntries.Count -gt 0
    # Provider Schema B forbids select_existing when there are no active
    # entries. Keep the internal validator defensive: if a provider violates
    # that schema, normalize the unsafe selection to ask_manual below instead
    # of ever allowing an assignment.
    $AllowedDecisions = @('select_existing', 'search_catalog', 'ask_manual')
    $AllowedCategories = @('game', 'anime', 'movie', 'tv_show', 'cartoon', 'other', 'unknown')
    if (
        -not $Result -or
        -not $Result.PSObject.Properties['decision'] -or
        -not $Result.PSObject.Properties['category'] -or
        -not $Result.PSObject.Properties['query'] -or
        -not $Result.PSObject.Properties['intentConfidence'] -or
        -not $Result.PSObject.Properties['reason'] -or
        ($HasActiveEntries -and -not $Result.PSObject.Properties['entryId']) -or
        ($HasActiveEntries -and -not $Result.PSObject.Properties['existingSelectionConfidence']) -or
        $AllowedDecisions -notcontains [string]$Result.decision -or
        $AllowedCategories -notcontains [string]$Result.category -or
        [string]::IsNullOrWhiteSpace([string]$Result.reason)
    ) {
        Throw-LlmError "LLM_SCHEMA_VALIDATION_ERROR" "OpenRouter intent response did not match the required schema."
    }

    $IntentConfidence = ConvertTo-LlmConfidence $Result.intentConfidence
    if ($null -eq $IntentConfidence) {
        Throw-LlmError "LLM_SCHEMA_VALIDATION_ERROR" "OpenRouter intent confidence is invalid."
    }
    if (-not $HasActiveEntries) {
        $Result | Add-Member -NotePropertyName entryId -NotePropertyValue '' -Force
        $Result | Add-Member -NotePropertyName existingSelectionConfidence -NotePropertyValue 0.0 -Force
    }
    $ExistingConfidence = ConvertTo-LlmConfidence $Result.existingSelectionConfidence
    if ($null -eq $ExistingConfidence) {
        Throw-LlmError "LLM_SCHEMA_VALIDATION_ERROR" "OpenRouter existing selection confidence is invalid."
    }

    $Result.intentConfidence = [double]$IntentConfidence
    $Result.existingSelectionConfidence = [double]$ExistingConfidence
    $ProviderEntryId = Limit-LogText ([string]$Result.entryId) 300
    if ($HasActiveEntries -and [string]$Result.decision -ne 'select_existing') {
        if ($ProviderEntryId -ne '__none__' -or [double]$ExistingConfidence -ne 0.0) {
            Throw-LlmError "LLM_SCHEMA_VALIDATION_ERROR" "OpenRouter non-selection intent fields are invalid."
        }
        $ProviderEntryId = ''
    }
    elseif ($ProviderEntryId -eq '__none__') {
        $ProviderEntryId = ''
    }
    $Result.entryId = $ProviderEntryId
    $Result.query = Limit-LogText ([string]$Result.query) 200
    $Result.reason = Limit-LogText ([string]$Result.reason) 400
    if ([string]$Result.decision -eq 'select_existing') {
        $Selected = @($ActiveEntries | Where-Object { [string]$_.id -eq [string]$Result.entryId } | Select-Object -First 1)[0]
        $SelectionInvalid = -not $Selected -or
            [double]$ExistingConfidence -lt [double]$script:LlmExistingSelectionThreshold -or
            -not (Test-LotCategoriesCompatible ([string]$Result.category) ([string]$Selected.category))
        if ($SelectionInvalid) {
            $FallbackDecision = if (Test-LlmIntentReadyForCatalog ([string]$Result.category) ([string]$Result.query) ([double]$IntentConfidence)) {
                'search_catalog'
            } else { 'ask_manual' }
            return [pscustomobject]@{
                decision = $FallbackDecision
                entryId = ''
                category = [string]$Result.category
                query = [string]$Result.query
                intentConfidence = [double]$IntentConfidence
                existingSelectionConfidence = 0.0
                reason = 'AI не смог безопасно подтвердить существующий лот.'
            }
        }
        return $Result
    }

    if ([string]$Result.decision -eq 'search_catalog') {
        if (
            -not [string]::IsNullOrWhiteSpace([string]$Result.entryId) -or
            -not (Test-LlmIntentReadyForCatalog ([string]$Result.category) ([string]$Result.query) ([double]$IntentConfidence))
        ) {
            return [pscustomobject]@{
                decision = 'ask_manual'
                entryId = ''
                category = [string]$Result.category
                query = [string]$Result.query
                intentConfidence = [double]$IntentConfidence
                existingSelectionConfidence = [double]$ExistingConfidence
                reason = [string]$Result.reason
            }
        }
        return $Result
    }

    $Result.entryId = ''
    return $Result
}

function Read-JsonFileSafe {
    param(
        [string]$Path,
        [object]$Fallback
    )

    try {
        if (-not [System.IO.File]::Exists($Path)) { return $Fallback }
        $Raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($Raw)) { return $Fallback }
        return $Raw | ConvertFrom-Json
    }
    catch {
        Write-AppLog -Level "WARN" -Message "Cache read failed: $Path $($_.Exception.Message)"
        return $Fallback
    }
}

function Enter-NamedMutex {
    param([string]$Name)

    $Mutex = [System.Threading.Mutex]::new($false, $Name)
    try {
        if (-not $Mutex.WaitOne(10000)) {
            throw "Timed out waiting for application data lock."
        }
        return $Mutex
    }
    catch [System.Threading.AbandonedMutexException] {
        return $Mutex
    }
    catch {
        $Mutex.Dispose()
        throw
    }
}

function Exit-NamedMutex {
    param([AllowNull()][System.Threading.Mutex]$Mutex)

    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch {}
    $Mutex.Dispose()
}

function Write-JsonFileSafe {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 20
    )

    if (-not (Ensure-CacheDirectory)) { return $false }
    try {
        $Json = $Data | ConvertTo-Json -Depth $Depth
        $TempPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($TempPath, $Json, [System.Text.UTF8Encoding]::new($true))
        if ([System.IO.File]::Exists($Path)) {
            try {
                [System.IO.File]::Replace($TempPath, $Path, $null)
            }
            catch {
                Move-Item -LiteralPath $TempPath -Destination $Path -Force
            }
        }
        else {
            [System.IO.File]::Move($TempPath, $Path)
        }
        return $true
    }
    catch {
        try {
            if ($TempPath -and [System.IO.File]::Exists($TempPath)) {
                [System.IO.File]::Delete($TempPath)
            }
        } catch {}
        Write-AppLog -Level "ERROR" -Message "Cache write failed: $Path $($_.Exception.Message)"
        return $false
    }
}

function New-EmptyCollectorStateStore {
    return [pscustomobject]@{
        version = 1
        seenDonationKeys = @()
        pendingDonations = @()
        integrations = [pscustomobject]@{
            donatepay = [pscustomobject]@{ lastSeenId = $null; baselineReady = $false; signature = "" }
            donationalerts = [pscustomobject]@{ lastSeenId = $null; baselineReady = $false; signature = "" }
        }
    }
}

function Get-CollectorStateSnapshot {
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DP = $script:ServerState.Integrations.DonatePay
        $DA = $script:ServerState.Integrations.DonationAlerts
        return [pscustomobject]@{
            version = 1
            seenDonationKeys = @($script:ServerState.SeenDonationKeys.Keys | ForEach-Object { [string]$_ })
            pendingDonations = @($script:ServerState.DonationsPending)
            integrations = [pscustomobject]@{
                donatepay = [pscustomobject]@{
                    lastSeenId = $DP.LastSeenId
                    baselineReady = [bool]$DP.BaselineReady
                    signature = [string]$DP.Signature
                }
                donationalerts = [pscustomobject]@{
                    lastSeenId = $DA.LastSeenId
                    baselineReady = [bool]$DA.BaselineReady
                    signature = [string]$DA.Signature
                }
            }
        }
    }
    finally { [System.Threading.Monitor]::Exit($script:StateLock) }
}

function Save-CollectorState {
    param([AllowNull()][object]$Snapshot = $null)

    if ($null -eq $Snapshot) { $Snapshot = Get-CollectorStateSnapshot }
    $Mutex = Enter-NamedMutex $script:CollectorStateMutexName
    try {
        if (-not (Write-JsonFileSafe $script:CollectorStatePath $Snapshot 30)) {
            throw "Failed to persist collector delivery state."
        }
        return $true
    }
    finally { Exit-NamedMutex $Mutex }
}

function Restore-CollectorState {
    $Mutex = Enter-NamedMutex $script:CollectorStateMutexName
    try { $Stored = Read-JsonFileSafe $script:CollectorStatePath (New-EmptyCollectorStateStore) }
    finally { Exit-NamedMutex $Mutex }
    if (-not $Stored) { return $false }

    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $Pending = [System.Collections.ArrayList]::new()
        $Seen = @{}
        foreach ($Key in @($Stored.seenDonationKeys)) {
            $Text = [string]$Key
            if (-not [string]::IsNullOrWhiteSpace($Text) -and $Text.Length -le 500) { $Seen[$Text] = $true }
        }
        foreach ($Donation in @($Stored.pendingDonations)) {
            $Source = [string]$Donation.source
            $ExternalId = [string]$Donation.externalId
            $Id = [string]$Donation.id
            if (
                [string]::IsNullOrWhiteSpace($Source) -or
                [string]::IsNullOrWhiteSpace($ExternalId) -or
                [string]::IsNullOrWhiteSpace($Id)
            ) { continue }
            [void]$Pending.Add($Donation)
            $Seen[(Get-DonationKey $Source $ExternalId)] = $true
        }
        $script:ServerState.DonationsPending = $Pending
        $script:ServerState.SeenDonationKeys = $Seen
        foreach ($Mapping in @(
            [pscustomobject]@{ runtime = $script:ServerState.Integrations.DonatePay; saved = $Stored.integrations.donatepay }
            [pscustomobject]@{ runtime = $script:ServerState.Integrations.DonationAlerts; saved = $Stored.integrations.donationalerts }
        )) {
            $Runtime = $Mapping.runtime
            $Saved = $Mapping.saved
            if (-not $Saved) { continue }
            $Cursor = 0L
            if ([long]::TryParse([string]$Saved.lastSeenId, [ref]$Cursor) -and $Cursor -gt 0) {
                $Runtime.LastSeenId = $Cursor
            }
            $Runtime.BaselineReady = [bool]$Saved.baselineReady
            $Runtime.Signature = [string]$Saved.signature
        }
        return $true
    }
    finally { [System.Threading.Monitor]::Exit($script:StateLock) }
}

function Normalize-CurrencyCode {
    param([AllowNull()][object]$Value)

    $Code = ([string]$Value).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($Code)) { return "" }
    if ($Code -in @("RUB", "RUR") -or $Code -eq [string][char]0x20BD) { return "RUB" }
    if ($Code -in @([string][char]0x24, ("US" + [char]0x24))) { return "USD" }
    if ($Code -eq [string][char]0x20AC) { return "EUR" }
    return $Code
}

function Convert-CurrencyDecimal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return [decimal]0 }
    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [float] -or $Value -is [int] -or $Value -is [long]) {
        try { return [decimal]$Value } catch { return [decimal]0 }
    }
    $Text = ([string]$Value).Trim().Replace([char]0x00A0, [char]0x20).Replace(" ", "").Replace(",", ".")
    $Parsed = [decimal]0
    if ([decimal]::TryParse(
        $Text,
        [System.Globalization.NumberStyles]::AllowLeadingSign -bor [System.Globalization.NumberStyles]::AllowDecimalPoint,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$Parsed
    )) {
        return $Parsed
    }
    return [decimal]0
}

function New-UnavailableCurrencyRateSnapshot {
    param([AllowNull()][string]$Error = "Currency rates are unavailable.")

    return [pscustomobject]@{
        ok = $false
        baseCurrency = "RUB"
        rates = [pscustomobject]@{ USD = [decimal]0; EUR = [decimal]0 }
        effectiveDate = ""
        fetchedAt = ""
        source = "unavailable"
        stale = $true
        error = Limit-LogText ([string]$Error) 300
    }
}

function Test-CurrencyRateSnapshot {
    param([AllowNull()][object]$Snapshot)

    if (-not $Snapshot -or (Normalize-CurrencyCode $Snapshot.baseCurrency) -ne "RUB") { return $false }
    $Usd = Convert-CurrencyDecimal $Snapshot.rates.USD
    $Eur = Convert-CurrencyDecimal $Snapshot.rates.EUR
    return $Usd -gt 0 -and $Eur -gt 0
}

function Convert-CbrCurrencyXml {
    param([Parameter(Mandatory = $true)][string]$XmlText)

    if ([string]::IsNullOrWhiteSpace($XmlText)) { throw "CBR returned an empty response." }
    [xml]$Document = $XmlText
    $Rates = @{ USD = [decimal]0; EUR = [decimal]0 }
    foreach ($Valute in @($Document.ValCurs.Valute)) {
        $Code = Normalize-CurrencyCode $Valute.CharCode
        if (-not $Rates.ContainsKey($Code)) { continue }
        $Nominal = Convert-CurrencyDecimal $Valute.Nominal
        $Value = Convert-CurrencyDecimal $Valute.Value
        if ($Nominal -le 0 -or $Value -le 0) { continue }
        $Rates[$Code] = $Value / $Nominal
    }
    if ($Rates.USD -le 0 -or $Rates.EUR -le 0) {
        throw "CBR response does not contain valid USD and EUR rates."
    }

    $EffectiveDate = ""
    $RawDate = [string]$Document.ValCurs.Date
    $ParsedDate = [datetime]::MinValue
    foreach ($Format in @("dd.MM.yyyy", "MM/dd/yyyy", "yyyy-MM-dd")) {
        if ([datetime]::TryParseExact(
            $RawDate,
            $Format,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$ParsedDate
        )) {
            $EffectiveDate = $ParsedDate.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($EffectiveDate)) { $EffectiveDate = $RawDate }

    return [pscustomobject]@{
        ok = $true
        baseCurrency = "RUB"
        rates = [pscustomobject]@{ USD = [decimal]$Rates.USD; EUR = [decimal]$Rates.EUR }
        effectiveDate = $EffectiveDate
        fetchedAt = (Get-Date).ToUniversalTime().ToString("o")
        source = "cbr"
        stale = $false
        error = ""
    }
}

function Get-CachedCurrencyRateSnapshot {
    param(
        [string]$Path = $script:CurrencyRatesCachePath,
        [AllowNull()][string]$Error = ""
    )

    $Cached = Read-JsonFileSafe $Path $null
    if (-not (Test-CurrencyRateSnapshot $Cached)) { return $null }
    return [pscustomobject]@{
        ok = $true
        baseCurrency = "RUB"
        rates = [pscustomobject]@{
            USD = Convert-CurrencyDecimal $Cached.rates.USD
            EUR = Convert-CurrencyDecimal $Cached.rates.EUR
        }
        effectiveDate = Limit-LogText ([string]$Cached.effectiveDate) 40
        fetchedAt = Limit-LogText ([string]$Cached.fetchedAt) 80
        source = "cbr_cache"
        stale = $true
        error = Limit-LogText ([string]$Error) 300
    }
}

function Initialize-CurrencyRates {
    param(
        [AllowNull()][scriptblock]$Loader = $null,
        [string]$CachePath = $script:CurrencyRatesCachePath
    )

    if ($script:CurrencyRatesInitialized) { return $script:CurrencyRateSnapshot }
    $script:CurrencyRatesInitialized = $true
    $script:CurrencyRatesLoadCount++
    try {
        $XmlText = if ($Loader) {
            [string](& $Loader)
        }
        else {
            [string](Invoke-WebRequest -UseBasicParsing -Uri "https://www.cbr.ru/scripts/XML_daily.asp" -TimeoutSec 10).Content
        }
        $Snapshot = Convert-CbrCurrencyXml $XmlText
        $Mutex = Enter-NamedMutex $script:CurrencyRatesMutexName
        try {
            if (-not (Write-JsonFileSafe $CachePath $Snapshot)) {
                Write-AppLog -Level "WARN" -Message "Currency rate cache write failed."
            }
        }
        finally { Exit-NamedMutex $Mutex }
        $script:CurrencyRateSnapshot = $Snapshot
        Write-AppLog -Level "INFO" -Message "Currency rates loaded from CBR; effectiveDate=$($Snapshot.effectiveDate)."
        return $Snapshot
    }
    catch {
        $SafeError = Limit-LogText (Mask-SecretText $_.Exception.Message) 300
        $Mutex = Enter-NamedMutex $script:CurrencyRatesMutexName
        try { $Cached = Get-CachedCurrencyRateSnapshot $CachePath $SafeError }
        finally { Exit-NamedMutex $Mutex }
        if ($Cached) {
            $script:CurrencyRateSnapshot = $Cached
            Write-Host "Currency rates: using saved CBR snapshot." -ForegroundColor Yellow
            Write-AppLog -Level "WARN" -Message "Currency rate request failed; using saved CBR snapshot. $SafeError"
            return $Cached
        }
        $script:CurrencyRateSnapshot = New-UnavailableCurrencyRateSnapshot $SafeError
        Write-Host "Currency rates are unavailable; EUR/USD donations require manual RUB amount." -ForegroundColor Yellow
        Write-AppLog -Level "WARN" -Message "Currency rates are unavailable; EUR/USD donations require manual RUB amount. $SafeError"
        return $script:CurrencyRateSnapshot
    }
}

function Get-CurrencyRateStatus {
    $Snapshot = $script:CurrencyRateSnapshot
    if (-not $Snapshot) { $Snapshot = New-UnavailableCurrencyRateSnapshot "Currency rates are not initialized." }
    return [pscustomobject]@{
        ok = [bool]$Snapshot.ok
        baseCurrency = "RUB"
        rates = [pscustomobject]@{
            USD = Convert-CurrencyDecimal $Snapshot.rates.USD
            EUR = Convert-CurrencyDecimal $Snapshot.rates.EUR
        }
        effectiveDate = Limit-LogText ([string]$Snapshot.effectiveDate) 40
        fetchedAt = Limit-LogText ([string]$Snapshot.fetchedAt) 80
        source = Limit-LogText ([string]$Snapshot.source) 40
        stale = [bool]$Snapshot.stale
        error = Limit-LogText ([string]$Snapshot.error) 300
    }
}

function Convert-DonationAlertsAmountToRub {
    param(
        [AllowNull()][object]$OriginalAmount,
        [AllowNull()][object]$OriginalCurrency,
        [AllowNull()][object]$AmountInUserCurrency,
        [AllowNull()][object]$UserCurrency,
        [AllowNull()][object]$RateSnapshot = $script:CurrencyRateSnapshot
    )

    $Amount = Convert-CurrencyDecimal $OriginalAmount
    $Currency = Normalize-CurrencyCode $OriginalCurrency
    $UserAmount = Convert-CurrencyDecimal $AmountInUserCurrency
    $NormalizedUserCurrency = Normalize-CurrencyCode $UserCurrency
    $Result = [ordered]@{
        amount = [decimal]0
        currency = "RUB"
        originalAmount = $Amount
        originalCurrency = $Currency
        exchangeRate = [decimal]0
        conversionSource = "unavailable"
        conversionStatus = "unavailable"
        conversionDate = ""
        rateFetchedAt = ""
        conversionError = ""
    }

    if ($Amount -le 0) {
        $Result.conversionError = "Исходная сумма доната некорректна."
        return [pscustomobject]$Result
    }
    if ($Currency -eq "RUB") {
        $Result.amount = [decimal][Math]::Round($Amount, 0, [MidpointRounding]::AwayFromZero)
        $Result.exchangeRate = [decimal]1
        $Result.conversionSource = "original"
        $Result.conversionStatus = "converted"
        return [pscustomobject]$Result
    }
    if ($UserAmount -gt 0 -and $NormalizedUserCurrency -eq "RUB") {
        $Result.amount = [decimal][Math]::Round($UserAmount, 0, [MidpointRounding]::AwayFromZero)
        $Result.exchangeRate = $UserAmount / $Amount
        $Result.conversionSource = "donationalerts"
        $Result.conversionStatus = "converted"
        $Result.conversionDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
        return [pscustomobject]$Result
    }
    if ($Currency -in @("USD", "EUR") -and (Test-CurrencyRateSnapshot $RateSnapshot)) {
        $Rate = Convert-CurrencyDecimal $RateSnapshot.rates.$Currency
        if ($Rate -gt 0) {
            $Result.amount = [decimal][Math]::Round(($Amount * $Rate), 0, [MidpointRounding]::AwayFromZero)
            $Result.exchangeRate = $Rate
            $Result.conversionSource = if ([bool]$RateSnapshot.stale -or [string]$RateSnapshot.source -eq "cbr_cache") { "cbr_cache" } else { "cbr" }
            $Result.conversionStatus = "converted"
            $Result.conversionDate = Limit-LogText ([string]$RateSnapshot.effectiveDate) 40
            $Result.rateFetchedAt = Limit-LogText ([string]$RateSnapshot.fetchedAt) 80
            return [pscustomobject]$Result
        }
    }

    $Result.conversionError = if ($Currency -in @("USD", "EUR")) {
        "Курс $Currency/RUB недоступен. Укажите сумму в RUB вручную."
    } else {
        "Валюта '$Currency' не поддерживается. Укажите сумму в RUB вручную."
    }
    return [pscustomobject]$Result
}

function Get-SteamSearchCache {
    $Data = Read-JsonFileSafe $script:SteamSearchCachePath ([pscustomobject]@{})
    if (-not $Data) { return [pscustomobject]@{} }
    return $Data
}

function Get-SteamSearchCachedCandidates {
    param(
        [string]$Query,
        [long]$Generation
    )

    $Normalized = Normalize-LotTitle $Query
    if ([string]::IsNullOrWhiteSpace($Normalized)) { return @() }

    $Mutex = Enter-NamedMutex $script:CacheMutexName
    try {
        $Cache = Get-SteamSearchCache
        $Item = $Cache.PSObject.Properties[$Normalized]
        if (
            -not $Item -or
            -not $Item.Value -or
            [long]$Item.Value.generation -ne $Generation -or
            -not $Item.Value.candidates
        ) { return @() }
        return @($Item.Value.candidates | Where-Object { $_.candidateId })
    }
    finally {
        Exit-NamedMutex $Mutex
    }
}

function Set-SteamSearchCachedCandidates {
    param(
        [string]$Query,
        [object[]]$Candidates,
        [long]$Generation
    )

    $Normalized = Normalize-LotTitle $Query
    if ([string]::IsNullOrWhiteSpace($Normalized)) { return $false }

    if (@($Candidates).Count -eq 0) { return $false }
    if (-not (Test-LlmGenerationCurrent $Generation)) { return $false }
    $Mutex = Enter-NamedMutex $script:CacheMutexName
    try {
        $Cache = Get-SteamSearchCache
        $Cache | Add-Member -NotePropertyName $Normalized -NotePropertyValue ([pscustomobject]@{
            generation = $Generation
            updatedAt = (Get-Date).ToUniversalTime().ToString("o")
            candidates = @($Candidates)
        }) -Force
        return Write-JsonFileSafe $script:SteamSearchCachePath $Cache 20
    }
    finally {
        Exit-NamedMutex $Mutex
    }
}

function Search-SteamStoreCandidates {
    param(
        [string]$Query,
        [string]$JobId = "",
        [long]$Generation = 1
    )

    $Normalized = Normalize-LotTitle $Query
    if ([string]::IsNullOrWhiteSpace($Normalized)) { return @() }

    $Cached = @(Get-SteamSearchCachedCandidates $Query $Generation)
    if ($Cached.Count -gt 0) { return $Cached }

    $Url = "https://store.steampowered.com/api/storesearch/?term=$([System.Uri]::EscapeDataString($Query))&cc=US&l=english"
    $Response = Invoke-RestMethod -Uri $Url -Method Get -Headers @{ Accept = "application/json" } -TimeoutSec 20
    $Items = if ($Response -and $Response.items) { @($Response.items) } else { @() }
    $UsedRussianFallback = $false
    if ($Items.Count -eq 0 -and [System.Text.RegularExpressions.Regex]::IsMatch($Query, '\p{IsCyrillic}')) {
        $RussianUrl = "https://store.steampowered.com/api/storesearch/?term=$([System.Uri]::EscapeDataString($Query))&cc=RU&l=russian"
        $RussianResponse = Invoke-RestMethod -Uri $RussianUrl -Method Get -Headers @{ Accept = "application/json" } -TimeoutSec 20
        $Items = if ($RussianResponse -and $RussianResponse.items) { @($RussianResponse.items) } else { @() }
        $UsedRussianFallback = $Items.Count -gt 0
    }

    $Candidates = @($Items | Where-Object {
        $_.id -and -not [string]::IsNullOrWhiteSpace([string]$_.name)
    } | ForEach-Object {
        $AppId = [string]$_.id
        $LocalizedName = [string]$_.name
        $Name = $LocalizedName
        $TitleConfirmed = -not $UsedRussianFallback
        if ($UsedRussianFallback) {
            try {
                $DetailsUrl = "https://store.steampowered.com/api/appdetails?appids=$([System.Uri]::EscapeDataString($AppId))&cc=US&l=english"
                $Details = Invoke-RestMethod -Uri $DetailsUrl -Method Get -Headers @{ Accept = "application/json" } -TimeoutSec 15
                $DetailsNode = if ($Details -and $Details.PSObject.Properties[$AppId]) { $Details.PSObject.Properties[$AppId].Value } else { $null }
                if ($DetailsNode -and [bool]$DetailsNode.success -and -not [string]::IsNullOrWhiteSpace([string]$DetailsNode.data.name)) {
                    $Name = [string]$DetailsNode.data.name
                    $TitleConfirmed = $true
                }
            }
            catch {
                $TitleConfirmed = $false
            }
        }
        $AppNorm = Normalize-LotTitle $Name
        $Comparison = Compare-LotTitles $Normalized $AppNorm
        $LocalizedComparison = Compare-LotTitles $Normalized (Normalize-LotTitle $LocalizedName)
        $Score = [Math]::Max([double]$Comparison.score, [double]$LocalizedComparison.score)

        if ($Score -ge 0.35) {
            [pscustomobject]@{
                candidateId = "steam:$AppId"
                source = "steam"
                externalId = $AppId
                title = $Name
                sourceUrl = "https://store.steampowered.com/app/$AppId"
                imageUrl = if ($_.tiny_image) { [string]$_.tiny_image } else { "" }
                sourceMode = "store_search"
                availability = "search_result"
                metadataIncomplete = [string]::IsNullOrWhiteSpace([string]$_.tiny_image) -or -not $TitleConfirmed
                titleConfirmed = $TitleConfirmed
                score = [Math]::Round([double]$Score, 4)
            }
        }
    } | Sort-Object -Property score -Descending | Select-Object -First 5)

    if (-not $JobId -or (Test-LlmJobGenerationCurrent $JobId $Generation)) {
        Set-SteamSearchCachedCandidates $Query $Candidates $Generation | Out-Null
    }
    return $Candidates
}

function Merge-SteamCandidatesByAppId {
    param(
        [object[]]$CandidateGroups,
        [int]$Limit = 5
    )

    $ById = @{}
    foreach ($Group in @($CandidateGroups)) {
        if (-not $Group) { continue }
        $MatchedQuery = Limit-LogText ([string]$Group.query) 160
        foreach ($Candidate in @($Group.candidates)) {
            if (-not $Candidate -or [string]::IsNullOrWhiteSpace([string]$Candidate.externalId)) { continue }
            $Id = [string]$Candidate.externalId
            if (-not $ById.ContainsKey($Id)) {
                $ById[$Id] = [pscustomobject]@{
                    candidateId = "steam:$Id"
                    source = 'steam'
                    externalId = $Id
                    title = Limit-LogText ([string]$Candidate.title) 200
                    sourceUrl = Limit-LogText ([string]$Candidate.sourceUrl) 1000
                    imageUrl = Limit-LogText ([string]$Candidate.imageUrl) 1000
                    sourceMode = Limit-LogText ([string]$Candidate.sourceMode) 40
                    availability = Limit-LogText ([string]$Candidate.availability) 40
                    metadataIncomplete = [bool]$Candidate.metadataIncomplete
                    titleConfirmed = if ($Candidate.PSObject.Properties['titleConfirmed']) { [bool]$Candidate.titleConfirmed } else { $true }
                    score = [Math]::Max(0.0, [Math]::Min(1.0, [double]$Candidate.score))
                    matchedQueries = @()
                }
            }
            $Stored = $ById[$Id]
            if ([double]$Candidate.score -gt [double]$Stored.score) { $Stored.score = [double]$Candidate.score }
            if (-not [bool]$Stored.titleConfirmed -and $Candidate.PSObject.Properties['titleConfirmed'] -and [bool]$Candidate.titleConfirmed) {
                $Stored.title = Limit-LogText ([string]$Candidate.title) 200
                $Stored.titleConfirmed = $true
                $Stored.metadataIncomplete = [bool]$Candidate.metadataIncomplete
            }
            if ($MatchedQuery -and @($Stored.matchedQueries) -notcontains $MatchedQuery) {
                $Stored.matchedQueries = @($Stored.matchedQueries) + $MatchedQuery
            }
        }
    }
    return @($ById.Values | Sort-Object -Property @{ Expression = 'score'; Descending = $true }, @{ Expression = 'title'; Descending = $false } | Select-Object -First ([Math]::Max(1, $Limit)))
}

function Search-SteamCandidatesForQueries {
    param(
        [object]$Item,
        [string]$JobId = '',
        [long]$Generation = 1,
        [AllowNull()][scriptblock]$SteamSearcher = $null
    )

    $Queries = @(Get-LlmItemSearchQueries $Item $script:LlmMaxSearchQueriesPerItem)
    $Groups = New-Object System.Collections.Generic.List[object]
    $Failures = 0
    foreach ($Query in $Queries) {
        if ($JobId) { Assert-LlmJobGenerationCurrent $JobId $Generation }
        try {
            $Found = if ($SteamSearcher) {
                @(& $SteamSearcher $Query $JobId $Generation)
            } else {
                @(Search-SteamStoreCandidates $Query $JobId $Generation)
            }
            $Groups.Add([pscustomobject]@{ query = $Query; candidates = @($Found) })
        }
        catch {
            $Failures++
            Write-AppLog -Level 'WARN' -Message "Steam search variant failed for AI job."
        }
    }
    if ($JobId) { Assert-LlmJobGenerationCurrent $JobId $Generation }
    return [pscustomobject]@{
        queries = $Queries
        attempted = $Queries.Count
        failures = $Failures
        candidates = @(Merge-SteamCandidatesByAppId @($Groups | ForEach-Object { $_ }) $script:LlmMaxCandidatesPerItem)
    }
}

function Get-LlmExistingOptionsForItem {
    param(
        [object]$Item,
        [object[]]$Entries,
        [object[]]$Candidates = @()
    )

    if (-not $Item) { return @() }
    $Titles = @(Get-LlmItemSearchQueries $Item $script:LlmMaxSearchQueriesPerItem)
    $ByEntryId = @{}
    foreach ($Entry in @($Entries)) {
        if (-not $Entry -or [bool]$Entry.eliminated -or [string]::IsNullOrWhiteSpace([string]$Entry.id)) { continue }
        $MatchKind = ''
        foreach ($Candidate in @($Candidates)) {
            if (
                -not [string]::IsNullOrWhiteSpace([string]$Candidate.source) -and
                -not [string]::IsNullOrWhiteSpace([string]$Candidate.externalId) -and
                [string]$Entry.source -eq [string]$Candidate.source -and
                [string]$Entry.externalId -eq [string]$Candidate.externalId
            ) {
                $MatchKind = 'exact_external_identity'
                break
            }
        }
        if (-not $MatchKind) {
            $EntryTitleInfo = Get-LlmTitleInformation ([string]$Entry.name)
            if (-not $EntryTitleInfo.usable) { continue }
            foreach ($Title in $Titles) {
                $QueryTitleInfo = Get-LlmTitleInformation $Title
                if ($QueryTitleInfo.usable -and (Compare-LotTitles $Title ([string]$Entry.name)).exact) {
                    $MatchKind = 'exact_title'
                    break
                }
            }
        }
        if (-not $MatchKind) { continue }
        $CategoryCompatible = Test-LotCategoriesCompatible ([string]$Item.category) ([string]$Entry.category)
        $SelectedByModel = [string]$Item.existingEntryId -eq [string]$Entry.id
        $SafeAutoAssign = $SelectedByModel -and
            $CategoryCompatible -and
            [double]$Item.existingSelectionConfidence -ge [double]$script:LlmExistingSelectionThreshold -and
            @('exact_title', 'exact_external_identity') -contains $MatchKind
        $ByEntryId[[string]$Entry.id] = [pscustomobject]@{
            optionId = "entry:$([string]$Entry.id)"
            kind = 'existing_entry'
            entryId = [string]$Entry.id
            title = Limit-LogText ([string]$Entry.name) 200
            category = Limit-LogText ([string]$Entry.category) 40
            source = Limit-LogText ([string]$Entry.source) 40
            externalId = Limit-LogText ([string]$Entry.externalId) 200
            sourceUrl = Limit-LogText ([string]$Entry.sourceUrl) 1000
            entryFingerprint = Get-EntryFingerprint $Entry
            matchKind = $MatchKind
            categoryMismatch = -not $CategoryCompatible
            selectedByModel = $SelectedByModel
            safeAutoAssign = $SafeAutoAssign
        }
    }
    return @($ByEntryId.Values | Sort-Object -Property @{ Expression = 'selectedByModel'; Descending = $true }, @{ Expression = 'matchKind'; Descending = $false }, @{ Expression = 'title'; Descending = $false } | Select-Object -First 10)
}

function Add-LlmCandidateExistingMetadata {
    param(
        [object[]]$Candidates,
        [object[]]$Entries,
        [AllowNull()][string]$ExpectedCategory
    )

    return @($Candidates | ForEach-Object {
        $Candidate = $_
        $Existing = Search-ExistingEntryByCandidate $Candidate $Entries $ExpectedCategory
        if ($Existing) {
            $MatchKind = if (
                [string]$Existing.source -eq [string]$Candidate.source -and
                -not [string]::IsNullOrWhiteSpace([string]$Candidate.externalId) -and
                [string]$Existing.externalId -eq [string]$Candidate.externalId
            ) { 'exact_external_identity' } else { 'exact_title' }
            $Candidate | Add-Member -NotePropertyName existingEntryId -NotePropertyValue ([string]$Existing.id) -Force
            $Candidate | Add-Member -NotePropertyName existingEntryFingerprint -NotePropertyValue (Get-EntryFingerprint $Existing) -Force
            $Candidate | Add-Member -NotePropertyName existingEntryCategory -NotePropertyValue ([string]$Existing.category) -Force
            $Candidate | Add-Member -NotePropertyName existingMatchKind -NotePropertyValue $MatchKind -Force
            $Candidate | Add-Member -NotePropertyName categoryMismatch -NotePropertyValue (-not (Test-LotCategoriesCompatible $ExpectedCategory ([string]$Existing.category))) -Force
        }
        $Candidate
    })
}

function Search-ExistingEntryByCandidate {
    param(
        [object]$Candidate,
        [object[]]$Entries,
        [AllowNull()][string]$ExpectedCategory = ''
    )

    if (-not $Candidate) { return $null }
    foreach ($Entry in @($Entries)) {
        if (-not $Entry -or [bool]$Entry.eliminated) { continue }
        if (
            -not [string]::IsNullOrWhiteSpace([string]$Candidate.source) -and
            -not [string]::IsNullOrWhiteSpace([string]$Candidate.externalId) -and
            [string]$Entry.source -eq [string]$Candidate.source -and
            [string]$Entry.externalId -eq [string]$Candidate.externalId
        ) {
            return $Entry
        }
    }
    $Match = Find-ExistingEntryMatch ([string]$Candidate.title) $Entries $ExpectedCategory
    if ($Match -and $Match.confidence -ge 0.80) { return $Match.entry }
    return $null
}

function Test-EliminatedEntryByCandidate {
    param(
        [object]$Candidate,
        [object[]]$Entries,
        [AllowNull()][string]$ExpectedCategory = ''
    )

    if (-not $Candidate) { return $false }
    foreach ($Entry in @($Entries)) {
        if (-not $Entry -or -not [bool]$Entry.eliminated) { continue }
        if (
            [string]$Entry.source -eq [string]$Candidate.source -and
            -not [string]::IsNullOrWhiteSpace([string]$Candidate.externalId) -and
            [string]$Entry.externalId -eq [string]$Candidate.externalId
        ) { return $true }
    }
    return $null -ne (Find-EliminatedEntryMatch ([string]$Candidate.title) $Entries $ExpectedCategory)
}

function Get-CandidateComparableTitles {
    param([object]$Candidate)

    if (-not $Candidate) { return @() }
    return @(
        @($Candidate.title, $Candidate.titleEnglish, $Candidate.titleRomaji, $Candidate.titleNative) + @($Candidate.synonyms) |
            ForEach-Object { Normalize-LotTitle ([string]$_) } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Test-CandidateQualifierConflict {
    param(
        [string]$Query,
        [object]$Candidate
    )

    if (-not $Candidate) { return $true }
    $QueryYearMatch = [System.Text.RegularExpressions.Regex]::Match((Normalize-LotTitle $Query), '\b(19|20)\d{2}\b')
    if ($QueryYearMatch.Success -and $Candidate.seasonYear) {
        if ([string]$Candidate.seasonYear -ne $QueryYearMatch.Value) { return $true }
    }
    return $false
}

function Test-FranchiseVariantAlternative {
    param(
        [string]$Query,
        [object]$ExactCandidate,
        [object[]]$OtherCandidates
    )

    if (@(Get-LotVariantTokens $Query).Count -gt 0) { return $false }
    foreach ($Candidate in @($OtherCandidates)) {
        foreach ($Title in @(Get-CandidateComparableTitles $Candidate)) {
            $Comparison = Compare-LotTitles $Query $Title
            if (
                $Comparison.hasVariantConflict -and
                @(Get-LotVariantTokens $Title).Count -gt 0 -and
                (Get-TokenSimilarity $Query $Title) -ge 0.40
            ) {
                return $true
            }
        }
    }
    return $false
}

function Get-UniqueExactCatalogCandidate {
    param(
        [string]$Query,
        [object[]]$Candidates
    )

    $QueryNormalized = Normalize-LotTitle $Query
    $ExactCandidates = @($Candidates | Select-Object -First 5 | Where-Object {
        $Candidate = $_
        @(
            Get-CandidateComparableTitles $Candidate |
                Where-Object { (Compare-LotTitles $QueryNormalized $_).exact }
        ).Count -gt 0
    })
    if ($ExactCandidates.Count -eq 1) { return $ExactCandidates[0] }
    return $null
}

function Test-CatalogCandidatesAmbiguous {
    param(
        [string]$Query,
        [object[]]$Candidates
    )

    $List = @($Candidates | Select-Object -First 5)
    if ($List.Count -eq 0) { return $true }
    $QueryNormalized = Normalize-LotTitle $Query
    $ExactCandidates = @($List | Where-Object {
        $Candidate = $_
        @(Get-CandidateComparableTitles $Candidate | Where-Object { (Compare-LotTitles $QueryNormalized $_).exact }).Count -gt 0
    })
    if ($ExactCandidates.Count -eq 1) {
        $ExactCandidate = Get-UniqueExactCatalogCandidate $QueryNormalized $List
        $Others = @($List | Where-Object { [string]$_.candidateId -ne [string]$ExactCandidate.candidateId })
        if (
            -not (Test-CandidateQualifierConflict $QueryNormalized $ExactCandidate) -and
            -not (Test-FranchiseVariantAlternative $QueryNormalized $ExactCandidate $Others)
        ) {
            return $false
        }
    }
    elseif ($ExactCandidates.Count -gt 1) {
        return $true
    }

    $Top = $List[0]
    $TopScore = [double]$Top.score
    if ($TopScore -lt 0.88) { return $true }
    if ($List.Count -eq 1) { return $TopScore -lt 0.94 }

    $Second = $List[1]
    $SecondScore = [double]$Second.score
    if (($TopScore - $SecondScore) -lt 0.12) { return $true }

    $TopName = Normalize-LotTitle ([string]$Top.title)
    $SecondName = Normalize-LotTitle ([string]$Second.title)
    $FranchiseSimilarity = Get-TokenSimilarity $TopName $SecondName
    $HasVariantQualifier = @(Get-LotVariantTokens $TopName).Count -gt 0 -or @(Get-LotVariantTokens $SecondName).Count -gt 0
    $QueryHasQualifier = @(Get-LotVariantTokens $QueryNormalized).Count -gt 0
    if ($FranchiseSimilarity -ge 0.45 -and $HasVariantQualifier -and -not $QueryHasQualifier) { return $true }

    return $false
}

function Get-AnimeSearchCache {
    $Data = Read-JsonFileSafe $script:AnimeSearchCachePath ([pscustomobject]@{})
    if (-not $Data) { return [pscustomobject]@{} }
    return $Data
}

function Set-AnimeSearchCacheItem {
    param(
        [string]$QueryKey,
        [object[]]$Candidates,
        [long]$Generation
    )

    if (@($Candidates).Count -eq 0) { return }
    if (-not (Test-LlmGenerationCurrent $Generation)) { return }
    $Mutex = Enter-NamedMutex $script:CacheMutexName
    try {
        $Cache = Get-AnimeSearchCache
        $Cache | Add-Member -NotePropertyName $QueryKey -NotePropertyValue ([pscustomobject]@{
            generation = $Generation
            updatedAt = (Get-Date).ToUniversalTime().ToString("o")
            candidates = @($Candidates)
        }) -Force
        Write-JsonFileSafe $script:AnimeSearchCachePath $Cache 20 | Out-Null
    }
    finally {
        Exit-NamedMutex $Mutex
    }
}

function Search-AnimeCandidates {
    param(
        [string]$Query,
        [string]$JobId = "",
        [long]$Generation = 1
    )

    $Key = Normalize-LotTitle $Query
    if ([string]::IsNullOrWhiteSpace($Key)) { return @() }
    $Mutex = Enter-NamedMutex $script:CacheMutexName
    try {
        $Cache = Get-AnimeSearchCache
        if ($Cache.PSObject.Properties[$Key] -and [long]$Cache.$Key.generation -eq $Generation) {
            $CachedCandidates = @($Cache.$Key.candidates | Where-Object { $_.candidateId })
            if ($CachedCandidates.Count -gt 0) { return $CachedCandidates }
        }
    }
    finally {
        Exit-NamedMutex $Mutex
    }

    $Candidates = @()
    try {
        $Graphql = @{
            query = 'query ($search: String) { Page(page: 1, perPage: 5) { media(search: $search, type: ANIME) { id title { romaji english native } synonyms format seasonYear episodes popularity siteUrl coverImage { medium } } } }'
            variables = @{ search = $Query }
        } | ConvertTo-Json -Depth 20
        $Response = Invoke-RestMethod -Uri "https://graphql.anilist.co" -Method Post -ContentType "application/json" -Headers @{ Accept = "application/json" } -Body $Graphql -TimeoutSec 20
        $Candidates = @($Response.data.Page.media | ForEach-Object {
            $TitleEnglish = [string]$_.title.english
            $TitleRomaji = [string]$_.title.romaji
            $TitleNative = [string]$_.title.native
            $Title = if ($TitleEnglish) { $TitleEnglish } elseif ($TitleRomaji) { $TitleRomaji } else { $TitleNative }
            $SearchNames = @($TitleEnglish, $TitleRomaji, $TitleNative) + @($_.synonyms)
            $Score = @($SearchNames | Where-Object { $_ } | ForEach-Object { (Compare-LotTitles $Query ([string]$_)).score } | Sort-Object -Descending | Select-Object -First 1)
            [pscustomobject]@{
                candidateId = "anilist:$([string]$_.id)"
                source = "anilist"
                externalId = [string]$_.id
                title = $Title
                titleEnglish = $TitleEnglish
                titleRomaji = $TitleRomaji
                titleNative = $TitleNative
                synonyms = @($_.synonyms | ForEach-Object { Limit-LogText ([string]$_) 120 })
                format = [string]$_.format
                seasonYear = if ($_.seasonYear) { [int]$_.seasonYear } else { $null }
                episodes = if ($_.episodes) { [int]$_.episodes } else { $null }
                popularity = if ($_.popularity) { [int]$_.popularity } else { 0 }
                sourceUrl = [string]$_.siteUrl
                imageUrl = [string]$_.coverImage.medium
                score = if ($Score.Count) { [Math]::Round([double]$Score[0], 4) } else { 0 }
            }
        } | Sort-Object -Property score -Descending | Select-Object -First 5)
    }
    catch {
        Write-AppLog -Level "WARN" -Message "AniList search failed: $($_.Exception.Message)"
    }

    if ($Candidates.Count -eq 0) {
        try {
            $Url = "https://api.jikan.moe/v4/anime?q=$([System.Uri]::EscapeDataString($Query))&limit=5"
            $Response = Invoke-RestMethod -Uri $Url -Method Get -Headers @{ Accept = "application/json" } -TimeoutSec 20
            $Candidates = @($Response.data | ForEach-Object {
                $JikanTitle = if ($_.title_english) { [string]$_.title_english } else { [string]$_.title }
                $JikanNames = @($JikanTitle, [string]$_.title, [string]$_.title_japanese) + @($_.title_synonyms)
                $JikanScores = @($JikanNames | Where-Object { $_ } | ForEach-Object { (Compare-LotTitles $Query ([string]$_)).score } | Sort-Object -Descending | Select-Object -First 1)
                [pscustomobject]@{
                    candidateId = "jikan:$([string]$_.mal_id)"
                    source = "jikan"
                    externalId = [string]$_.mal_id
                    title = $JikanTitle
                    titleEnglish = [string]$_.title_english
                    titleRomaji = [string]$_.title
                    titleNative = [string]$_.title_japanese
                    synonyms = @($_.title_synonyms | ForEach-Object { Limit-LogText ([string]$_) 120 })
                    format = [string]$_.type
                    seasonYear = if ($_.year) { [int]$_.year } else { $null }
                    episodes = if ($_.episodes) { [int]$_.episodes } else { $null }
                    popularity = if ($_.popularity) { [int]$_.popularity } else { 0 }
                    sourceUrl = [string]$_.url
                    imageUrl = [string]$_.images.jpg.image_url
                    score = if ($JikanScores.Count) { [Math]::Round([double]$JikanScores[0], 4) } else { 0 }
                }
            } | Sort-Object -Property score -Descending | Select-Object -First 5)
        }
        catch {
            Write-AppLog -Level "WARN" -Message "Jikan search failed: $($_.Exception.Message)"
        }
    }

    if (-not $JobId -or (Test-LlmJobGenerationCurrent $JobId $Generation)) {
        Set-AnimeSearchCacheItem $Key @($Candidates) $Generation
    }
    return @($Candidates)
}

function New-LlmCodedException {
    param(
        [string]$Code,
        [string]$Message
    )

    $Exception = [System.InvalidOperationException]::new($Message)
    $Exception.Data['LlmErrorCode'] = $Code
    return $Exception
}

function Throw-LlmError {
    param(
        [string]$Code,
        [string]$Message
    )

    throw (New-LlmCodedException $Code $Message)
}

function ConvertFrom-LlmStructuredJson {
    param(
        [AllowNull()][string]$Content,
        [string]$EmptyMessage = "OpenRouter returned an empty structured response."
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        Throw-LlmError "LLM_RESPONSE_PARSE_ERROR" $EmptyMessage
    }
    try {
        return $Content | ConvertFrom-Json
    }
    catch {
        Throw-LlmError "LLM_RESPONSE_PARSE_ERROR" "OpenRouter returned malformed structured JSON."
    }
}

function Normalize-OpenRouterContentText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return "" }
    $Normalized = ([string]$Text).Trim()
    while ($Normalized.Length -gt 0 -and $Normalized[0] -eq [char]0xFEFF) {
        $Normalized = $Normalized.Substring(1).TrimStart()
    }
    return $Normalized.Trim()
}

function Get-OpenRouterMessageContentInfo {
    param([AllowNull()][object]$Message)

    $Content = if ($Message -and $Message.PSObject.Properties['content']) { $Message.content } else { $null }
    $ContentType = if ($null -eq $Content) { "null" } else { $Content.GetType().FullName }
    $PartCount = 0
    $Text = ""

    if ($Content -is [string]) {
        $Text = [string]$Content
    }
    elseif ($Content -is [System.Array] -or $Content -is [System.Collections.IList]) {
        $Parts = [System.Collections.Generic.List[string]]::new()
        foreach ($Part in @($Content)) {
            $PartCount++
            if ($null -eq $Part) { continue }
            if ($Part -is [string]) {
                # OpenRouter text-part arrays are expected to use objects. A
                # bare string is not a documented part and is ignored.
                continue
            }
            $Candidate = ""
            if (
                $Part.PSObject.Properties['type'] -and
                [string]$Part.type -eq 'text' -and
                $Part.PSObject.Properties['text'] -and
                $Part.text -is [string]
            ) {
                $Candidate = [string]$Part.text
            }
            elseif ($Part.PSObject.Properties['text'] -and $Part.text -is [string]) {
                $Candidate = [string]$Part.text
            }
            elseif ($Part.PSObject.Properties['content'] -and $Part.content -is [string]) {
                $Candidate = [string]$Part.content
            }
            if (-not [string]::IsNullOrEmpty($Candidate)) { $Parts.Add($Candidate) }
        }
        $Text = $Parts -join ''
    }
    elseif ($null -ne $Content) {
        if ($Content.PSObject.Properties['text'] -and $Content.text -is [string]) {
            $Text = [string]$Content.text
        }
        elseif ($Content.PSObject.Properties['content'] -and $Content.content -is [string]) {
            $Text = [string]$Content.content
        }
    }

    return [pscustomobject]@{
        text = Normalize-OpenRouterContentText $Text
        contentClrType = $ContentType
        contentPartCount = $PartCount
    }
}

function Get-OpenRouterMessageContentText {
    param([AllowNull()][object]$Message)

    $Refusal = if ($Message -and $Message.PSObject.Properties['refusal']) {
        Normalize-OpenRouterContentText ([string]$Message.refusal)
    } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($Refusal)) {
        Throw-LlmError "LLM_RESPONSE_REFUSAL" "OpenRouter refused to produce the requested structured response."
    }
    $Info = Get-OpenRouterMessageContentInfo $Message
    if ([string]::IsNullOrWhiteSpace([string]$Info.text)) {
        Throw-LlmError "LLM_RESPONSE_CONTENT_MISSING" "OpenRouter returned no text content."
    }
    return [string]$Info.text
}

function Get-OpenRouterContentFingerprint {
    param([AllowNull()][string]$Text)

    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = (Get-StrictUtf8Encoding).GetBytes([string]$Text)
        $Hash = $Sha.ComputeHash($Bytes)
        return (([BitConverter]::ToString($Hash)).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
    }
    finally { $Sha.Dispose() }
}

function Test-OpenRouterStructuredObject {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.Array]) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $true }
    return $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'
}

function Get-OpenRouterParsedTopLevelType {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Array]) { return 'array' }
    if (Test-OpenRouterStructuredObject $Value) { return 'object' }
    if ($Value -is [string]) { return 'string' }
    return $Value.GetType().FullName
}

function Get-OpenRouterSafeDiagnosticsText {
    param([AllowNull()][object]$Diagnostics)

    if (-not $Diagnostics) { return "" }
    $Pairs = [System.Collections.Generic.List[string]]::new()
    foreach ($Name in @(
        'contentClrType', 'contentLength', 'contentPartCount', 'startsWithFence',
        'looksDoubleEncoded', 'parsedTopLevelType', 'presentKeys', 'finishReason',
        'model', 'provider', 'requestId', 'contentFingerprint'
    )) {
        if (-not $Diagnostics.PSObject.Properties[$Name]) { continue }
        $Value = Limit-LogText (Mask-SecretText ([string]$Diagnostics.$Name)) 200
        if ([string]::IsNullOrWhiteSpace($Value)) { continue }
        $Pairs.Add("$Name=$Value")
    }
    return Limit-LogText ($Pairs -join ' ') 1000
}

function Add-LlmSafeDiagnostics {
    param(
        [AllowNull()][System.Exception]$Exception,
        [AllowNull()][object]$Diagnostics
    )

    if (-not $Exception -or -not $Diagnostics) { return }
    $SafeText = Get-OpenRouterSafeDiagnosticsText $Diagnostics
    if (-not [string]::IsNullOrWhiteSpace($SafeText)) {
        $Exception.Data['LlmSafeDiagnostics'] = $SafeText
    }
}

function Throw-OpenRouterStructuredContentError {
    param(
        [string]$Code,
        [string]$Message,
        [AllowNull()][object]$Diagnostics
    )

    $Exception = New-LlmCodedException $Code $Message
    Add-LlmSafeDiagnostics $Exception $Diagnostics
    throw $Exception
}

function ConvertFrom-OpenRouterStructuredContent {
    param(
        [AllowNull()][object]$Message,
        [AllowNull()][string]$FinishReason = "",
        [AllowNull()][string]$Model = "",
        [AllowNull()][string]$Provider = "",
        [AllowNull()][string]$RequestId = "",
        [ref]$Diagnostics
    )

    $Info = Get-OpenRouterMessageContentInfo $Message
    $Text = [string]$Info.text
    $Metadata = [pscustomobject]@{
        contentClrType = Limit-LogText ([string]$Info.contentClrType) 120
        contentLength = $Text.Length
        contentPartCount = [int]$Info.contentPartCount
        startsWithFence = $Text.StartsWith('```')
        looksDoubleEncoded = $false
        parsedTopLevelType = ''
        presentKeys = ''
        finishReason = Limit-LogText $FinishReason 80
        model = Limit-LogText $Model 160
        provider = Limit-LogText $Provider 120
        requestId = Limit-LogText $RequestId 160
        contentFingerprint = if ($Text.Length -gt 0) { Get-OpenRouterContentFingerprint $Text } else { '' }
    }
    if ($Diagnostics) { $Diagnostics.Value = $Metadata }

    $Refusal = if ($Message -and $Message.PSObject.Properties['refusal']) {
        Normalize-OpenRouterContentText ([string]$Message.refusal)
    } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($Refusal)) {
        Throw-OpenRouterStructuredContentError 'LLM_RESPONSE_REFUSAL' 'OpenRouter refused to produce the requested structured response.' $Metadata
    }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Throw-OpenRouterStructuredContentError 'LLM_RESPONSE_CONTENT_MISSING' 'OpenRouter returned no text content.' $Metadata
    }

    $CandidateText = $Text
    $Parsed = $null
    $ParsedOk = $false
    try {
        $Parsed = $CandidateText | ConvertFrom-Json -ErrorAction Stop
        $ParsedOk = $true
    }
    catch {}

    if (-not $ParsedOk -and $Metadata.startsWithFence) {
        $FenceMatch = [regex]::Match(
            $CandidateText,
            '\A```(?:json)?[ \t]*(?:\r?\n)?(?<body>[\s\S]*?)(?:\r?\n)?```\z',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($FenceMatch.Success) {
            $CandidateText = Normalize-OpenRouterContentText $FenceMatch.Groups['body'].Value
            try {
                $Parsed = $CandidateText | ConvertFrom-Json -ErrorAction Stop
                $ParsedOk = $true
            }
            catch {}
        }
    }

    if (-not $ParsedOk) {
        Throw-OpenRouterStructuredContentError 'LLM_RESPONSE_PARSE_ERROR' 'OpenRouter returned malformed structured JSON.' $Metadata
    }

    $Metadata.parsedTopLevelType = Get-OpenRouterParsedTopLevelType $Parsed
    if ($Parsed -is [string]) {
        $InnerText = Normalize-OpenRouterContentText ([string]$Parsed)
        if ($InnerText.StartsWith('{') -and $InnerText.EndsWith('}')) {
            $Metadata.looksDoubleEncoded = $true
            try { $Parsed = $InnerText | ConvertFrom-Json -ErrorAction Stop }
            catch {
                Throw-OpenRouterStructuredContentError 'LLM_RESPONSE_PARSE_ERROR' 'OpenRouter returned malformed double-encoded structured JSON.' $Metadata
            }
            $Metadata.parsedTopLevelType = Get-OpenRouterParsedTopLevelType $Parsed
        }
    }

    if (-not (Test-OpenRouterStructuredObject $Parsed)) {
        Throw-OpenRouterStructuredContentError 'LLM_SCHEMA_VALIDATION_ERROR' 'OpenRouter structured response must be a JSON object.' $Metadata
    }
    $SafeKeys = @($Parsed.PSObject.Properties.Name | ForEach-Object {
        $Key = [string]$_
        if ($Key -match '^[A-Za-z][A-Za-z0-9_]{0,63}$') { $Key } else { '<nonstandard>' }
    } | Select-Object -Unique)
    $Metadata.presentKeys = Limit-LogText (($SafeKeys -join ',')) 300
    if ($Diagnostics) { $Diagnostics.Value = $Metadata }
    return $Parsed
}

function ConvertFrom-OpenRouterIntentResponse {
    param(
        [AllowNull()][object]$Response,
        [object[]]$Entries
    )

    if (
        -not $Response -or
        -not $Response.PSObject.Properties['choices'] -or
        @($Response.choices).Count -eq 0 -or
        -not @($Response.choices)[0].PSObject.Properties['message']
    ) {
        Throw-LlmError 'LLM_RESPONSE_CONTENT_MISSING' 'OpenRouter returned no message content.'
    }

    $Choice = @($Response.choices)[0]
    $Diagnostics = $null
    $Result = ConvertFrom-OpenRouterStructuredContent `
        -Message $Choice.message `
        -FinishReason ([string]$Choice.finish_reason) `
        -Model ([string]$Response.model) `
        -Provider ([string]$Response.provider) `
        -RequestId ([string]$Response.id) `
        -Diagnostics ([ref]$Diagnostics)
    try {
        return ConvertTo-LlmNormalizedIntentEnvelope $Result $Entries $Diagnostics
    }
    catch {
        Add-LlmSafeDiagnostics $_.Exception $Diagnostics
        throw
    }
}

function ConvertTo-LlmConfidence {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $null }

    $Parsed = 0.0
    if ($Value -is [string]) {
        $Text = ([string]$Value).Trim()
        if (
            [string]::IsNullOrWhiteSpace($Text) -or
            -not [double]::TryParse(
                $Text,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$Parsed
            )
        ) {
            return $null
        }
    }
    elseif (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]
    ) {
        try {
            $Parsed = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            return $null
        }
    }
    else {
        return $null
    }

    if ([double]::IsNaN($Parsed) -or [double]::IsInfinity($Parsed) -or $Parsed -lt 0 -or $Parsed -gt 1) {
        return $null
    }
    return [double]$Parsed
}

function Get-StrictUtf8Encoding {
    return [System.Text.UTF8Encoding]::new($false, $true)
}

function ConvertTo-Utf8JsonBytes {
    param(
        [AllowNull()][object]$Value,
        [int]$Depth = 30
    )

    try {
        $Json = $Value | ConvertTo-Json -Depth $Depth -Compress
        return (Get-StrictUtf8Encoding).GetBytes($Json)
    }
    catch {
        Throw-LlmError "LLM_REQUEST_ENCODING_ERROR" "OpenRouter request could not be encoded as UTF-8."
    }
}

function ConvertFrom-Utf8JsonBytes {
    param(
        [AllowNull()][byte[]]$Bytes,
        [string]$EmptyMessage = "OpenRouter returned an empty response."
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        Throw-LlmError "LLM_RESPONSE_PARSE_ERROR" $EmptyMessage
    }
    try {
        $Json = (Get-StrictUtf8Encoding).GetString($Bytes)
    }
    catch {
        Throw-LlmError "LLM_RESPONSE_ENCODING_ERROR" "OpenRouter returned invalid UTF-8."
    }
    return ConvertFrom-LlmStructuredJson $Json $EmptyMessage
}

function Get-OpenRouterSafeUpstreamError {
    param(
        [AllowNull()][object]$Payload,
        [int]$StatusCode
    )

    $Message = "OpenRouter returned HTTP $StatusCode."
    if ($Payload) {
        $Candidate = ""
        if ($Payload.PSObject.Properties['error'] -and $Payload.error) {
            if ($Payload.error -is [string]) { $Candidate = [string]$Payload.error }
            elseif ($Payload.error.PSObject.Properties['message']) { $Candidate = [string]$Payload.error.message }
        }
        elseif ($Payload.PSObject.Properties['message']) {
            $Candidate = [string]$Payload.message
        }
        if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
            $Message = Limit-LogText (Get-MaskedText $Candidate) 300
        }
    }
    return $Message
}

function Get-OpenRouterRetryAfterSeconds {
    param([AllowNull()][object]$Response)

    if (-not $Response -or -not $Response.Headers -or -not $Response.Headers.RetryAfter) { return 0 }
    try {
        if ($Response.Headers.RetryAfter.Delta) {
            return [Math]::Max(1, [int][Math]::Ceiling($Response.Headers.RetryAfter.Delta.TotalSeconds))
        }
        if ($Response.Headers.RetryAfter.Date) {
            return [Math]::Max(1, [int][Math]::Ceiling(($Response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds))
        }
    }
    catch {}
    return 0
}

function New-OpenRouterHttpException {
    param(
        [string]$Message,
        [int]$StatusCode = 0,
        [int]$RetryAfterSeconds = 0,
        [string]$OpenRouterErrorCode = ""
    )

    $Exception = [System.Net.Http.HttpRequestException]::new((Limit-LogText (Get-MaskedText $Message) 500))
    $Exception.Data['HttpStatusCode'] = $StatusCode
    $Exception.Data['RetryAfterSeconds'] = $RetryAfterSeconds
    if (-not [string]::IsNullOrWhiteSpace($OpenRouterErrorCode)) {
        $Exception.Data['OpenRouterErrorCode'] = Limit-LogText $OpenRouterErrorCode 100
    }
    return $Exception
}

function Get-LlmExceptionDataValue {
    param(
        [AllowNull()][System.Exception]$Exception,
        [string]$Name
    )

    $Current = $Exception
    while ($Current) {
        try {
            if ($Current.Data.Contains($Name)) { return $Current.Data[$Name] }
        }
        catch {}
        $Current = $Current.InnerException
    }
    return $null
}

function Get-LlmHttpStatusCode {
    param([AllowNull()][System.Exception]$Exception)

    $Stored = Get-LlmExceptionDataValue $Exception 'HttpStatusCode'
    if ($null -ne $Stored) {
        try { return [int]$Stored } catch {}
    }
    $Current = $Exception
    while ($Current) {
        try { return [int]$Current.Response.StatusCode } catch {}
        $Current = $Current.InnerException
    }
    return 0
}

function Get-LlmRetryAfterSeconds {
    param([AllowNull()][System.Exception]$Exception)

    $Stored = Get-LlmExceptionDataValue $Exception 'RetryAfterSeconds'
    if ($null -ne $Stored) {
        try { return [Math]::Max(0, [int]$Stored) } catch {}
    }
    return 0
}

function Invoke-OpenRouterRequest {
    param(
        [object]$Payload,
        [int]$TimeoutSec = 45
    )

    $ApiKey = Get-OpenRouterStoredApiKey
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        Throw-LlmError "OPENROUTER_KEY_MISSING" "OpenRouter API key is not configured."
    }
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {
        Throw-LlmError "OPENROUTER_HTTP_UNAVAILABLE" "System.Net.Http is unavailable."
    }

    $ProxyUrl = Get-OpenRouterStoredProxyUrl
    $Handler = $null
    $Client = $null
    $Request = $null
    $Content = $null
    $Response = $null
    $Cancellation = $null
    try {
        $RequestBytes = ConvertTo-Utf8JsonBytes $Payload 30
        $Handler = [System.Net.Http.HttpClientHandler]::new()
        $Handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
            $ProxyUri = [Uri]$ProxyUrl
            $Proxy = [System.Net.WebProxy]::new($ProxyUri)
            if (-not [string]::IsNullOrWhiteSpace($ProxyUri.UserInfo)) {
                $Parts = $ProxyUri.UserInfo.Split(':', 2)
                $UserName = [Uri]::UnescapeDataString($Parts[0])
                $Password = if ($Parts.Count -gt 1) { [Uri]::UnescapeDataString($Parts[1]) } else { "" }
                $Proxy.Credentials = [System.Net.NetworkCredential]::new($UserName, $Password)
            }
            $Handler.Proxy = $Proxy
            $Handler.UseProxy = $true
        }

        $Client = [System.Net.Http.HttpClient]::new($Handler, $false)
        $Request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Post,
            "https://openrouter.ai/api/v1/chat/completions"
        )
        $Request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $ApiKey)
        $Request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/json"))
        [void]$Request.Headers.TryAddWithoutValidation("HTTP-Referer", "http://127.0.0.1:5500")
        [void]$Request.Headers.TryAddWithoutValidation("X-Title", "PapichWheel")
        $Content = [System.Net.Http.ByteArrayContent]::new($RequestBytes)
        $Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/json")
        $Content.Headers.ContentType.CharSet = "utf-8"
        $Request.Content = $Content

        $Cancellation = [System.Threading.CancellationTokenSource]::new()
        $Cancellation.CancelAfter([TimeSpan]::FromSeconds([Math]::Max(1, $TimeoutSec)))
        try {
            $Response = $Client.SendAsync(
                $Request,
                [System.Net.Http.HttpCompletionOption]::ResponseContentRead,
                $Cancellation.Token
            ).GetAwaiter().GetResult()
            $ResponseBytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        }
        catch [System.OperationCanceledException] {
            if ($Cancellation.IsCancellationRequested) {
                Throw-LlmError "OPENROUTER_TIMEOUT" "OpenRouter request timed out."
            }
            throw
        }

        if (-not $Response.IsSuccessStatusCode) {
            $StatusCode = [int]$Response.StatusCode
            $RetryAfter = Get-OpenRouterRetryAfterSeconds $Response
            $ErrorPayload = $null
            $ErrorCode = ""
            try {
                $ErrorPayload = ConvertFrom-Utf8JsonBytes $ResponseBytes "OpenRouter returned an empty error response."
                if ($ErrorPayload -and $ErrorPayload.error -and $ErrorPayload.error.PSObject.Properties['code']) {
                    $ErrorCode = [string]$ErrorPayload.error.code
                }
            }
            catch {
                if ((Get-LlmExceptionCode $_.Exception) -eq 'LLM_RESPONSE_ENCODING_ERROR') { throw }
            }
            throw (New-OpenRouterHttpException `
                (Get-OpenRouterSafeUpstreamError $ErrorPayload $StatusCode) `
                $StatusCode `
                $RetryAfter `
                $ErrorCode)
        }
        return ConvertFrom-Utf8JsonBytes $ResponseBytes "OpenRouter returned an empty HTTP response."
    }
    finally {
        if ($Cancellation) { $Cancellation.Dispose() }
        if ($Response) { $Response.Dispose() }
        if ($Request) { $Request.Dispose() }
        elseif ($Content) { $Content.Dispose() }
        if ($Client) { $Client.Dispose() }
        if ($Handler) { $Handler.Dispose() }
    }
}

function Get-OpenRouterIntentProviderSchema {
    param([object[]]$CurrentEntries)

    $Entries = @(Get-ActiveEntriesForLlmIntent $CurrentEntries)
    $ItemProperties = @{
        category = @{ type = 'string'; enum = @('game', 'anime', 'movie', 'tv_show', 'cartoon', 'other', 'unknown') }
        catalog = @{ type = 'string'; enum = @('steam', 'anime', 'none') }
        mentionedTitle = @{ type = 'string' }
        displayTitle = @{ type = 'string' }
        officialTitleGuess = @{ type = 'string' }
        searchQueries = @{
            type = 'array'
            maxItems = $script:LlmMaxSearchQueriesPerItem
            items = @{ type = 'string' }
        }
        originalLanguage = @{ type = 'string'; enum = @('ru', 'en', 'ja', 'ko', 'zh', 'other', 'unknown') }
        confidence = @{ type = 'number'; minimum = 0; maximum = 1 }
        reason = @{ type = 'string' }
    }
    $Required = @('category', 'catalog', 'mentionedTitle', 'displayTitle', 'officialTitleGuess', 'searchQueries', 'originalLanguage', 'confidence', 'reason')
    if ($Entries.Count -gt 0) {
        $AllowedEntryIds = @($Entries | ForEach-Object { [string]$_.id } | Select-Object -Unique)
        $ItemProperties.existingEntryId = @{ type = 'string'; enum = @($AllowedEntryIds + '__none__') }
        $ItemProperties.existingSelectionConfidence = @{ type = 'number'; minimum = 0; maximum = 1 }
        $Required += @('existingEntryId', 'existingSelectionConfidence')
    }
    return @{
        type = 'object'
        properties = @{
            items = @{
                type = 'array'
                minItems = 0
                maxItems = $script:LlmMaxItems
                items = @{
                    type = 'object'
                    properties = $ItemProperties
                    required = $Required
                    additionalProperties = $false
                }
            }
        }
        required = @('items')
        additionalProperties = $false
    }
}

function Invoke-OpenRouterIntentAnalysis {
    param(
        [object]$Donation,
        [object]$Settings,
        [string]$NormalizedMessage,
        [object[]]$Entries
    )

    $Model = if ($Settings -and -not [string]::IsNullOrWhiteSpace([string]$Settings.model)) { [string]$Settings.model } else { $script:DefaultLlmModel }
    $CurrentEntries = @(Get-ActiveEntriesForLlmIntent $Entries)
    $SystemPrompt = @"
Prompt version: auction-precision-v6

Analyze exactly one donation for a local auction. Return only strict schema-valid JSON, without markdown or text outside JSON. Extract auction targets, not every mentioned work.

Decide separately for every mentioned work, in this order.

1. EXCLUSION GATE

Exclude a work mentioned only in:
- a question about it, review, comparison or recommendation;
- plot, characters, places or thematic description;
- gameplay instructions, current gameplay or past experience;
- a request to check its trailer, page or gameplay;
- advertising, jokes or examples of channel content;
- a hypothetical or existing-auction outcome such as "if X wins".

A question is a target only when it asks which concrete work should receive the donation or be selected for the auction.

Never infer a work from plot details, characters, fictional companies or places.

Exclusions override standalone-title detection. A separate direct allocation cue still wins for the title governed by that cue.

If the reason would say "no auction cue", "merely mentioned", "suggested to check" or similar, DO NOT return that item.

2. TARGET GATE

Include a concrete work only when at least one condition applies:

A. A direct allocation cue governs it:
"на TITLE", "донат/доначу на", "кинь/кидаю/докинь/добавь/закинь", "в аук/лот", "пикаю/выбираю TITLE".

B. It is an explicit alternative in an auction or stream-content choice:
"TITLE_A или TITLE_B", "хочу TITLE_A, но можно TITLE_B", "если нельзя TITLE_A — TITLE_B", "реши сам".
Return every concrete alternative, including discouraged or unlikely ones.

C. It is a standalone nomination: the whole message, or an isolated beginning/end of the message, is a recognizable concrete title and the surrounding text does not discuss, review or describe that same work.

A new direct allocation cue starts a new target.

3. EXTRACTION AND NORMALIZATION

Return one item per distinct canonical work, in mention order, maximum five.

Merge repeated mentions and aliases of the same work into one item. Never combine different works.

mentionedTitle:
- must be the smallest useful verbatim contiguous substring of donationMessage;
- must contain actual title words;
- must not be only "первый", "второй", a pronoun, category or preposition.

displayTitle:
- use the canonical, correctly spelled title;
- preserve meaningful numbers, year, season, episode, chapter, edition and subtitle;
- never infer a sequel from an ordinal alone;
- Russian-origin works stay in Russian Cyrillic with correct capitalization and "ё";
- foreign games use the official Steam/product title;
- other foreign media use the standard official international product title;
- avoid literal translations and scholarly romanization when a widely used international title exists.

category must be one of:
game, anime, movie, tv_show, cartoon, other, unknown.

catalog must be steam for a likely video game, anime for anime lookup, otherwise none.
officialTitleGuess is only a catalog search hint and never authoritative metadata.

searchQueries:
- prefer one canonical query;
- add a second only for a materially different alias or language;
- queries must be unique ignoring case and refer only to this item.

confidence covers both auction intent and title identification.
reason must be brief, Russian and consistent with inclusion.

Never return generic words such as "игра", "аниме", "сериал", "фильм", "мем", "хоррор" or "смерть".

Known aliases, not an exhaustive list:
- "копатель онлайн" = Digger Online;
- "булли" = Bully;
- "коратель/каратель" = The Punisher, game;
- METEL = Metel - Horror Escape;
- "край оф фир" = Cry of Fear;
- "фнафыч 4" = Five Nights at Freddy's 4;
- "добрыню STORY" = "Добрыня Никитич и Змей Горыныч", game;
- "деус секс мд" = Deus Ex: Mankind Divided;
- "готика ремейк" = Gothic 1 Remake;
- "цифровой цирк" = The Amazing Digital Circus, cartoon;
- "The Coffin of Andy and Laylay" = The Coffin of Andy and Leyley, game;
- "алеша/алёша попович" = "Алёша Попович и Тугарин Змей", game; an English catalog alias may appear only in searchQueries or officialTitleGuess, never replace displayTitle;
- AMAZING ONLINE stays AMAZING ONLINE.

When currentEntries are provided, choose existingEntryId only for an unambiguous exact work, including its part, season, year, remake/remaster, movie or special. Similar theme is not a match: "Дальнобойщики 2" is not Euro Truck Simulator 2. Otherwise use __none__ and existingSelectionConfidence=0.

Examples:
- "Кидаю на A. Слышал про B? Чекни трейлер" => A only.
- "Как тебе A и B? Донат на C" => C only.
- "Если A выиграет, будешь играть?" => items=[].
- "Хочу A, но можно B, реши сам" => A and B.
- A title followed by its plot description, without allocation or nomination => items=[].

Before output silently verify:
- every item passed the target gate;
- no exclusion-only mention was included;
- every direct-cue target and every auction-choice alternative is present;
- duplicates and aliases are merged;
- mentionedTitle occurs verbatim in donationMessage;
- installments, seasons, chapters and years were preserved;
- no title was inferred only from plot context;
- searchQueries are case-insensitively unique.

Never return lot IDs, external IDs, URLs, catalog availability claims or donation-crediting instructions.
"@
    if ($CurrentEntries.Count -gt 0) {
        $SystemPrompt += "`nFor every item return existingEntryId and existingSelectionConfidence. Use __none__ and 0 when no exact current entry is safe."
    } else {
        $SystemPrompt += "`nThere are no current entries. Do not return existingEntryId or existingSelectionConfidence."
    }
    $UserPayload = [pscustomobject]@{
        donationMessage = Limit-LogText ([string]$Donation.message) 1000
        currentEntries = $CurrentEntries
    }
    $Schema = Get-OpenRouterIntentProviderSchema $CurrentEntries
    $Payload = @{
        model = $Model
        max_tokens = 1200
        provider = @{ require_parameters = $true }
        response_format = @{
            type = "json_schema"
            json_schema = @{
                name = "donation_lot_analysis"
                strict = $true
                schema = $Schema
            }
        }
        messages = @(
            @{ role = "system"; content = $SystemPrompt },
            @{ role = "user"; content = ($UserPayload | ConvertTo-Json -Depth 20 -Compress) }
        )
    }

    $Response = Invoke-OpenRouterRequest $Payload 45
    return ConvertFrom-OpenRouterIntentResponse $Response $CurrentEntries
}

function Test-OpenRouterIntegration {
    param([string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $script:DefaultLlmModel }
    $Schema = Get-OpenRouterIntentProviderSchema @()
    $ItemSchema = $Schema.properties.items.items
    $ItemSchema.properties.category.enum = @('unknown')
    $ItemSchema.properties.catalog.enum = @('none')
    $Payload = @{
        model = $Model
        max_tokens = 120
        provider = @{ require_parameters = $true }
        response_format = @{
            type = "json_schema"
            json_schema = @{ name = "papich_openrouter_test"; strict = $true; schema = $Schema }
        }
        messages = @(
            @{ role = "system"; content = "Return the requested strict JSON object." },
            @{ role = "user"; content = "Return one items element: category unknown, catalog none, mentionedTitle test, displayTitle test, officialTitleGuess test, searchQueries containing test, originalLanguage unknown, confidence 0.5, and a short Russian reason." }
        )
    }
    $StartedAt = Get-Date
    try {
        $Response = Invoke-OpenRouterRequest $Payload 20
        $NormalizedResponse = ConvertFrom-OpenRouterIntentResponse $Response @()
        $ParsedItems = @(ConvertTo-LlmIntentItems $NormalizedResponse @())
        if ($ParsedItems.Count -ne 1 -or [string]$ParsedItems[0].category -ne "unknown" -or [double]$ParsedItems[0].confidence -ne 0.5) {
            throw "Selected model returned invalid structured output."
        }
        $ElapsedMs = [int]((Get-Date) - $StartedAt).TotalMilliseconds
        return [pscustomobject]@{
            ok = $true
            configured = $true
            proxyConfigured = -not [string]::IsNullOrWhiteSpace((Get-OpenRouterStoredProxyUrl))
            maskedProxyUrl = Get-MaskedProxyUrl (Get-OpenRouterStoredProxyUrl)
            elapsedMs = $ElapsedMs
            model = [string]$Response.model
            status = "connected"
        }
    }
    catch {
        $RawError = Get-MaskedText $_.Exception.Message
        $StatusCode = Get-LlmHttpStatusCode $_.Exception
        $LowerError = $RawError.ToLowerInvariant()
        $FriendlyError = if ([string]::IsNullOrWhiteSpace((Get-OpenRouterStoredApiKey))) { "OpenRouter key is not configured." }
            elseif ($StatusCode -eq 401 -or $StatusCode -eq 403) { "OpenRouter rejected the API key." }
            elseif ($StatusCode -eq 404 -or $LowerError.Contains("model")) { "Selected OpenRouter model was not found or is unavailable." }
            elseif ($StatusCode -eq 429) { "OpenRouter rate limit reached. Try again later." }
            elseif ($LowerError.Contains("schema") -or $LowerError.Contains("structured")) { "Selected model does not support the required structured output." }
            elseif ($LowerError.Contains("proxy")) { "OpenRouter proxy is unavailable or configured incorrectly." }
            elseif ($LowerError.Contains("timeout") -or $LowerError.Contains("timed out")) { "OpenRouter request timed out." }
            elseif ($StatusCode -ge 500) { "OpenRouter provider is temporarily unavailable." }
            else { Limit-LogText $RawError 300 }
        return [pscustomobject]@{
            ok = $false
            configured = -not [string]::IsNullOrWhiteSpace((Get-OpenRouterStoredApiKey))
            proxyConfigured = -not [string]::IsNullOrWhiteSpace((Get-OpenRouterStoredProxyUrl))
            maskedProxyUrl = Get-MaskedProxyUrl (Get-OpenRouterStoredProxyUrl)
            error = $FriendlyError
            status = 503
        }
    }
}

function Assert-LlmJobGenerationCurrent {
    param(
        [string]$JobId,
        [long]$Generation
    )

    if ($JobId -and -not (Test-LlmJobGenerationCurrent $JobId $Generation)) {
        Throw-LlmError "LLM_JOB_CANCELLED" "AI job belongs to an inactive auction."
    }
}

function Test-LlmIntentReadyForCatalog {
    param(
        [AllowNull()][string]$Category,
        [AllowNull()][string]$Query,
        [double]$IntentConfidence
    )

    $QueryInfo = Get-LlmTitleInformation $Query
    return [bool]$QueryInfo.usable -and
        [string]$Category -ne 'unknown' -and
        $IntentConfidence -ge 0.50
}

function Invoke-LlmDonationItemPipeline {
    param(
        [object]$Item,
        [object[]]$Entries,
        [object]$Settings,
        [string]$JobId,
        [long]$Generation,
        [AllowNull()][scriptblock]$SteamSearcher = $null,
        [AllowNull()][scriptblock]$AnimeSearcher = $null
    )

    $Query = if (-not [string]::IsNullOrWhiteSpace([string]$Item.officialTitleGuess)) {
        [string]$Item.officialTitleGuess
    } elseif (@($Item.searchQueries).Count -gt 0) {
        [string]$Item.searchQueries[0]
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Item.displayTitle)) {
        [string]$Item.displayTitle
    } else {
        [string]$Item.mentionedTitle
    }
    $Query = Limit-LogText $Query 200
    $Candidates = @()
    $CatalogStatus = 'not_applicable'
    $ManualSuggestion = Get-LlmManualLotSuggestion `
        ([string]$Item.displayTitle) `
        ([string]$Item.category) `
        ([string]$Item.originalLanguage)
    $ExistingOptions = @(Get-LlmExistingOptionsForItem $Item $Entries)
    $SafeSelectedOption = @($ExistingOptions | Where-Object { [bool]$_.safeAutoAssign } | Select-Object -First 1)[0]
    $ShouldSearchCatalog = -not $SafeSelectedOption -and
        (Test-LlmIntentReadyForCatalog ([string]$Item.category) $Query ([double]$Item.confidence))

    if ($ShouldSearchCatalog -and [string]$Item.catalog -eq 'steam') {
        if ($Settings -and $Settings.allowSteam -eq $false) {
            $CatalogStatus = 'disabled'
        }
        else {
            if ($JobId) { Update-LlmJobStage $JobId 'searching_steam' $Generation }
            $SearchResult = Search-SteamCandidatesForQueries $Item $JobId $Generation $SteamSearcher
            $Candidates = @($SearchResult.candidates)
            $CatalogStatus = if ($Candidates.Count -gt 0) { 'ok' }
                elseif ($SearchResult.attempted -gt 0 -and $SearchResult.failures -ge $SearchResult.attempted) { 'unavailable' }
                else { 'not_found' }
        }
    }
    elseif ($ShouldSearchCatalog -and [string]$Item.catalog -eq 'anime') {
        if ($Settings -and $Settings.allowAnime -eq $false) {
            $CatalogStatus = 'disabled'
        }
        else {
            if ($JobId) { Update-LlmJobStage $JobId 'searching_anime' $Generation }
            $AnimeQuery = @($Item.searchQueries | Select-Object -First 1)[0]
            if ([string]::IsNullOrWhiteSpace([string]$AnimeQuery)) { $AnimeQuery = $Query }
            try {
                $Candidates = if ($AnimeSearcher) {
                    @(& $AnimeSearcher $AnimeQuery $JobId $Generation)
                } else {
                    @(Search-AnimeCandidates $AnimeQuery $JobId $Generation)
                }
                $CatalogStatus = if ($Candidates.Count -gt 0) { 'ok' } else { 'not_found' }
            }
            catch {
                Write-AppLog -Level 'WARN' -Message 'Anime search failed for AI job.'
                $CatalogStatus = 'unavailable'
            }
        }
    }

    if ($JobId) { Assert-LlmJobGenerationCurrent $JobId $Generation }
    $Candidates = @(Add-LlmCandidateExistingMetadata `
        @($Candidates | Where-Object { $_ -and $_.candidateId } | Select-Object -First $script:LlmMaxCandidatesPerItem) `
        $Entries `
        ([string]$Item.category))
    $ExistingOptions = @(Get-LlmExistingOptionsForItem $Item $Entries $Candidates)
    return [pscustomobject]@{
        itemId = Limit-LogText ([string]$Item.itemId) 40
        category = [string]$Item.category
        catalog = [string]$Item.catalog
        mentionedTitle = Limit-LogText ([string]$Item.mentionedTitle) 200
        displayTitle = Normalize-LlmDisplayTitle ([string]$Item.displayTitle)
        officialTitleGuess = Limit-LogText ([string]$Item.officialTitleGuess) 200
        originalLanguage = Limit-LogText ([string]$Item.originalLanguage) 20
        query = $Query
        searchQueries = @($Item.searchQueries | Select-Object -First $script:LlmMaxSearchQueriesPerItem)
        intentConfidence = [double]$Item.confidence
        existingSelectionConfidence = [double]$Item.existingSelectionConfidence
        existingOptions = $ExistingOptions
        candidates = $Candidates
        manualSuggestion = $ManualSuggestion
        catalogStatus = $CatalogStatus
        reason = Limit-LogText ([string]$Item.reason) 400
    }
}

function Invoke-LlmDonationPipeline {
    param(
        [object]$InputData,
        [AllowNull()][scriptblock]$IntentAnalyzer = $null,
        [AllowNull()][scriptblock]$SteamSearcher = $null,
        [AllowNull()][scriptblock]$AnimeSearcher = $null
    )

    $Donation = $InputData.donation
    $Settings = if ($InputData.settings) { $InputData.settings } else { [pscustomobject]@{} }
    $Entries = Get-SafeEntriesForLlm $InputData.entries
    if (-not $Donation) { throw 'Missing donation.' }
    $JobId = [string]$InputData.jobId
    $Generation = if ($InputData.PSObject.Properties['generation']) { [long]$InputData.generation } else { 1L }
    $Message = Limit-LogText ([string]$Donation.message) 1000
    $Normalized = Normalize-LlmText $Message

    if ($JobId) {
        Assert-LlmJobGenerationCurrent $JobId $Generation
        Update-LlmJobStage $JobId 'analyzing_intent' $Generation
    }
    # Exactly one main OpenRouter analysis is performed here. Catalog
    # candidates are never sent back to OpenRouter.
    $RawIntent = if ($IntentAnalyzer) {
        & $IntentAnalyzer $Donation $Settings $Normalized $Entries
    } else {
        Invoke-OpenRouterIntentAnalysis $Donation $Settings $Normalized $Entries
    }
    if ($JobId) { Assert-LlmJobGenerationCurrent $JobId $Generation }
    $IntentItems = @(ConvertTo-LlmIntentItems $RawIntent $Entries | Select-Object -First $script:LlmMaxItems)
    if ($IntentItems.Count -eq 0) {
        return [pscustomobject]@{
            ok = $true
            result = ConvertTo-LlmResult `
                -Action 'ask_manual' `
                -Category 'unknown' `
                -MatchedBy 'no_auction_target' `
                -Items @() `
                -Reason 'AI не нашёл явного предложения лота.'
        }
    }

    $Results = New-Object System.Collections.Generic.List[object]
    foreach ($Item in $IntentItems) {
        if ($JobId) {
            Assert-LlmJobGenerationCurrent $JobId $Generation
            Update-LlmJobStage $JobId 'checking_entries' $Generation
        }
        $Results.Add((Invoke-LlmDonationItemPipeline $Item $Entries $Settings $JobId $Generation $SteamSearcher $AnimeSearcher))
    }
    if ($JobId) {
        Assert-LlmJobGenerationCurrent $JobId $Generation
        Update-LlmJobStage $JobId 'ranking_candidates' $Generation
    }

    $ResultItems = @($Results | ForEach-Object { $_ })
    $FirstItem = $ResultItems[0]
    if ($ResultItems.Count -eq 1) {
        $SafeOption = @($FirstItem.existingOptions | Where-Object { [bool]$_.safeAutoAssign } | Select-Object -First 1)[0]
        if ($SafeOption) {
            $FinalConfidence = [Math]::Min([double]$FirstItem.intentConfidence, [double]$FirstItem.existingSelectionConfidence)
            return [pscustomobject]@{
                ok = $true
                result = ConvertTo-LlmResult `
                    -Action 'assign_existing' `
                    -Category ([string]$FirstItem.category) `
                    -IntentConfidence ([double]$FirstItem.intentConfidence) `
                    -SelectionConfidence ([double]$FirstItem.existingSelectionConfidence) `
                    -FinalConfidence $FinalConfidence `
                    -Query ([string]$FirstItem.query) `
                    -MatchedBy "llm_existing_entry_$([string]$SafeOption.matchKind)" `
                    -ExistingMatchKind ([string]$SafeOption.matchKind) `
                    -EntryId ([string]$SafeOption.entryId) `
                    -EntryFingerprint $SafeOption.entryFingerprint `
                    -Items $ResultItems `
                    -Reason ([string]$FirstItem.reason)
            }
        }
    }

    $FlatCandidates = @($ResultItems | ForEach-Object { @($_.candidates) } | Select-Object -First $script:LlmMaxCandidatesPerItem)
    $SummaryReason = if ($ResultItems.Count -gt 1) {
        'Выберите один итоговый вариант: вся сумма доната будет добавлена только в один лот.'
    } elseif ($FirstItem.catalogStatus -eq 'unavailable') {
        'Каталог временно недоступен. Можно выбрать существующий лот или создать ручной лот по подсказке AI.'
    } elseif ($FirstItem.catalogStatus -eq 'not_found') {
        'Каталог не подтвердил название. Можно выбрать существующий лот или создать ручной лот по подсказке AI.'
    } else {
        [string]$FirstItem.reason
    }
    return [pscustomobject]@{
        ok = $true
        result = ConvertTo-LlmResult `
            -Action 'ask_manual' `
            -Category ([string]$FirstItem.category) `
            -IntentConfidence ([double]$FirstItem.intentConfidence) `
            -Query ([string]$FirstItem.query) `
            -MatchedBy 'manual_options' `
            -Candidates $FlatCandidates `
            -Items $ResultItems `
            -Reason $SummaryReason
    }
}

function New-EmptyLlmJobsStore {
    return [pscustomobject]@{
        version = 3
        revision = 0
        auctionGeneration = 1
        jobs = @()
    }
}

function Read-LlmJobsStoreUnsafe {
    $Store = Read-JsonFileSafe $script:LlmJobsPath (New-EmptyLlmJobsStore)
    if (-not $Store) { $Store = New-EmptyLlmJobsStore }
    if (-not $Store.PSObject.Properties["version"]) {
        $Store | Add-Member -NotePropertyName version -NotePropertyValue 3 -Force
    } else {
        $Store.version = 3
    }
    if (-not $Store.PSObject.Properties["revision"]) { $Store | Add-Member -NotePropertyName revision -NotePropertyValue 0 -Force }
    if (-not $Store.PSObject.Properties["auctionGeneration"] -or [long]$Store.auctionGeneration -lt 1) {
        $Store | Add-Member -NotePropertyName auctionGeneration -NotePropertyValue 1 -Force
    }
    if (-not $Store.PSObject.Properties["jobs"]) { $Store | Add-Member -NotePropertyName jobs -NotePropertyValue @() -Force }
    foreach ($Job in @($Store.jobs)) {
        if (-not $Job.PSObject.Properties["pipelineVersion"]) {
            $Job | Add-Member -NotePropertyName pipelineVersion -NotePropertyValue 0 -Force
        }
        if (-not $Job.PSObject.Properties["generation"]) {
            $Job | Add-Member -NotePropertyName generation -NotePropertyValue ([long]$Store.auctionGeneration) -Force
        }
        if (-not $Job.PSObject.Properties["errorCode"]) {
            $Job | Add-Member -NotePropertyName errorCode -NotePropertyValue "" -Force
        }
    }
    return $Store
}

function Write-LlmJobsStoreUnsafe {
    param([object]$Store)
    return Write-JsonFileSafe $script:LlmJobsPath $Store 35
}

function Write-LlmJobsStoreOrThrow {
    param([object]$Store)
    if (-not (Write-LlmJobsStoreUnsafe $Store)) {
        Throw-LlmError "LLM_JOBS_PERSISTENCE_ERROR" "AI job state could not be saved."
    }
    return $true
}

function Get-NextLlmRevision {
    param([object]$Store)
    $Store.revision = [long]$Store.revision + 1
    return [long]$Store.revision
}

function Get-LlmAnalysisKey {
    param([object]$InputData)

    $Donation = $InputData.donation
    if (-not $Donation) { return "" }
    $Source = [string]$Donation.source
    $ExternalId = [string]$Donation.externalId
    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($ExternalId)) { return "" }
    $Fingerprint = Get-LlmInputFingerprint $InputData
    if ([string]::IsNullOrWhiteSpace($Fingerprint)) { return "" }
    $Expected = "v$($script:LlmPipelineVersion):${Source}:${ExternalId}:$Fingerprint"
    $Provided = if ($InputData.PSObject.Properties["analysisKey"]) { [string]$InputData.analysisKey } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($Provided) -and $Provided -ne $Expected) { return "" }
    return Limit-LogText $Expected 300
}

function Get-LlmInputFingerprint {
    param([object]$InputData)

    if (-not $InputData -or -not $InputData.donation) { return "" }
    $Donation = $InputData.donation
    $Values = [System.Collections.Generic.List[string]]::new()
    $Values.Add([string]$script:LlmPipelineVersion)
    $Values.Add((Limit-LogText ([string]$Donation.source) 40))
    $Values.Add((Limit-LogText ([string]$Donation.externalId) 200))
    $Values.Add((Limit-LogText ([string]$Donation.message) 1000))
    $ActiveEntries = @(Get-ActiveEntriesForLlmIntent $InputData.entries)
    $Values.Add([string]$ActiveEntries.Count)
    foreach ($Entry in $ActiveEntries) {
        $Values.Add([string]$Entry.id)
        $Values.Add([string]$Entry.name)
        $Values.Add([string]$Entry.category)
        $Values.Add([string]$Entry.source)
        $Values.Add([string]$Entry.externalId)
    }
    $Canonical = ($Values | ForEach-Object { "$($_.Length):$_" }) -join '|'
    [uint64]$Hash = 2166136261
    foreach ($Character in $Canonical.ToCharArray()) {
        [uint64]$Mixed = $Hash -bxor [uint64][int][char]$Character
        $Hash = ($Mixed * 16777619) % 4294967296
    }
    return ([uint32]$Hash).ToString('x8', [Globalization.CultureInfo]::InvariantCulture)
}

function New-LlmJobId {
    return "llm-job-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
}

function New-LlmJobFromInput {
    param(
        [object]$InputData,
        [string]$AnalysisKey,
        [long]$Revision,
        [long]$Generation
    )

    $Donation = $InputData.donation
    $Settings = if ($InputData.settings) { $InputData.settings } else { [pscustomobject]@{} }
    $Model = if ($Settings.PSObject.Properties["model"] -and -not [string]::IsNullOrWhiteSpace([string]$Settings.model)) { [string]$Settings.model } else { $script:DefaultLlmModel }
    $AllowSteam = -not $Settings.PSObject.Properties["allowSteam"] -or $Settings.allowSteam -ne $false
    $AllowAnime = -not $Settings.PSObject.Properties["allowAnime"] -or $Settings.allowAnime -ne $false
    $AssignThreshold = if ($Settings.PSObject.Properties["confidenceAssignThreshold"]) { [double]$Settings.confidenceAssignThreshold } else { 0.85 }
    $CreateThreshold = if ($Settings.PSObject.Properties["confidenceCreateThreshold"]) { [double]$Settings.confidenceCreateThreshold } else { 0.92 }
    $Now = (Get-Date).ToUniversalTime().ToString("o")
    return [pscustomobject]@{
        jobId = New-LlmJobId
        analysisKey = $AnalysisKey
        pipelineVersion = [int]$script:LlmPipelineVersion
        generation = $Generation
        source = [string]$Donation.source
        externalId = [string]$Donation.externalId
        status = "queued"
        stage = "waiting"
        attempt = 0
        nextAttemptAt = ""
        revision = $Revision
        createdAt = $Now
        updatedAt = $Now
        startedAt = ""
        finishedAt = ""
        donation = [pscustomobject]@{
            id = Limit-LogText ([string]$Donation.id) 300
            source = Limit-LogText ([string]$Donation.source) 40
            externalId = Limit-LogText ([string]$Donation.externalId) 200
            username = Limit-LogText ([string]$Donation.username) 200
            amount = [double]$Donation.amount
            currency = Limit-LogText ([string]$Donation.currency) 20
            message = Limit-LogText ([string]$Donation.message) 1000
        }
        entriesSnapshot = @(Get-SafeEntriesForLlm $InputData.entries)
        settings = [pscustomobject]@{
            model = Limit-LogText $Model 200
            allowSteam = $AllowSteam
            allowAnime = $AllowAnime
            confidenceAssignThreshold = $AssignThreshold
            confidenceCreateThreshold = $CreateThreshold
        }
        result = $null
        error = ""
        errorCode = ""
    }
}

function Add-OrGet-LlmJob {
    param([object]$InputData)

    if (-not $InputData) {
        return [pscustomobject]@{ ok = $false; error = "Missing job data."; status = 400 }
    }
    $RequestedPipelineVersion = 0
    if ($InputData.PSObject.Properties['pipelineVersion']) {
        try { $RequestedPipelineVersion = [int]$InputData.pipelineVersion } catch { $RequestedPipelineVersion = 0 }
    }
    if ($RequestedPipelineVersion -ne [int]$script:LlmPipelineVersion) {
        return [pscustomobject]@{
            ok = $false
            error = "AI pipeline version is stale. Reload the application."
            code = "LLM_PIPELINE_VERSION_MISMATCH"
            status = 409
            pipelineVersion = [int]$script:LlmPipelineVersion
        }
    }
    $AnalysisKey = Get-LlmAnalysisKey $InputData
    if ([string]::IsNullOrWhiteSpace($AnalysisKey)) {
        return [pscustomobject]@{ ok = $false; error = "Invalid analysisKey or donation identity."; status = 400 }
    }
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Generation = [long]$Store.auctionGeneration
        $RequestedGeneration = 0L
        if ($InputData.PSObject.Properties['auctionGeneration']) {
            try { $RequestedGeneration = [long]$InputData.auctionGeneration } catch { $RequestedGeneration = 0L }
        }
        if ($RequestedGeneration -ne $Generation) {
            return [pscustomobject]@{
                ok = $false
                error = "Auction generation is stale. Resynchronize the admin tab."
                code = "AUCTION_GENERATION_MISMATCH"
                status = 409
                currentAuctionGeneration = $Generation
            }
        }
        $Existing = @($Store.jobs | Where-Object {
            [string]$_.analysisKey -eq $AnalysisKey -and
            [long]$_.generation -eq $Generation -and
            [int]$_.pipelineVersion -eq [int]$script:LlmPipelineVersion
        } | Sort-Object createdAt -Descending | Select-Object -First 1)
        if ($Existing.Count -gt 0) {
            $Job = $Existing[0]
            $Force = $InputData.PSObject.Properties["force"] -and [bool]$InputData.force
            if ($Force -and @("done", "error", "cancelled") -contains [string]$Job.status) {
                $Revision = Get-NextLlmRevision $Store
                $Now = (Get-Date).ToUniversalTime().ToString("o")
                $Job.status = "queued"
                $Job.stage = "waiting"
                $Job.attempt = 0
                $Job.nextAttemptAt = ""
                $Job.revision = $Revision
                $Job.updatedAt = $Now
                $Job.startedAt = ""
                $Job.finishedAt = ""
                $Job.result = $null
                $Job.error = ""
                $Job.errorCode = ""
                $Template = New-LlmJobFromInput $InputData $AnalysisKey $Revision $Generation
                $Job.donation = $Template.donation
                $Job.entriesSnapshot = @($Template.entriesSnapshot)
                $Job.settings = $Template.settings
                $Job.pipelineVersion = [int]$script:LlmPipelineVersion
                [void](Write-LlmJobsStoreOrThrow $Store)
                return [pscustomobject]@{ ok = $true; jobId = [string]$Job.jobId; analysisKey = $AnalysisKey; pipelineVersion = [int]$script:LlmPipelineVersion; status = "queued"; revision = $Revision; generation = $Generation; auctionGeneration = $Generation; existing = $true }
            }
            return [pscustomobject]@{ ok = $true; jobId = [string]$Job.jobId; analysisKey = $AnalysisKey; pipelineVersion = [int]$script:LlmPipelineVersion; status = [string]$Job.status; stage = [string]$Job.stage; revision = [long]$Store.revision; generation = $Generation; auctionGeneration = $Generation; existing = $true }
        }

        $Revision = Get-NextLlmRevision $Store
        $Job = New-LlmJobFromInput $InputData $AnalysisKey $Revision $Generation
        $Store.jobs = @($Store.jobs) + @($Job)
        [void](Write-LlmJobsStoreOrThrow $Store)
        return [pscustomobject]@{ ok = $true; jobId = [string]$Job.jobId; analysisKey = $AnalysisKey; pipelineVersion = [int]$script:LlmPipelineVersion; status = "queued"; stage = "waiting"; revision = $Revision; generation = $Generation; auctionGeneration = $Generation; existing = $false }
    }
    finally {
        Exit-NamedMutex $Mutex
    }
}

function Get-LlmJobsSummary {
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Generation = [long]$Store.auctionGeneration
        $Jobs = @($Store.jobs | Where-Object {
            [long]$_.generation -eq $Generation -and
            [int]$_.pipelineVersion -eq [int]$script:LlmPipelineVersion
        })
        return [pscustomobject]@{
            pipelineVersion = [int]$script:LlmPipelineVersion
            revision = [long]$Store.revision
            auctionGeneration = $Generation
            queued = @($Jobs | Where-Object { $_.status -eq "queued" }).Count
            running = @($Jobs | Where-Object { $_.status -eq "running" }).Count
            retryWaiting = @($Jobs | Where-Object { $_.status -eq "retry_wait" }).Count
            done = @($Jobs | Where-Object { $_.status -eq "done" }).Count
            errors = @($Jobs | Where-Object { $_.status -eq "error" }).Count
            resultsAvailable = @($Jobs | Where-Object { @("done", "error") -contains [string]$_.status }).Count -gt 0
        }
    }
    finally { Exit-NamedMutex $Mutex }
}

function Test-LlmGenerationCurrent {
    param([long]$Generation)

    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        return [long]$Store.auctionGeneration -eq $Generation
    }
    finally { Exit-NamedMutex $Mutex }
}

function Test-LlmJobGenerationCurrent {
    param(
        [string]$JobId,
        [long]$Generation
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) { return $false }
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        if ([long]$Store.auctionGeneration -ne $Generation) { return $false }
        return @($Store.jobs | Where-Object {
            [string]$_.jobId -eq $JobId -and
            [long]$_.generation -eq $Generation -and
            [int]$_.pipelineVersion -eq [int]$script:LlmPipelineVersion -and
            [string]$_.status -ne "cancelled"
        }).Count -gt 0
    }
    finally { Exit-NamedMutex $Mutex }
}

function Get-LlmJobResults {
    param([object]$InputData)

    if (-not $InputData) { $InputData = [pscustomobject]@{ afterRevision = 0; analysisKeys = @() } }
    $AfterRevision = 0L
    try { $AfterRevision = [long]$InputData.afterRevision } catch {}
    $RawKeys = if ($InputData.PSObject.Properties["analysisKeys"]) { @($InputData.analysisKeys) } else { @() }
    $Keys = @($RawKeys | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        if ($Keys.Count -eq 0) {
            return [pscustomobject]@{ ok = $true; revision = [long]$Store.revision; auctionGeneration = [long]$Store.auctionGeneration; jobs = @() }
        }
        $Jobs = @($Store.jobs | Where-Object {
            [long]$_.generation -eq [long]$Store.auctionGeneration -and
            [int]$_.pipelineVersion -eq [int]$script:LlmPipelineVersion -and
            ($Keys -contains [string]$_.analysisKey) -and
            [long]$_.revision -gt $AfterRevision
        } | ForEach-Object {
            [pscustomobject]@{
                jobId = [string]$_.jobId
                analysisKey = [string]$_.analysisKey
                pipelineVersion = [int]$_.pipelineVersion
                status = [string]$_.status
                stage = [string]$_.stage
                revision = [long]$_.revision
                generation = [long]$_.generation
                nextAttemptAt = [string]$_.nextAttemptAt
                result = $_.result
                error = Limit-LogText ([string]$_.error) 500
                errorCode = [string]$_.errorCode
                finishedAt = [string]$_.finishedAt
            }
        })
        return [pscustomobject]@{ ok = $true; revision = [long]$Store.revision; auctionGeneration = [long]$Store.auctionGeneration; jobs = $Jobs }
    }
    finally { Exit-NamedMutex $Mutex }
}

function Update-LlmJobStage {
    param(
        [string]$JobId,
        [string]$Stage,
        [long]$Generation = 0
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) { return }
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Job = @($Store.jobs | Where-Object {
            [string]$_.jobId -eq $JobId -and
            ($Generation -le 0 -or [long]$_.generation -eq $Generation) -and
            [long]$_.generation -eq [long]$Store.auctionGeneration -and
            [int]$_.pipelineVersion -eq [int]$script:LlmPipelineVersion
        } | Select-Object -First 1)[0]
        if (-not $Job -or [string]$Job.status -ne "running" -or [string]$Job.stage -eq $Stage) { return }
        $Job.stage = $Stage
        $Job.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
        $Job.revision = Get-NextLlmRevision $Store
        [void](Write-LlmJobsStoreOrThrow $Store)
    }
    finally { Exit-NamedMutex $Mutex }
}

function Repair-InterruptedLlmJobs {
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Changed = $false
        foreach ($Job in @($Store.jobs)) {
            if (
                [long]$Job.generation -eq [long]$Store.auctionGeneration -and
                [int]$Job.pipelineVersion -ne [int]$script:LlmPipelineVersion -and
                @('queued', 'running', 'retry_wait') -contains [string]$Job.status
            ) {
                $Job.status = 'cancelled'
                $Job.stage = 'finished'
                $Job.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                $Job.finishedAt = $Job.updatedAt
                $Job.revision = Get-NextLlmRevision $Store
                $Changed = $true
            }
            elseif (
                [long]$Job.generation -eq [long]$Store.auctionGeneration -and
                [int]$Job.pipelineVersion -eq [int]$script:LlmPipelineVersion -and
                [string]$Job.status -eq "running"
            ) {
                $Job.status = "queued"
                $Job.stage = "waiting"
                $Job.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
                $Job.revision = Get-NextLlmRevision $Store
                $Changed = $true
            }
        }
        if ($Changed) { [void](Write-LlmJobsStoreOrThrow $Store) }
    }
    finally { Exit-NamedMutex $Mutex }
}

function Take-NextLlmJob {
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Now = (Get-Date).ToUniversalTime()
        $Ready = @($Store.jobs | Where-Object {
            if ([long]$_.generation -ne [long]$Store.auctionGeneration) { return $false }
            if ([int]$_.pipelineVersion -ne [int]$script:LlmPipelineVersion) { return $false }
            if ([string]$_.status -eq "queued") { return $true }
            if ([string]$_.status -ne "retry_wait") { return $false }
            if ([string]::IsNullOrWhiteSpace([string]$_.nextAttemptAt)) { return $true }
            try { return [DateTimeOffset]::Parse([string]$_.nextAttemptAt).UtcDateTime -le $Now } catch { return $true }
        } | Sort-Object createdAt | Select-Object -First 1)
        if ($Ready.Count -eq 0) { return $null }
        $Job = $Ready[0]
        $Revision = Get-NextLlmRevision $Store
        $Job.status = "running"
        $Job.stage = "analyzing_intent"
        $Job.attempt = [int]$Job.attempt + 1
        $Job.nextAttemptAt = ""
        $Job.startedAt = (Get-Date).ToUniversalTime().ToString("o")
        $Job.updatedAt = $Job.startedAt
        $Job.revision = $Revision
        [void](Write-LlmJobsStoreOrThrow $Store)
        return ($Job | ConvertTo-Json -Depth 35 | ConvertFrom-Json)
    }
    finally { Exit-NamedMutex $Mutex }
}

function Get-LlmExceptionCode {
    param([AllowNull()][System.Exception]$Exception)

    $Current = $Exception
    while ($Current) {
        try {
            $Code = [string]$Current.Data['LlmErrorCode']
            if (-not [string]::IsNullOrWhiteSpace($Code)) { return $Code }
        } catch {}
        $Current = $Current.InnerException
    }
    return ""
}

function Test-LlmTransientNetworkException {
    param([AllowNull()][System.Exception]$Exception)

    $Current = $Exception
    while ($Current) {
        $TypeName = $Current.GetType().FullName
        if ($TypeName -eq 'System.Net.Http.HttpRequestException') {
            # HttpClient also uses HttpRequestException for non-2xx responses
            # created above. A response with a real status is not a transport
            # failure and must be classified by that status instead.
            if ((Get-LlmHttpStatusCode $Current) -le 0) { return $true }
        }
        elseif ($TypeName -in @(
            'System.TimeoutException',
            'System.Net.Sockets.SocketException',
            'System.Threading.Tasks.TaskCanceledException'
        )) { return $true }
        if ($Current -is [System.Net.WebException]) {
            if ($Current.Status -in @(
                [System.Net.WebExceptionStatus]::ConnectFailure,
                [System.Net.WebExceptionStatus]::NameResolutionFailure,
                [System.Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                [System.Net.WebExceptionStatus]::Timeout,
                [System.Net.WebExceptionStatus]::ReceiveFailure,
                [System.Net.WebExceptionStatus]::SendFailure,
                [System.Net.WebExceptionStatus]::ConnectionClosed,
                [System.Net.WebExceptionStatus]::KeepAliveFailure
            )) { return $true }
        }
        $Current = $Current.InnerException
    }
    return $false
}

function Get-LlmFailureClassification {
    param(
        [AllowNull()][System.Exception]$Exception,
        [string]$Message,
        [int]$StatusCode,
        [int]$Attempt,
        [int]$RetryAfter = 0
    )

    $InternalCode = Get-LlmExceptionCode $Exception
    $Lower = ([string]$Message).ToLowerInvariant()
    $Code = $InternalCode
    $RetryableType = $false

    if ([string]::IsNullOrWhiteSpace($Code)) {
        if ($StatusCode -eq 429 -or $Lower.Contains('too many requests')) {
            $Code = 'OPENROUTER_RATE_LIMIT'
            $RetryableType = $true
        }
        elseif ($StatusCode -in @(500, 502, 503, 504)) {
            $Code = 'OPENROUTER_UPSTREAM_ERROR'
            $RetryableType = $true
        }
        elseif ($StatusCode -in @(401, 403)) { $Code = 'OPENROUTER_AUTH_ERROR' }
        elseif ($StatusCode -eq 404 -or $Lower.Contains('invalid model') -or $Lower.Contains('model not found')) { $Code = 'OPENROUTER_INVALID_MODEL' }
        elseif ($Lower.Contains('json schema') -or $Lower.Contains('structured output')) { $Code = 'LLM_SCHEMA_VALIDATION_ERROR' }
        elseif ($StatusCode -eq 400) { $Code = 'OPENROUTER_BAD_REQUEST' }
        elseif ($Lower.Contains('timed out') -or $Lower.Contains('timeout')) {
            $Code = 'OPENROUTER_TIMEOUT'
            $RetryableType = $true
        }
        elseif (Test-LlmTransientNetworkException $Exception) {
            $Code = 'OPENROUTER_TRANSIENT_NETWORK'
            $RetryableType = $true
        }
        else { $Code = 'PIPELINE_ERROR' }
    }
    elseif ($Code -in @('OPENROUTER_RATE_LIMIT', 'OPENROUTER_TIMEOUT', 'OPENROUTER_TRANSIENT_NETWORK', 'OPENROUTER_UPSTREAM_ERROR')) {
        $RetryableType = $true
    }

    $StructuredResponseRetry = -not [string]::IsNullOrWhiteSpace($InternalCode) -and $Code -in @(
        'LLM_RESPONSE_PARSE_ERROR',
        'LLM_RESPONSE_CONTENT_MISSING',
        'LLM_SCHEMA_VALIDATION_ERROR'
    )
    if ($StructuredResponseRetry) { $RetryableType = $true }

    $CanRetry = if ($Code -eq 'OPENROUTER_RATE_LIMIT') {
        $Attempt -le 3
    } elseif ($StructuredResponseRetry) {
        # Structured providers occasionally stop with an empty/truncated body.
        # One automatic retry hides that transient failure without creating a loop.
        $Attempt -le 1
    } else {
        $RetryableType -and $Attempt -le 2
    }
    $Backoffs = @(2, 5, 15)
    $DelaySec = if ($RetryAfter -gt 0) {
        $RetryAfter
    } else {
        $Backoffs[[Math]::Min($Backoffs.Count - 1, [Math]::Max(0, $Attempt - 1))]
    }
    return [pscustomobject]@{
        code = $Code
        retry = $CanRetry
        delaySec = $DelaySec
        statusCode = $StatusCode
    }
}

function Get-LlmFailureInfo {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord, [int]$Attempt)

    $Message = Get-MaskedText $ErrorRecord.Exception.Message
    $StatusCode = Get-LlmHttpStatusCode $ErrorRecord.Exception
    $RetryAfter = Get-LlmRetryAfterSeconds $ErrorRecord.Exception
    if ($RetryAfter -le 0) {
        try {
            $RetryHeader = [string]$ErrorRecord.Exception.Response.Headers["Retry-After"]
            if (-not [int]::TryParse($RetryHeader, [ref]$RetryAfter) -and -not [string]::IsNullOrWhiteSpace($RetryHeader)) {
                try {
                    $RetryAt = [DateTimeOffset]::Parse($RetryHeader)
                    $RetryAfter = [Math]::Max(1, [int][Math]::Ceiling(($RetryAt - [DateTimeOffset]::UtcNow).TotalSeconds))
                } catch {}
            }
        } catch {}
    }
    $Classification = Get-LlmFailureClassification $ErrorRecord.Exception $Message $StatusCode $Attempt $RetryAfter
    $Diagnostics = Limit-LogText (Get-MaskedText ([string](Get-LlmExceptionDataValue $ErrorRecord.Exception 'LlmSafeDiagnostics'))) 1000
    return [pscustomobject]@{
        message = Limit-LogText $Message 500
        code = [string]$Classification.code
        retry = [bool]$Classification.retry
        delaySec = [int]$Classification.delaySec
        statusCode = $StatusCode
        diagnostics = $Diagnostics
    }
}

function Complete-LlmJob {
    param(
        [string]$JobId,
        [long]$Generation,
        [object]$Result
    )

    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Job = @($Store.jobs | Where-Object {
            [string]$_.jobId -eq $JobId -and
            [long]$_.generation -eq $Generation -and
            [int]$_.pipelineVersion -eq [int]$script:LlmPipelineVersion
        } | Select-Object -First 1)[0]
        if (-not $Job -or [long]$Store.auctionGeneration -ne $Generation -or [string]$Job.status -eq "cancelled") { return }
        $Now = (Get-Date).ToUniversalTime().ToString("o")
        $Job.status = "done"
        $Job.stage = "finished"
        $Job.result = $Result
        $Job.error = ""
        $Job.errorCode = ""
        $Job.finishedAt = $Now
        $Job.updatedAt = $Now
        $Job.revision = Get-NextLlmRevision $Store
        [void](Write-LlmJobsStoreOrThrow $Store)
    }
    finally { Exit-NamedMutex $Mutex }
}

function Fail-OrRetryLlmJob {
    param(
        [string]$JobId,
        [long]$Generation,
        [object]$Failure
    )

    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Job = @($Store.jobs | Where-Object {
            [string]$_.jobId -eq $JobId -and
            [long]$_.generation -eq $Generation -and
            [int]$_.pipelineVersion -eq [int]$script:LlmPipelineVersion
        } | Select-Object -First 1)[0]
        if (-not $Job -or [long]$Store.auctionGeneration -ne $Generation -or [string]$Job.status -eq "cancelled") { return }
        $Now = (Get-Date).ToUniversalTime()
        if ([bool]$Failure.retry) {
            $Job.status = "retry_wait"
            $Job.stage = "waiting"
            $Job.nextAttemptAt = $Now.AddSeconds([int]$Failure.delaySec).ToString("o")
            $Job.finishedAt = ""
        }
        else {
            $Job.status = "error"
            $Job.stage = "finished"
            $Job.nextAttemptAt = ""
            $Job.finishedAt = $Now.ToString("o")
        }
        $Job.error = Limit-LogText ([string]$Failure.message) 500
        $Job.errorCode = [string]$Failure.code
        $Job.updatedAt = $Now.ToString("o")
        $Job.revision = Get-NextLlmRevision $Store
        [void](Write-LlmJobsStoreOrThrow $Store)
    }
    finally { Exit-NamedMutex $Mutex }
}

function Clear-LlmJobs {
    param([object]$InputData)

    if (-not $InputData) { $InputData = [pscustomobject]@{ analysisKeys = @(); all = $false } }
    $RawKeys = if ($InputData.PSObject.Properties["analysisKeys"]) { @($InputData.analysisKeys) } else { @() }
    $Keys = @($RawKeys | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    $ClearAll = $InputData.PSObject.Properties["all"] -and [bool]$InputData.all
    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $Before = @($Store.jobs).Count
        if ($ClearAll) { $Store.jobs = @() }
        elseif ($Keys.Count -gt 0) { $Store.jobs = @($Store.jobs | Where-Object { $Keys -notcontains [string]$_.analysisKey }) }
        $Removed = $Before - @($Store.jobs).Count
        if ($Removed -gt 0) {
            [void](Get-NextLlmRevision $Store)
            [void](Write-LlmJobsStoreOrThrow $Store)
        }
        return [pscustomobject]@{ ok = $true; removed = $Removed; revision = [long]$Store.revision; auctionGeneration = [long]$Store.auctionGeneration }
    }
    finally { Exit-NamedMutex $Mutex }
}

function Clear-LlmSearchCaches {
    $Cleared = $true
    $Mutex = Enter-NamedMutex $script:CacheMutexName
    try {
        foreach ($Path in @($script:SteamSearchCachePath, $script:AnimeSearchCachePath)) {
            try {
                if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
            }
            catch {
                $Cleared = $false
                Write-AppLog -Level "WARN" -Message "Search cache clear failed: $Path $($_.Exception.Message)"
            }
        }
    }
    finally { Exit-NamedMutex $Mutex }
    return $Cleared
}

function Clear-LlmAuctionData {
    param([AllowNull()][object]$InputData)

    $Mutex = Enter-NamedMutex $script:LlmJobsMutexName
    try {
        $Store = Read-LlmJobsStoreUnsafe
        $RemovedJobs = @($Store.jobs).Count
        $Store.auctionGeneration = [long]$Store.auctionGeneration + 1
        $Store.jobs = @()
        $Revision = Get-NextLlmRevision $Store
        if (-not (Write-LlmJobsStoreUnsafe $Store)) {
            throw "Failed to persist the new auction generation."
        }
        $Generation = [long]$Store.auctionGeneration
    }
    finally { Exit-NamedMutex $Mutex }

    $CacheCleared = Clear-LlmSearchCaches
    $DonatePayCursor = 0L
    $ClearStartedAt = ""
    try {
        if ($InputData -and $InputData.PSObject.Properties['donatePayCursor']) {
            $DonatePayCursor = [long]$InputData.donatePayCursor
        }
        if ($InputData -and $InputData.PSObject.Properties['clearStartedAt']) {
            $ClearStartedAt = [string]$InputData.clearStartedAt
        }
    } catch { $DonatePayCursor = 0L }
    $CollectorResult = Clear-CollectorPendingDonations $DonatePayCursor $ClearStartedAt
    return [pscustomobject]@{
        ok = $true
        auctionGeneration = $Generation
        revision = $Revision
        removedJobs = $RemovedJobs
        cacheCleared = [bool]$CacheCleared
        clearedCollectorDonations = [int]$CollectorResult.removed
        preservedCollectorDonations = [int]$CollectorResult.pending
        releasedDonatePayKeys = [int]$CollectorResult.releasedDonatePayKeys
    }
}

function Reset-AllApplicationData {
    $RestartLlmWorker = $null -ne $script:LlmWorkerHandle
    if ($RestartLlmWorker) {
        Stop-LlmWorkerRunspace $script:LlmWorkerHandle
        $script:LlmWorkerHandle = $null
    }
    Stop-DonationAlertsPollRunspace $script:DonationAlertsPollHandle
    $script:DonationAlertsPollHandle = $null
    Stop-DonatePayRecoveryRunspace $script:DonatePayRecoveryHandle
    $script:DonatePayRecoveryHandle = $null
    $script:DonatePayRecoveryCompleted = $null
    try {
        Stop-CollectorRuntime -SkipPersistence
        Clear-CollectorDonations -SkipPersistence | Out-Null
        [System.Threading.Monitor]::Enter($script:StateLock)
        try {
            $script:ServerState.SessionStartedAt = (Get-Date).ToUniversalTime().ToString("o")
            $DP = $script:ServerState.Integrations.DonatePay
            $DP.Region = "ru"
            $DP.UserId = ""
            $DP.LastEventAt = ""
            $DA = $script:ServerState.Integrations.DonationAlerts
            $DA.AppId = ""
            $DA.TokenType = "Bearer"
            $DA.UserId = ""
            $DA.UserCurrency = ""
            $DA.LastEventAt = ""
        }
        finally { [System.Threading.Monitor]::Exit($script:StateLock) }

        $JobsMutex = Enter-NamedMutex $script:LlmJobsMutexName
        try {
            if ([System.IO.File]::Exists($script:LlmJobsPath)) {
                [System.IO.File]::Delete($script:LlmJobsPath)
            }
        }
        finally { Exit-NamedMutex $JobsMutex }

        $CacheMutex = Enter-NamedMutex $script:CacheMutexName
        try {
            if ([System.IO.Directory]::Exists($script:CacheDir)) {
                [System.IO.Directory]::Delete($script:CacheDir, $true)
            }
        }
        finally { Exit-NamedMutex $CacheMutex }

        if ([System.IO.File]::Exists($script:SecretsPath)) {
            [System.IO.File]::Delete($script:SecretsPath)
        }
        if ([System.IO.File]::Exists($LogPath)) {
            [System.IO.File]::WriteAllText($LogPath, "", [System.Text.UTF8Encoding]::new($true))
        }

        # Publish the durable marker only after every required cleanup step has
        # succeeded. Clients may then treat a new epoch as a completed reset.
        $ResetEpoch = Set-NewAppResetEpoch
        return [pscustomobject]@{ ok = $true; reset = $true; resetEpoch = $ResetEpoch }
    }
    finally {
        if ($RestartLlmWorker -and $null -eq $script:LlmWorkerHandle) {
            try {
                $script:LlmWorkerHandle = Start-LlmWorkerRunspace
            }
            catch {
                Write-AppLog -Level "ERROR" -Message "AI worker restart after full reset failed: $($_.Exception.Message)"
            }
        }
    }
}

function Start-LlmWorkerLoop {
    try { Repair-InterruptedLlmJobs } catch { Write-AppLog -Level "ERROR" -Message "AI job recovery failed: $($_.Exception.Message)" }
    Write-AppLog -Level "INFO" -Message "AI worker started"
    while (-not (Test-ServerStopRequested)) {
        try {
            $Job = Take-NextLlmJob
        }
        catch {
            Write-AppLog -Level "ERROR" -Message "AI worker queue read failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 1
            continue
        }
        if (-not $Job) {
            Start-Sleep -Milliseconds 500
            continue
        }
        try {
            $InputData = [pscustomobject]@{
                jobId = [string]$Job.jobId
                generation = [long]$Job.generation
                donation = $Job.donation
                entries = @($Job.entriesSnapshot)
                settings = $Job.settings
            }
            $Pipeline = Invoke-LlmDonationPipeline $InputData
            if (-not $Pipeline -or $Pipeline.ok -ne $true -or -not $Pipeline.result) {
                Throw-LlmError "PIPELINE_RESULT_INVALID" "AI pipeline returned an invalid result."
            }
            Complete-LlmJob ([string]$Job.jobId) ([long]$Job.generation) $Pipeline.result
        }
        catch {
            $Failure = Get-LlmFailureInfo $_ ([int]$Job.attempt)
            if (Test-LlmJobGenerationCurrent ([string]$Job.jobId) ([long]$Job.generation)) {
                Write-AppLog -Level "WARN" -Message "AI job $([string]$Job.analysisKey) failed (attempt $([int]$Job.attempt), code $([string]$Failure.code), status $([int]$Failure.statusCode)): $([string]$Failure.message)"
                if (-not [string]::IsNullOrWhiteSpace([string]$Failure.diagnostics)) {
                    Write-AppLog -Level "WARN" -Message "AI parse diagnostics: $([string]$Failure.diagnostics)"
                }
                try {
                    Fail-OrRetryLlmJob ([string]$Job.jobId) ([long]$Job.generation) $Failure
                }
                catch {
                    Write-AppLog -Level "ERROR" -Message "AI job failure state could not be saved: $($_.Exception.Message)"
                }
            }
        }
        finally {
            Start-Sleep -Seconds 1
        }
    }
    Write-AppLog -Level "INFO" -Message "AI worker stopped"
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
    $FailureTypes = [System.Collections.Generic.List[string]]::new()
    $WebExceptionStatus = ""

    $CurrentError = $Error
    while ($CurrentError) {
        $FailureTypes.Add($CurrentError.GetType().FullName)
        if ([string]::IsNullOrWhiteSpace($WebExceptionStatus) -and $CurrentError -is [System.Net.WebException]) {
            $WebExceptionStatus = [string]$CurrentError.Status
        }
        $CurrentError = $CurrentError.InnerException
    }

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
        failureType = Limit-LogText ($FailureTypes -join ',') 500
        webExceptionStatus = Limit-LogText $WebExceptionStatus 80
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
    $LogUpstreamBody = -not ([string]$Service).StartsWith('DonationAlerts', [StringComparison]::OrdinalIgnoreCase)

    if ($ErrorData.endpoint) { Write-Host "  endpoint: $SafeEndpoint" -ForegroundColor Yellow }
    if ($ErrorData.upstreamStatus) { Write-Host "  upstream status: $($ErrorData.upstreamStatus)" -ForegroundColor Yellow }
    if ($ErrorData.upstreamUrl) { Write-Host "  upstream url: $SafeUrl" -ForegroundColor Yellow }
    if ($LogUpstreamBody -and $ErrorData.upstreamBody) { Write-Host "  upstream body: $SafeBody" -ForegroundColor Yellow }
    if ($ErrorData.exceptionMessage) { Write-Host "  exception: $SafeException" -ForegroundColor Yellow }
    if ($ErrorData.endpoint) { Write-AppLog -Level "ERROR" -Message "  endpoint: $SafeEndpoint" }
    if ($ErrorData.upstreamStatus) { Write-AppLog -Level "ERROR" -Message "  upstream status: $($ErrorData.upstreamStatus)" }
    if ($ErrorData.upstreamUrl) { Write-AppLog -Level "ERROR" -Message "  upstream url: $SafeUrl" }
    if ($LogUpstreamBody -and $ErrorData.upstreamBody) { Write-AppLog -Level "ERROR" -Message "  upstream body: $SafeBody" }
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
        $AccessToken = Get-DonatePayStoredToken
    }
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        return [pscustomobject]@{
            ok = $false
            endpoint = $LocalEndpoint
            method = "GET"
            upstreamUrl = ""
            upstreamStatus = $null
            upstreamBody = ""
            error = "DonatePay access token is not configured."
            status = 401
        }
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

function Invoke-DonatePaySocketToken {
    param([object]$InputData)

    $Region = if ([string]$InputData.region -eq "eu") { "eu" } else { "ru" }
    $AccessToken = [string]$InputData.access_token
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        $AccessToken = Get-DonatePayStoredToken
    }
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        return [pscustomobject]@{
            ok = $false
            endpoint = "/api/dp/socket-token"
            method = "POST"
            upstreamUrl = ""
            upstreamStatus = $null
            upstreamBody = ""
            error = "DonatePay access token is not configured."
            status = 401
        }
    }

    $HostName = Get-DonatePayHost $Region
    $Url = "https://$HostName/api/v2/socket/token"
    try {
        return Invoke-RestMethod `
            -Uri $Url `
            -Method Post `
            -Headers @{ Accept = "application/json" } `
            -ContentType "application/json" `
            -Body (@{ access_token = $AccessToken } | ConvertTo-Json -Compress) `
            -TimeoutSec 30
    }
    catch {
        $Friendly = Get-FriendlyDonatePayProxyError $_.Exception
        return New-UpstreamError $Friendly "/api/dp/socket-token" "POST" $Url $_.Exception
    }
}

function Invoke-DonatePaySubscribe {
    param([object]$InputData)

    $Region = if ([string]$InputData.region -eq "eu") { "eu" } else { "ru" }
    $AccessToken = Get-DonatePayStoredToken
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        return [pscustomobject]@{
            ok = $false
            endpoint = "/centrifuge/subscribe"
            method = "POST"
            upstreamUrl = ""
            upstreamStatus = $null
            upstreamBody = ""
            error = "DonatePay access token is not configured."
            status = 401
        }
    }

    $Payload = @{}
    if ($InputData) {
        foreach ($Property in $InputData.PSObject.Properties) {
            if ($Property.Name -ne "access_token") {
                $Payload[$Property.Name] = $Property.Value
            }
        }
    }
    $Payload["access_token"] = $AccessToken

    $HostName = Get-DonatePayHost $Region
    $Url = "https://$HostName/api/v2/socket/token"
    try {
        return Invoke-RestMethod `
            -Uri $Url `
            -Method Post `
            -Headers @{ Accept = "application/json" } `
            -ContentType "application/json" `
            -Body ($Payload | ConvertTo-Json -Depth 20 -Compress) `
            -TimeoutSec 30
    }
    catch {
        $Friendly = Get-FriendlyDonatePayProxyError $_.Exception
        return New-UpstreamError $Friendly "/centrifuge/subscribe" "POST" $Url $_.Exception
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

function Test-DonationAlertsPollPayloadValid {
    param([AllowNull()][object]$Payload)

    if ($null -eq $Payload) { return $false }
    if ($Payload -is [System.Array]) { return $true }
    return $null -ne $Payload.PSObject.Properties['data']
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
    param(
        [hashtable]$Donation,
        [switch]$DeferPersistence
    )

    $Source = [string]$Donation.source
    $ExternalId = [string]$Donation.externalId
    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($ExternalId)) {
        return $false
    }

    $Key = Get-DonationKey $Source $ExternalId
    $Amount = Get-DonationAmountValue $Donation.amount
    $ConversionUnavailable = (
        $Source -eq "donationalerts" -and
        [string]$Donation.conversionStatus -eq "unavailable" -and
        (Convert-CurrencyDecimal $Donation.originalAmount) -gt 0
    )
    $DateValid = $false
    try {
        [void][DateTimeOffset]::Parse([string]$Donation.createdAt)
        $DateValid = $true
    } catch {}

    $Changed = $false
    $Added = $false
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        if ($script:ServerState.SeenDonationKeys.ContainsKey($Key)) {
            return $false
        }
        $script:ServerState.SeenDonationKeys[$Key] = $true
        $Changed = $true
        if ([double]::IsNaN($Amount) -or ($Amount -le 0 -and -not $ConversionUnavailable) -or -not $DateValid) {
            Write-Host "[Collector] invalid donation skipped: $Key" -ForegroundColor Yellow
            Write-AppLog -Level "WARN" -Message "[Collector] invalid donation skipped: $Key"
        }
        else {
            $Donation.serverQueuedAt = (Get-Date).ToUniversalTime().ToString("o")
            [void]$script:ServerState.DonationsPending.Add([pscustomobject]$Donation)
            $Added = $true
            Write-Host "[Collector] pending donations: $($script:ServerState.DonationsPending.Count)" -ForegroundColor DarkCyan
            Write-AppLog -Level "INFO" -Message "[Collector] pending donations: $($script:ServerState.DonationsPending.Count)"
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    if ($Changed -and -not $DeferPersistence) { [void](Save-CollectorState) }
    return $Added
}

function Test-ServerDonationKnown {
    param(
        [string]$Source,
        [object]$ExternalId
    )

    $Key = Get-DonationKey $Source $ExternalId
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        if ($script:ServerState.SeenDonationKeys.ContainsKey($Key)) { return $true }
        return @($script:ServerState.DonationsPending | Where-Object {
            [string]$_.source -eq $Source -and [string]$_.externalId -eq [string]$ExternalId
        } | Select-Object -First 1).Count -gt 0
    }
    finally { [System.Threading.Monitor]::Exit($script:StateLock) }
}

function Get-DonationAlertsProfileCurrency {
    param([AllowNull()][object]$ProfileResponse)

    if (-not $ProfileResponse) { return "" }
    $Value = Get-FirstPresentValue @(
        $ProfileResponse.data.currency,
        $ProfileResponse.data.currency_code,
        $ProfileResponse.data.user_currency,
        $ProfileResponse.currency,
        $ProfileResponse.currency_code,
        $ProfileResponse.user_currency
    )
    $Normalized = Normalize-CurrencyCode $Value
    if ($Normalized -match '^[A-Z]{3}$') { return $Normalized }
    return ""
}

function Get-DonationAlertsUserCurrency {
    param(
        [AllowNull()][object]$Raw,
        [AllowNull()][string]$ProfileCurrency = ""
    )

    $PayloadCurrency = Get-FirstPresentValue @(
        $Raw.user_currency,
        $Raw.user_currency_code,
        $Raw.amount_in_user_currency_currency,
        $Raw.currency_in_user_currency,
        $Raw.data.user_currency,
        $Raw.data.user_currency_code
    )
    $Normalized = Normalize-CurrencyCode $PayloadCurrency
    if (-not [string]::IsNullOrWhiteSpace($Normalized)) { return $Normalized }
    return Normalize-CurrencyCode $ProfileCurrency
}

function Convert-DonationAlertsRow {
    param(
        [object]$Raw,
        [AllowNull()][object]$RateSnapshot = $script:CurrencyRateSnapshot,
        [AllowNull()][string]$ProfileCurrency = ""
    )

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
    $OriginalAmount = $Raw.amount
    if ((Convert-CurrencyDecimal $OriginalAmount) -le 0) { $OriginalAmount = $Raw.sum }
    if ($null -eq $OriginalAmount) { $OriginalAmount = 0 }
    $OriginalCurrency = Get-FirstPresentValue @($Raw.currency, $Raw.currency_code, "")
    $AmountInUserCurrency = Get-FirstPresentValue @($Raw.amount_in_user_currency, 0)
    if ([string]::IsNullOrWhiteSpace($ProfileCurrency)) {
        try { $ProfileCurrency = [string]$script:ServerState.Integrations.DonationAlerts.UserCurrency } catch { $ProfileCurrency = "" }
    }
    $UserCurrency = Get-DonationAlertsUserCurrency $Raw $ProfileCurrency
    $Conversion = Convert-DonationAlertsAmountToRub `
        -OriginalAmount $OriginalAmount `
        -OriginalCurrency $OriginalCurrency `
        -AmountInUserCurrency $AmountInUserCurrency `
        -UserCurrency $UserCurrency `
        -RateSnapshot $RateSnapshot
    $CreatedRaw = Get-FirstPresentValue @($Raw.created_at, $Raw.createdAt, $Raw.date, $Raw.message.created_at, $Raw.data.created_at)
    $ExternalId = [string]$Raw.id

    return @{
        id = "server-donationalerts-$ExternalId"
        source = "donationalerts"
        externalId = $ExternalId
        username = $Username
        amount = $Conversion.amount
        currency = $Conversion.currency
        originalAmount = $Conversion.originalAmount
        originalCurrency = $Conversion.originalCurrency
        exchangeRate = $Conversion.exchangeRate
        conversionSource = $Conversion.conversionSource
        conversionStatus = $Conversion.conversionStatus
        conversionDate = $Conversion.conversionDate
        rateFetchedAt = $Conversion.rateFetchedAt
        conversionError = $Conversion.conversionError
        message = $Message
        createdAt = Convert-DonationDateToIso $CreatedRaw "donationalerts"
        status = "pending"
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
    }
}

function Initialize-DonationAlertsRuntimeFields {
    param([hashtable]$ServiceState)

    $Defaults = @{
        ConsecutiveFailures = 0
        FirstFailureAt = ""
        LastFailureAt = ""
        LastFailureKind = ""
        LastFailureMessageSafe = ""
        LastSuccessAt = ""
        Degraded = $false
        NextPollAt = ""
        RecoveryLogged = $true
        FailureEscalated = $false
    }
    foreach ($Name in $Defaults.Keys) {
        if (-not $ServiceState.ContainsKey($Name)) { $ServiceState[$Name] = $Defaults[$Name] }
    }
}

function Get-DonationAlertsFailureClassification {
    param([AllowNull()][object]$Result)

    $StatusCode = 0
    try { $StatusCode = [int]$Result.upstreamStatus } catch {}
    $FailureType = ([string]$Result.failureType).ToLowerInvariant()
    $WebStatus = ([string]$Result.webExceptionStatus).ToLowerInvariant()
    $ExceptionText = ([string]$Result.exceptionMessage).ToLowerInvariant()

    if ($StatusCode -in @(401, 403)) {
        return [pscustomobject]@{ kind = 'auth'; transient = $false; auth = $true; statusCode = $StatusCode; safeMessage = 'Требуется переподключение DonationAlerts.' }
    }
    if ($StatusCode -eq 400) {
        return [pscustomobject]@{ kind = 'upstream_contract'; transient = $false; auth = $false; statusCode = $StatusCode; safeMessage = 'DonationAlerts отклонил параметры подключения.' }
    }
    if ($StatusCode -eq 429) {
        return [pscustomobject]@{ kind = 'rate_limit'; transient = $true; auth = $false; statusCode = $StatusCode; safeMessage = 'Временное ограничение DonationAlerts, выполняется повтор.' }
    }
    if ($StatusCode -in @(500, 502, 503, 504)) {
        return [pscustomobject]@{ kind = 'upstream_unavailable'; transient = $true; auth = $false; statusCode = $StatusCode; safeMessage = 'DonationAlerts временно недоступен, выполняется повтор.' }
    }

    $TransportStatuses = @(
        'connectfailure', 'nameresolutionfailure', 'proxynameresolutionfailure',
        'timeout', 'receivefailure', 'sendfailure', 'connectionclosed', 'keepalivefailure'
    )
    $TransportText = @(
        'connection reset', 'connection aborted', 'forcibly closed', 'transport connection',
        'name resolution', 'timed out', 'timeout', 'соединение разорвано',
        'транспортного соединения', 'принудительно разорвано'
    )
    $IsTransport = $StatusCode -le 0 -and (
        $FailureType.Contains('system.io.ioexception') -or
        $FailureType.Contains('system.net.http.httprequestexception') -or
        $FailureType.Contains('system.net.sockets.socketexception') -or
        $FailureType.Contains('system.net.webexception') -or
        $TransportStatuses -contains $WebStatus
    )
    if (-not $IsTransport -and $StatusCode -le 0) {
        foreach ($Fragment in $TransportText) {
            if ($ExceptionText.Contains($Fragment)) { $IsTransport = $true; break }
        }
    }
    if ($IsTransport) {
        $Kind = if ($ExceptionText.Contains('timed out') -or $ExceptionText.Contains('timeout') -or $WebStatus -eq 'timeout') { 'timeout' }
            elseif ($ExceptionText.Contains('name resolution') -or $WebStatus.Contains('nameresolution')) { 'dns_failure' }
            else { 'connection_reset' }
        return [pscustomobject]@{ kind = $Kind; transient = $true; auth = $false; statusCode = $StatusCode; safeMessage = 'Временная ошибка соединения DonationAlerts, выполняется повтор.' }
    }
    return [pscustomobject]@{ kind = 'collector_error'; transient = $false; auth = $false; statusCode = $StatusCode; safeMessage = 'Ошибка ответа DonationAlerts.' }
}

function Get-DonationAlertsBackoffSeconds {
    param([int]$ConsecutiveFailures)

    if ($ConsecutiveFailures -le 1) { return 10 }
    if ($ConsecutiveFailures -eq 2) { return 30 }
    return 60
}

function Set-DonationAlertsFailureState {
    param(
        [hashtable]$ServiceState,
        [object]$Result,
        [AllowNull()][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    Initialize-DonationAlertsRuntimeFields $ServiceState
    $Failure = Get-DonationAlertsFailureClassification $Result
    $NowUtc = $Now.ToUniversalTime()
    $ServiceState.ConsecutiveFailures = [int]$ServiceState.ConsecutiveFailures + 1
    if ([string]::IsNullOrWhiteSpace([string]$ServiceState.FirstFailureAt)) {
        $ServiceState.FirstFailureAt = $NowUtc.ToString('o')
    }
    $ServiceState.LastFailureAt = $NowUtc.ToString('o')
    $ServiceState.LastFailureKind = [string]$Failure.kind
    $ServiceState.LastFailureMessageSafe = [string]$Failure.safeMessage
    $ServiceState.LastError = [string]$Failure.safeMessage
    $ServiceState.RecoveryLogged = $false

    $DelaySec = if ($Failure.transient) { Get-DonationAlertsBackoffSeconds ([int]$ServiceState.ConsecutiveFailures) } else { 300 }
    $NextPoll = $NowUtc.AddSeconds($DelaySec).ToString('o')
    $ServiceState.BackoffUntil = $NextPoll
    $ServiceState.NextPollAt = $NextPoll
    $ServiceState.Degraded = [bool]$Failure.transient
    $ServiceState.Status = if ($Failure.auth) { 'auth_error' } elseif ($Failure.transient) { 'degraded' } else { 'error' }

    if ($Failure.transient) {
        if ([int]$ServiceState.ConsecutiveFailures -eq 1) {
            Write-AppLog -Level 'WARN' -Message "[DonationAlerts] temporary transport failure; retrying kind=$([string]$Failure.kind) attempt=1 nextRetrySec=$DelaySec"
        }
        $OutageSeconds = 0
        try { $OutageSeconds = ($NowUtc - [DateTimeOffset]::Parse([string]$ServiceState.FirstFailureAt)).TotalSeconds } catch {}
        if (-not [bool]$ServiceState.FailureEscalated -and ([int]$ServiceState.ConsecutiveFailures -ge 3 -or $OutageSeconds -ge 120)) {
            $ServiceState.FailureEscalated = $true
            Write-AppLog -Level 'ERROR' -Message "[DonationAlerts] connection remains unavailable kind=$([string]$Failure.kind) attempts=$([int]$ServiceState.ConsecutiveFailures)"
        }
    }
    else {
        Write-AppLog -Level 'ERROR' -Message "[DonationAlerts] terminal collector failure kind=$([string]$Failure.kind) status=$([int]$Failure.statusCode)"
    }
    return $Failure
}

function Clear-DonationAlertsFailureState {
    param(
        [hashtable]$ServiceState,
        [AllowNull()][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    Initialize-DonationAlertsRuntimeFields $ServiceState
    $FailureCount = [int]$ServiceState.ConsecutiveFailures
    if ($FailureCount -gt 0 -and -not [bool]$ServiceState.RecoveryLogged) {
        Write-AppLog -Level 'INFO' -Message "[DonationAlerts] connection recovered after $FailureCount failure(s)."
    }
    Reset-DonationAlertsFailureState $ServiceState
    $ServiceState.LastSuccessAt = $Now.ToUniversalTime().ToString('o')
}

function Reset-DonationAlertsFailureState {
    param([hashtable]$ServiceState)

    Initialize-DonationAlertsRuntimeFields $ServiceState
    $ServiceState.BackoffUntil = $null
    $ServiceState.NextPollAt = ""
    $ServiceState.LastError = ""
    $ServiceState.ConsecutiveFailures = 0
    $ServiceState.FirstFailureAt = ""
    $ServiceState.LastFailureAt = ""
    $ServiceState.LastFailureKind = ""
    $ServiceState.LastFailureMessageSafe = ""
    $ServiceState.LastSuccessAt = ""
    $ServiceState.Degraded = $false
    $ServiceState.RecoveryLogged = $true
    $ServiceState.FailureEscalated = $false
}

function Set-CollectorBackoff {
    param([hashtable]$ServiceState, [object]$Result)
    [void](Set-DonationAlertsFailureState $ServiceState $Result)
}

function Clear-CollectorBackoff {
    param([hashtable]$ServiceState)
    Clear-DonationAlertsFailureState $ServiceState
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


function Apply-DonationAlertsCollectorResult {
    param(
        [AllowNull()][object]$Result,
        [string]$ExpectedSignature,
        [long]$ExpectedRuntimeGeneration = $script:CollectorRuntimeGeneration
    )

    $Service = $script:ServerState.Integrations.DonationAlerts
    if (
        -not $Service.Enabled -or
        $script:CollectorPausedPreserveCursor -or
        $ExpectedRuntimeGeneration -ne $script:CollectorRuntimeGeneration -or
        [string]$Service.Signature -cne [string]$ExpectedSignature
    ) { return $false }

    if ($Result -and $Result.ok -eq $false) {
        [void](Set-DonationAlertsFailureState $Service $Result)
        return $false
    }

    if (-not (Test-DonationAlertsPollPayloadValid $Result)) {
        $ContractFailure = [pscustomobject]@{
            ok = $false
            upstreamStatus = 400
            failureType = 'DONATIONALERTS_UPSTREAM_CONTRACT'
            webExceptionStatus = ''
            exceptionMessage = ''
            error = 'DonationAlerts returned an invalid polling payload.'
        }
        [void](Set-DonationAlertsFailureState $Service $ContractFailure)
        return $false
    }

    $Rows = @(Get-ApiRows $Result)
    $MaxId = Get-LastSeenIdValue $Service
    if (-not $Service.BaselineReady) {
        $PreviousCursor = $Service.LastSeenId
        $PreviousBaselineReady = [bool]$Service.BaselineReady
        foreach ($Row in $Rows) {
            $Id = Get-NumericDonationId $Row.id
            if ($Id -gt $MaxId) { $MaxId = $Id }
        }
        $Service.LastSeenId = $MaxId
        $Service.BaselineReady = $true
        $Service.Status = "connected"
        $Service.LastEventAt = (Get-Date).ToUniversalTime().ToString("o")
        Clear-CollectorBackoff $Service
        if (-not (Save-CollectorState)) {
            $Service.LastSeenId = $PreviousCursor
            $Service.BaselineReady = $PreviousBaselineReady
            return $false
        }
        Write-Host "[DonationAlerts] baseline ready, lastSeenId=$MaxId" -ForegroundColor Green
        Write-AppLog -Level "INFO" -Message "[DonationAlerts] baseline ready, lastSeenId=$MaxId"
        return $true
    }

    $CurrentCursor = Get-LastSeenIdValue $Service
    $NewRows = @($Rows | Sort-Object { Get-NumericDonationId $_.id } | Where-Object {
        (Get-NumericDonationId $_.id) -gt $CurrentCursor
    })
    $Added = 0
    foreach ($Row in $NewRows) {
        $Donation = Convert-DonationAlertsRow $Row
        $Accepted = $false
        if ($Donation) {
            if (Add-ServerDonation $Donation -DeferPersistence) {
                $Added++
                $Accepted = $true
            }
            elseif (Test-ServerDonationKnown 'donationalerts' ([string]$Donation.externalId)) {
                $Accepted = $true
            }
        }
        if ($Accepted) {
            $Id = Get-NumericDonationId $Row.id
            if ($Id -gt $MaxId) { $MaxId = $Id }
        }
    }
    if ($MaxId -gt $CurrentCursor) { $Service.LastSeenId = $MaxId }
    $Service.Status = "connected"
    $Service.LastEventAt = (Get-Date).ToUniversalTime().ToString("o")
    Clear-CollectorBackoff $Service
    if (-not (Save-CollectorState)) {
        $Service.LastSeenId = $CurrentCursor
        return $false
    }
    if ($Added -gt 0) {
        Write-Host "[DonationAlerts] received $($Rows.Count), new $Added" -ForegroundColor DarkCyan
        Write-AppLog -Level "INFO" -Message "[DonationAlerts] received $($Rows.Count), new $Added"
    }
    return $true
}

function Get-DonatePayRecoveryRequestContext {
    param([object]$InputData)
    $After = 0L
    try { $After = [long]$InputData.after } catch {}
    $Limit = 100
    try {
        if ($InputData.limit) {
            $Limit = [Math]::Max(1, [Math]::Min(100, [int]$InputData.limit))
        }
    } catch {}

    return [pscustomobject]@{
        requestId = [string]$InputData.requestId
        region = [string]$InputData.region
        after = $After
        limit = $Limit
        auctionGeneration = [long]$InputData.auctionGeneration
    }
}

function Invoke-DonatePayRecoveryFetch {
    param([object]$InputData)

    $Context = Get-DonatePayRecoveryRequestContext $InputData
    $Payload = @{
        region = [string]$Context.region
        access_token = [string]$InputData.access_token
        limit = [int]$Context.limit
        order = "ASC"
        type = "donation"
    }
    if ([long]$Context.after -gt 0) { $Payload.after = [long]$Context.after }
    return Invoke-DonatePayApi ([string]$Context.region) "/api/v1/notifications" ([pscustomobject]$Payload) "/api/dp/recovery-transactions"
}

function Apply-DonatePayRecoveryResult {
    param(
        [AllowNull()][object]$Result,
        [object]$Context
    )

    $After = [long]$Context.after

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
        if ($Donation -and (Add-ServerDonation $Donation -DeferPersistence)) { $Added++ }
    }

    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DonatePayState = $script:ServerState.Integrations.DonatePay
        if ($MaxId -gt (Get-LastSeenIdValue $DonatePayState)) { $DonatePayState.LastSeenId = $MaxId }
        $DonatePayState.BaselineReady = $true
        $DonatePayState.LastEventAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    finally { [System.Threading.Monitor]::Exit($script:StateLock) }
    [void](Save-CollectorState)

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

function Invoke-CollectorTickIfDue {
    Complete-DonationAlertsPollRunspaceIfReady
    Complete-DonatePayRecoveryRunspaceIfReady
    if ($script:DonationAlertsPollHandle) { return }
    if (-not $script:CollectorEnabled) {
        return
    }

    $Now = Get-Date
    if ($Now -lt $script:NextCollectorTickAt) {
        return
    }

    $script:NextCollectorTickAt = $Now.AddSeconds(5)

    $PollInput = $null
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DA = $script:ServerState.Integrations.DonationAlerts
        $PollDue = $DA.Enabled -and
            -not [string]::IsNullOrWhiteSpace([string]$DA.AccessToken) -and
            -not (Test-CollectorBackoff $DA) -and (
                -not $DA.LastPollAt -or
                ((New-TimeSpan -Start ([DateTimeOffset]::Parse([string]$DA.LastPollAt).DateTime) -End $Now).TotalSeconds -ge [int]$DA.PollingIntervalSec)
            )
        if ($PollDue) {
            $DA.LastPollAt = $Now.ToUniversalTime().ToString("o")
            $PollInput = [pscustomobject]@{
                accessToken = [string]$DA.AccessToken
                signature = [string]$DA.Signature
                runtimeGeneration = [long]$script:CollectorRuntimeGeneration
            }
        }
    }
    finally { [System.Threading.Monitor]::Exit($script:StateLock) }

    if ($PollInput) {
        try { $script:DonationAlertsPollHandle = Start-DonationAlertsPollRunspace $PollInput }
        catch {
            Write-Host "[Collector] poll worker start failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-AppLog -Level "ERROR" -Message "[Collector] poll worker start failed: $($_.Exception.Message)"
        }
    }
}

function Start-DonationAlertsPollRunspace {
    param([object]$PollInput)

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = "MTA"
    $Runspace.Open()
    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Runspace
    [void]$PowerShell.AddCommand($PSCommandPath)
    [void]$PowerShell.AddParameter("Root", $RootPath)
    [void]$PowerShell.AddParameter("ServerOnly", $true)
    [void]$PowerShell.AddParameter("DonationAlertsPollWorkerOnly", $true)
    [void]$PowerShell.AddParameter("DonationAlertsPollInput", $PollInput)
    try {
        $AsyncResult = $PowerShell.BeginInvoke()
        return [pscustomobject]@{
            Runspace = $Runspace
            PowerShell = $PowerShell
            AsyncResult = $AsyncResult
            Signature = [string]$PollInput.signature
            RuntimeGeneration = [long]$PollInput.runtimeGeneration
        }
    }
    catch {
        $PowerShell.Dispose()
        $Runspace.Close()
        $Runspace.Dispose()
        throw
    }
}

function Stop-DonationAlertsPollRunspace {
    param([AllowNull()][object]$Handle)

    if (-not $Handle) { return }
    try {
        if ($Handle.AsyncResult -and -not $Handle.AsyncResult.IsCompleted) { $Handle.PowerShell.Stop() }
        if ($Handle.AsyncResult -and $Handle.AsyncResult.IsCompleted) { [void]$Handle.PowerShell.EndInvoke($Handle.AsyncResult) }
    } catch {}
    try { $Handle.PowerShell.Dispose() } catch {}
    try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch {}
}

function Complete-DonationAlertsPollRunspaceIfReady {
    $Handle = $script:DonationAlertsPollHandle
    if (-not $Handle -or -not $Handle.AsyncResult.IsCompleted) { return }
    $script:DonationAlertsPollHandle = $null
    try {
        $Output = @($Handle.PowerShell.EndInvoke($Handle.AsyncResult))
        $Envelope = @($Output | Where-Object { $_ -and $_.PSObject.Properties['signature'] } | Select-Object -Last 1)[0]
        if ($Envelope) {
            [void](Apply-DonationAlertsCollectorResult `
                $Envelope.result `
                ([string]$Envelope.signature) `
                ([long]$Envelope.runtimeGeneration))
        }
        else { throw "DonationAlerts poll worker returned no result." }
    }
    catch {
        $Failure = New-UpstreamError `
            'DonationAlerts poll worker failed.' `
            '/api/collector/donationalerts' `
            'GET' `
            'https://www.donationalerts.com/api/v1/alerts/donations' `
            $_.Exception
        [void](Apply-DonationAlertsCollectorResult $Failure ([string]$Handle.Signature) ([long]$Handle.RuntimeGeneration))
    }
    finally {
        try { $Handle.PowerShell.Dispose() } catch {}
        try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch {}
    }
}

function Start-DonatePayRecoveryRunspace {
    param([object]$WorkerInput)

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = "MTA"
    $Runspace.Open()
    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Runspace
    [void]$PowerShell.AddCommand($PSCommandPath)
    [void]$PowerShell.AddParameter("Root", $RootPath)
    [void]$PowerShell.AddParameter("ServerOnly", $true)
    [void]$PowerShell.AddParameter("DonatePayRecoveryWorkerOnly", $true)
    [void]$PowerShell.AddParameter("DonatePayRecoveryWorkerInput", $WorkerInput)
    try {
        $AsyncResult = $PowerShell.BeginInvoke()
        return [pscustomobject]@{ Runspace = $Runspace; PowerShell = $PowerShell; AsyncResult = $AsyncResult }
    }
    catch {
        $PowerShell.Dispose()
        $Runspace.Close()
        $Runspace.Dispose()
        throw
    }
}

function Queue-DonatePayRecoveryRequest {
    param([object]$InputData)

    Complete-DonatePayRecoveryRunspaceIfReady
    $Context = Get-DonatePayRecoveryRequestContext $InputData
    $RequestedId = [string]$Context.requestId
    if (
        $script:DonatePayRecoveryCompleted -and
        -not [string]::IsNullOrWhiteSpace($RequestedId) -and
        [string]$script:DonatePayRecoveryCompleted.requestId -ceq $RequestedId
    ) {
        return $script:DonatePayRecoveryCompleted.response
    }
    if ($script:DonatePayRecoveryHandle) {
        $ActiveId = [string]$script:DonatePayRecoveryHandle.RequestId
        if ([string]::IsNullOrWhiteSpace($RequestedId) -or $RequestedId -ceq $ActiveId) {
            return [pscustomobject]@{
                ok = $true
                queued = $true
                inFlight = $true
                requestId = $ActiveId
                lastSeenId = [long]$script:DonatePayRecoveryHandle.After
                auctionGeneration = [long]$script:DonatePayRecoveryHandle.AuctionGeneration
            }
        }
        return [pscustomobject]@{
            ok = $false
            error = "Another DonatePay recovery request is already running."
            code = "DONATEPAY_RECOVERY_IN_PROGRESS"
            status = 409
            requestId = $ActiveId
        }
    }
    $Token = Get-DonatePayStoredToken
    if ([string]::IsNullOrWhiteSpace($Token)) {
        return [pscustomobject]@{ ok = $false; error = "DonatePay access token is not configured."; status = 401 }
    }
    $CurrentGeneration = [long](Get-LlmJobsSummary).auctionGeneration
    if ([long]$Context.auctionGeneration -le 0) { $Context.auctionGeneration = $CurrentGeneration }
    if ([long]$Context.auctionGeneration -ne $CurrentGeneration) {
        return [pscustomobject]@{ ok = $false; error = "Auction generation is stale."; code = "AUCTION_GENERATION_MISMATCH"; status = 409; currentAuctionGeneration = $CurrentGeneration }
    }
    $RequestId = "dp-recovery-$([guid]::NewGuid().ToString('N'))"
    $WorkerInput = [pscustomobject]@{
        requestId = $RequestId
        region = [string]$Context.region
        after = [long]$Context.after
        limit = [int]$Context.limit
        auctionGeneration = [long]$Context.auctionGeneration
        access_token = $Token
        tokenFingerprint = Get-DonationAlertsTokenFingerprint $Token
    }
    $Handle = Start-DonatePayRecoveryRunspace $WorkerInput
    $Handle | Add-Member -NotePropertyName RequestId -NotePropertyValue $RequestId -Force
    $Handle | Add-Member -NotePropertyName After -NotePropertyValue ([long]$Context.after) -Force
    $Handle | Add-Member -NotePropertyName AuctionGeneration -NotePropertyValue ([long]$Context.auctionGeneration) -Force
    $script:DonatePayRecoveryHandle = $Handle
    $script:DonatePayRecoveryCompleted = $null
    return [pscustomobject]@{
        ok = $true
        queued = $true
        inFlight = $false
        requestId = $RequestId
        lastSeenId = [long]$Context.after
        auctionGeneration = [long]$Context.auctionGeneration
    }
}

function Complete-DonatePayRecoveryRunspaceIfReady {
    $Handle = $script:DonatePayRecoveryHandle
    if (-not $Handle -or -not $Handle.AsyncResult.IsCompleted) { return }
    $script:DonatePayRecoveryHandle = $null
    try {
        $Output = @($Handle.PowerShell.EndInvoke($Handle.AsyncResult))
        $Envelope = @($Output | Where-Object { $_ -and $_.PSObject.Properties['context'] } | Select-Object -Last 1)[0]
        if (-not $Envelope) { throw "DonatePay recovery worker returned no result." }
        $Context = $Envelope.context
        $CurrentGeneration = [long](Get-LlmJobsSummary).auctionGeneration
        $CurrentFingerprint = Get-DonationAlertsTokenFingerprint (Get-DonatePayStoredToken)
        if ([long]$Context.auctionGeneration -ne $CurrentGeneration) {
            Write-AppLog -Level "INFO" -Message "Discarded DonatePay recovery result from an old auction."
            $script:DonatePayRecoveryCompleted = [pscustomobject]@{
                requestId = [string]$Context.requestId
                response = [pscustomobject]@{
                    ok = $false
                    error = "DonatePay recovery result belongs to an old auction."
                    code = "AUCTION_GENERATION_MISMATCH"
                    status = 409
                    currentAuctionGeneration = $CurrentGeneration
                }
            }
            return
        }
        if ([string]$Context.tokenFingerprint -cne $CurrentFingerprint) {
            Write-AppLog -Level "INFO" -Message "Discarded DonatePay recovery result from an old connection."
            $script:DonatePayRecoveryCompleted = [pscustomobject]@{
                requestId = [string]$Context.requestId
                response = [pscustomobject]@{
                    ok = $false
                    error = "DonatePay connection changed while recovery was running."
                    code = "DONATEPAY_CONNECTION_CHANGED"
                    status = 409
                }
            }
            return
        }
        $Applied = Apply-DonatePayRecoveryResult $Envelope.result $Context
        if ($Applied -and $Applied.ok -eq $false) { Write-UpstreamErrorLog "DonatePay recovery" $Applied }
        if (-not $Applied) { throw "DonatePay recovery produced no result." }
        $Applied | Add-Member -NotePropertyName requestId -NotePropertyValue ([string]$Context.requestId) -Force
        $Applied | Add-Member -NotePropertyName completed -NotePropertyValue $true -Force
        $script:DonatePayRecoveryCompleted = [pscustomobject]@{
            requestId = [string]$Context.requestId
            response = $Applied
        }
    }
    catch {
        Write-Host "[DonatePay] recovery worker failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-AppLog -Level "ERROR" -Message "[DonatePay] recovery worker failed: $($_.Exception.Message)"
        $script:DonatePayRecoveryCompleted = [pscustomobject]@{
            requestId = [string]$Handle.RequestId
            response = [pscustomobject]@{
                ok = $false
                error = "DonatePay recovery failed."
                code = "DONATEPAY_RECOVERY_FAILED"
                status = 503
                requestId = [string]$Handle.RequestId
            }
        }
    }
    finally {
        try { $Handle.PowerShell.Dispose() } catch {}
        try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch {}
    }
}

function Stop-DonatePayRecoveryRunspace {
    param([AllowNull()][object]$Handle)

    if (-not $Handle) { return }
    try {
        if ($Handle.AsyncResult -and -not $Handle.AsyncResult.IsCompleted) { $Handle.PowerShell.Stop() }
        if ($Handle.AsyncResult -and $Handle.AsyncResult.IsCompleted) { [void]$Handle.PowerShell.EndInvoke($Handle.AsyncResult) }
    } catch {}
    try { $Handle.PowerShell.Dispose() } catch {}
    try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch {}
}

function Get-CollectorIdentitySignature {
    param(
        [string]$Service,
        [AllowNull()][string]$AccessToken,
        [AllowNull()][string]$Region = "",
        [AllowNull()][string]$UserId = ""
    )

    $Fingerprint = Get-DonationAlertsTokenFingerprint $AccessToken
    if ($Service -eq "donatepay") {
        $SafeRegion = if ($Region -eq "eu") { "eu" } else { "ru" }
        return "$SafeRegion|$Fingerprint|$([string]$UserId)"
    }
    return "$Fingerprint|$([string]$UserId)"
}

function Update-CollectorConfig {
    param([object]$InputData)

    $AnyConfigChanged = $false
    $PreparedDPInput = $InputData.donatepay
    $PreparedDPIncomingAccessToken = if ($PreparedDPInput) { [string]$PreparedDPInput.accessToken } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($PreparedDPIncomingAccessToken)) {
        if (-not (Set-DonatePayStoredToken $PreparedDPIncomingAccessToken)) {
            Write-AppLog -Level "ERROR" -Message "DonatePay token update failed; keeping the previous runtime configuration."
            $PreparedDPInput = $null
        }
    }
    $PreparedDAInput = $InputData.donationalerts
    $PreparedDAIncomingAccessToken = if ($PreparedDAInput) { [string]$PreparedDAInput.accessToken } else { "" }
    $PreparedDAIncomingTokenSaved = $false
    if (-not [string]::IsNullOrWhiteSpace($PreparedDAIncomingAccessToken)) {
        $PreparedDAIncomingTokenSaved = Set-DonationAlertsStoredTokenAndResetCurrency $PreparedDAIncomingAccessToken
        if (-not $PreparedDAIncomingTokenSaved) {
            Write-AppLog -Level "ERROR" -Message "DonationAlerts token update failed; keeping the previous runtime configuration."
        }
    }
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DPInput = $PreparedDPInput
        $DAInput = $PreparedDAInput

        if ($DPInput) {
            $DP = $script:ServerState.Integrations.DonatePay
            $PreviousAccessToken = $DP.AccessToken
            $PreviousUserId = $DP.UserId
            $IncomingAccessToken = [string]$DPInput.accessToken
            $EffectiveAccessToken = if (-not [string]::IsNullOrWhiteSpace($IncomingAccessToken)) {
                $IncomingAccessToken
            } elseif (-not [string]::IsNullOrWhiteSpace($PreviousAccessToken)) {
                $PreviousAccessToken
            } else {
                Get-DonatePayStoredToken
            }
            $HasStoredAccessToken = -not [string]::IsNullOrWhiteSpace($EffectiveAccessToken)
            $NewEnabled = [bool]$DPInput.enabled -and $HasStoredAccessToken
            $Signature = Get-CollectorIdentitySignature "donatepay" $EffectiveAccessToken ([string]$DPInput.region) ([string]$DPInput.userId)
            $Changed = $DP.Signature -ne $Signature
            $AnyConfigChanged = $AnyConfigChanged -or $Changed
            $DP.Enabled = $NewEnabled
            $DP.Region = if ([string]$DPInput.region -eq "eu") { "eu" } else { "ru" }
            $DP.AccessToken = $EffectiveAccessToken
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
                $DP.UserId = if (-not [string]::IsNullOrWhiteSpace([string]$PreviousUserId)) {
                    $PreviousUserId
                } else {
                    [string]$DPInput.userId
                }
                if ([string]::IsNullOrWhiteSpace($DP.AccessToken) -and $HasStoredAccessToken) {
                    $DP.AccessToken = $EffectiveAccessToken
                }
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
            $IncomingAccessToken = $PreparedDAIncomingAccessToken
            if ($PreparedDAIncomingTokenSaved) { $DA.UserCurrency = "" }
            $EffectiveAccessToken = if ($PreparedDAIncomingTokenSaved) {
                $IncomingAccessToken
            } elseif (-not [string]::IsNullOrWhiteSpace($PreviousAccessToken)) {
                $PreviousAccessToken
            } else {
                Get-DonationAlertsStoredToken
            }
            $HasStoredAccessToken = -not [string]::IsNullOrWhiteSpace($EffectiveAccessToken)
            $NewEnabled = [bool]$DAInput.enabled -and $HasStoredAccessToken
            $EffectiveTokenFingerprint = Get-DonationAlertsTokenFingerprint $EffectiveAccessToken
            $Signature = Get-CollectorIdentitySignature "donationalerts" $EffectiveAccessToken "" ([string]$DAInput.userId)
            $Changed = $DA.Signature -ne $Signature
            $AnyConfigChanged = $AnyConfigChanged -or $Changed
            $DA.Enabled = $NewEnabled
            $DA.AppId = [string]$DAInput.appId
            $DA.AccessToken = $EffectiveAccessToken
            $DA.TokenType = if ($DAInput.tokenType) { [string]$DAInput.tokenType } else { "Bearer" }
            $DA.UserId = [string]$DAInput.userId
            $DA.Signature = $Signature
            $DA.PollingIntervalSec = $Interval
            if ($Changed) {
                $DA.LastSeenId = $null
                $DA.BaselineReady = $false
                $DA.LastPollAt = $null
                Reset-DonationAlertsFailureState $DA
                $DA.Status = if ($DA.Enabled) { "connecting" } else { "disconnected" }
            }
            else {
                $DA.AccessToken = $PreviousAccessToken
                $DA.TokenType = $PreviousTokenType
                if ([string]::IsNullOrWhiteSpace($DA.AccessToken) -and $HasStoredAccessToken) {
                    $DA.AccessToken = $EffectiveAccessToken
                }
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

    $script:CollectorEnabled = -not $script:CollectorPausedPreserveCursor
    $script:NextCollectorTickAt = (Get-Date).AddMilliseconds(500)
    [void](Save-CollectorState)

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
    $LlmStatus = Get-LlmJobsSummary
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DP = $script:ServerState.Integrations.DonatePay
        $DA = $script:ServerState.Integrations.DonationAlerts
        Initialize-DonationAlertsRuntimeFields $DA
        $DPSecretStatus = Get-DonatePaySecretStatus
        $DASecretStatus = Get-DonationAlertsSecretStatus
        return [pscustomobject]@{
            ok = $true
            resetEpoch = Get-AppResetEpoch
            sessionStartedAt = $script:ServerState.SessionStartedAt
            services = [pscustomobject]@{
                donatepay = [pscustomobject]@{
                    enabled = [bool]$DP.Enabled
                    status = [string]$DP.Status
                    lastError = [string]$DP.LastError
                    lastEventAt = [string]$DP.LastEventAt
                    baselineReady = [bool]$DP.BaselineReady
                    hasAccessToken = (-not [string]::IsNullOrWhiteSpace([string]$DP.AccessToken)) -or [bool]$DPSecretStatus.hasAccessToken
                    connected = (-not [string]::IsNullOrWhiteSpace([string]$DP.AccessToken)) -or [bool]$DPSecretStatus.hasAccessToken
                }
                donationalerts = [pscustomobject]@{
                    enabled = [bool]$DA.Enabled
                    running = [bool]($DA.Enabled -and $script:CollectorEnabled -and -not $script:CollectorPausedPreserveCursor)
                    status = [string]$DA.Status
                    lastError = [string]$DA.LastError
                    lastEventAt = [string]$DA.LastEventAt
                    baselineReady = [bool]$DA.BaselineReady
                    degraded = [bool]$DA.Degraded
                    consecutiveFailures = [int]$DA.ConsecutiveFailures
                    lastSuccessAt = [string]$DA.LastSuccessAt
                    lastFailureAt = [string]$DA.LastFailureAt
                    lastFailureKind = [string]$DA.LastFailureKind
                    nextPollAt = [string]$DA.NextPollAt
                    hasAccessToken = (-not [string]::IsNullOrWhiteSpace([string]$DA.AccessToken)) -or [bool]$DASecretStatus.hasAccessToken
                    connected = (-not [string]::IsNullOrWhiteSpace([string]$DA.AccessToken)) -or [bool]$DASecretStatus.hasAccessToken
                }
            }
            pendingServerDonations = $script:ServerState.DonationsPending.Count
            pausedPreserveCursor = [bool]$script:CollectorPausedPreserveCursor
            currency = Get-CurrencyRateStatus
            llm = $LlmStatus
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
}

function Stop-CollectorRuntime {
    param([switch]$SkipPersistence)

    $script:CollectorRuntimeGeneration++
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
        Reset-DonationAlertsFailureState $script:ServerState.Integrations.DonationAlerts
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    $script:CollectorEnabled = $false
    $script:CollectorPausedPreserveCursor = $false
    $script:NextCollectorTickAt = Get-Date
    if (-not $SkipPersistence) { [void](Save-CollectorState) }
}

function Pause-CollectorRuntimePreserveCursor {
    $script:CollectorRuntimeGeneration++
    $script:CollectorPausedPreserveCursor = $true
    $script:CollectorEnabled = $false
    return [pscustomobject]@{ ok = $true; pausedPreserveCursor = $true }
}

function Resume-CollectorRuntimePreserveCursor {
    $script:CollectorPausedPreserveCursor = $false
    $script:CollectorEnabled = $true
    $script:NextCollectorTickAt = (Get-Date).AddMilliseconds(100)
    return [pscustomobject]@{ ok = $true; pausedPreserveCursor = $false }
}

function Disconnect-DonationAlertsIntegration {
    if (-not (Remove-DonationAlertsStoredToken)) {
        throw "Could not remove DonationAlerts secret."
    }
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DA = $script:ServerState.Integrations.DonationAlerts
        $DA.Enabled = $false
        $DA.AccessToken = ""
        $DA.UserCurrency = ""
        $DA.Signature = ""
        $DA.Status = "disconnected"
        $DA.LastError = ""
        $DA.BackoffUntil = $null
        $DA.LastPollAt = $null
        $DA.LastSeenId = $null
        $DA.BaselineReady = $false
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    [void](Save-CollectorState)
    return Get-DonationAlertsSecretStatus
}

function Disconnect-DonatePayIntegration {
    if (-not (Remove-DonatePayStoredToken)) {
        throw "Could not remove DonatePay secret."
    }
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $DP = $script:ServerState.Integrations.DonatePay
        $DP.Enabled = $false
        $DP.AccessToken = ""
        $DP.Signature = ""
        $DP.Status = "disconnected"
        $DP.LastError = ""
        $DP.BackoffUntil = $null
        $DP.LastPollAt = $null
        $DP.LastSeenId = $null
        $DP.BaselineReady = $false
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    [void](Save-CollectorState)
    return Get-DonatePaySecretStatus
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
    $Result = $null
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        if ($Ids.Count -le 0) {
            $Result = [pscustomobject]@{ ok = $true; removed = 0; pending = $script:ServerState.DonationsPending.Count }
        }
        else {
            $Before = $script:ServerState.DonationsPending.Count
            $Remaining = [System.Collections.ArrayList]::new()
            foreach ($Donation in $script:ServerState.DonationsPending) {
                if ($Ids -notcontains [string]$Donation.id) {
                    [void]$Remaining.Add($Donation)
                }
            }
            $script:ServerState.DonationsPending = $Remaining
            $Result = [pscustomobject]@{
                ok = $true
                removed = ($Before - $script:ServerState.DonationsPending.Count)
                pending = $script:ServerState.DonationsPending.Count
            }
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    if ([int]$Result.removed -gt 0) { [void](Save-CollectorState) }
    return $Result
}

function Clear-CollectorDonations {
    param([switch]$SkipPersistence)

    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $script:ServerState.DonationsPending.Clear()
        $script:ServerState.SeenDonationKeys.Clear()
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    if (-not $SkipPersistence) { [void](Save-CollectorState) }
    return [pscustomobject]@{ ok = $true }
}

function Clear-CollectorPendingDonations {
    param(
        [long]$DonatePayCursor = 0,
        [AllowNull()][string]$ClearStartedAt = ""
    )

    $Result = $null
    [System.Threading.Monitor]::Enter($script:StateLock)
    try {
        $Cutoff = $null
        if (-not [string]::IsNullOrWhiteSpace($ClearStartedAt)) {
            try { $Cutoff = [DateTimeOffset]::Parse($ClearStartedAt).ToUniversalTime() } catch { $Cutoff = $null }
        }
        $Before = $script:ServerState.DonationsPending.Count
        $Remaining = [System.Collections.ArrayList]::new()
        $ReleasedDonatePayKeys = 0
        foreach ($Donation in @($script:ServerState.DonationsPending)) {
            $QueuedAt = $null
            if ($Cutoff -and $Donation.PSObject.Properties['serverQueuedAt']) {
                try { $QueuedAt = [DateTimeOffset]::Parse([string]$Donation.serverQueuedAt).ToUniversalTime() } catch { $QueuedAt = $null }
            }
            if ($Cutoff -and $QueuedAt -and $QueuedAt -ge $Cutoff) {
                [void]$Remaining.Add($Donation)
                continue
            }
            if ([string]$Donation.source -ne 'donatepay') { continue }
            $DonationId = Get-NumericDonationId $Donation.externalId
            if ($DonationId -le $DonatePayCursor) { continue }
            $Key = Get-DonationKey 'donatepay' ([string]$Donation.externalId)
            if ($script:ServerState.SeenDonationKeys.ContainsKey($Key)) {
                $script:ServerState.SeenDonationKeys.Remove($Key)
                $ReleasedDonatePayKeys++
            }
        }
        $script:ServerState.DonationsPending = $Remaining
        $Removed = $Before - $Remaining.Count
        $Result = [pscustomobject]@{
            ok = $true
            removed = $Removed
            pending = $Remaining.Count
            releasedDonatePayKeys = $ReleasedDonatePayKeys
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:StateLock)
    }
    [void](Save-CollectorState)
    return $Result
}

function Start-LlmWorkerRunspace {
    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = "MTA"
    $Runspace.Open()
    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Runspace
    [void]$PowerShell.AddCommand($PSCommandPath)
    [void]$PowerShell.AddParameter("Root", $RootPath)
    [void]$PowerShell.AddParameter("ServerOnly", $true)
    [void]$PowerShell.AddParameter("LlmWorkerOnly", $true)
    if ($TrayState) { [void]$PowerShell.AddParameter("TrayState", $TrayState) }
    $AsyncResult = $PowerShell.BeginInvoke()
    return [pscustomobject]@{ Runspace = $Runspace; PowerShell = $PowerShell; AsyncResult = $AsyncResult }
}

function Stop-LlmWorkerRunspace {
    param([AllowNull()][object]$Handle)

    if (-not $Handle) { return }
    try {
        if ($Handle.AsyncResult -and -not $Handle.AsyncResult.IsCompleted) {
            $Handle.PowerShell.Stop()
        }
        if ($Handle.AsyncResult -and $Handle.AsyncResult.IsCompleted) {
            $Handle.PowerShell.EndInvoke($Handle.AsyncResult)
        }
    } catch {
        Write-AppLog -Level "WARN" -Message "AI worker stop failed: $($_.Exception.Message)"
    }
    try { $Handle.PowerShell.Dispose() } catch {}
    try { $Handle.Runspace.Close(); $Handle.Runspace.Dispose() } catch {}
}

if ($DonationAlertsPollWorkerOnly) {
    $PollToken = [string]$DonationAlertsPollInput.accessToken
    $PollSignature = [string]$DonationAlertsPollInput.signature
    $PollResult = Invoke-DonationAlertsApi `
        "https://www.donationalerts.com/api/v1/alerts/donations" `
        $PollToken `
        "/api/collector/donationalerts"
    Write-Output ([pscustomobject]@{
        signature = $PollSignature
        runtimeGeneration = [long]$DonationAlertsPollInput.runtimeGeneration
        result = $PollResult
    })
    return
}

if ($DonatePayRecoveryWorkerOnly) {
    $RecoveryContext = Get-DonatePayRecoveryRequestContext $DonatePayRecoveryWorkerInput
    $RecoveryContext | Add-Member -NotePropertyName tokenFingerprint -NotePropertyValue ([string]$DonatePayRecoveryWorkerInput.tokenFingerprint) -Force
    $RecoveryResult = Invoke-DonatePayRecoveryFetch $DonatePayRecoveryWorkerInput
    Write-Output ([pscustomobject]@{ context = $RecoveryContext; result = $RecoveryResult })
    return
}

if ($LlmWorkerOnly) {
    Start-LlmWorkerLoop
    return
}

try {
    [void](Restore-CollectorState)
}
catch {
    Write-AppLog -Level "ERROR" -Message "Collector state restore failed: $($_.Exception.Message)"
}
$script:ServerState.Integrations.DonationAlerts.UserCurrency = Normalize-CurrencyCode (Get-DonationAlertsStoredUserCurrency)

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

if ($SkipStartupNetwork) {
    $script:CurrencyRatesInitialized = $true
    $script:CurrencyRatesLoadCount = 1
    $script:CurrencyRateSnapshot = New-UnavailableCurrencyRateSnapshot "Startup network is disabled for runtime tests."
}
else {
    [void](Initialize-CurrencyRates)
    Test-AppVersion
    Write-AppVersionLog
}
$script:LlmWorkerHandle = Start-LlmWorkerRunspace

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
            $Stream.ReadTimeout = $script:ClientIoTimeoutMs
            $Stream.WriteTimeout = $script:ClientIoTimeoutMs
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
            if ($RequestLine.Length -gt $script:MaxRequestLineChars) {
                Send-Json $Stream 431 @{ ok = $false; error = "Request line is too large."; status = 431 }
                continue
            }

            $Headers = @{}
            $HeaderChars = 0
            $HeaderCount = 0
            $HeadersTooLarge = $false
            while ($true) {
                $HeaderLine = $Reader.ReadLine()
                if ([string]::IsNullOrEmpty($HeaderLine)) { break }
                $HeaderChars += $HeaderLine.Length
                $HeaderCount++
                if ($HeaderChars -gt $script:MaxRequestHeaderChars -or $HeaderCount -gt $script:MaxRequestHeaderCount) {
                    $HeadersTooLarge = $true
                    break
                }
                $Separator = $HeaderLine.IndexOf(":")
                if ($Separator -gt 0) {
                    $Name = $HeaderLine.Substring(0, $Separator).Trim().ToLowerInvariant()
                    $Value = $HeaderLine.Substring($Separator + 1).Trim()
                    $Headers[$Name] = $Value
                }
            }
            if ($HeadersTooLarge) {
                Send-Json $Stream 431 @{ ok = $false; error = "Request headers are too large."; status = 431 }
                continue
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
            $ContentLength = 0L
            if ($Headers.ContainsKey("content-length")) {
                if (-not [long]::TryParse($Headers["content-length"], [ref]$ContentLength) -or $ContentLength -lt 0) {
                    Send-Json $Stream 400 @{ ok = $false; error = "Invalid Content-Length."; status = 400 }
                    continue
                }
                if (-not (Test-RequestContentLengthAllowed $ContentLength $script:MaxRequestBodyBytes)) {
                    Send-Json $Stream 413 @{ ok = $false; error = "Request body is too large."; status = 413 }
                    continue
                }
            }

            $HostHeader = Get-RequestHeaderValue $Headers "Host"
            if (-not (Test-AllowedHostHeader $HostHeader $SelectedPort)) {
                Send-Json $Stream 403 @{ ok = $false; error = "Forbidden host."; status = 403 }
                continue
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

            if ((Test-SensitiveLocalApiPath $DecodedTarget) -and -not (Require-LocalAppToken $Stream $Headers $HeadOnly)) {
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
                        resetEpoch = Get-AppResetEpoch
                        version = Get-AppVersionStatus
                        integrations = [pscustomobject]@{
                            donatepay = Get-DonatePaySecretStatus
                            donationalerts = Get-DonationAlertsSecretStatus
                            openrouter = Get-OpenRouterSecretStatus
                        }
                        currency = Get-CurrencyRateStatus
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

            if ($DecodedTarget -eq "/api/currency/status") {
                if ($Method -ne "GET") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                }
                else {
                    Send-Json $Stream 200 (Get-CurrencyRateStatus) $HeadOnly
                }
                continue
            }

            if ($DecodedTarget -eq "/api/app/reset") {
                if ($Method -ne "POST") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                }
                else {
                    Send-Json $Stream 200 (Reset-AllApplicationData)
                }
                continue
            }

            if ($DecodedTarget -eq "/centrifuge/subscribe") {
                if ($Method -ne "POST") {
                    Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                    continue
                }
                try {
                    $InputData = Read-JsonBody $Reader $ContentLength
                    $Result = Invoke-DonatePaySubscribe $InputData
                    if ($Result -and $Result.ok -eq $false) {
                        Write-AppLog -Level "ERROR" -Message "DonatePay subscribe proxy request failed."
                        $StatusCode = 500
                        try {
                            $ParsedStatus = 0
                            if ([int]::TryParse([string]$Result.status, [ref]$ParsedStatus) -and $ParsedStatus -ge 400) {
                                $StatusCode = $ParsedStatus
                            }
                        } catch {}
                        Send-Json $Stream $StatusCode $Result
                    }
                    else {
                        Send-Json $Stream 200 $Result
                    }
                }
                catch {
                    $FriendlyError = if ($_.Exception -is [System.ArgumentException]) {
                        $_.Exception.Message
                    } else {
                        Get-FriendlyDonatePayProxyError $_.Exception
                    }
                    Write-AppLog -Level "ERROR" -Message "DonatePay subscribe proxy request failed: $FriendlyError"
                    Send-Json $Stream 500 @{
                        ok = $false
                        endpoint = $DecodedTarget
                        method = "POST"
                        upstreamUrl = ""
                        upstreamStatus = $null
                        upstreamBody = ""
                        error = $FriendlyError
                        status = 500
                    }
                }
                continue
            }

            if ($DecodedTarget.StartsWith("/api/integrations/openrouter/")) {
                try {
                    switch ($DecodedTarget) {
                        "/api/integrations/openrouter/secret" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            $ApiKey = [string]$InputData.apiKey
                            if ([string]::IsNullOrWhiteSpace($ApiKey)) {
                                Send-Json $Stream 400 @{ ok = $false; error = "Missing OpenRouter API key."; status = 400 }
                                break
                            }
                            if (-not (Set-OpenRouterStoredApiKey $ApiKey)) {
                                Send-Json $Stream 500 @{ ok = $false; error = "Could not save OpenRouter secret."; status = 500 }
                                break
                            }
                            Send-Json $Stream 200 (Get-OpenRouterSecretStatus)
                        }
                        "/api/integrations/openrouter/status" {
                            if ($Method -ne "GET") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Get-OpenRouterSecretStatus) $HeadOnly
                        }
                        "/api/integrations/openrouter/proxy" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            $ProxyUrl = [string]$InputData.proxyUrl
                            if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
                                if (-not (Remove-OpenRouterStoredProxyUrl)) {
                                    Send-Json $Stream 500 @{ ok = $false; error = "Could not remove OpenRouter proxy."; status = 500 }
                                    break
                                }
                                Send-Json $Stream 200 (Get-OpenRouterSecretStatus)
                                break
                            }
                            try {
                                $ParsedProxy = [System.Uri]::new($ProxyUrl)
                                if ($ParsedProxy.Scheme -ne "http" -and $ParsedProxy.Scheme -ne "https") {
                                    Send-Json $Stream 400 @{ ok = $false; error = "OpenRouter proxy must be http:// or https://."; status = 400 }
                                    break
                                }
                            }
                            catch {
                                Send-Json $Stream 400 @{ ok = $false; error = "Invalid OpenRouter proxy URL."; status = 400 }
                                break
                            }
                            if (-not (Set-OpenRouterStoredProxyUrl $ProxyUrl)) {
                                Send-Json $Stream 500 @{ ok = $false; error = "Could not save OpenRouter proxy."; status = 500 }
                                break
                            }
                            Send-Json $Stream 200 (Get-OpenRouterSecretStatus)
                        }
                        "/api/integrations/openrouter/test" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            $Result = Test-OpenRouterIntegration ([string]$InputData.model)
                            $StatusCode = if ($Result.ok) { 200 } else { 503 }
                            Send-Json $Stream $StatusCode $Result
                        }
                        "/api/integrations/openrouter/disconnect" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            if (-not (Remove-OpenRouterStoredConfiguration)) {
                                Send-Json $Stream 500 @{ ok = $false; error = "Could not remove OpenRouter configuration."; status = 500 }
                                break
                            }
                            Send-Json $Stream 200 (Get-OpenRouterSecretStatus)
                        }
                        default {
                            Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                        }
                    }
                }
                catch {
                    Write-AppLog -Level "ERROR" -Message "[OpenRouter secret] request error: $($_.Exception.Message)"
                    Send-Json $Stream 500 @{ ok = $false; error = "OpenRouter secret request failed."; exceptionMessage = Get-MaskedText $_.Exception.Message; status = 500 }
                }
                continue
            }

            if ($DecodedTarget.StartsWith("/api/llm/")) {
                try {
                    switch ($DecodedTarget) {
                        "/api/llm/jobs" {
                            if ($Method -ne "POST") { Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }; break }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            $Result = Add-OrGet-LlmJob $InputData
                            $StatusCode = if ($Result.ok) { 200 } else { [int]$Result.status }
                            Send-Json $Stream $StatusCode $Result
                        }
                        "/api/llm/jobs/results" {
                            if ($Method -ne "POST") { Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }; break }
                            Send-Json $Stream 200 (Get-LlmJobResults (Read-JsonBody $Reader $ContentLength))
                        }
                        "/api/llm/auction/clear" {
                            if ($Method -ne "POST") { Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }; break }
                            Send-Json $Stream 200 (Clear-LlmAuctionData (Read-JsonBody $Reader $ContentLength))
                        }
                        "/api/llm/jobs/clear" {
                            if ($Method -ne "POST") { Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }; break }
                            Send-Json $Stream 200 (Clear-LlmJobs (Read-JsonBody $Reader $ContentLength))
                        }
                        default {
                            Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                        }
                    }
                }
                catch {
                    Write-AppLog -Level "ERROR" -Message "[LLM jobs] request error: $($_.Exception.Message)"
                    Send-Json $Stream 500 @{ ok = $false; error = "AI job request failed."; status = 500 }
                }
                continue
            }

            if ($DecodedTarget.StartsWith("/api/integrations/donationalerts/")) {
                try {
                    switch ($DecodedTarget) {
                        "/api/integrations/donationalerts/secret" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            $AccessToken = [string]$InputData.accessToken
                            if ([string]::IsNullOrWhiteSpace($AccessToken)) {
                                Send-Json $Stream 400 @{ ok = $false; error = "Missing DonationAlerts access token."; status = 400 }
                                break
                            }
                            if (-not (Set-DonationAlertsStoredTokenAndResetCurrency -AccessToken $AccessToken -UpdateRuntime)) {
                                Send-Json $Stream 500 @{ ok = $false; error = "Could not save DonationAlerts secret."; status = 500 }
                                break
                            }
                            [System.Threading.Monitor]::Enter($script:StateLock)
                            try {
                                $DA = $script:ServerState.Integrations.DonationAlerts
                                if ($DA.Enabled -or -not [string]::IsNullOrWhiteSpace([string]$DA.AppId)) {
                                    $DA.Enabled = $true
                                    if ($DA.Status -eq "disconnected") { $DA.Status = "connecting" }
                                    $DA.LastError = ""
                                    $DA.Signature = ""
                                }
                            }
                            finally {
                                [System.Threading.Monitor]::Exit($script:StateLock)
                            }
                            Send-Json $Stream 200 (Get-DonationAlertsSecretStatus)
                        }
                        "/api/integrations/donationalerts/status" {
                            if ($Method -ne "GET") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Get-DonationAlertsSecretStatus) $HeadOnly
                        }
                        "/api/integrations/donationalerts/disconnect" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Disconnect-DonationAlertsIntegration)
                        }
                        default {
                            Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                        }
                    }
                }
                catch {
                    Write-AppLog -Level "ERROR" -Message "[DonationAlerts secret] request error: $($_.Exception.Message)"
                    Send-Json $Stream 500 @{
                        ok = $false
                        error = "DonationAlerts secret request failed."
                        exceptionMessage = Get-MaskedText $_.Exception.Message
                        status = 500
                    }
                }
                continue
            }

            if ($DecodedTarget.StartsWith("/api/integrations/donatepay/")) {
                try {
                    switch ($DecodedTarget) {
                        "/api/integrations/donatepay/secret" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            $InputData = Read-JsonBody $Reader $ContentLength
                            $AccessToken = [string]$InputData.accessToken
                            if ([string]::IsNullOrWhiteSpace($AccessToken)) {
                                Send-Json $Stream 400 @{ ok = $false; error = "Missing DonatePay access token."; status = 400 }
                                break
                            }
                            if (-not (Set-DonatePayStoredToken $AccessToken)) {
                                Send-Json $Stream 500 @{ ok = $false; error = "Could not save DonatePay secret."; status = 500 }
                                break
                            }
                            [System.Threading.Monitor]::Enter($script:StateLock)
                            try {
                                $DP = $script:ServerState.Integrations.DonatePay
                                $DP.AccessToken = $AccessToken
                                $DP.Region = if ([string]$InputData.region -eq "eu") { "eu" } else { "ru" }
                                if ($DP.Enabled -or -not [string]::IsNullOrWhiteSpace([string]$DP.UserId)) {
                                    $DP.Enabled = $true
                                    if ($DP.Status -eq "disconnected") { $DP.Status = "connecting" }
                                    $DP.LastError = ""
                                    $DP.Signature = ""
                                }
                            }
                            finally {
                                [System.Threading.Monitor]::Exit($script:StateLock)
                            }
                            Send-Json $Stream 200 (Get-DonatePaySecretStatus)
                        }
                        "/api/integrations/donatepay/status" {
                            if ($Method -ne "GET") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Get-DonatePaySecretStatus) $HeadOnly
                        }
                        "/api/integrations/donatepay/disconnect" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Disconnect-DonatePayIntegration)
                        }
                        default {
                            Send-Json $Stream 404 @{ ok = $false; error = "API endpoint not found."; status = 404 }
                        }
                    }
                }
                catch {
                    Write-AppLog -Level "ERROR" -Message "[DonatePay secret] request error: $($_.Exception.Message)"
                    Send-Json $Stream 500 @{
                        ok = $false
                        error = "DonatePay secret request failed."
                        exceptionMessage = Get-MaskedText $_.Exception.Message
                        status = 500
                    }
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
                        "/api/collector/pause" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Pause-CollectorRuntimePreserveCursor)
                        }
                        "/api/collector/resume" {
                            if ($Method -ne "POST") {
                                Send-Json $Stream 405 @{ ok = $false; error = "Method not allowed."; status = 405 }
                                break
                            }
                            Send-Json $Stream 200 (Resume-CollectorRuntimePreserveCursor)
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
                            $AccessToken = [string]$InputData.access_token
                            if ([string]::IsNullOrWhiteSpace($AccessToken)) {
                                $AccessToken = Get-DonationAlertsStoredToken
                            }
                            $RequestTokenFingerprint = Get-DonationAlertsTokenFingerprint $AccessToken
                            $Result = Invoke-DonationAlertsApi `
                                "https://www.donationalerts.com/api/v1/user/oauth" `
                                $AccessToken `
                                $DecodedTarget
                            if (-not ($Result -and $Result.ok -eq $false)) {
                                $ProfileCurrency = Get-DonationAlertsProfileCurrency $Result
                                if (-not [string]::IsNullOrWhiteSpace($ProfileCurrency)) {
                                    $CurrencySaved = Set-DonationAlertsStoredUserCurrencyForToken `
                                        -Currency $ProfileCurrency `
                                        -AccessToken $AccessToken `
                                        -ExpectedTokenFingerprint $RequestTokenFingerprint `
                                        -UpdateRuntime
                                    if (-not $CurrencySaved) {
                                        Write-AppLog -Level "WARN" -Message "DonationAlerts profile currency was not saved because the token changed or secure storage was unavailable."
                                    }
                                }
                            }
                        }
                        "/api/da/donations" {
                            $AccessToken = [string]$InputData.access_token
                            if ([string]::IsNullOrWhiteSpace($AccessToken)) {
                                $AccessToken = Get-DonationAlertsStoredToken
                            }
                            $Result = Invoke-DonationAlertsApi `
                                "https://www.donationalerts.com/api/v1/alerts/donations" `
                                $AccessToken `
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
                        "/api/dp/socket-token" {
                            $Result = Invoke-DonatePaySocketToken $InputData
                        }
                        "/api/dp/user" {
                            $Result = Invoke-DonatePayApi $Region "/api/v1/user" $InputData $DecodedTarget
                        }
                        "/api/dp/transactions" {
                            $Result = Invoke-DonatePayApi $Region "/api/v1/transactions" $InputData $DecodedTarget
                        }
                        "/api/dp/recovery-transactions" {
                            $Result = Queue-DonatePayRecoveryRequest $InputData
                        }
                        default {
                            $ApiFound = $false
                        }
                    }
                    if ($ApiFound) {
                        if ($Result -and $Result.ok -eq $false) {
                            Write-Host "DonatePay proxy request failed." -ForegroundColor Yellow
                            Write-AppLog -Level "ERROR" -Message "DonatePay proxy request failed."
                            $StatusCode = 500
                            try {
                                $ParsedStatus = 0
                                if ([int]::TryParse([string]$Result.status, [ref]$ParsedStatus) -and $ParsedStatus -ge 400) {
                                    $StatusCode = $ParsedStatus
                                }
                            } catch {}
                            Send-Json $Stream $StatusCode $Result
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

            if (-not (Test-AllowedStaticPath $DecodedTarget)) {
                Send-Json $Stream 404 @{ ok = $false; error = "Not found."; status = 404 } $HeadOnly
                continue
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

            $ContentType = Get-ContentType $RequestedPath
            if ([System.IO.Path]::GetFileName($RequestedPath) -eq "koleso_papich.html") {
                $Html = [System.IO.File]::ReadAllText($RequestedPath, [System.Text.Encoding]::UTF8)
                $Html = $Html.Replace('const LOCAL_APP_TOKEN = "__LOCAL_APP_TOKEN__";', "const LOCAL_APP_TOKEN = `"$script:LocalAppToken`";")
                $Html = $Html.Replace('nonce="__LOCAL_SCRIPT_NONCE__"', "nonce=`"$script:LocalScriptNonce`"")
                $Body = [System.Text.Encoding]::UTF8.GetBytes($Html)
            }
            else {
                $Body = [System.IO.File]::ReadAllBytes($RequestedPath)
            }
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
    Stop-DonationAlertsPollRunspace $script:DonationAlertsPollHandle
    $script:DonationAlertsPollHandle = $null
    Stop-DonatePayRecoveryRunspace $script:DonatePayRecoveryHandle
    $script:DonatePayRecoveryHandle = $null
    Stop-LlmWorkerRunspace $script:LlmWorkerHandle
    if ($Listener) {
        try { $Listener.Stop(); Write-AppLog -Level "INFO" -Message "HTTP listener stopped" } catch {
            Write-AppLog -Level "ERROR" -Message "HTTP listener stop error: $($_.Exception.Message)"
        }
    }
}
