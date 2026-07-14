param()

$ErrorActionPreference = 'Stop'
$ServerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'local_server.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($ServerPath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) {
    throw "local_server.ps1 parse failed: $($ParseErrors[0].Message)"
}
# GitHub Actions checks out text files with CRLF on Windows. Normalize only the
# in-memory test fixture so source-contract assertions are platform-independent.
$ServerSource = [System.IO.File]::ReadAllText($ServerPath, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")

$FunctionNames = @(
    'Mask-SecretText',
    'Limit-LogText',
    'Normalize-LotTitle',
    'Test-SensitiveLocalApiPath',
    'Test-AllowedStaticPath',
    'Test-AllowedHostHeader',
    'Test-RequestContentLengthAllowed',
    'Get-LotTitleTokens',
    'Test-ValidRomanNumeral',
    'Test-LotVariantToken',
    'Get-LotVariantTokens',
    'Get-NormalizedEditSimilarity',
    'Compare-LotTitles',
    'Normalize-LotCategory',
    'Test-LotCategoriesCompatible',
    'Get-TokenSimilarity',
    'Find-ExistingEntryMatch',
    'Find-EliminatedEntryMatch',
    'Search-ExistingEntryByCandidate',
    'Test-EliminatedEntryByCandidate',
    'Get-CandidateComparableTitles',
    'Test-CandidateQualifierConflict',
    'Test-FranchiseVariantAlternative',
    'Get-UniqueExactCatalogCandidate',
    'Test-CatalogCandidatesAmbiguous',
    'Test-LlmIntentReadyForCatalog',
    'New-LlmCodedException',
    'Throw-LlmError',
    'ConvertTo-LlmConfidence',
    'Get-LlmExceptionCode',
    'Test-LlmTransientNetworkException',
    'Get-LlmFailureClassification',
    'Ensure-SecretsDirectory',
    'Ensure-CacheDirectory',
    'Protect-SecretString',
    'Unprotect-SecretString',
    'New-EmptySecretsData',
    'Read-SecretsFile',
    'Write-SecretsFile',
    'Get-IntegrationSecretNode',
    'Get-IntegrationSecret',
    'Get-DonationAlertsStoredToken',
    'Get-DonationAlertsTokenFingerprint',
    'Set-DonationAlertsStoredTokenAndResetCurrency',
    'Get-DonationAlertsStoredUserCurrency',
    'Set-DonationAlertsStoredUserCurrencyForToken',
    'Get-AppResetEpoch',
    'Set-NewAppResetEpoch',
    'Read-JsonFileSafe',
    'Enter-NamedMutex',
    'Exit-NamedMutex',
    'Write-JsonFileSafe',
    'New-EmptyCollectorStateStore',
    'Get-CollectorStateSnapshot',
    'Save-CollectorState',
    'Restore-CollectorState',
    'Normalize-CurrencyCode',
    'Convert-CurrencyDecimal',
    'New-UnavailableCurrencyRateSnapshot',
    'Test-CurrencyRateSnapshot',
    'Convert-CbrCurrencyXml',
    'Get-CachedCurrencyRateSnapshot',
    'Initialize-CurrencyRates',
    'Get-CurrencyRateStatus',
    'Convert-DonationAlertsAmountToRub',
    'Get-SteamSearchCache',
    'Get-SteamSearchCachedCandidates',
    'Set-SteamSearchCachedCandidates',
    'New-EmptyLlmJobsStore',
    'Read-LlmJobsStoreUnsafe',
    'Write-LlmJobsStoreUnsafe',
    'Write-LlmJobsStoreOrThrow',
    'Get-NextLlmRevision',
    'Get-LlmAnalysisKey',
    'New-LlmJobId',
    'Get-SafeEntriesForLlm',
    'New-LlmJobFromInput',
    'Add-OrGet-LlmJob',
    'Test-LlmGenerationCurrent',
    'Test-LlmJobGenerationCurrent',
    'Complete-LlmJob',
    'Clear-LlmSearchCaches',
    'Get-NumericDonationId',
    'Get-LastSeenIdValue',
    'Get-DonationKey',
    'Get-FirstPresentValue',
    'Get-DonationAmountValue',
    'Convert-DonationDateToIso',
    'Get-DonationAlertsProfileCurrency',
    'Get-DonationAlertsUserCurrency',
    'Convert-DonationAlertsRow',
    'Convert-DonatePayNotificationRow',
    'Apply-DonationAlertsCollectorResult',
    'Get-DonatePayRecoveryRequestContext',
    'Get-CollectorIdentitySignature',
    'Pause-CollectorRuntimePreserveCursor',
    'Resume-CollectorRuntimePreserveCursor',
    'Stop-CollectorRuntime',
    'Clear-CollectorPendingDonations',
    'Clear-LlmAuctionData'
)

$Definitions = $Ast.FindAll({
    param($Node)
    $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)

foreach ($Name in $FunctionNames) {
    $Definition = @($Definitions | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)[0]
    if (-not $Definition) { throw "Missing function under test: $Name" }
    Invoke-Expression $Definition.Extent.Text
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'" }
}

$OriginalTestCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    $JsonConfidence = '{"intentConfidence":0.85}' | ConvertFrom-Json
    Assert-Equal (ConvertTo-LlmConfidence $JsonConfidence.intentConfidence) ([double]0.85) 'ConvertFrom-Json confidence failed under ru-RU.'
    Assert-Equal (ConvertTo-LlmConfidence ([double]0.85)) ([double]0.85) 'Numeric confidence failed under ru-RU.'
    Assert-Equal (ConvertTo-LlmConfidence '0.85') ([double]0.85) 'Invariant confidence string failed under ru-RU.'
    Assert-Equal (ConvertTo-LlmConfidence 0) ([double]0) 'Zero confidence boundary failed.'
    Assert-Equal (ConvertTo-LlmConfidence 1) ([double]1) 'One confidence boundary failed.'
    Assert-True ($null -eq (ConvertTo-LlmConfidence '0,85')) 'Localized confidence string must be rejected.'
    Assert-True ($null -eq (ConvertTo-LlmConfidence -0.01)) 'Negative confidence must be rejected.'
    Assert-True ($null -eq (ConvertTo-LlmConfidence 1.01)) 'Confidence greater than one must be rejected.'
    Assert-True ($null -eq (ConvertTo-LlmConfidence $true)) 'Boolean confidence must be rejected.'
    Assert-True ($null -eq (ConvertTo-LlmConfidence $null)) 'Null confidence must be rejected.'
    Assert-True ($null -eq (ConvertTo-LlmConfidence ([double]::NaN))) 'NaN confidence must be rejected.'
    Assert-True ($null -eq (ConvertTo-LlmConfidence ([double]::PositiveInfinity))) 'Infinite confidence must be rejected.'
}
finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $OriginalTestCulture
}
Assert-Equal ([Threading.Thread]::CurrentThread.CurrentCulture.Name) $OriginalTestCulture.Name 'Confidence tests did not restore the original culture.'

$IntentFunctionStart = $ServerSource.IndexOf('function Invoke-OpenRouterIntentAnalysis')
$IntentFunctionEnd = $ServerSource.IndexOf('function Invoke-OpenRouterCandidateSelection', $IntentFunctionStart)
$IntentFunctionSource = $ServerSource.Substring($IntentFunctionStart, $IntentFunctionEnd - $IntentFunctionStart)
Assert-True ($IntentFunctionSource.Contains('ConvertTo-LlmConfidence $Result.intentConfidence')) 'Intent analysis does not use the shared confidence validator.'
Assert-True ($IntentFunctionSource.Contains('$Result.intentConfidence = [double]$Confidence')) 'Intent confidence is not normalized back to double.'
$SelectionFunctionStart = $IntentFunctionEnd
$SelectionFunctionEnd = $ServerSource.IndexOf('function Test-OpenRouterIntegration', $SelectionFunctionStart)
$SelectionFunctionSource = $ServerSource.Substring($SelectionFunctionStart, $SelectionFunctionEnd - $SelectionFunctionStart)
Assert-True ($SelectionFunctionSource.Contains('ConvertTo-LlmConfidence $Selection.selectionConfidence')) 'Candidate selection does not use the shared confidence validator.'
Assert-True ($SelectionFunctionSource.Contains('$Selection.selectionConfidence = [double]$SelectionConfidence')) 'Selection confidence is not normalized back to double.'
$OpenRouterTestStart = $SelectionFunctionEnd
$OpenRouterTestEnd = $ServerSource.IndexOf('function Assert-LlmJobGenerationCurrent', $OpenRouterTestStart)
$OpenRouterTestSource = $ServerSource.Substring($OpenRouterTestStart, $OpenRouterTestEnd - $OpenRouterTestStart)
Assert-True ($OpenRouterTestSource.Contains('intentConfidence 0.5')) 'OpenRouter integration test does not request fractional confidence.'
Assert-True ($OpenRouterTestSource.Contains('ConvertTo-LlmConfidence $Parsed.intentConfidence')) 'OpenRouter integration test bypasses the shared confidence validator.'

function Write-AppLog {
    param([string]$Level = 'INFO', [string]$Message = '')
}

Assert-True (Test-SensitiveLocalApiPath '/api/collector/pause') 'Collector pause endpoint must require X-Local-App-Token.'
Assert-True (Test-SensitiveLocalApiPath '/api/collector/resume') 'Collector resume endpoint must require X-Local-App-Token.'
Assert-True (Test-SensitiveLocalApiPath '/api/app/reset') 'Full reset endpoint must require X-Local-App-Token.'
Assert-True (Test-SensitiveLocalApiPath '/api/currency/status') 'Currency status endpoint must require X-Local-App-Token.'
Assert-False (Test-SensitiveLocalApiPath '/api/health') 'Health endpoint should remain open.'
Assert-Equal ([regex]::Matches($ServerSource, '\[void\]\(Write-LlmJobsStoreUnsafe').Count) 0 'An AI job transition still ignores a failed disk write.'
Assert-True ($ServerSource.Contains('Start-DonationAlertsPollRunspace $PollInput')) 'Routine DonationAlerts polling still runs inside the HTTP request loop.'
Assert-True ($ServerSource.Contains('$ExpectedRuntimeGeneration -ne $script:CollectorRuntimeGeneration')) 'DonationAlerts accepts a poll result started before collector pause/clear.'
Assert-True ($ServerSource.Contains('$Result = Queue-DonatePayRecoveryRequest $InputData')) 'DonatePay recovery still blocks the HTTP request loop.'
Assert-True ($ServerSource.Contains('[long]$Context.auctionGeneration -ne $CurrentGeneration')) 'DonatePay recovery result is not protected by auction generation.'
Assert-True ($ServerSource.Contains('[string]$Context.tokenFingerprint -cne $CurrentFingerprint')) 'DonatePay recovery result is not protected against token replacement.'
Assert-True ($ServerSource.Contains('Stop-DonationAlertsPollRunspace $script:DonationAlertsPollHandle')) 'Full reset or shutdown can leave a DonationAlerts poll worker running.'
Assert-True ($ServerSource.Contains('Stop-DonatePayRecoveryRunspace $script:DonatePayRecoveryHandle')) 'Full reset or shutdown can leave a DonatePay recovery worker running.'
Assert-False ($ServerSource.Contains('[void](Set-DonatePayStoredToken $IncomingAccessToken)')) 'Collector runtime can accept a DonatePay token whose secure write failed.'
$OpenRouterDisconnectStart = $ServerSource.IndexOf('"/api/integrations/openrouter/disconnect"')
$OpenRouterDisconnectEnd = $ServerSource.IndexOf('default {', $OpenRouterDisconnectStart)
$OpenRouterDisconnectSource = $ServerSource.Substring($OpenRouterDisconnectStart, $OpenRouterDisconnectEnd - $OpenRouterDisconnectStart)
Assert-True ($OpenRouterDisconnectSource.Contains('Remove-OpenRouterStoredConfiguration')) 'OpenRouter key and proxy are not removed atomically.'
Assert-True (Test-AllowedStaticPath '/') 'Root page must remain publicly servable.'
Assert-True (Test-AllowedStaticPath '/koleso_papich.html') 'Application HTML must remain publicly servable.'
Assert-True (Test-AllowedStaticPath '/centrifuge.min.js') 'Local Centrifuge asset must remain publicly servable.'
foreach ($PrivatePath in @('/server.log', '/local_server.ps1', '/build_release_single_bat.ps1', '/.papich_git/config', '/secrets.json')) {
    Assert-False (Test-AllowedStaticPath $PrivatePath) "Private file path must not be served: $PrivatePath"
}
Assert-True (Test-AllowedHostHeader '127.0.0.1:5500' 5500) 'Loopback IPv4 Host header was rejected.'
Assert-True (Test-AllowedHostHeader 'LOCALHOST:5500' 5500) 'Case-insensitive localhost Host header was rejected.'
Assert-False (Test-AllowedHostHeader 'attacker.example' 5500) 'Foreign Host header was accepted.'
Assert-True (Test-RequestContentLengthAllowed 0 1024) 'Empty request body was rejected.'
Assert-True (Test-RequestContentLengthAllowed 1024 1024) 'Maximum allowed request body was rejected.'
Assert-False (Test-RequestContentLengthAllowed 1025 1024) 'Oversized request body was accepted.'
$MaskedProxy = Mask-SecretText 'proxy=http://alice:super-secret@127.0.0.1:7890'
Assert-False ($MaskedProxy.Contains('super-secret')) 'Proxy password was not masked.'
Assert-True ($MaskedProxy.Contains('alice:***@')) 'Proxy userinfo masking removed the safe username or marker.'
Assert-True ($ServerSource.Contains('Cache-Control: no-store, max-age=0')) 'Sensitive local responses may still be cached.'
Assert-True ($ServerSource.Contains('X-Content-Type-Options: nosniff')) 'nosniff is missing from local responses.'
Assert-True ($ServerSource.Contains('$Stream.ReadTimeout = $script:ClientIoTimeoutMs')) 'Local HTTP clients can hold the single request loop open indefinitely.'
Assert-True ($ServerSource.Contains('$Stream.WriteTimeout = $script:ClientIoTimeoutMs')) 'Local HTTP writes have no timeout.'
Assert-False ($ServerSource.Contains('raw = $Raw')) 'Full upstream donation payload is still persisted server-side.'

$TempSecretsDir = Join-Path ([System.IO.Path]::GetTempPath()) "papich-da-secrets-$([Guid]::NewGuid().ToString('N'))"
try {
    $script:SecretsDir = $TempSecretsDir
    $script:SecretsPath = Join-Path $TempSecretsDir 'secrets.json'
    $script:SecretsMutexName = "PapichWheelSecretsTest-$([Guid]::NewGuid().ToString('N'))"
    $script:StateLock = [object]::new()
    $script:ServerState = @{
        Integrations = @{
            DonationAlerts = @{
                AccessToken = ''
                UserCurrency = ''
                Signature = ''
            }
        }
    }
    $TokenA = 'test-da-account-a'
    $TokenB = 'test-da-account-b'
    $FingerprintA = Get-DonationAlertsTokenFingerprint $TokenA
    $FingerprintB = Get-DonationAlertsTokenFingerprint $TokenB
    Assert-Equal $FingerprintA.Length 24 'DonationAlerts token fingerprint has the wrong bounded length.'
    Assert-False ($FingerprintA.Contains($TokenA)) 'DonationAlerts fingerprint exposes the source token.'

    Assert-True (Set-DonationAlertsStoredTokenAndResetCurrency -AccessToken $TokenA -UpdateRuntime) 'Could not save test DonationAlerts token A.'
    Assert-True (Set-DonationAlertsStoredUserCurrencyForToken -Currency 'RUB' -AccessToken $TokenA -ExpectedTokenFingerprint $FingerprintA -UpdateRuntime) 'Could not bind RUB profile currency to token A.'
    Assert-Equal (Get-DonationAlertsStoredUserCurrency) 'RUB' 'Fingerprint-matched profile currency was not loaded.'
    Assert-Equal $script:ServerState.Integrations.DonationAlerts.UserCurrency 'RUB' 'Runtime profile currency was not updated for token A.'

    Assert-True (Set-DonationAlertsStoredTokenAndResetCurrency -AccessToken $TokenB -UpdateRuntime) 'Could not atomically replace DonationAlerts token.'
    $SecretsAfterTokenB = Read-SecretsFile
    $NodeAfterTokenB = $SecretsAfterTokenB.integrations.donationalerts
    Assert-Equal (Unprotect-SecretString ([string]$NodeAfterTokenB.accessToken)) $TokenB 'Stored DonationAlerts token B is missing.'
    Assert-False ([bool]$NodeAfterTokenB.PSObject.Properties['userCurrency']) 'Old profile currency survived token replacement.'
    Assert-False ([bool]$NodeAfterTokenB.PSObject.Properties['userCurrencyTokenFingerprint']) 'Old currency fingerprint survived token replacement.'
    Assert-Equal $script:ServerState.Integrations.DonationAlerts.UserCurrency '' 'Runtime profile currency survived token replacement.'

    $TestRates = [pscustomobject]@{
        ok = $true; baseCurrency = 'RUB'; rates = [pscustomobject]@{ USD = [decimal]88.50; EUR = [decimal]87.75 };
        effectiveDate = '2026-07-13'; fetchedAt = '2026-07-13T10:00:00Z'; source = 'cbr'; stale = $false; error = ''
    }
    $BeforeProfileB = Convert-DonationAlertsAmountToRub -OriginalAmount 50 -OriginalCurrency 'EUR' -AmountInUserCurrency 999 -UserCurrency (Get-DonationAlertsStoredUserCurrency) -RateSnapshot $TestRates
    Assert-Equal $BeforeProfileB.conversionSource 'cbr' 'Old profile currency was used before token B profile validation.'

    Assert-False (Set-DonationAlertsStoredUserCurrencyForToken -Currency 'RUB' -AccessToken $TokenA -ExpectedTokenFingerprint $FingerprintA) 'Stale token A profile response was accepted after token B replacement.'
    Assert-Equal (Get-DonationAlertsStoredUserCurrency) '' 'Stale profile response populated token B currency.'
    Assert-True (Set-DonationAlertsStoredUserCurrencyForToken -Currency 'RUB' -AccessToken $TokenB -ExpectedTokenFingerprint $FingerprintB -UpdateRuntime) 'Could not bind profile currency to token B.'
    $AfterProfileB = Convert-DonationAlertsAmountToRub -OriginalAmount 50 -OriginalCurrency 'EUR' -AmountInUserCurrency 999 -UserCurrency (Get-DonationAlertsStoredUserCurrency) -RateSnapshot $TestRates
    Assert-Equal $AfterProfileB.amount ([decimal]999) 'Confirmed token B profile amount was not used.'
    Assert-Equal $AfterProfileB.conversionSource 'donationalerts' 'Confirmed token B profile has the wrong conversion source.'

    $MismatchedSecrets = Read-SecretsFile
    $MismatchedSecrets.integrations.donationalerts.userCurrencyTokenFingerprint = $FingerprintA
    Assert-True (Write-SecretsFile $MismatchedSecrets) 'Could not prepare mismatched fingerprint fixture.'
    Assert-Equal (Get-DonationAlertsStoredUserCurrency) '' 'Mismatched profile currency fingerprint was trusted.'
    $LegacySecrets = Read-SecretsFile
    $LegacySecrets.integrations.donationalerts.PSObject.Properties.Remove('userCurrencyTokenFingerprint')
    Assert-True (Write-SecretsFile $LegacySecrets) 'Could not prepare legacy currency fixture.'
    Assert-Equal (Get-DonationAlertsStoredUserCurrency) '' 'Legacy profile currency without fingerprint was trusted.'

    Assert-True (Set-DonationAlertsStoredTokenAndResetCurrency -AccessToken $TokenA -UpdateRuntime) 'Could not restore token A before atomic failure test.'
    Assert-True (Set-DonationAlertsStoredUserCurrencyForToken -Currency 'RUB' -AccessToken $TokenA -ExpectedTokenFingerprint $FingerprintA -UpdateRuntime) 'Could not restore token A profile before atomic failure test.'
    $SecretsBeforeFailure = [System.IO.File]::ReadAllText($script:SecretsPath, [System.Text.Encoding]::UTF8)
    $RuntimeTokenBeforeFailure = $script:ServerState.Integrations.DonationAlerts.AccessToken
    $RuntimeCurrencyBeforeFailure = $script:ServerState.Integrations.DonationAlerts.UserCurrency
    Assert-False (Set-DonationAlertsStoredTokenAndResetCurrency -AccessToken $TokenB -UpdateRuntime -WriteOperation { param($Secrets) return $false }) 'Failed atomic token write unexpectedly succeeded.'
    Assert-Equal ([System.IO.File]::ReadAllText($script:SecretsPath, [System.Text.Encoding]::UTF8)) $SecretsBeforeFailure 'Failed token write partially changed secrets.json.'
    Assert-Equal $script:ServerState.Integrations.DonationAlerts.AccessToken $RuntimeTokenBeforeFailure 'Failed token write changed runtime token.'
    Assert-Equal $script:ServerState.Integrations.DonationAlerts.UserCurrency $RuntimeCurrencyBeforeFailure 'Failed token write changed runtime currency.'
}
finally {
    if ([System.IO.Directory]::Exists($TempSecretsDir)) { [System.IO.Directory]::Delete($TempSecretsDir, $true) }
}

$TokenStorageFunctionStart = $ServerSource.IndexOf('function Set-DonationAlertsStoredTokenAndResetCurrency')
$TokenStorageFunctionEnd = $ServerSource.IndexOf('function Set-DonatePayStoredToken', $TokenStorageFunctionStart + 10)
$TokenStorageFunctionSource = $ServerSource.Substring($TokenStorageFunctionStart, $TokenStorageFunctionEnd - $TokenStorageFunctionStart)
Assert-False ($TokenStorageFunctionSource.Contains('Write-AppLog')) 'DonationAlerts token transaction logs token-derived data.'
Assert-True ($ServerSource.Contains('Set-DonationAlertsStoredUserCurrencyForToken')) 'DonationAlerts profile currency is not token-bound.'
Assert-False ($ServerSource.Contains('Set-DonationAlertsStoredUserCurrency $ProfileCurrency')) 'Legacy unbound profile currency write is still active.'
Assert-Equal (Normalize-CurrencyCode 'RUR') 'RUB' 'RUR was not normalized to RUB.'
Assert-Equal (Normalize-CurrencyCode ([string][char]0x20AC)) 'EUR' 'Euro symbol was not normalized.'

$MockCbrXml = @'
<?xml version="1.0" encoding="windows-1251"?>
<ValCurs Date="13.07.2026" name="Foreign Currency Market">
  <Valute ID="R01235"><NumCode>840</NumCode><CharCode>USD</CharCode><Nominal>100</Nominal><Name>US Dollar</Name><Value>1234,56</Value></Valute>
  <Valute ID="R01239"><NumCode>978</NumCode><CharCode>EUR</CharCode><Nominal>1</Nominal><Name>Euro</Name><Value>95,25</Value></Valute>
</ValCurs>
'@
$ParsedRates = Convert-CbrCurrencyXml $MockCbrXml
Assert-Equal ([decimal]$ParsedRates.rates.USD) ([decimal]12.3456) 'CBR Nominal was not applied to USD rate.'
Assert-Equal ([decimal]$ParsedRates.rates.EUR) ([decimal]95.25) 'CBR decimal comma was not parsed invariantly.'
Assert-Equal $ParsedRates.effectiveDate '2026-07-13' 'CBR effective date was not normalized.'

$RateSnapshot = [pscustomobject]@{
    ok = $true
    baseCurrency = 'RUB'
    rates = [pscustomobject]@{ USD = [decimal]88.50; EUR = [decimal]87.75 }
    effectiveDate = '2026-07-13'
    fetchedAt = '2026-07-13T10:00:00Z'
    source = 'cbr'
    stale = $false
    error = ''
}
$RubResult = Convert-DonationAlertsAmountToRub -OriginalAmount 1000 -OriginalCurrency 'RUB' -AmountInUserCurrency 0 -UserCurrency '' -RateSnapshot $RateSnapshot
Assert-Equal $RubResult.amount ([decimal]1000) 'RUB donation amount changed.'
Assert-Equal $RubResult.conversionSource 'original' 'RUB donation source is not original.'
$DaResult = Convert-DonationAlertsAmountToRub -OriginalAmount 50 -OriginalCurrency 'EUR' -AmountInUserCurrency 4388 -UserCurrency 'RUB' -RateSnapshot $RateSnapshot
Assert-Equal $DaResult.amount ([decimal]4388) 'Confirmed DonationAlerts RUB amount was not used.'
Assert-Equal $DaResult.conversionSource 'donationalerts' 'Confirmed user amount has wrong source.'
$UnconfirmedDaResult = Convert-DonationAlertsAmountToRub -OriginalAmount 50 -OriginalCurrency 'EUR' -AmountInUserCurrency 4388 -UserCurrency '' -RateSnapshot $RateSnapshot
Assert-Equal $UnconfirmedDaResult.amount ([decimal]4388) 'Unconfirmed user amount did not fall back to CBR conversion.'
Assert-Equal $UnconfirmedDaResult.conversionSource 'cbr' 'Unconfirmed user amount was trusted instead of CBR.'
$UsdResult = Convert-DonationAlertsAmountToRub -OriginalAmount 60 -OriginalCurrency 'USD' -AmountInUserCurrency 0 -UserCurrency '' -RateSnapshot $RateSnapshot
Assert-Equal $UsdResult.amount ([decimal]5310) 'USD to RUB conversion is incorrect.'
$RoundedResult = Convert-DonationAlertsAmountToRub -OriginalAmount 1 -OriginalCurrency 'USD' -AmountInUserCurrency 0 -UserCurrency '' -RateSnapshot ([pscustomobject]@{
    baseCurrency = 'RUB'; rates = [pscustomobject]@{ USD = [decimal]4387.50; EUR = [decimal]1 }; source = 'cbr'; stale = $false
})
Assert-Equal $RoundedResult.amount ([decimal]4388) 'Currency midpoint was not rounded AwayFromZero.'
$RurResult = Convert-DonationAlertsAmountToRub -OriginalAmount 1500 -OriginalCurrency 'RUR' -AmountInUserCurrency 0 -UserCurrency '' -RateSnapshot $RateSnapshot
Assert-Equal $RurResult.amount ([decimal]1500) 'RUR donation was not treated as RUB.'
$UnknownResult = Convert-DonationAlertsAmountToRub -OriginalAmount 50 -OriginalCurrency 'GBP' -AmountInUserCurrency 0 -UserCurrency '' -RateSnapshot $RateSnapshot
Assert-Equal $UnknownResult.conversionStatus 'unavailable' 'Unknown currency was credited automatically.'
Assert-Equal $UnknownResult.amount ([decimal]0) 'Unknown currency kept a creditable amount.'
$NoRatesResult = Convert-DonationAlertsAmountToRub -OriginalAmount 50 -OriginalCurrency 'EUR' -AmountInUserCurrency 0 -UserCurrency '' -RateSnapshot (New-UnavailableCurrencyRateSnapshot 'offline')
Assert-Equal $NoRatesResult.conversionStatus 'unavailable' 'EUR without startup rates was credited automatically.'
Assert-Equal $NoRatesResult.amount ([decimal]0) 'EUR without rates was silently treated as RUB.'

$TempCurrencyDir = Join-Path ([System.IO.Path]::GetTempPath()) "papich-currency-test-$([Guid]::NewGuid().ToString('N'))"
$TempCurrencyPath = Join-Path $TempCurrencyDir 'currency_rates.json'
try {
    [System.IO.Directory]::CreateDirectory($TempCurrencyDir) | Out-Null
    [System.IO.File]::WriteAllText($TempCurrencyPath, ($RateSnapshot | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($true))
    $script:CacheDir = $TempCurrencyDir
    $script:CurrencyRatesCachePath = $TempCurrencyPath
    $script:CurrencyRatesMutexName = "PapichWheelCurrencyTest-$([Guid]::NewGuid().ToString('N'))"
    $script:CurrencyRatesInitialized = $false
    $script:CurrencyRatesLoadCount = 0
    $script:CurrencyRateSnapshot = $null
    $FallbackRates = Initialize-CurrencyRates -Loader { throw 'mock network failure' } -CachePath $TempCurrencyPath
    Assert-True $FallbackRates.ok 'Currency cache fallback failed after startup network error.'
    Assert-True $FallbackRates.stale 'Cached currency snapshot was not marked stale.'
    Assert-Equal $FallbackRates.source 'cbr_cache' 'Cached currency snapshot has wrong source.'
    [void](Initialize-CurrencyRates -Loader { throw 'must not run twice' } -CachePath $TempCurrencyPath)
    Assert-Equal $script:CurrencyRatesLoadCount 1 'Currency loader ran more than once in one server process.'
}
finally {
    if ([System.IO.Directory]::Exists($TempCurrencyDir)) { [System.IO.Directory]::Delete($TempCurrencyDir, $true) }
}

$ConvertedRow = Convert-DonationAlertsRow ([pscustomobject]@{
    id = 'da-1'; username = 'viewer'; amount = 50; currency = 'EUR'; amount_in_user_currency = 4388;
    user_currency = 'RUB'; message = 'test'; created_at = '2026-07-13 10:00:00'
}) $RateSnapshot 'RUB'
Assert-Equal $ConvertedRow.amount ([decimal]4388) 'DonationAlerts row did not store credited RUB amount.'
Assert-Equal $ConvertedRow.currency 'RUB' 'DonationAlerts credited currency is not RUB.'
Assert-Equal $ConvertedRow.originalAmount ([decimal]50) 'DonationAlerts original amount was lost.'
Assert-Equal $ConvertedRow.originalCurrency 'EUR' 'DonationAlerts original currency was lost.'
Assert-Equal $ConvertedRow.conversionStatus 'converted' 'DonationAlerts row conversion status is incorrect.'
$UnavailableRow = Convert-DonationAlertsRow ([pscustomobject]@{
    id = 'da-2'; username = 'viewer'; amount = 50; currency = 'GBP'; message = 'test'; created_at = '2026-07-13 10:00:00'
}) $RateSnapshot ''
Assert-Equal $UnavailableRow.amount ([decimal]0) 'Unavailable DonationAlerts row kept a creditable amount.'
Assert-Equal $UnavailableRow.originalAmount ([decimal]50) 'Unavailable DonationAlerts row lost original amount.'
Assert-Equal $UnavailableRow.conversionStatus 'unavailable' 'Unavailable DonationAlerts row has wrong status.'

$DonatePayRow = Convert-DonatePayNotificationRow ([pscustomobject]@{
    id = 'dp-1'; type = 'donation'; vars = [pscustomobject]@{ name = 'viewer'; sum = 700; currency = 'RUB'; comment = 'test' };
    created_at = '2026-07-13T10:00:00Z'
})
Assert-Equal $DonatePayRow.amount 700 'DonatePay amount mapping changed.'
Assert-Equal $DonatePayRow.currency 'RUB' 'DonatePay currency mapping changed.'

$DonatePayFunctionStart = $ServerSource.IndexOf('function Convert-DonatePayNotificationRow')
$DonatePayFunctionEnd = $ServerSource.IndexOf('function Set-CollectorBackoff', $DonatePayFunctionStart)
$DonatePayFunctionSource = $ServerSource.Substring($DonatePayFunctionStart, $DonatePayFunctionEnd - $DonatePayFunctionStart)
Assert-False ($DonatePayFunctionSource.Contains('CurrencyRate')) 'DonatePay converter unexpectedly uses currency subsystem.'
Assert-False ($DonatePayFunctionSource.Contains('Convert-DonationAlertsAmountToRub')) 'DonatePay converter unexpectedly converts currencies.'
Assert-Equal ([regex]::Matches($ServerSource, '(?m)^\s*\[void\]\(Initialize-CurrencyRates\)\s*$').Count) 1 'Currency rates are not initialized exactly once at server startup.'
Assert-True ($ServerSource.Contains('$ConversionUnavailable')) 'Server collector cannot queue DonationAlerts when currency conversion is unavailable.'
Assert-True ($ServerSource.Contains('resetEpoch = Get-AppResetEpoch')) 'Bootstrap/collector status does not expose the non-secret reset epoch.'
Assert-True ($ServerSource.Contains('resetEpoch = $ResetEpoch')) 'Full reset response does not return the new reset epoch.'
$ResetFunctionStart = $ServerSource.IndexOf('function Reset-AllApplicationData')
$ResetFunctionEnd = $ServerSource.IndexOf('function Start-LlmWorkerLoop', $ResetFunctionStart)
$ResetFunctionSource = $ServerSource.Substring($ResetFunctionStart, $ResetFunctionEnd - $ResetFunctionStart)
Assert-True ($ResetFunctionSource.IndexOf('$ResetEpoch = Set-NewAppResetEpoch') -gt $ResetFunctionSource.IndexOf('[System.IO.File]::Delete($script:SecretsPath)')) 'Reset epoch is published before required server cleanup finishes.'
Assert-True ($ResetFunctionSource.Contains('AI worker restart after full reset failed')) 'Full reset does not safely handle an AI worker restart failure.'
Assert-True ($ResetFunctionSource.Contains('Stop-DonationAlertsPollRunspace $script:DonationAlertsPollHandle')) 'Full reset leaves an in-flight DonationAlerts request able to restore deleted runtime data.'
Assert-True ($ResetFunctionSource.Contains('Stop-DonatePayRecoveryRunspace $script:DonatePayRecoveryHandle')) 'Full reset leaves an in-flight DonatePay recovery able to restore deleted runtime data.'

function New-TestEntry {
    param(
        [string]$Id,
        [string]$Name,
        [bool]$Eliminated = $false,
        [string]$Source = '',
        [string]$ExternalId = '',
        [string]$Category = ''
    )
    return [pscustomobject]@{
        id = $Id
        name = $Name
        eliminated = $Eliminated
        source = $Source
        externalId = $ExternalId
        category = $Category
    }
}

$GrannyBase = New-TestEntry 'base' 'Granny'
$GrannyThree = New-TestEntry 'three' 'Granny 3'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Granny 3' @($GrannyBase))) 'Granny 3 must not match Granny.'
Assert-True ((Find-ExistingEntryMatch 'Granny 3' @($GrannyThree)).entry.id -eq 'three') 'Granny 3 exact match failed.'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Naruto Shippuden' @((New-TestEntry 'naruto' 'Naruto')))) 'Naruto Shippuden must not match Naruto.'
Assert-True ($null -eq (Find-ExistingEntryMatch 'The Witcher 3' @((New-TestEntry 'witcher' 'The Witcher')))) 'The Witcher 3 must not match The Witcher.'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Attack on Titan: Final Season' @((New-TestEntry 'aot' 'Attack on Titan')))) 'Final Season must not match base Attack on Titan.'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Resident Evil 4' @((New-TestEntry 're' 'Resident Evil')))) 'Resident Evil 4 must not match Resident Evil.'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Portal' @((New-TestEntry 'postal' 'Postal')))) 'Portal must not fuzzy-match Postal.'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Inside' @((New-TestEntry 'insider' 'Insider')))) 'Inside must not fuzzy-match Insider.'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Control' @((New-TestEntry 'controls' 'Controls')))) 'Control must not fuzzy-match Controls.'
Assert-True ((Compare-LotTitles 'The Witcher 3' 'Witcher 3').exact) 'Safe article difference should be exact.'

$AnimeNaruto = New-TestEntry 'anime-naruto' 'Naruto' $false '' '' 'anime'
Assert-True ($null -eq (Find-ExistingEntryMatch 'Naruto' @($AnimeNaruto) 'game')) 'Known different categories must not match by title.'
Assert-True ((Find-ExistingEntryMatch 'Naruto' @($AnimeNaruto) 'anime').entry.id -eq 'anime-naruto') 'Same known category exact match failed.'
Assert-True ((Find-ExistingEntryMatch 'Naruto' @((New-TestEntry 'legacy' 'Naruto')) 'game').entry.id -eq 'legacy') 'Legacy empty category should remain compatible.'
Assert-True ((Find-ExistingEntryMatch 'Naruto' @((New-TestEntry 'legacy-unknown' 'Naruto' $false '' '' 'unknown')) 'game').entry.id -eq 'legacy-unknown') 'Legacy unknown category should remain compatible.'

$ExternalEntry = New-TestEntry 'steam-entry' 'Renamed title' $false 'steam' '123456'
$ExternalCandidate = [pscustomobject]@{ source = 'steam'; externalId = '123456'; title = 'Different title' }
Assert-True ((Search-ExistingEntryByCandidate $ExternalCandidate @($ExternalEntry)).id -eq 'steam-entry') 'source + externalId exact match failed.'
$CrossCategoryCandidate = [pscustomobject]@{ source = 'steam'; externalId = '999'; title = 'Naruto' }
Assert-True ($null -eq (Search-ExistingEntryByCandidate $CrossCategoryCandidate @($AnimeNaruto) 'game')) 'Steam Naruto must not match anime Naruto by title.'
$CrossCategoryExternal = New-TestEntry 'external-priority' 'Naruto Anime' $false 'steam' '999' 'anime'
Assert-True ((Search-ExistingEntryByCandidate $CrossCategoryCandidate @($CrossCategoryExternal) 'game').id -eq 'external-priority') 'Exact source + externalId must have priority over category.'
$Eliminated = New-TestEntry 'gone' 'Granny 3' $true
Assert-True ($null -eq (Find-ExistingEntryMatch 'Granny 3' @($Eliminated))) 'Eliminated entry must not be assignable.'

$GrannyCandidates = @(
    [pscustomobject]@{ candidateId = 'steam:1'; title = 'Granny 3'; score = 1.0; source = 'steam' },
    [pscustomobject]@{ candidateId = 'steam:2'; title = 'Granny'; score = 0.92; source = 'steam' },
    [pscustomobject]@{ candidateId = 'steam:3'; title = 'Granny: Chapter Two'; score = 0.88; source = 'steam' }
)
Assert-False (Test-CatalogCandidatesAmbiguous 'Granny 3' $GrannyCandidates) 'Unique exact Granny 3 should skip candidate-selection LLM.'
$DbdCandidates = @(
    [pscustomobject]@{ candidateId = 'steam:10'; title = 'Dead by Daylight'; score = 1.0; source = 'steam' },
    [pscustomobject]@{ candidateId = 'steam:11'; title = 'Dead by Daylight Mobile'; score = 0.93; source = 'steam' }
)
Assert-False (Test-CatalogCandidatesAmbiguous 'Dead by Daylight' $DbdCandidates) 'Unique exact Dead by Daylight should skip candidate-selection LLM.'
$AnimeExact = @(
    [pscustomobject]@{ candidateId = 'anilist:1'; title = 'Jujutsu Kaisen'; titleRomaji = 'Jujutsu Kaisen'; score = 1.0; source = 'anilist'; format = 'TV' },
    [pscustomobject]@{ candidateId = 'anilist:2'; title = 'Jujutsu Kaisen Phantom Parade'; score = 0.65; source = 'anilist'; format = 'ONA' }
)
Assert-False (Test-CatalogCandidatesAmbiguous 'Jujutsu Kaisen' $AnimeExact) 'Unique exact anime candidate should skip candidate-selection LLM when alternatives are not close.'
$NarutoCandidates = @(
    [pscustomobject]@{ candidateId = 'anilist:10'; title = 'Naruto'; score = 1.0; source = 'anilist'; format = 'TV' },
    [pscustomobject]@{ candidateId = 'anilist:11'; title = 'Naruto Shippuden'; score = 0.92; source = 'anilist'; format = 'TV' }
)
Assert-True (Test-CatalogCandidatesAmbiguous 'Naruto' $NarutoCandidates) 'Naruto franchise variants should require selection LLM or manual review.'
$SeriesCandidates = @(
    [pscustomobject]@{ candidateId = 'steam:20'; title = 'Granny'; score = 1.0; source = 'steam' },
    [pscustomobject]@{ candidateId = 'steam:21'; title = 'Granny 2'; score = 0.90; source = 'steam' }
)
Assert-True (Test-CatalogCandidatesAmbiguous 'Granny' $SeriesCandidates) 'A franchise query without a part number should be ambiguous.'
Assert-True (Test-LlmIntentReadyForCatalog 'anime' 'Naruto' 0.90) 'Known ambiguous Naruto franchise should reach catalog search.'
Assert-False (Test-LlmIntentReadyForCatalog 'unknown' '' 0.90) 'Unknown intent must remain manual.'

foreach ($Roman in @('I', 'II', 'III', 'IV', 'V', 'VI', 'IX', 'X', 'XII', 'XIV', 'XIX', 'XX')) {
    Assert-True (Test-ValidRomanNumeral $Roman) "$Roman should be a valid part numeral."
}
foreach ($NotRoman in @('civil', 'dmc', 'mix', 'IIII', 'VX', 'IC', 'hello')) {
    Assert-False (Test-ValidRomanNumeral $NotRoman) "$NotRoman must not be treated as a Roman part numeral."
}

$RateLimit = Get-LlmFailureClassification $null 'Too Many Requests' 429 1 0
Assert-True ($RateLimit.retry -and $RateLimit.code -eq 'OPENROUTER_RATE_LIMIT') '429 must be retryable.'
$Unavailable = Get-LlmFailureClassification $null 'Service unavailable' 503 1 0
Assert-True ($Unavailable.retry -and $Unavailable.code -eq 'OPENROUTER_UPSTREAM_ERROR') '503 must be retryable.'
$Timeout = Get-LlmFailureClassification ([TimeoutException]::new('timeout')) 'timeout' 0 1 0
Assert-True ($Timeout.retry -and $Timeout.code -eq 'OPENROUTER_TIMEOUT') 'Timeout must be retryable.'
foreach ($Code in @('LLM_RESPONSE_PARSE_ERROR', 'UNKNOWN_CANDIDATE_ID', 'PIPELINE_RESULT_INVALID')) {
    $Exception = New-LlmCodedException $Code 'test failure'
    $Failure = Get-LlmFailureClassification $Exception $Exception.Message 0 1 0
    Assert-False $Failure.retry "$Code must not be retryable."
    Assert-True ($Failure.code -eq $Code) "$Code classification was lost."
}
$ProgrammingError = Get-LlmFailureClassification ([InvalidOperationException]::new('local bug')) 'local bug' 0 1 0
Assert-False $ProgrammingError.retry 'Unknown status-free programming errors must not retry.'

function Write-AppLog { param([string]$Level, [string]$Message) }
function Limit-LogText { param([AllowNull()][string]$Text, [int]$MaxLength = 500); $Value = [string]$Text; if ($Value.Length -le $MaxLength) { return $Value }; return $Value.Substring(0, $MaxLength) }
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "papich-ai-tests-$([Guid]::NewGuid().ToString('N'))"
$script:CacheDir = Join-Path $TestRoot 'cache'
$script:SecretsDir = $TestRoot
$script:ResetEpochPath = Join-Path $TestRoot 'reset_epoch.txt'
$script:SteamSearchCachePath = Join-Path $script:CacheDir 'steam_search_cache.json'
$script:AnimeSearchCachePath = Join-Path $script:CacheDir 'anime_search_cache.json'
$script:LlmJobsPath = Join-Path $script:CacheDir 'llm_jobs.json'
$script:CollectorStatePath = Join-Path $script:CacheDir 'collector_state.json'
$script:LlmJobsMutexName = "PapichWheelLlmJobsTest-$([Guid]::NewGuid().ToString('N'))"
$script:CollectorStateMutexName = "PapichWheelCollectorStateTest-$([Guid]::NewGuid().ToString('N'))"
$script:CacheMutexName = "PapichWheelSearchCacheTest-$([Guid]::NewGuid().ToString('N'))"
$script:StateLock = [object]::new()
$TestDonatePayState = @{
    Enabled = $true; AccessToken = 'test-runtime-secret'; Status = 'connected'; LastError = ''
    BackoffUntil = $null; LastPollAt = $null; LastSeenId = 50L; BaselineReady = $true; Signature = 'dp'
}
$TestDonationAlertsState = @{
    Enabled = $true; AccessToken = 'test-runtime-secret'; Status = 'connected'; LastError = ''
    BackoffUntil = $null; LastPollAt = $null; LastSeenId = 100L; BaselineReady = $true; Signature = 'da'
}
$script:ServerState = @{
    DonationsPending = [System.Collections.ArrayList]::new()
    SeenDonationKeys = @{ 'donatepay:old' = $true }
    Integrations = @{
        DonatePay = $TestDonatePayState
        DonationAlerts = $TestDonationAlertsState
    }
}
$script:CollectorEnabled = $true
$script:CollectorPausedPreserveCursor = $false
$script:CollectorRuntimeGeneration = 2L
$script:NextCollectorTickAt = Get-Date

$StalePollAccepted = Apply-DonationAlertsCollectorResult ([pscustomobject]@{ data = @() }) 'da' 1L
Assert-False $StalePollAccepted 'DonationAlerts poll started before pause was accepted after collector generation changed.'
Assert-True $script:ServerState.Integrations.DonationAlerts.BaselineReady 'Stale DonationAlerts poll changed baseline state.'
Assert-Equal $script:ServerState.Integrations.DonationAlerts.LastSeenId 100L 'Stale DonationAlerts poll changed the saved cursor.'

[void]$script:ServerState.DonationsPending.Add([pscustomobject]@{
    id = 'persisted-da'; source = 'donationalerts'; externalId = 'persisted-101'; amount = 100; createdAt = [DateTimeOffset]::UtcNow.ToString('o')
})
$script:ServerState.SeenDonationKeys['donationalerts:persisted-101'] = $true
Assert-True (Save-CollectorState) 'Collector state snapshot could not be persisted.'
$script:ServerState.DonationsPending = [System.Collections.ArrayList]::new()
$script:ServerState.SeenDonationKeys = @{}
$script:ServerState.Integrations.DonationAlerts.LastSeenId = $null
$script:ServerState.Integrations.DonationAlerts.BaselineReady = $false
$script:ServerState.Integrations.DonationAlerts.Signature = ''
Assert-True (Restore-CollectorState) 'Collector state snapshot could not be restored.'
Assert-True ($script:ServerState.DonationsPending.Count -eq 1) 'Unacked collector donation did not survive a server restart simulation.'
Assert-True ($script:ServerState.SeenDonationKeys.ContainsKey('donationalerts:persisted-101')) 'Collector dedupe history did not survive restart simulation.'
Assert-True ($script:ServerState.Integrations.DonationAlerts.LastSeenId -eq 100L) 'DonationAlerts cursor did not survive restart simulation.'
Assert-True $script:ServerState.Integrations.DonationAlerts.BaselineReady 'DonationAlerts baseline did not survive restart simulation.'
Assert-True ($script:ServerState.Integrations.DonationAlerts.Signature -eq 'da') 'DonationAlerts collector signature did not survive restart simulation.'

Assert-True ([string]::IsNullOrWhiteSpace((Get-AppResetEpoch))) 'Reset epoch should be empty before the first full reset marker.'
$FirstResetEpoch = Set-NewAppResetEpoch
Assert-True (-not [string]::IsNullOrWhiteSpace($FirstResetEpoch)) 'Full reset marker was not created.'
Assert-True ((Get-AppResetEpoch) -eq $FirstResetEpoch) 'Persisted full reset marker could not be read.'
$SecondResetEpoch = Set-NewAppResetEpoch
Assert-True ($SecondResetEpoch -ne $FirstResetEpoch) 'Consecutive full resets reused the same reset epoch.'
Assert-True ((Get-AppResetEpoch) -eq $SecondResetEpoch) 'Full reset marker was not atomically replaced.'

$PauseResult = Pause-CollectorRuntimePreserveCursor
Assert-True $PauseResult.pausedPreserveCursor 'Collector preserve-cursor pause did not activate.'
Assert-False $script:CollectorEnabled 'Collector continued polling while preserve-cursor pause was active.'
Assert-True ($script:ServerState.Integrations.DonationAlerts.LastSeenId -eq 100L) 'Pause reset DonationAlerts LastSeenId.'
Assert-True $script:ServerState.Integrations.DonationAlerts.BaselineReady 'Pause reset DonationAlerts baseline.'
$ResumeResult = Resume-CollectorRuntimePreserveCursor
Assert-False $ResumeResult.pausedPreserveCursor 'Collector preserve-cursor resume did not clear pause state.'
Assert-True $script:CollectorEnabled 'Collector did not resume polling.'
Assert-True ($script:ServerState.Integrations.DonationAlerts.LastSeenId -eq 100L) 'Resume changed DonationAlerts LastSeenId.'
Assert-True $script:ServerState.Integrations.DonationAlerts.BaselineReady 'Resume forced a new DonationAlerts baseline.'
Assert-True (101L -gt (Get-LastSeenIdValue $script:ServerState.Integrations.DonationAlerts)) 'DonationAlerts ID 101 was not considered newer than preserved cursor 100.'
$DaIdentity = Get-CollectorIdentitySignature 'donationalerts' 'token-a' '' '100'
Assert-True ($DaIdentity -eq (Get-CollectorIdentitySignature 'donationalerts' 'token-a' '' '100')) 'DonationAlerts identity signature is unstable across pause/resume.'
Assert-False ($DaIdentity -eq (Get-CollectorIdentitySignature 'donationalerts' 'token-b' '' '100')) 'DonationAlerts token replacement did not change collector identity.'
$DpIdentity = Get-CollectorIdentitySignature 'donatepay' 'token-a' 'ru' '200'
Assert-False ($DpIdentity -eq (Get-CollectorIdentitySignature 'donatepay' 'token-a' 'eu' '200')) 'DonatePay region change did not change collector identity.'
$RecoveryContext = Get-DonatePayRecoveryRequestContext ([pscustomobject]@{
    requestId = 'dp-recovery-test'
    region = 'eu'
    after = 123
    limit = 500
    auctionGeneration = 7
})
Assert-Equal $RecoveryContext.requestId 'dp-recovery-test' 'DonatePay recovery request id was not preserved.'
Assert-Equal $RecoveryContext.after 123L 'DonatePay recovery cursor was not preserved.'
Assert-Equal $RecoveryContext.limit 100 'DonatePay recovery limit was not clamped.'
Assert-Equal $RecoveryContext.auctionGeneration 7L 'DonatePay recovery generation was not preserved.'
[void]$script:ServerState.DonationsPending.Add([pscustomobject]@{ id = 'old-donation' })
[void]$script:ServerState.DonationsPending.Add([pscustomobject]@{ id = 'dp-old'; source = 'donatepay'; externalId = '10' })
[void]$script:ServerState.DonationsPending.Add([pscustomobject]@{ id = 'dp-race'; source = 'donatepay'; externalId = '11' })
$script:ServerState.SeenDonationKeys['donatepay:10'] = $true
$script:ServerState.SeenDonationKeys['donatepay:11'] = $true

try {
    $OriginalLlmWriter = ${function:Write-LlmJobsStoreUnsafe}
    try {
        Set-Item -Path Function:Write-LlmJobsStoreUnsafe -Value { param([object]$Store); return $false }
        $PersistenceFailureThrown = $false
        try { [void](Write-LlmJobsStoreOrThrow (New-EmptyLlmJobsStore)) } catch { $PersistenceFailureThrown = $true }
        Assert-True $PersistenceFailureThrown 'AI job persistence failure was acknowledged as a successful state transition.'
    }
    finally {
        Set-Item -Path Function:Write-LlmJobsStoreUnsafe -Value $OriginalLlmWriter
    }

    $Store = New-EmptyLlmJobsStore
    $Store.jobs = @([pscustomobject]@{
        jobId = 'old-job'
        analysisKey = 'donatepay:old'
        generation = 1
        status = 'running'
        errorCode = ''
    })
    Assert-True (Write-LlmJobsStoreUnsafe $Store) 'Initial jobs store write failed.'
    $Candidate = [pscustomobject]@{ candidateId = 'steam:1'; title = 'Granny 3' }
    Assert-True (Set-SteamSearchCachedCandidates 'Granny 3' @($Candidate) 1) 'Current-generation cache write failed.'

    $ClearResult = Clear-LlmAuctionData ([pscustomobject]@{ donatePayCursor = 10 })
    Assert-True ($ClearResult.auctionGeneration -eq 2) 'Auction generation was not incremented.'
    Assert-True ((Read-LlmJobsStoreUnsafe).jobs.Count -eq 0) 'Previous auction jobs were not cleared.'
    Assert-True ($script:ServerState.DonationsPending.Count -eq 0) 'Collector delivery queue was not cleared.'
    Assert-True ($script:ServerState.SeenDonationKeys.ContainsKey('donatepay:old')) 'Seen donation keys must survive auction clear.'
    Assert-True ($script:ServerState.SeenDonationKeys.ContainsKey('donatepay:10')) 'Accepted DonatePay cursor history must survive auction clear.'
    Assert-False ($script:ServerState.SeenDonationKeys.ContainsKey('donatepay:11')) 'Unaccepted DonatePay event newer than the saved cursor must be recoverable.'
    Assert-True ($ClearResult.releasedDonatePayKeys -eq 1) 'DonatePay clear race did not release exactly one recoverable key.'
    Complete-LlmJob 'old-job' 1 ([pscustomobject]@{ action = 'assign_existing' })
    Assert-True ((Read-LlmJobsStoreUnsafe).jobs.Count -eq 0) 'Stale worker restored a cleared job result.'
    Assert-False (Set-SteamSearchCachedCandidates 'Granny 3' @($Candidate) 1) 'Stale worker wrote cache for an old generation.'

    $StaleCache = [pscustomobject]@{}
    $StaleCache | Add-Member -NotePropertyName 'granny 3' -NotePropertyValue ([pscustomobject]@{
        generation = 1
        candidates = @($Candidate)
    })
    Assert-True (Write-JsonFileSafe $script:SteamSearchCachePath $StaleCache 10) 'Stale cache test setup failed.'
    Assert-True (@(Get-SteamSearchCachedCandidates 'Granny 3' 2).Count -eq 0) 'New auction read stale cache data.'
    Assert-True (Set-SteamSearchCachedCandidates 'Granny 3' @($Candidate) 2) 'New-generation cache write failed.'
    Assert-True (@(Get-SteamSearchCachedCandidates 'Granny 3' 2).Count -eq 1) 'New-generation cache read failed.'

    $StaleJobInput = [pscustomobject]@{
        auctionGeneration = 1
        analysisKey = 'donatepay:stale'
        donation = [pscustomobject]@{ id = 'stale'; source = 'donatepay'; externalId = 'stale'; username = 'test'; amount = 100; currency = 'RUB'; message = 'Naruto' }
        entries = @()
        settings = [pscustomobject]@{}
    }
    $StaleJobResult = Add-OrGet-LlmJob $StaleJobInput
    Assert-False $StaleJobResult.ok 'Stale auction generation must not create an AI job.'
    Assert-True ($StaleJobResult.status -eq 409) 'Stale generation must return HTTP contract status 409.'
    Assert-True ($StaleJobResult.code -eq 'AUCTION_GENERATION_MISMATCH') 'Stable stale-generation error code missing.'
    Assert-True ($StaleJobResult.currentAuctionGeneration -eq 2) 'Current generation missing from stale response.'
    Assert-True ((Read-LlmJobsStoreUnsafe).jobs.Count -eq 0) 'Stale generation unexpectedly created a job.'

    $ClearCutoff = [DateTimeOffset]::UtcNow
    [void]$script:ServerState.DonationsPending.Add([pscustomobject]@{
        id = 'da-before-clear'; source = 'donationalerts'; externalId = '100'; serverQueuedAt = $ClearCutoff.AddSeconds(-1).ToString('o')
    })
    [void]$script:ServerState.DonationsPending.Add([pscustomobject]@{
        id = 'da-during-clear'; source = 'donationalerts'; externalId = '101'; serverQueuedAt = $ClearCutoff.AddSeconds(1).ToString('o')
    })
    $script:ServerState.SeenDonationKeys['donationalerts:100'] = $true
    $script:ServerState.SeenDonationKeys['donationalerts:101'] = $true
    $CutoffClearResult = Clear-CollectorPendingDonations 0 $ClearCutoff.ToString('o')
    Assert-True ($CutoffClearResult.removed -eq 1) 'Auction clear did not remove the pre-clear collector item.'
    Assert-True ($script:ServerState.DonationsPending.Count -eq 1) 'Donation queued during clear was lost.'
    Assert-True ([string]$script:ServerState.DonationsPending[0].externalId -eq '101') 'Wrong server donation survived the clear cutoff.'
    Assert-True ($script:ServerState.SeenDonationKeys.ContainsKey('donationalerts:101')) 'Preserved in-flight DonationAlerts event lost its dedupe key.'

    Stop-CollectorRuntime
    Assert-True ($null -eq $script:ServerState.Integrations.DonationAlerts.LastSeenId) 'Full collector stop did not reset DonationAlerts cursor.'
    Assert-False $script:ServerState.Integrations.DonationAlerts.BaselineReady 'Full collector stop did not reset DonationAlerts baseline.'
    Assert-True ($null -eq $script:ServerState.Integrations.DonatePay.LastSeenId) 'Full collector stop did not reset DonatePay cursor.'
}
finally {
    if ([System.IO.Directory]::Exists($TestRoot)) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}

Write-Host 'AI logic tests ok'
