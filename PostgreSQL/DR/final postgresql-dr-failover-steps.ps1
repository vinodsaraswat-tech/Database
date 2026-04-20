# Set the variable context
az account set --subscription “Microsoft Azure Sponsorship-Factory"
$RGP="rg-emea-sql-mig-poc"
$RGR="rg-emea-sql-mig-poc"
$PRIMARY="pgsql-uks-01"
$REPLICA="pgsql-ukw-01”
$PE_RG="rg-emea-sql-mig-poc"
$VIRTUALEP="vepgsqldev"
$PRIMARY_PE="pe-pgsql-uks-01.9b85ed32-9c2e-4d5d-978a-c9df44857160"
$REPLICA_PE="pe-pgsql-ukw-01.0ffbbfcc-3d6b-4edd-8348-4488503cfbac"

# display private endpoint name for primary server
az postgres flexible-server private-endpoint-connection list -g "rg-emea-sql-mig-poc" -s "pgsql-uks-01"   -o table

# display private endpoint name for secondary server
az postgres flexible-server private-endpoint-connection list -g "rg-emea-sql-mig-poc" -s "pgsql-uks-01"   -o table

#Primary server details

az postgres flexible-server show -g "$RGP" -n "$PRIMARY" --query "{name:name,state:state,location:location,version:version,role:replicationRole}" -o table

#az postgres flexible-server show -g "$RG" -n "$PRIMARY" -o table

#number of replicas

az postgres flexible-server replica list -g "$RGP" -n "$PRIMARY" --query "length(@)" -o tsv

#list replica details
#az postgres flexible-server replica list -g "$RGP" -n "$PRIMARY" --query "{location:location,name:name,replicationRole:replicationRole,ResourceGroup:resourceGroup,state:state}" -o table

az postgres flexible-server replica list  -g "$RGP"   -n "$PRIMARY"  --query "[].{Name:name, ResourceGroup:resourceGroup, Location:location, Role:replicationRole, State:state}"  -o table

#Secondary server details

az postgres flexible-server show -g "$RGR" -n "$REPLICA" --query "{name:name,state:state,location:location,version:version,role:replicationRole}" -o table

#virtual endpoint details

az postgres flexible-server virtual-endpoint list    -g "$RGP"  --server-name "$PRIMARY"    -o table

#Create virtual endpoint if not exists

az postgres flexible-server virtual-endpoint create   -g "$RGP"   --server-name "$PRIMARY"   -n $VIRTUALEP   --endpoint-type ReadWrite   --members "$REPLICA"`
#delete virtual endpoint
#az postgres flexible-server virtual-endpoint delete   --resource-group $RGP   --server-name $PRIMARY  --name $VIRTUALEP  --yes

# virtual endpoint rw and r url details
az postgres flexible-server virtual-endpoint list  -g $RGP  -s $PRIMARY --query "[].{EndpointName:name,Type:endpointType,TargetServers:members}"  -o table

az postgres flexible-server virtual-endpoint list -g $RGP -s $PRIMARY --query "[].{EndpointName:name,Type:endpointType,TargetServers: join(',', members[].name)}" -o table

az postgres flexible-server virtual-endpoint list  -g $RGR  -s $REPLICA   --query "[].{EndpointName:name,Type:endpointType,TargetServers: join(',', members)}"   -o table

az postgres flexible-server virtual-endpoint list -g $RGR -s $REPLICA --query "[].{Tag: (endpointType=='ReadWrite' && '🟢RW' || '🔵RO'), EndpointName:name, Type:endpointType, TargetServers: join(', ', members)}" -o table
#Capture server parameters (baseline)
$primaryParams = az postgres flexible-server parameter list --resource-group "$RGP"  --server-name "$PRIMARY"  -o json | ConvertFrom-Json


# Get only writable params that are modified from default on PRIMARY
az postgres flexible-server parameter list -g $RGP -s $PRIMARY --query "[?isReadOnly==``false`` && value!=defaultValue].{name:name,value:value,isDynamic:isDynamic}" ` -o json | ConvertFrom-Json


$replicaParams = az postgres flexible-server parameter list --resource-group "$RGR" --server-name "$REPLICA" -o json | ConvertFrom-Json

#save to json file
$primaryParams | ConvertTo-Json -Depth 5 | Out-File primary-params.json
$replicaParams | ConvertTo-Json -Depth 5 | Out-File replica-params.json

# few important parameter validation
<#

max_connections,work_mem,shared_buffers,log_min_duration_statement, max_prepared_transactions, max_locks_per_transaction, max_wal_senders, max_worker_processes

#>

az postgres flexible-server parameter show -g "$RGP" -s "$PRIMARY" --name max_connections --query "{name:name,value:value,source:source}" -o json

az postgres flexible-server parameter show -g "$RGR" -s "$REPLICA" --name max_connections --query "{name:name,value:value,source:source}" -o json

az postgres flexible-server parameter show -g "$RGP" -s "$PRIMARY" --name shared_buffers --query "{name:name,value:value,source:source}" -o json
az postgres flexible-server parameter show -g "$RGR" -s "$REPLICA" --name shared_buffers --query "{name:name,value:value,source:source}" -o json
az postgres flexible-server parameter show -g "$RGR" -s "$REPLICA" --name max_wal_senders --query "{name:name,value:value,source:source}" -o json

<# DNS and private endpoint details#>

az network private-endpoint show   -g "$PE_RG"   -n "pe-pgsql-uks-01"   --query "{name:name,subnet:subnet.id,customDnsConfigs:customDnsConfigs}"   -o json
az network private-endpoint show   -g "$PE_RG"   -n "pe-pgsql-ukw-01"   --query "{name:name,subnet:subnet.id,customDnsConfigs:customDnsConfigs}"   -o json
#az network private-endpoint dns-zone-group list --endpoint-name "$PRIMARY_PE" -g "$PE_RG" -o table

#az network private-endpoint dns-zone-group list --endpoint-name "$REPLICA_PE" -g "$PE_RG" -o table

az network private-endpoint dns-zone-group list   -g "$PE_RG"   --endpoint-name "pe-pgsql-uks-01"   -o table 

az network private-endpoint dns-zone-group list   -g "$PE_RG"   --endpoint-name "pe-pgsql-ukw-01"   -o table  

nslookup "$PRIMARY.postgres.database.azure.com"

nslookup "$REPLICA.postgres.database.azure.com"

nslookup "$PRIMARY.privatelink.postgres.database.azure.com" 
nslookup "$REPLICA.privatelink.postgres.database.azure.com" 

# Capture the connection string details for primary and secondary replica
az postgres flexible-server show-connection-string -s "$PRIMARY" -d "postgres" -u "pgadmins"

az postgres flexible-server show-connection-string -s "$REPLICA" -d "postgres" -u "pgadmins"

#On PRIMARY (psql), capture current WAL position:
SELECT now() AS sample_time_utc, pg_current_wal_lsn() AS primary_wal_lsn;

#On REPLICA (psql), capture replay position and replay delay:
SELECT now() AS sample_time_utc, pg_last_wal_replay_lsn() AS replica_replay_lsn, EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int AS replay_delay_seconds;
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '<replica_replay_lsn_from_replica_query>') AS byte_lag;
Promote the replica to primary using planned switchover mode.
#perform planned failover

az postgres flexible-server replica promote -g "$RGR" -n "$REPLICA" --promote-mode switchover --promote-option planned --yes

#Replica status post failover
az postgres flexible-server show -g "$RGR" -n "$REPLICA" --query "{name:name,state:state,location:location,version:version,role:replicationRole}" -o table

#check for replica details from new primary

az postgres flexible-server replica list  -g "$RGP"   -n "$PRIMARY"  --query "[].{Name:name, ResourceGroup:resourceGroup, Location:location, Role:replicationRole, State:state}"  -o table

#Compare parameters
$diff = Compare-Object `
  ($primaryParams | Select name,value) `
  ($replicaParams | Select name,value) `
  -Property name,value
  $diff | Out-File param-drift.txt

#Apply Missing Parameters on New Primary
foreach ($p in $primaryParams) {
  az postgres flexible-server parameter set `
    --resource-group "$RGR" `
    --server-name "$REPLICA" `
    --name $p.name `
    --value $p.value
}

#apply the parameter difference to new primary from old primary
foreach ($p in $primaryParams) {
  az postgres flexible-server parameter set -g $RGR -s $REPLICA -n $($p.name) --value "$($p.value)" --only-show-errors
}

foreach ($p in $primaryParams) {
  try {
    az postgres flexible-server parameter set -g $RGR -s $REPLICA -n $($p.name) --value "$($p.value)" --only-show-errors | Out-Null
    Write-Host "[OK] $($p.name)"
  }
  catch {
    Write-Host "[FAIL] $($p.name) -> $($_.Exception.Message)"
  }
}

$staticChanges = $primaryParams | Where-Object { $_.isDynamic -eq $false }
if ($staticChanges.Count -gt 0) {
  Write-Host "Static params changed (restart may be needed):"
  $staticChanges | ForEach-Object { Write-Host " - $($_.name)=$($_.value)" }
}

# optional for automation perpose


do {
  Start-Sleep -Seconds 15
  $state = az postgres flexible-server show -g $RGR -n $REPLICA --query "state" -o tsv
  Write-Host "Server state: $state"
} while ($state -ne "Ready")

#On new primary
SELECT now() AS sample_time_utc, pg_current_wal_lsn() AS primary_wal_lsn;
 
-- On new replica
SELECT now() AS sample_time_utc, pg_last_wal_replay_lsn() AS replica_replay_lsn, EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int AS replay_delay_seconds;
#failback

az postgres flexible-server replica promote -g "$RGP" -n "$PRIMARY" --promote-mode switchover --promote-option planned --yes

#force failover

az postgres flexible-server replica promote -g "$RGR" -n "$REPLICA" --promote-mode switchover --promote-option forced --yes

