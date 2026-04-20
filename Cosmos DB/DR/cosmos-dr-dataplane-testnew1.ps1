#Requires -Version 7.0

<#

.SYNOPSIS

    Cosmos DB data-plane validation script for DR tests.

    Performs insert, point-read, query, and optional cleanup against SQL API.

 

.DESCRIPTION

    This script uses Cosmos DB data-plane REST endpoints with either master key

    auth (when local auth is enabled) or AAD token auth (when local auth is disabled).

    It also ensures database and container exist through Azure CLI management commands.

 

.PARAMETER ResourceGroup

    Azure resource group name.

 

.PARAMETER Account

    Cosmos DB account name.

 

.PARAMETER DatabaseName

    Database name (default: 'testdb').

 

.PARAMETER ContainerName

    Container name (default: 'testctr').

 

.PARAMETER PartitionKey

    Partition key path (default: '/id').

 

.PARAMETER SkipCleanup

    Do not delete the inserted test document.

 

.EXAMPLE

    .\cosmos-dr-dataplane-test.ps1 -ResourceGroup rg-prod -Account cosacct01

    .\cosmos-dr-dataplane-test.ps1 -ResourceGroup rg-prod -Account cosacct01 -DatabaseName drtest -ContainerName drdata

#>

 

param(

    [Parameter(Mandatory = $true)]

    [string]$ResourceGroup,

 

    [Parameter(Mandatory = $true)]

    [string]$Account,

 

    [Parameter(Mandatory = $false)]

    [string]$DatabaseName = 'testdb',

 

    [Parameter(Mandatory = $false)]

    [string]$ContainerName = 'testctr',

 

    [Parameter(Mandatory = $false)]

    [string]$PartitionKey = '/id',

 

    [Parameter(Mandatory = $false)]

    [switch]$SkipCleanup

)

 

$ErrorActionPreference = 'Stop'

 

function Write-Header {

    param([string]$Message)

    Write-Host "`n==> $Message" -ForegroundColor Cyan

}

 

function Write-Success {

    param([string]$Message)

    Write-Host "    [OK] $Message" -ForegroundColor Green

}

 

function Write-Warn {

    param([string]$Message)

    Write-Host "    [WARN] $Message" -ForegroundColor Yellow

}

 

function Stop-Script {

    param([string]$Message)

    Write-Host "    [ERROR] $Message" -ForegroundColor Red

    exit 1

}

 

function Get-ExceptionDetails {

    # Accepts the full ErrorRecord ($_ in a catch block) for PS7 HttpClient compatibility.

    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

 

    $msg = $ErrorRecord.Exception.Message

 

    # PS7: Invoke-RestMethod puts the response body in ErrorDetails.Message

    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {

        return "$msg | Body: $($ErrorRecord.ErrorDetails.Message)"

    }

 

    # PS5 fallback: HttpWebResponse stream

    $resp = $ErrorRecord.Exception.Response

    if ($null -ne $resp) {

        try {

            $stream = $resp.GetResponseStream()

            if ($stream) {

                $reader = [System.IO.StreamReader]::new($stream)

                $body = $reader.ReadToEnd()

                if (-not [string]::IsNullOrWhiteSpace($body)) {

                    return "$msg | Body: $body"

                }

            }

        } catch { }

    }

 

    return $msg

}

 

function New-CosmosAuthHeader {

    param(

        [Parameter(Mandatory = $true)][string]$Verb,

        [Parameter(Mandatory = $true)][string]$ResourceType,

        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ResourceLink = '',

        [Parameter(Mandatory = $true)][string]$DateRfc1123,

        [Parameter(Mandatory = $true)][string]$MasterKey

    )

 

    $keyBytes = [Convert]::FromBase64String($MasterKey)

    $payload = "{0}`n{1}`n{2}`n{3}`n`n" -f $Verb.ToLowerInvariant(), $ResourceType.ToLowerInvariant(), $ResourceLink, $DateRfc1123.ToLowerInvariant()

    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)

    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload))

    $sig = [Convert]::ToBase64String($hash)

    $token = "type=master&ver=1.0&sig=$sig"

    return [System.Uri]::EscapeDataString($token)

}

 

function New-CosmosAadAuthHeader {

    param([Parameter(Mandatory = $true)][string]$AadToken)

 

    $token = "type=aad&ver=1.0&sig=$AadToken"

    return [System.Uri]::EscapeDataString($token)

}

 

function Get-CosmosAadToken {

    # Cloud Shell/MSI often requires scope format for non-ARM audiences.

    $token = $null

 

    try {

        $token = az account get-access-token --scope "https://cosmos.azure.com//.default" --query accessToken --output tsv 2>$null

    } catch {

        $token = $null

    }

 

    if ([string]::IsNullOrWhiteSpace($token)) {

        try {

            # Fallback for environments where resource-style is still supported.

            $token = az account get-access-token --resource "https://cosmos.azure.com/" --query accessToken --output tsv 2>$null

        } catch {

            $token = $null

        }

    }

 

    if (-not [string]::IsNullOrWhiteSpace($token)) {

        return $token.Trim()

    }

 

    return $null

}

 

function Invoke-CosmosRest {

    param(

        [Parameter(Mandatory = $true)][string]$Method,

        [Parameter(Mandatory = $true)][string]$ResourceType,

        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$ResourceLink = '',

        [Parameter(Mandatory = $true)][string]$Endpoint,

        [Parameter(Mandatory = $true)][ValidateSet('master', 'aad')][string]$AuthType,

        [Parameter(Mandatory = $false)][string]$MasterKey,

        [Parameter(Mandatory = $false)][string]$AadToken,

        [Parameter(Mandatory = $false)][string]$RequestPath,

        [Parameter(Mandatory = $false)][string]$Body,

        [Parameter(Mandatory = $false)][string]$ContentType = 'application/json',

        [Parameter(Mandatory = $false)][hashtable]$ExtraHeaders

    )

 

    $date = [DateTime]::UtcNow.ToString('r')

    if ($AuthType -eq 'master') {

        if ([string]::IsNullOrWhiteSpace($MasterKey)) {

            throw "Master key is required for AuthType 'master'."

        }

        $auth = New-CosmosAuthHeader -Verb $Method -ResourceType $ResourceType -ResourceLink $ResourceLink -DateRfc1123 $date -MasterKey $MasterKey

    } else {

        if ([string]::IsNullOrWhiteSpace($AadToken)) {

            throw "AAD token is required for AuthType 'aad'."

        }

        $auth = New-CosmosAadAuthHeader -AadToken $AadToken

    }

 

    $headers = @{

        'Authorization' = $auth

        'x-ms-date' = $date

        'x-ms-version' = '2018-12-31'

    }

    if ($ExtraHeaders) {

        foreach ($k in $ExtraHeaders.Keys) {

            $headers[$k] = $ExtraHeaders[$k]

        }

    }

 

    if ([string]::IsNullOrWhiteSpace($RequestPath)) {

        if (-not [string]::IsNullOrWhiteSpace($ResourceLink)) {

            $RequestPath = $ResourceLink

        }

    }

    $base = $Endpoint.TrimEnd('/')

    $uri = if ([string]::IsNullOrWhiteSpace($RequestPath)) { $base } else { "$base/$RequestPath" }

 

    if ($Body) {

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)

        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $bodyBytes -ContentType $ContentType

    }

    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers

}

 

Write-Header "Checking prerequisites"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {

    Stop-Script "Azure CLI not found. Install from https://aka.ms/azure-cli"

}

 

try {

    $null = az account show --output none

} catch {

    Stop-Script "Not logged in to Azure CLI. Run 'az login' first."

}

Write-Success "Azure CLI and login context verified"

 

Write-Header "Loading Cosmos account metadata"

$accountObj = az cosmosdb show -g $ResourceGroup -n $Account --output json | ConvertFrom-Json

if (-not $accountObj) {

    Stop-Script "Cosmos account '$Account' was not found in resource group '$ResourceGroup'."

}

 

$endpoint = $accountObj.documentEndpoint

$multiWrite = [bool]$accountObj.enableMultipleWriteLocations

$disableLocalAuth = [bool]$accountObj.disableLocalAuth

$readRegions = @($accountObj.readLocations | ForEach-Object { $_.locationName })

$writeRegions = @($accountObj.writeLocations | ForEach-Object { $_.locationName })

 

Write-Host "  Endpoint:      $endpoint"

Write-Host "  Read regions:  $($readRegions -join ', ')"

Write-Host "  Write regions: $($writeRegions -join ', ')"

Write-Host "  Multi-write:   $multiWrite"

Write-Host "  Local auth:    $([string](-not $disableLocalAuth))"

 

$authType = 'master'

$masterKey = $null

$aadToken = $null

 

if ($disableLocalAuth) {

    $authType = 'aad'

    Write-Header "Getting AAD token for Cosmos data-plane"

    $aadToken = Get-CosmosAadToken

    if (-not $aadToken) {

        Stop-Script "Failed to get AAD token. In Cloud Shell run: az logout ; az login --scope 'https://cosmos.azure.com//.default'"

    }

    Write-Success "AAD token retrieved"

    Write-Warn "Using AAD auth. Principal must have Cosmos DB data-plane RBAC role (for example: Cosmos DB Built-in Data Contributor)."

} else {

    Write-Header "Getting account key"

    $masterKey = az cosmosdb keys list -g $ResourceGroup -n $Account --query primaryMasterKey --output tsv

    if (-not $masterKey) {

        Stop-Script "Could not retrieve primary master key. Ensure your principal has listKeys permission."

    }

    $masterKey = $masterKey.Trim()

    Write-Success "Master key retrieved"

}

 

$authParams = @{

    AuthType  = $authType

    MasterKey = $masterKey

    AadToken  = $aadToken

}

 

Write-Header "Validating data-plane auth"

try {

    # Signed against root feed to validate key/signature before insert.

    $null = Invoke-CosmosRest -Method 'GET' -ResourceType 'dbs' -ResourceLink '' -RequestPath 'dbs' -Endpoint $endpoint @authParams

    Write-Success "Data-plane auth check passed"

} catch {

    $details = Get-ExceptionDetails -ErrorRecord $_

    Stop-Script "Data-plane auth check failed: $details. If using AAD auth, verify Cosmos data-plane RBAC role assignment on the account/database/container scope."

}

 

Write-Header "Ensuring database and container exist"

az cosmosdb sql database create -g $ResourceGroup -a $Account -n $DatabaseName --output none

az cosmosdb sql container create -g $ResourceGroup -a $Account -d $DatabaseName -n $ContainerName -p $PartitionKey --output none

Write-Success "Database '$DatabaseName' and container '$ContainerName' are ready"

 

Write-Header "Test 1: Insert document"

$testId = "dr-test-{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))

$partitionKeyJson = [string](ConvertTo-Json @($testId) -Compress)

$testDocObj = @{

    id = $testId

    pk = $testId

    testType = 'dr-validation'

    timestamp = (Get-Date).ToUniversalTime().ToString('o')

    sourceWriteRegion = if ($writeRegions.Count -gt 0) { $writeRegions[0] } else { 'unknown' }

}

$testDocJson = $testDocObj | ConvertTo-Json -Depth 5

 Write-Host $testDocJson

try {

    $docsCollectionLink = "dbs/$DatabaseName/colls/$ContainerName/docs"

    $docsParentLink = "dbs/$DatabaseName/colls/$ContainerName"

    $insertHeaders = @{ 'x-ms-documentdb-partitionkey' = $partitionKeyJson }

    $null = Invoke-CosmosRest -Method 'POST' -ResourceType 'docs' -ResourceLink $docsParentLink -RequestPath $docsCollectionLink -Endpoint $endpoint -Body $testDocJson -ExtraHeaders $insertHeaders @authParams

    Write-Success "Inserted document id '$testId' for the region" $testDocJson.sourceWriteRegion

} catch {

    $details = Get-ExceptionDetails -ErrorRecord $_

    Stop-Script "Insert failed: $details"

}

 

Write-Header "Test 2: Point read"

try {

    $docLink = "dbs/$DatabaseName/colls/$ContainerName/docs/$testId"

    $readHeaders = @{ 'x-ms-documentdb-partitionkey' = $partitionKeyJson }

    $doc = Invoke-CosmosRest -Method 'GET' -ResourceType 'docs' -ResourceLink $docLink -Endpoint $endpoint -ExtraHeaders $readHeaders @authParams

    if ($doc.id -ne $testId) {

        Stop-Script "Read returned wrong id. Expected '$testId', got '$($doc.id)'"

    }

    Write-Success "Point read succeeded for '$testId'"

} catch {

    $details = Get-ExceptionDetails -ErrorRecord $_

    Stop-Script "Point read failed: $details"

}

 

Write-Header "Test 3: Query"

try {

    $queryBody = @{ query = 'SELECT TOP 5 c.id, c.timestamp, c.testType FROM c WHERE c.testType = @t ORDER BY c.timestamp DESC'; parameters = @(@{name='@t'; value='dr-validation'}) } | ConvertTo-Json -Depth 6

    $queryHeaders = @{

        'x-ms-documentdb-isquery' = 'True'

        'x-ms-documentdb-partitionkey' = $partitionKeyJson

    }

    $queryLink = "dbs/$DatabaseName/colls/$ContainerName/docs"

    $queryAuthLink = "dbs/$DatabaseName/colls/$ContainerName"

    $queryResult = Invoke-CosmosRest -Method 'POST' -ResourceType 'docs' -ResourceLink $queryAuthLink -RequestPath $queryLink -Endpoint $endpoint -Body $queryBody -ContentType 'application/query+json' -ExtraHeaders $queryHeaders @authParams

    $count = @($queryResult.Documents).Count

    if ($count -lt 1) {

        Stop-Script "Query returned no rows."

    }

    Write-Success "Query succeeded with $count row(s)"

} catch {

    $details = Get-ExceptionDetails -ErrorRecord $_

    Stop-Script "Query failed: $details"

}

 

Write-Header "Test 4: Multi-region write status"

if ($multiWrite) {

    Write-Success "Multi-region writes are enabled"

} else {

    Write-Warn "Multi-region writes are disabled"

}

 <#

if (-not $SkipCleanup) {

    Write-Header "Test 5: Cleanup"

    try {

        $deleteLink = "dbs/$DatabaseName/colls/$ContainerName/docs/$testId"

        $deleteHeaders = @{ 'x-ms-documentdb-partitionkey' = $partitionKeyJson }

        $null = Invoke-CosmosRest -Method 'DELETE' -ResourceType 'docs' -ResourceLink $deleteLink -Endpoint $endpoint -ExtraHeaders $deleteHeaders @authParams

        Write-Success "Deleted test document '$testId'"

    } catch {

        $details = Get-ExceptionDetails -ErrorRecord $_

        Write-Warn "Cleanup failed: $details"

    }

} else {

    Write-Warn "SkipCleanup enabled. Test document retained: $testId"

}

 #>

Write-Header "Data-plane validation complete"

Write-Success "Insert, read, and query checks passed"