param(
    [ValidateRange(1, 65535)][int]$Port = 5501,
    [switch]$NoOpenBrowser,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:HtmlPath = Join-Path $script:Root 'ai_tester.html'
$script:LogicPath = Join-Path $script:Root 'ai_tester_logic.js'
$script:DefaultPromptPath = Join-Path $script:Root 'experimental_prompt.txt'
$script:SchemaPath = Join-Path $script:Root 'experimental_schema.json'
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
    $LocalAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
}
$script:PapichDataDir = Join-Path $LocalAppData 'PapichWheel'
$script:TesterDataDir = Join-Path $script:PapichDataDir 'ai-tester'
$script:SavedPromptPath = Join-Path $script:TesterDataDir 'experimental_prompt.txt'
$script:LogPath = Join-Path $script:TesterDataDir 'ai-tester.log'
$script:SecretsPath = Join-Path $script:PapichDataDir 'secrets.json'
$script:StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:MaxRequestBodyBytes = 2MB
$script:MaxResponseBodyBytes = 2MB
$script:MaxRawContentChars = 65536
$script:MaxPromptChars = 30000
$script:MaxDonationMessageChars = 4000
$script:MaxDonationNameChars = 120
$script:ApiToken = ''
$script:Listener = $null

function New-RandomToken {
    $Bytes = New-Object byte[] 32
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $Rng.GetBytes($Bytes) }
    finally { $Rng.Dispose() }
    return ([BitConverter]::ToString($Bytes)).Replace('-', '').ToLowerInvariant()
}

function Get-Sha256Hex {
    param([string]$Text)
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = $script:StrictUtf8.GetBytes($Text)
        return ([BitConverter]::ToString($Sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $Sha.Dispose() }
}

function Ensure-TesterDataDirectory {
    if (-not [System.IO.Directory]::Exists($script:TesterDataDir)) {
        [System.IO.Directory]::CreateDirectory($script:TesterDataDir) | Out-Null
    }
}

function Write-TesterLog {
    param([string]$Level, [string]$Message)
    try {
        Ensure-TesterDataDirectory
        if ([System.IO.File]::Exists($script:LogPath) -and ([System.IO.FileInfo]$script:LogPath).Length -gt 1MB) {
            [System.IO.File]::Delete($script:LogPath)
        }
        $Safe = ([string]$Message -replace '(?i)(Bearer\s+)[^\s]+', '$1***')
        $Safe = $Safe -replace '(?i)(api[_-]?key\s*[=:]\s*)[^\s]+', '$1***'
        if ($Safe.Length -gt 1000) { $Safe = $Safe.Substring(0, 1000) }
        $Line = "[$([DateTime]::UtcNow.ToString('o'))] [$Level] $Safe$([Environment]::NewLine)"
        [System.IO.File]::AppendAllText($script:LogPath, $Line, [System.Text.UTF8Encoding]::new($true))
    }
    catch {}
}

function Read-TextUtf8 {
    param([string]$Path)
    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    return $script:StrictUtf8.GetString($Bytes).TrimStart([char]0xFEFF)
}

function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    Ensure-TesterDataDirectory
    $TempPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($TempPath, $Text, [System.Text.UTF8Encoding]::new($false, $true))
        if ([System.IO.File]::Exists($Path)) {
            try { [System.IO.File]::Replace($TempPath, $Path, $null) }
            catch { Move-Item -LiteralPath $TempPath -Destination $Path -Force }
        }
        else { [System.IO.File]::Move($TempPath, $Path) }
    }
    finally {
        if ([System.IO.File]::Exists($TempPath)) { try { [System.IO.File]::Delete($TempPath) } catch {} }
    }
}

function Get-ExperimentalPrompt {
    if ([System.IO.File]::Exists($script:SavedPromptPath)) { return Read-TextUtf8 $script:SavedPromptPath }
    return Read-TextUtf8 $script:DefaultPromptPath
}

function Get-PromptMetadata {
    param([string]$Text)
    $FirstLine = (($Text -split "`r?`n", 2)[0]).Trim()
    $Version = 'custom'
    if ($FirstLine.Contains(':')) {
        $Candidate = $FirstLine.Substring($FirstLine.IndexOf(':') + 1).Trim()
        if ($Candidate -match '^[A-Za-z0-9._-]{1,80}$') { $Version = $Candidate }
    }
    return [ordered]@{
        version = $Version
        fingerprint = (Get-Sha256Hex $Text).Substring(0, 24)
        characterCount = $Text.Length
        text = $Text
        customized = [System.IO.File]::Exists($script:SavedPromptPath)
    }
}

function Read-SecretsData {
    for ($Attempt = 0; $Attempt -lt 2; $Attempt++) {
        try {
            if (-not [System.IO.File]::Exists($script:SecretsPath)) { return $null }
            $Text = [System.IO.File]::ReadAllText($script:SecretsPath, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
            return $Text | ConvertFrom-Json
        }
        catch {
            if ($Attempt -eq 0) { Start-Sleep -Milliseconds 50 }
        }
    }
    return $null
}

function Unprotect-StoredSecret {
    param([AllowNull()][string]$ProtectedText)
    if ([string]::IsNullOrWhiteSpace($ProtectedText)) { return '' }
    try {
        $Secure = ConvertTo-SecureString -String $ProtectedText
        return [System.Net.NetworkCredential]::new('', $Secure).Password
    }
    catch { return '' }
}

function Get-OptionalProperty {
    param([AllowNull()][object]$Object, [string]$Name, [AllowNull()][object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        $Property = $Object.PSObject.Properties[$Name]
        if ($Property) { return $Property.Value }
    }
    catch {}
    return $Default
}

function Get-OpenRouterConfiguration {
    $Data = Read-SecretsData
    $Node = $null
    if ($Data -and $Data.integrations) { $Node = $Data.integrations.openrouter }
    $ApiKey = ''
    $ProxyUrl = ''
    if ($Node) {
        $ApiKey = Unprotect-StoredSecret ([string](Get-OptionalProperty $Node 'apiKey' ''))
        $ProxyUrl = Unprotect-StoredSecret ([string](Get-OptionalProperty $Node 'proxyUrl' ''))
    }
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { $ProxyUrl = [string]$env:PAPICH_OPENROUTER_PROXY }
    return @{ apiKey = $ApiKey; proxyUrl = $ProxyUrl }
}

function New-TesterException {
    param(
        [string]$Code,
        [string]$Message,
        [int]$HttpStatus = 500,
        [bool]$Retryable = $false,
        [bool]$Critical = $false,
        [int]$RetryAfterSeconds = 0,
        [AllowNull()][object]$Details = $null
    )
    $Exception = [System.Exception]::new($Message)
    $Exception.Data['TesterCode'] = $Code
    $Exception.Data['HttpStatus'] = $HttpStatus
    $Exception.Data['Retryable'] = $Retryable
    $Exception.Data['Critical'] = $Critical
    $Exception.Data['RetryAfterSeconds'] = $RetryAfterSeconds
    if ($null -ne $Details) { $Exception.Data['Details'] = $Details }
    return $Exception
}

function Throw-TesterError {
    param(
        [string]$Code,
        [string]$Message,
        [int]$HttpStatus = 500,
        [bool]$Retryable = $false,
        [bool]$Critical = $false,
        [int]$RetryAfterSeconds = 0,
        [AllowNull()][object]$Details = $null
    )
    throw (New-TesterException $Code $Message $HttpStatus $Retryable $Critical $RetryAfterSeconds $Details)
}

function ConvertTo-StrictJsonBytes {
    param([object]$Value, [int]$Depth = 30)
    try { return $script:StrictUtf8.GetBytes(($Value | ConvertTo-Json -Depth $Depth -Compress)) }
    catch { Throw-TesterError 'REQUEST_ENCODING_ERROR' 'Request could not be encoded as UTF-8.' 500 $false $false }
}

function ConvertFrom-StrictJsonBytes {
    param([byte[]]$Bytes, [string]$ErrorCode = 'INVALID_JSON')
    try {
        $Text = $script:StrictUtf8.GetString($Bytes).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($Text)) { Throw-TesterError $ErrorCode 'JSON body is empty.' 400 $false $false }
        return $Text | ConvertFrom-Json
    }
    catch {
        if ($_.Exception.Data.Contains('TesterCode')) { throw }
        Throw-TesterError $ErrorCode 'JSON could not be parsed.' 400 $false $false
    }
}

function Remove-UnsupportedStructuredSchemaKeywords {
    param([AllowNull()][object]$Node)
    if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return }
    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [System.Collections.IDictionary])) {
        foreach ($Item in @($Node)) { Remove-UnsupportedStructuredSchemaKeywords $Item }
        return
    }
    foreach ($Name in @('$schema', 'minLength', 'maxLength', 'uniqueItems')) {
        if ($Node.PSObject.Properties[$Name]) { $Node.PSObject.Properties.Remove($Name) }
    }
    foreach ($Property in @($Node.PSObject.Properties)) {
        Remove-UnsupportedStructuredSchemaKeywords $Property.Value
    }
}

function Get-PortableStructuredSchema {
    param([object]$Schema)
    try {
        $Clone = ($Schema | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
        Remove-UnsupportedStructuredSchemaKeywords $Clone
        return $Clone
    }
    catch { Throw-TesterError 'SCHEMA_CONVERSION_ERROR' 'Structured response schema could not be prepared.' 500 $false $false }
}

function Get-SafeDiagnosticText {
    param([AllowNull()][object]$Value, [int]$MaxLength = 500)
    if ($null -eq $Value) { return '' }
    $Text = ([string]$Value -replace '[\r\n\t]+', ' ').Trim()
    $Text = $Text -replace '(?i)(Bearer\s+)[^\s]+', '$1***'
    $Text = $Text -replace '(?i)(api[_-]?key\s*[=:]\s*)[^\s]+', '$1***'
    $Text = $Text -replace '(?i)sk-or-v1-[A-Za-z0-9_-]+', '***'
    if ($Text.Length -gt $MaxLength) { $Text = $Text.Substring(0, $MaxLength) }
    return $Text
}

function Get-OpenRouterErrorDetails {
    param([byte[]]$ResponseBytes, [string]$Model, [object]$PromptMetadata, [long]$LatencyMs)
    $OpenRouterMessage = ''
    $ErrorType = ''
    $ProviderCode = ''
    $RequestId = ''
    try {
        $Text = $script:StrictUtf8.GetString($ResponseBytes).TrimStart([char]0xFEFF)
        if (-not [string]::IsNullOrWhiteSpace($Text)) {
            $Envelope = $Text | ConvertFrom-Json
            $ErrorNode = Get-OptionalProperty $Envelope 'error' $null
            if ($ErrorNode) {
                $OpenRouterMessage = Get-SafeDiagnosticText (Get-OptionalProperty $ErrorNode 'message' '') 500
                $Metadata = Get-OptionalProperty $ErrorNode 'metadata' $null
                if ($Metadata) {
                    $ErrorType = Get-SafeDiagnosticText (Get-OptionalProperty $Metadata 'error_type' '') 100
                    $ProviderCode = Get-SafeDiagnosticText (Get-OptionalProperty $Metadata 'provider_code' '') 100
                }
            }
            $RequestId = Get-SafeDiagnosticText (Get-OptionalProperty $Envelope 'id' '') 200
        }
    }
    catch {}
    return [ordered]@{
        requestId = $RequestId
        model = $Model
        provider = 'openrouter'
        finishReason = 'error'
        promptFingerprint = [string]$PromptMetadata.fingerprint
        latencyMs = [Math]::Max(0, $LatencyMs)
        rawAiContent = ''
        openRouterMessage = $OpenRouterMessage
        errorType = $ErrorType
        providerCode = $ProviderCode
        usage = [ordered]@{ promptTokens = 0; completionTokens = 0; cachedTokens = 0; cost = $null }
    }
}

function Get-MessageContentText {
    param([object]$Message)
    if (-not $Message) { Throw-TesterError 'AI_CONTENT_MISSING' 'OpenRouter response has no message.' 502 $false $false }
    $Refusal = [string](Get-OptionalProperty $Message 'refusal' '')
    if (-not [string]::IsNullOrWhiteSpace($Refusal)) {
        Throw-TesterError 'AI_RESPONSE_REFUSAL' 'OpenRouter refused to return a structured response.' 422 $false $false
    }
    $Content = Get-OptionalProperty $Message 'content' $null
    if ($Content -is [string]) { return ([string]$Content).TrimStart([char]0xFEFF).Trim() }
    $Parts = New-Object System.Collections.Generic.List[string]
    if ($Content -is [System.Collections.IEnumerable] -and -not ($Content -is [System.Collections.IDictionary])) {
        foreach ($Part in @($Content)) {
            if ($Part -is [string]) { $Parts.Add([string]$Part); continue }
            if ($Part -and $Part.PSObject.Properties['text'] -and $Part.text -is [string]) { $Parts.Add([string]$Part.text); continue }
            if ($Part -and $Part.PSObject.Properties['content'] -and $Part.content -is [string]) { $Parts.Add([string]$Part.content) }
        }
    }
    elseif ($Content) {
        if ($Content.PSObject.Properties['text'] -and $Content.text -is [string]) { $Parts.Add([string]$Content.text) }
        elseif ($Content.PSObject.Properties['content'] -and $Content.content -is [string]) { $Parts.Add([string]$Content.content) }
    }
    $Text = [string]::Join('', $Parts.ToArray()).TrimStart([char]0xFEFF).Trim()
    if ([string]::IsNullOrWhiteSpace($Text)) { Throw-TesterError 'AI_CONTENT_MISSING' 'OpenRouter returned no text content.' 502 $false $false }
    return $Text
}

function ConvertFrom-StructuredContent {
    param([string]$Content)
    $Candidate = $Content.TrimStart([char]0xFEFF).Trim()
    if ($Candidate -match '(?s)^```(?:json)?\s*(?<body>.*?)\s*```$') { $Candidate = $Matches.body.Trim() }
    try { $Parsed = $Candidate | ConvertFrom-Json }
    catch { Throw-TesterError 'AI_RESPONSE_PARSE_ERROR' 'OpenRouter returned malformed structured JSON.' 502 $false $false }
    if ($Parsed -is [string]) {
        $Inner = ([string]$Parsed).Trim()
        try { $Parsed = $Inner | ConvertFrom-Json }
        catch { Throw-TesterError 'AI_RESPONSE_PARSE_ERROR' 'OpenRouter returned malformed double-encoded JSON.' 502 $false $false }
    }
    if ($null -eq $Parsed -or $Parsed -is [string] -or $Parsed -is [System.Array] -or $Parsed -is [ValueType]) {
        Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Structured response must be a JSON object.' 422 $false $false
    }
    return $Parsed
}

function ConvertTo-Confidence {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [bool]) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Confidence is invalid.' 422 $false $false }
    $Number = 0.0
    if ($Value -is [string]) {
        if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Number)) {
            Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Confidence is invalid.' 422 $false $false
        }
    }
    else {
        try { $Number = [Convert]::ToDouble($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Confidence is invalid.' 422 $false $false }
    }
    if ([double]::IsNaN($Number) -or [double]::IsInfinity($Number) -or $Number -lt 0 -or $Number -gt 1) {
        Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Confidence is outside the allowed range.' 422 $false $false
    }
    return $Number
}

function Get-ValidatedText {
    param([object]$Value, [string]$Field, [int]$MaxLength)
    if (-not ($Value -is [string])) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' "$Field must be a string." 422 $false $false }
    $Text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt $MaxLength -or $Text -match '[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]') {
        Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' "$Field is invalid." 422 $false $false
    }
    return $Text
}

function Validate-ExperimentalResponse {
    param([object]$Parsed)
    if (-not $Parsed.PSObject.Properties['items']) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Response has no items.' 422 $false $false }
    $TopKeys = @($Parsed.PSObject.Properties.Name)
    if ($TopKeys.Count -ne 1 -or $TopKeys[0] -ne 'items') { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Response contains unexpected fields.' 422 $false $false }
    $Items = @($Parsed.items)
    if ($Items.Count -gt 5) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Response contains too many items.' 422 $false $false }
    if ($null -eq $Parsed.items) { $Items = @() }
    $AllowedCategories = @('game', 'anime', 'movie', 'tv_show', 'cartoon', 'other', 'unknown')
    $AllowedLanguages = @('ru', 'en', 'ja', 'ko', 'zh', 'other', 'unknown')
    $Required = @('category', 'mentionedTitle', 'displayTitle', 'searchQueries', 'originalLanguage', 'confidence', 'reason')
    $Validated = New-Object System.Collections.Generic.List[object]
    foreach ($Item in $Items) {
        if ($null -eq $Item -or $Item -is [string] -or $Item -is [ValueType]) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Item is not an object.' 422 $false $false }
        $Keys = @($Item.PSObject.Properties.Name)
        foreach ($Name in $Required) { if (-not $Item.PSObject.Properties[$Name]) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' "Item is missing $Name." 422 $false $false } }
        foreach ($Name in $Keys) { if ($Required -notcontains $Name) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Item contains an unexpected field.' 422 $false $false } }
        $Category = [string]$Item.category
        $Language = [string]$Item.originalLanguage
        if ($AllowedCategories -notcontains $Category -or $AllowedLanguages -notcontains $Language) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'Item enum value is invalid.' 422 $false $false }
        $Queries = @($Item.searchQueries)
        if ($Queries.Count -lt 1 -or $Queries.Count -gt 4) { Throw-TesterError 'AI_SCHEMA_VALIDATION_ERROR' 'searchQueries count is invalid.' 422 $false $false }
        $Seen = @{}
        $CleanQueries = New-Object System.Collections.Generic.List[string]
        foreach ($Query in $Queries) {
            $Clean = Get-ValidatedText $Query 'searchQueries item' 200
            $Key = $Clean.ToLowerInvariant()
            if ($Seen.ContainsKey($Key)) { continue }
            $Seen[$Key] = $true
            $CleanQueries.Add($Clean)
        }
        $Validated.Add([ordered]@{
            category = $Category
            mentionedTitle = Get-ValidatedText $Item.mentionedTitle 'mentionedTitle' 200
            displayTitle = Get-ValidatedText $Item.displayTitle 'displayTitle' 200
            searchQueries = $CleanQueries.ToArray()
            originalLanguage = $Language
            confidence = ConvertTo-Confidence $Item.confidence
            reason = Get-ValidatedText $Item.reason 'reason' 500
        })
    }
    return [ordered]@{ items = $Validated.ToArray() }
}

function Get-RetryAfterSeconds {
    param([System.Net.Http.HttpResponseMessage]$Response)
    try {
        if ($Response.Headers.RetryAfter.Delta) { return [Math]::Max(1, [int][Math]::Ceiling($Response.Headers.RetryAfter.Delta.TotalSeconds)) }
        if ($Response.Headers.RetryAfter.Date) { return [Math]::Max(1, [int][Math]::Ceiling(($Response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)) }
    }
    catch {}
    return 0
}

function Invoke-ExperimentalOpenRouter {
    param([object]$Donation, [string]$Model)
    $Configuration = Get-OpenRouterConfiguration
    if ([string]::IsNullOrWhiteSpace([string]$Configuration.apiKey)) {
        Throw-TesterError 'OPENROUTER_KEY_MISSING' 'OpenRouter API key is not configured in PapichWheel.' 503 $false $true
    }
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { Throw-TesterError 'HTTP_UNAVAILABLE' 'System.Net.Http is unavailable.' 500 $false $true }
    $Prompt = Get-ExperimentalPrompt
    $PromptMetadata = Get-PromptMetadata $Prompt
    $Schema = (Read-TextUtf8 $script:SchemaPath) | ConvertFrom-Json
    $ProviderSchema = Get-PortableStructuredSchema $Schema
    $UserPayload = [ordered]@{
        task = 'analyze_one_donation'
        donation = [ordered]@{
            name = [string]$Donation.name
            amount = $Donation.amount
            currency = [string]$Donation.currency
            message = [string]$Donation.message
        }
    }
    $Payload = [ordered]@{
        model = $Model
        max_tokens = 1200
        provider = @{ require_parameters = $true }
        messages = @(
            @{ role = 'system'; content = $Prompt },
            @{ role = 'user'; content = ($UserPayload | ConvertTo-Json -Depth 10 -Compress) }
        )
        response_format = @{
            type = 'json_schema'
            json_schema = @{ name = 'papich_ai_tester_items'; strict = $true; schema = $ProviderSchema }
        }
    }
    $RequestBytes = ConvertTo-StrictJsonBytes $Payload 30
    $Handler = $null; $Client = $null; $Request = $null; $Response = $null; $Cancellation = $null
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $Handler = [System.Net.Http.HttpClientHandler]::new()
        $Handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $ProxyUrl = [string]$Configuration.proxyUrl
        if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
            try { $ProxyUri = [Uri]::new($ProxyUrl) } catch { Throw-TesterError 'PROXY_CONFIGURATION_ERROR' 'Configured OpenRouter proxy URL is invalid.' 503 $false $true }
            if ($ProxyUri.Scheme -notin @('http', 'https')) { Throw-TesterError 'PROXY_CONFIGURATION_ERROR' 'Only HTTP(S) OpenRouter proxies are supported.' 503 $false $true }
            $Proxy = [System.Net.WebProxy]::new($ProxyUri)
            if (-not [string]::IsNullOrWhiteSpace($ProxyUri.UserInfo)) {
                $Parts = $ProxyUri.UserInfo.Split(':', 2)
                $UserName = [Uri]::UnescapeDataString($Parts[0])
                $Password = ''
                if ($Parts.Count -gt 1) { $Password = [Uri]::UnescapeDataString($Parts[1]) }
                $Proxy.Credentials = [System.Net.NetworkCredential]::new($UserName, $Password)
            }
            $Handler.Proxy = $Proxy
            $Handler.UseProxy = $true
        }
        $Client = [System.Net.Http.HttpClient]::new($Handler, $false)
        $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://openrouter.ai/api/v1/chat/completions')
        $Request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', [string]$Configuration.apiKey)
        $Request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
        [void]$Request.Headers.TryAddWithoutValidation('HTTP-Referer', "http://127.0.0.1:$Port")
        [void]$Request.Headers.TryAddWithoutValidation('X-Title', 'PapichWheel AI Tester')
        $Content = [System.Net.Http.ByteArrayContent]::new($RequestBytes)
        $Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
        $Content.Headers.ContentType.CharSet = 'utf-8'
        $Request.Content = $Content
        $Cancellation = [System.Threading.CancellationTokenSource]::new()
        $Cancellation.CancelAfter([TimeSpan]::FromSeconds(60))
        try {
            $Response = $Client.SendAsync($Request, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $Cancellation.Token).GetAwaiter().GetResult()
            $ResponseBytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        }
        catch [System.OperationCanceledException] { Throw-TesterError 'OPENROUTER_TIMEOUT' 'OpenRouter request timed out.' 504 $true $false 0 }
        catch [System.Net.Http.HttpRequestException] { Throw-TesterError 'OPENROUTER_NETWORK_ERROR' 'OpenRouter transport failed.' 502 $true $false 0 }
        if ($ResponseBytes.Length -gt $script:MaxResponseBodyBytes) { Throw-TesterError 'OPENROUTER_RESPONSE_TOO_LARGE' 'OpenRouter response is too large.' 502 $false $false }
        if (-not $Response.IsSuccessStatusCode) {
            $Status = [int]$Response.StatusCode
            $RetryAfter = Get-RetryAfterSeconds $Response
            $Critical = $Status -eq 401 -or $Status -eq 403
            $Retryable = $Status -eq 429 -or $Status -ge 500
            $Code = "OPENROUTER_HTTP_$Status"
            $Message = if ($Critical) { 'OpenRouter rejected the API key.' } elseif ($Status -eq 429) { 'OpenRouter rate limit reached.' } elseif ($Status -ge 500) { 'OpenRouter is temporarily unavailable.' } else { "OpenRouter returned HTTP $Status." }
            $Details = Get-OpenRouterErrorDetails $ResponseBytes $Model $PromptMetadata ([long]$Stopwatch.ElapsedMilliseconds)
            Throw-TesterError $Code $Message $Status $Retryable $Critical $RetryAfter $Details
        }
        try { $ResponseText = $script:StrictUtf8.GetString($ResponseBytes).TrimStart([char]0xFEFF) }
        catch { Throw-TesterError 'AI_RESPONSE_ENCODING_ERROR' 'OpenRouter returned invalid UTF-8.' 502 $false $false }
        try { $Envelope = $ResponseText | ConvertFrom-Json }
        catch { Throw-TesterError 'OPENROUTER_ENVELOPE_INVALID' 'OpenRouter returned invalid JSON.' 502 $false $false }
        $Choices = @(Get-OptionalProperty $Envelope 'choices' @())
        if ($Choices.Count -lt 1) { Throw-TesterError 'AI_CONTENT_MISSING' 'OpenRouter response has no choices.' 502 $false $false }
        $Usage = Get-OptionalProperty $Envelope 'usage' $null
        $PromptTokens = if ($Usage) { [int](Get-OptionalProperty $Usage 'prompt_tokens' 0) } else { 0 }
        $CompletionTokens = if ($Usage) { [int](Get-OptionalProperty $Usage 'completion_tokens' 0) } else { 0 }
        $CachedTokens = 0
        $PromptTokenDetails = Get-OptionalProperty $Usage 'prompt_tokens_details' $null
        if ($PromptTokenDetails) { $CachedTokens = [int](Get-OptionalProperty $PromptTokenDetails 'cached_tokens' 0) }
        $Cost = $null
        $RawCost = Get-OptionalProperty $Usage 'cost' $null
        if ($null -ne $RawCost) { try { $Cost = [double]$RawCost } catch {} }
        $ResponseModel = [string](Get-OptionalProperty $Envelope 'model' '')
        $ResponseProvider = [string](Get-OptionalProperty $Envelope 'provider' '')
        $RequestId = [string](Get-OptionalProperty $Envelope 'id' '')
        $FinishReason = [string](Get-OptionalProperty $Choices[0] 'finish_reason' '')
        $RawContent = ''
        try {
            $RawContent = Get-MessageContentText (Get-OptionalProperty $Choices[0] 'message' $null)
            if ($RawContent.Length -gt $script:MaxRawContentChars) { Throw-TesterError 'AI_CONTENT_TOO_LARGE' 'Structured AI content is too large.' 502 $false $false }
            $Parsed = ConvertFrom-StructuredContent $RawContent
            $Validated = Validate-ExperimentalResponse $Parsed
        }
        catch {
            if ($_.Exception.Data.Contains('TesterCode')) {
                $StructuredCode = [string]$_.Exception.Data['TesterCode']
                $TransientStructuredFailure = $StructuredCode -in @(
                    'AI_CONTENT_MISSING',
                    'AI_RESPONSE_PARSE_ERROR',
                    'AI_SCHEMA_VALIDATION_ERROR'
                ) -and (
                    $FinishReason -eq 'error' -or
                    $CompletionTokens -eq 0 -or
                    [string]::IsNullOrWhiteSpace($RawContent)
                )
                if ($TransientStructuredFailure) {
                    $_.Exception.Data['Retryable'] = $true
                    $_.Exception.Data['RetryAfterSeconds'] = 1
                }
                $_.Exception.Data['Details'] = [ordered]@{
                    requestId = $RequestId
                    model = if ([string]::IsNullOrWhiteSpace($ResponseModel)) { $Model } else { $ResponseModel }
                    provider = if ([string]::IsNullOrWhiteSpace($ResponseProvider)) { 'openrouter' } else { $ResponseProvider }
                    finishReason = $FinishReason
                    promptFingerprint = $PromptMetadata.fingerprint
                    latencyMs = [long]$Stopwatch.ElapsedMilliseconds
                    rawAiContent = $RawContent
                    usage = [ordered]@{ promptTokens = $PromptTokens; completionTokens = $CompletionTokens; cachedTokens = $CachedTokens; cost = $Cost }
                }
            }
            throw
        }
        $Stopwatch.Stop()
        Write-TesterLog 'INFO' "OpenRouter request completed; status=200 bytes=$($ResponseBytes.Length) latencyMs=$($Stopwatch.ElapsedMilliseconds)"
        $ResultPromptMetadata = [ordered]@{
            version = $PromptMetadata.version
            fingerprint = $PromptMetadata.fingerprint
            characterCount = $PromptMetadata.characterCount
        }
        return [ordered]@{
            ok = $true
            aiResponse = $Validated
            rawAiContent = $RawContent
            catalogResults = [ordered]@{}
            usage = [ordered]@{ promptTokens = $PromptTokens; completionTokens = $CompletionTokens; cachedTokens = $CachedTokens; cost = $Cost }
            model = if ([string]::IsNullOrWhiteSpace($ResponseModel)) { $Model } else { $ResponseModel }
            provider = if ([string]::IsNullOrWhiteSpace($ResponseProvider)) { 'openrouter' } else { $ResponseProvider }
            requestId = $RequestId
            latencyMs = [long]$Stopwatch.ElapsedMilliseconds
            prompt = $ResultPromptMetadata
        }
    }
    finally {
        $Stopwatch.Stop()
        if ($Cancellation) { $Cancellation.Dispose() }
        if ($Response) { $Response.Dispose() }
        if ($Request) { $Request.Dispose() }
        if ($Client) { $Client.Dispose() }
        if ($Handler) { $Handler.Dispose() }
    }
}

function Test-DonationInput {
    param([object]$Donation)
    if (-not $Donation) { Throw-TesterError 'INVALID_DONATION' 'Donation is missing.' 400 $false $false }
    $Name = [string]$Donation.name
    $Message = [string]$Donation.message
    $Currency = [string]$Donation.currency
    if ($Name.Length -gt $script:MaxDonationNameChars -or [string]::IsNullOrWhiteSpace($Message) -or $Message.Length -gt $script:MaxDonationMessageChars) {
        Throw-TesterError 'INVALID_DONATION' 'Donation fields are invalid.' 400 $false $false
    }
    if ($Currency -notmatch '^[A-Z]{3,12}$') { Throw-TesterError 'INVALID_DONATION' 'Donation currency is invalid.' 400 $false $false }
    if ($Donation.amount -is [bool]) { Throw-TesterError 'INVALID_DONATION' 'Donation amount is invalid.' 400 $false $false }
    try { $Amount = [Convert]::ToDouble($Donation.amount, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { Throw-TesterError 'INVALID_DONATION' 'Donation amount is invalid.' 400 $false $false }
    if ([double]::IsNaN($Amount) -or [double]::IsInfinity($Amount) -or $Amount -lt 0 -or $Amount -gt 1000000000) { Throw-TesterError 'INVALID_DONATION' 'Donation amount is invalid.' 400 $false $false }
    return [ordered]@{ name = $Name; amount = $Amount; currency = $Currency; message = $Message }
}

function Test-TokenEqual {
    param([string]$Left, [string]$Right)
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    $Difference = 0
    for ($Index = 0; $Index -lt $Left.Length; $Index++) { $Difference = $Difference -bor ([int]$Left[$Index] -bxor [int]$Right[$Index]) }
    return $Difference -eq 0
}

function Read-HttpRequest {
    param([System.Net.Sockets.NetworkStream]$Stream)
    $Stream.ReadTimeout = 15000
    $HeaderBytes = New-Object System.Collections.Generic.List[byte]
    $Last = New-Object byte[] 4
    while ($HeaderBytes.Count -lt 32768) {
        $Value = $Stream.ReadByte()
        if ($Value -lt 0) { return $null }
        $Byte = [byte]$Value
        $HeaderBytes.Add($Byte)
        $Count = $HeaderBytes.Count
        if ($Count -ge 4 -and $HeaderBytes[$Count - 4] -eq 13 -and $HeaderBytes[$Count - 3] -eq 10 -and $HeaderBytes[$Count - 2] -eq 13 -and $HeaderBytes[$Count - 1] -eq 10) { break }
    }
    if ($HeaderBytes.Count -ge 32768) { Throw-TesterError 'REQUEST_HEADERS_TOO_LARGE' 'Request headers are too large.' 431 $false $false }
    $HeaderText = [System.Text.Encoding]::ASCII.GetString($HeaderBytes.ToArray())
    $Lines = $HeaderText -split "`r`n"
    $RequestLine = $Lines[0].Split(' ')
    if ($RequestLine.Count -lt 2) { Throw-TesterError 'BAD_REQUEST' 'Malformed request line.' 400 $false $false }
    $Headers = @{}
    for ($Index = 1; $Index -lt $Lines.Count; $Index++) {
        $Line = $Lines[$Index]
        if ([string]::IsNullOrEmpty($Line)) { break }
        $Colon = $Line.IndexOf(':')
        if ($Colon -le 0) { continue }
        $Headers[$Line.Substring(0, $Colon).Trim().ToLowerInvariant()] = $Line.Substring($Colon + 1).Trim()
    }
    $ContentLength = 0
    if ($Headers.ContainsKey('content-length')) {
        if (-not [int]::TryParse($Headers['content-length'], [ref]$ContentLength) -or $ContentLength -lt 0 -or $ContentLength -gt $script:MaxRequestBodyBytes) {
            Throw-TesterError 'REQUEST_BODY_TOO_LARGE' 'Request body is too large.' 413 $false $false
        }
    }
    $Body = New-Object byte[] $ContentLength
    $Offset = 0
    while ($Offset -lt $ContentLength) {
        $Read = $Stream.Read($Body, $Offset, $ContentLength - $Offset)
        if ($Read -le 0) { Throw-TesterError 'BAD_REQUEST' 'Request body ended early.' 400 $false $false }
        $Offset += $Read
    }
    $Target = $RequestLine[1]
    $Question = $Target.IndexOf('?')
    if ($Question -ge 0) { $Target = $Target.Substring(0, $Question) }
    return @{ method = $RequestLine[0].ToUpperInvariant(); path = $Target; headers = $Headers; body = $Body }
}

function Get-StatusText {
    param([int]$Status)
    switch ($Status) { 200 { 'OK' } 204 { 'No Content' } 400 { 'Bad Request' } 401 { 'Unauthorized' } 403 { 'Forbidden' } 404 { 'Not Found' } 413 { 'Payload Too Large' } 422 { 'Unprocessable Entity' } 429 { 'Too Many Requests' } 431 { 'Request Header Fields Too Large' } 500 { 'Internal Server Error' } 502 { 'Bad Gateway' } 503 { 'Service Unavailable' } 504 { 'Gateway Timeout' } default { 'Error' } }
}

function Send-HttpResponse {
    param([System.Net.Sockets.NetworkStream]$Stream, [int]$Status, [byte[]]$Body, [string]$ContentType = 'application/json; charset=utf-8')
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    $Header = "HTTP/1.1 $Status $(Get-StatusText $Status)`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`r`nConnection: close`r`n`r`n"
    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Header)
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-JsonResponse {
    param([System.Net.Sockets.NetworkStream]$Stream, [int]$Status, [object]$Value)
    Send-HttpResponse $Stream $Status (ConvertTo-StrictJsonBytes $Value 30)
}

function Test-ApiRequestAuthorized {
    param([hashtable]$Request)
    $Origin = [string]$Request.headers['origin']
    if (-not [string]::IsNullOrWhiteSpace($Origin) -and $Origin -ne "http://127.0.0.1:$Port") { return $false }
    return Test-TokenEqual ([string]$Request.headers['x-ai-tester-token']) $script:ApiToken
}

function Handle-ApiRequest {
    param([hashtable]$Request, [System.Net.Sockets.NetworkStream]$Stream)
    if ($Request.path -eq '/api/health' -and $Request.method -eq 'GET') {
        Send-JsonResponse $Stream 200 @{ ok = $true; server = 'papich-wheel-ai-tester'; port = $Port }
        return
    }
    if (-not (Test-ApiRequestAuthorized $Request)) { Send-JsonResponse $Stream 403 @{ ok = $false; error = @{ code = 'FORBIDDEN'; message = 'Forbidden.' } }; return }
    if ($Request.path -eq '/api/status' -and $Request.method -eq 'GET') {
        $Configuration = Get-OpenRouterConfiguration
        Send-JsonResponse $Stream 200 @{ ok = $true; openrouterConfigured = -not [string]::IsNullOrWhiteSpace([string]$Configuration.apiKey); prompt = Get-PromptMetadata (Get-ExperimentalPrompt); modelDefault = 'google/gemini-3-flash-preview' }
        return
    }
    if ($Request.path -eq '/api/prompt' -and $Request.method -eq 'GET') { Send-JsonResponse $Stream 200 @{ ok = $true; prompt = Get-PromptMetadata (Get-ExperimentalPrompt) }; return }
    if ($Request.path -eq '/api/prompt/save' -and $Request.method -eq 'POST') {
        $InputData = ConvertFrom-StrictJsonBytes $Request.body
        $Text = [string]$InputData.text
        if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt $script:MaxPromptChars -or $Text.Contains([char]0)) { Throw-TesterError 'INVALID_PROMPT' 'Prompt is empty or too large.' 400 $false $false }
        Write-TextAtomic $script:SavedPromptPath $Text
        Send-JsonResponse $Stream 200 @{ ok = $true; prompt = Get-PromptMetadata $Text }
        return
    }
    if ($Request.path -eq '/api/prompt/reset' -and $Request.method -eq 'POST') {
        if ([System.IO.File]::Exists($script:SavedPromptPath)) { [System.IO.File]::Delete($script:SavedPromptPath) }
        $Text = Get-ExperimentalPrompt
        Send-JsonResponse $Stream 200 @{ ok = $true; prompt = Get-PromptMetadata $Text }
        return
    }
    if ($Request.path -eq '/api/analyze' -and $Request.method -eq 'POST') {
        $InputData = ConvertFrom-StrictJsonBytes $Request.body
        $Donation = Test-DonationInput $InputData.donation
        $Model = [string]$InputData.model
        if ($Model -notmatch '^[A-Za-z0-9._:/-]{1,120}$') { Throw-TesterError 'INVALID_MODEL' 'Model name is invalid.' 400 $false $false }
        Send-JsonResponse $Stream 200 (Invoke-ExperimentalOpenRouter $Donation $Model)
        return
    }
    Send-JsonResponse $Stream 404 @{ ok = $false; error = @{ code = 'NOT_FOUND'; message = 'Not found.' } }
}

function Handle-Client {
    param([System.Net.Sockets.TcpClient]$Client)
    $Stream = $null
    try {
        if (-not [System.Net.IPAddress]::IsLoopback($Client.Client.RemoteEndPoint.Address)) { return }
        $Stream = $Client.GetStream()
        $Request = Read-HttpRequest $Stream
        if (-not $Request) { return }
        if ($Request.path.StartsWith('/api/')) { Handle-ApiRequest $Request $Stream; return }
        if ($Request.method -ne 'GET') { Send-JsonResponse $Stream 404 @{ ok = $false; error = @{ code = 'NOT_FOUND'; message = 'Not found.' } }; return }
        if ($Request.path -eq '/' -or $Request.path -eq '/ai_tester.html') {
            $Html = Read-TextUtf8 $script:HtmlPath
            $Html = $Html.Replace('__AI_TESTER_TOKEN__', $script:ApiToken)
            Send-HttpResponse $Stream 200 ($script:StrictUtf8.GetBytes($Html)) 'text/html; charset=utf-8'
            return
        }
        if ($Request.path -eq '/ai_tester_logic.js') { Send-HttpResponse $Stream 200 ([System.IO.File]::ReadAllBytes($script:LogicPath)) 'application/javascript; charset=utf-8'; return }
        if ($Request.path -eq '/favicon.ico') { Send-HttpResponse $Stream 204 (New-Object byte[] 0) 'image/x-icon'; return }
        Send-JsonResponse $Stream 404 @{ ok = $false; error = @{ code = 'NOT_FOUND'; message = 'Not found.' } }
    }
    catch {
        $Exception = $_.Exception
        $Code = if ($Exception.Data.Contains('TesterCode')) { [string]$Exception.Data['TesterCode'] } else { 'INTERNAL_ERROR' }
        $Status = if ($Exception.Data.Contains('HttpStatus')) { [int]$Exception.Data['HttpStatus'] } else { 500 }
        $Retryable = if ($Exception.Data.Contains('Retryable')) { [bool]$Exception.Data['Retryable'] } else { $false }
        $Critical = if ($Exception.Data.Contains('Critical')) { [bool]$Exception.Data['Critical'] } else { $false }
        $RetryAfter = if ($Exception.Data.Contains('RetryAfterSeconds')) { [int]$Exception.Data['RetryAfterSeconds'] } else { 0 }
        $Details = if ($Exception.Data.Contains('Details')) { $Exception.Data['Details'] } else { $null }
        $Message = if ($Code -eq 'INTERNAL_ERROR') { 'AI tester server failed.' } else { [string]$Exception.Message }
        Write-TesterLog 'WARN' "request failed; code=$Code status=$Status"
        if ($Stream) {
            try {
                $ErrorPayload = [ordered]@{ code = $Code; message = $Message; retryable = $Retryable; critical = $Critical; retryAfterSeconds = $RetryAfter }
                if ($null -ne $Details) { $ErrorPayload['details'] = $Details }
                Send-JsonResponse $Stream $Status @{ ok = $false; error = $ErrorPayload }
            }
            catch {}
        }
    }
    finally {
        if ($Stream) { $Stream.Dispose() }
        $Client.Close()
    }
}

foreach ($RequiredPath in @($script:HtmlPath, $script:LogicPath, $script:DefaultPromptPath, $script:SchemaPath)) {
    if (-not [System.IO.File]::Exists($RequiredPath)) { throw "Required AI tester file not found: $RequiredPath" }
}

if ($SelfTest) {
    $Prompt = Get-ExperimentalPrompt
    if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'Default prompt is empty.' }
    $Schema = (Read-TextUtf8 $script:SchemaPath) | ConvertFrom-Json
    if (-not $Schema.properties.items) { throw 'Experimental schema is invalid.' }
    $ProviderSchema = Get-PortableStructuredSchema $Schema
    $ProviderSchemaJson = $ProviderSchema | ConvertTo-Json -Depth 30 -Compress
    foreach ($UnsupportedKeyword in @('$schema', 'minLength', 'maxLength', 'uniqueItems')) {
        if ($ProviderSchemaJson.Contains(('"' + $UnsupportedKeyword + '"'))) { throw "Portable schema still contains unsupported keyword: $UnsupportedKeyword" }
    }
    if (-not $ProviderSchema.properties.items.maxItems -or -not $ProviderSchema.properties.items.items.additionalProperties.Equals($false)) {
        throw 'Portable schema lost required structural constraints.'
    }
    $Mock = '{"items":[{"category":"game","mentionedTitle":"test","displayTitle":"Test","searchQueries":["Test"],"originalLanguage":"en","confidence":0.5,"reason":"Test result."}]}'
    $Validated = Validate-ExperimentalResponse (ConvertFrom-StructuredContent $Mock)
    if ($Validated.items.Count -ne 1 -or $Validated.items[0].confidence -ne 0.5) { throw 'Response validator self-test failed.' }
    $MultipleMock = '{"items":[{"category":"game","mentionedTitle":"one","displayTitle":"One","searchQueries":["One"],"originalLanguage":"en","confidence":0.8,"reason":"First result."},{"category":"movie","mentionedTitle":"two","displayTitle":"Two","searchQueries":["Two"],"originalLanguage":"en","confidence":0.7,"reason":"Second result."}]}'
    $MultipleValidated = Validate-ExperimentalResponse (ConvertFrom-StructuredContent $MultipleMock)
    if ($MultipleValidated.items.Count -ne 2) { throw 'Multiple-item response validator self-test failed.' }
    $DuplicateQueryMock = '{"items":[{"category":"game","mentionedTitle":"test","displayTitle":"Test","searchQueries":["Test","test"],"originalLanguage":"en","confidence":0.5,"reason":"Duplicate query result."}]}'
    $DuplicateQueryValidated = Validate-ExperimentalResponse (ConvertFrom-StructuredContent $DuplicateQueryMock)
    if ($DuplicateQueryValidated.items[0].searchQueries.Count -ne 1) { throw 'Duplicate search query normalization self-test failed.' }
    Write-Host 'AI tester server self-test ok'
    return
}

Ensure-TesterDataDirectory
$script:ApiToken = New-RandomToken
$script:Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
    try { $script:Listener.Start() }
    catch [System.Net.Sockets.SocketException] { throw "AI tester could not bind 127.0.0.1:$Port. The port may already be in use." }
    $Url = "http://127.0.0.1:$Port/"
    Write-Host "PapichWheel AI tester is running at $Url"
    Write-Host 'Press Ctrl+C to stop.'
    if (-not $NoOpenBrowser) { try { Start-Process $Url } catch { Write-Host "Open this URL manually: $Url" } }
    while ($true) {
        $Client = $script:Listener.AcceptTcpClient()
        Handle-Client $Client
    }
}
finally {
    if ($script:Listener) { $script:Listener.Stop() }
}
