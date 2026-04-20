
<# check cosmos db multiregion write enabled#>

az cosmosdb show --resource-group "rg-emea-sql-mig-poc" --name "cosdb-acc02" --query "enableMultipleWriteLocations"

<# display cosmos db locations#>
az cosmosdb show  --resource-group "rg-emea-sql-mig-poc" --name "cosdb-acc02"  --query "locations[].locationName"

<# display cosmos db regions failover property and zone redundancy status#>

az cosmosdb show --name "cosdb-acc02" --resource-group "rg-emea-sql-mig-poc" --query "locations[].{region:locationName,failoverPriority:failoverPriority,isZoneRedundant:isZoneRedundant}" -o table

<# cosmos db failover to secondary#>

az cosmosdb failover-priority-change --name "cosdb-acc02" --resource-group "rg-emea-sql-mig-poc" --failover-policies "UK South=0" "UK West=1" "Southeast Asia=2"

<# cosmos db provisioning check post failover#>

az cosmosdb show --name "cosdb-acc02"   --resource-group "rg-emea-sql-mig-poc"   --query "provisioningState"

<# remove cosmos db region#>

az cosmosdb update   --name "cosdb-acc02"  --resource-group "rg-emea-sql-mig-poc"   --locations regionName=ukwest failoverPriority=0

<# add cosmos db region#>

az cosmosdb update --name "cosdb-acc02" --resource-group "rg-emea-sql-mig-poc" --locations regionName=uksouth failoverPriority=1 --locations regionName=ukwest failoverPriority=0


<# how to run DR test

./cosmos-dr-test.ps1 -ResourceGroup "rg-emea-sql-mig-poc"  -AccountName "cosdb-acc01"   -Primary uksouth

pwsh -File .\cosmos-dr-test.ps1 -ResourceGroup "rg-emea-sql-mig-poc" -AccountName "cosdb-acc01" -Primary uksouth
pwsh -File .\cosmos-dr-test.ps1 -ResourceGroup "rg-emea-sql-mig-poc" -AccountName "cosdb-acc01" -Primary eastus2 -Rollback


10mins to 30mins run the region check or provisioning check command try below

Submit region removal
DO
  Check provisioningState
WHILE provisioningState != Succeeded
Proceed

# 1. Run control-plane test
.\cosmos-dr-test.ps1 -ResourceGroup rg-prod -Account cosacct01 -Primary eastus2 -Rollback
 
# 2. Immediately after, validate data-plane
.\cosmos-dr-dataplane-test.ps1 -ResourceGroup rg-prod -Account cosacct01
 
# 3. Check output for any ✗ errors or ⚠ warnings

 "rg-emea-sql-mig-poc" --name "cosdb-acc01"
az cosmosdb sql role assignment create --resource-group "rg-emea-sql-mig-poc" --account-name "cosdb-acc02" --role-definition-id "00000000-0000-0000-0000-000000000002" --principal-id "585ad385-dd48-4a3b-9599-47e46dd1eac3" --scope "/subscriptions/55040da5-7038-4029-a92a-52502cb91b33/resourcegroups/rg-emea-sql-mig-poc/providers/Microsoft.DocumentDB/databaseAccounts/cosdb-acc02"


az identity show  --name "Vinod Saraswat"  --resource-group "rg-emea-sql-mig-poc"  --query principalId   -o tsv



az cosmosdb sql role assignment create  --resource-group "rg-emea-sql-mig-poc"  --account-name "cosdb-acc02"  --role-definition-id 00000000-0000-0000-0000-000000000002   --principal-id "585ad385-dd48-4a3b-9599-47e46dd1eac3"   --scope "/"


#>

az cosmosdb sql role assignment create --resource-group "rg-emea-sql-mig-poc" --account-name "cosdb-acc02" --role-definition-id "00000000-0000-0000-0000-000000000002" --principal-id "9aa43b70-5ee9-4a91-bce1-8dcc30fa406" --scope "/subscriptions/54e89a2c-0649-4b75-ab58-8d1c0dd78478/resourceGroups/a1a-52493-dev-rg-etcloud-uks-01/providers/Microsoft.DocumentDB/databaseAccounts/a1a-52493-dev-cosmos-etisg-uks-01"

