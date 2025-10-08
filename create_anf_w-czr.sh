#!/bin/bash
# Unified Azure NetApp Files Setup & Replication Script
# - Creates ANF account, pool, and volume in source and destination regions
# - Sets up cross-zone and cross-region replication

set -e

### ===== USER CONFIGURATION ===== ###
# Source
SOURCE_RG=""
SOURCE_LOCATION=""
SOURCE_ACCOUNT=""
SOURCE_POOL="" #Pool Name
SOURCE_POOL_SIZE_TIB="4"
SOURCE_SERVICE_LEVEL="Standard" #Choose Standard, Premium, or Ultra
SOURCE_VOLUME=""
SOURCE_VOLUME_SIZE_GIB="100"
SOURCE_VOLUME_THROUGHPUT="10"
SOURCE_VOLUME_PATH=""
SOURCE_ZONE="1"
ALLOWED_CLIENTS="0.0.0.0/0"
VNET_SOURCE=""
SUBNET_SOURCE=""

# Cross-Zone Target (same region, different zone)
ZONE_TARGET="2"

# Destination (Cross-Region)
TARGET_RG=""
TARGET_LOCATION=""
TARGET_ACCOUNT=""
TARGET_POOL="" #Pool Name
TARGET_POOL_SIZE_TIB="4"
TARGET_SERVICE_LEVEL="Standard" #Choose Standard, Premium, or Ultra
VNET_TARGET=""
SUBNET_TARGET=""
TARGET_ZONE="1"

# Replication
REPL_SCHEDULE="_10minutely"   # valid: hourly, daily, _10minutely

### ===== STEP 1: Register Provider ===== ###
#echo "Registering Microsoft.NetApp provider..."
#az provider register --namespace Microsoft.NetApp

### ===== STEP 2: Create Source ANF Account & Pool ===== ###
echo "Creating source ANF account..."
az netappfiles account create \
  --resource-group $SOURCE_RG \
  --name $SOURCE_ACCOUNT \
  --location $SOURCE_LOCATION

echo "Creating source ANF capacity pool..."
az netappfiles pool create \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --name $SOURCE_POOL \
  --location $SOURCE_LOCATION \
  --size $SOURCE_POOL_SIZE_TIB \
  --service-level $SOURCE_SERVICE_LEVEL \
  --qos-type Manual

### ===== STEP 3: Create Source Volume ===== ###
echo "Creating source ANF volume..."
az netappfiles volume create \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --pool-name $SOURCE_POOL \
  --name $SOURCE_VOLUME \
  --location $SOURCE_LOCATION \
  --service-level $SOURCE_SERVICE_LEVEL \
  --usage-threshold $SOURCE_VOLUME_SIZE_GIB \
  --throughput-mibps $SOURCE_VOLUME_THROUGHPUT \
  --file-path $SOURCE_VOLUME_PATH \
  --vnet $VNET_SOURCE \
  --subnet $SUBNET_SOURCE \
  --protocol-types NFSv4.1 \
  --allowed-clients 0.0.0.0/0 \
  --zones $SOURCE_ZONE \
  --network-features Standard

### ===== STEP 4: Create Destination ANF Account & Pool ===== ###
echo "Creating destination ANF account..."
az netappfiles account create \
  --resource-group $TARGET_RG \
  --name $TARGET_ACCOUNT \
  --location $TARGET_LOCATION

echo "Creating destination ANF capacity pool..."
az netappfiles pool create \
  --resource-group $TARGET_RG \
  --account-name $TARGET_ACCOUNT \
  --name $TARGET_POOL \
  --location $TARGET_LOCATION \
  --size $TARGET_POOL_SIZE_TIB \
  --service-level $TARGET_SERVICE_LEVEL \
  --qos-type Manual

### ===== STEP 5: Replication Setup ===== ###
echo "Retrieving source volume ID..."
SRC_VOL_ID=$(az netappfiles volume show \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --pool-name $SOURCE_POOL \
  --name $SOURCE_VOLUME \
  --query id -o tsv)

if [ -z "$SRC_VOL_ID" ]; then
  echo "Error: Source volume not found. Check your configuration."
  exit 1
fi

# Cross-Zone Replica
CROSSZONE_VOL="${SOURCE_VOLUME}-zone-replica"
echo "Creating cross-zone replica volume..."
az netappfiles volume create \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --pool-name $SOURCE_POOL \
  --name $CROSSZONE_VOL \
  --usage-threshold $SOURCE_VOLUME_SIZE_GIB  \
  --throughput-mibps $SOURCE_VOLUME_THROUGHPUT \
  --file-path "${CROSSZONE_VOL}" \
  --vnet $VNET_SOURCE \
  --subnet $SUBNET_SOURCE \
  --protocol-types NFSv4.1 \
  --allowed-clients 0.0.0.0/0 \
  --zones $TARGET_ZONE \
  --location $SOURCE_LOCATION \
  --network-features Standard \
  --endpoint-type "dst" \
  --remote-volume-resource-id $SRC_VOL_ID \
  --replication-schedule $REPL_SCHEDULE \
  --volume-type "DataProtection" \
  --service-level $SOURCE_SERVICE_LEVEL

DEST_VOLUME_ID=$(az netappfiles volume show \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --pool-name $SOURCE_POOL \
  --name $CROSSZONE_VOL \
  --query id -o tsv)

echo "Approving cross-zone replication relationship..."
az netappfiles volume replication approve \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --pool-name $SOURCE_POOL \
  --name $SOURCE_VOLUME \
  --remote-volume-resource-id $DEST_VOLUME_ID

echo "Cross-zone replication setup complete."

# Cross-Region Replica
CROSSREGION_VOL="${SOURCE_VOLUME}-region-replica"
echo "Creating cross-region replica volume..."

az netappfiles volume create \
 --resource-group $TARGET_RG \
 --account-name $TARGET_ACCOUNT \
 --pool-name $TARGET_POOL \
 --name $CROSSREGION_VOL \
 --usage-threshold $SOURCE_VOLUME_SIZE_GIB  \
 --throughput-mibps $SOURCE_VOLUME_THROUGHPUT \
 --file-path "${CROSSREGION_VOL}" \
 --vnet $VNET_TARGET \
 --subnet $SUBNET_TARGET \
 --protocol-types NFSv4.1 \
 --allowed-clients 0.0.0.0/0 \
 --zones $ZONE_TARGET \
 --location $TARGET_LOCATION \
 --network-features Standard \
 --endpoint-type "dst" \
 --remote-volume-resource-id $SRC_VOL_ID \
 --replication-schedule $REPL_SCHEDULE \
 --volume-type "DataProtection" \
 --service-level $TARGET_SERVICE_LEVEL

DEST_ID_REGION=$(az netappfiles volume show \
  --resource-group $TARGET_RG \
  --account-name $TARGET_ACCOUNT \
  --pool-name $TARGET_POOL \
  --name $CROSSREGION_VOL \
  --query id -o tsv)

echo "Approving cross-region replication relationship..."
az netappfiles volume replication approve \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --pool-name $SOURCE_POOL \
  --name $SOURCE_VOLUME \
  --remote-volume-resource-id $DEST_ID_REGION

echo "Cross-region replication setup complete."

### ===== STEP 6: Verification ===== ###
echo "Replication relationships for source volume:"
az netappfiles volume replication list \
  --resource-group $SOURCE_RG \
  --account-name $SOURCE_ACCOUNT \
  --pool-name $SOURCE_POOL \
  --volume-name $SOURCE_VOLUME \
  -o table

echo
echo "ANF accounts, pools, volumes, and replication successfully configured in both regions."
