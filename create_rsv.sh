#!/bin/bash

# Enhanced Azure Site Recovery Vault Setup Script
# Features: Interactive region/RG selection, zone redundancy, private networking
# Author: Generated for improved ASR vault deployment

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
LOCATION=""
RESOURCE_GROUP=""
VAULT_NAME=""
VNET_NAME=""
VNET_RESOURCE_GROUP=""
SUBNET_NAME=""
PRIVATE_ENDPOINT_RG=""
DNS_ZONE_RG=""
CREATE_NEW_RG=""
STORAGE_REDUNDANCY=""

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error_log() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success_log() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn_log() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if user is logged into Azure
check_azure_login() {
    log "Checking Azure CLI login status..."
    if ! az account show &> /dev/null; then
        error_log "You are not logged into Azure CLI. Please run 'az login' first."
        exit 1
    fi
    success_log "Azure CLI authentication verified."
}

# Function to select Azure region
select_region() {
    log "Fetching available Azure regions..."
    
    # Get all physical regions
    local regions=$(az account list-locations --query "[?metadata.regionType=='Physical'].{Name:name,DisplayName:displayName}" -o tsv | sort -k2)
    
    if [ -z "$regions" ]; then
        error_log "Failed to retrieve Azure regions."
        exit 1
    fi
    
    echo
    echo -e "${YELLOW}Available Azure regions:${NC}"
    echo "----------------------------------------"
    
    local counter=1
    declare -A region_map
    
    while IFS=$'\t' read -r name display_name; do
        printf "%2d. %s (%s)\n" $counter "$display_name" "$name"
        region_map[$counter]=$name
        ((counter++))
    done <<< "$regions"
    
    echo
    while true; do
        read -p "Please select a region (1-$((counter-1))): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$counter" ]; then
            LOCATION=${region_map[$choice]}
            log "Selected region: $LOCATION"
            break
        else
            error_log "Invalid selection. Please enter a number between 1 and $((counter-1))."
        fi
    done
}

# Function to select storage redundancy type
select_storage_redundancy() {
    echo
    echo -e "${YELLOW}Storage Redundancy Options:${NC}"
    echo "---------------------------"
    echo "1. Zone Redundant (ZRS) - Recommended for high availability"
    echo "   └── Data replicated across availability zones within the region"
    echo "2. Geo Redundant (GRS) - Cross-region protection"
    echo "   └── Data replicated to a secondary region for disaster recovery"
    echo "3. Locally Redundant (LRS) - Basic protection"
    echo "   └── Data replicated within a single datacenter (lowest cost)"
    
    # Check if region supports availability zones for ZRS
    local zone_support=$(az account list-locations --query "[?name=='$LOCATION' && not_null(availabilityZoneMappings)].name" -o tsv 2>/dev/null)
    
    if [ -z "$zone_support" ]; then
        echo
        warn_log "Note: Region $LOCATION may not support Zone Redundant Storage. ZRS selection may fall back to GRS."
    fi
    
    echo
    while true; do
        read -p "Please select storage redundancy (1-3): " choice
        
        case $choice in
            1)
                STORAGE_REDUNDANCY="ZoneRedundant"
                log "Selected: Zone Redundant Storage (ZRS)"
                if [ -n "$zone_support" ]; then
                    success_log "Region $LOCATION supports availability zones - ZRS will be configured."
                else
                    warn_log "Region $LOCATION may not support ZRS - will attempt but may fall back to GRS."
                fi
                break
                ;;
            2)
                STORAGE_REDUNDANCY="GeoRedundant"
                log "Selected: Geo Redundant Storage (GRS)"
                break
                ;;
            3)
                STORAGE_REDUNDANCY="LocallyRedundant"
                log "Selected: Locally Redundant Storage (LRS)"
                break
                ;;
            *)
                error_log "Invalid selection. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

# Function to select or create resource group
select_resource_group() {
    log "Fetching resource groups in region: $LOCATION..."
    
    local rgs=$(az group list --query "[?location=='$LOCATION'].name" -o tsv | sort)
    
    echo
    echo -e "${YELLOW}Available resource groups in $LOCATION:${NC}"
    echo "----------------------------------------"
    
    local counter=1
    declare -A rg_map
    
    if [ -n "$rgs" ]; then
        while read -r rg_name; do
            printf "%2d. %s\n" $counter "$rg_name"
            rg_map[$counter]=$rg_name
            ((counter++))
        done <<< "$rgs"
    fi
    
    printf "%2d. Create new resource group\n" $counter
    rg_map[$counter]="NEW"
    
    echo
    while true; do
        read -p "Please select a resource group (1-$counter): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$counter" ]; then
            if [ "${rg_map[$choice]}" == "NEW" ]; then
                CREATE_NEW_RG="yes"
                while true; do
                    read -p "Enter new resource group name: " new_rg_name
                    if [[ "$new_rg_name" =~ ^[a-zA-Z0-9._-]+$ ]] && [ ${#new_rg_name} -le 90 ]; then
                        RESOURCE_GROUP="$new_rg_name"
                        log "Will create new resource group: $RESOURCE_GROUP"
                        break
                    else
                        error_log "Invalid resource group name. Use alphanumeric characters, periods, underscores, hyphens. Max 90 characters."
                    fi
                done
            else
                RESOURCE_GROUP=${rg_map[$choice]}
                CREATE_NEW_RG="no"
                log "Selected existing resource group: $RESOURCE_GROUP"
            fi
            break
        else
            error_log "Invalid selection. Please enter a number between 1 and $counter."
        fi
    done
}

# Function to generate vault name
generate_vault_name() {
    local location_short=$(echo $LOCATION | sed 's/[^a-z0-9]//g' | cut -c1-8)
    local timestamp=$(date +%m%d)
    VAULT_NAME="rsv-${location_short}-${timestamp}"
    
    while true; do
        read -p "Enter vault name (default: $VAULT_NAME): " user_vault_name
        
        if [ -z "$user_vault_name" ]; then
            user_vault_name="$VAULT_NAME"
        fi
        
        if [[ "$user_vault_name" =~ ^[a-zA-Z][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [ ${#user_vault_name} -ge 2 ] && [ ${#user_vault_name} -le 50 ]; then
            VAULT_NAME="$user_vault_name"
            log "Vault name set to: $VAULT_NAME"
            break
        else
            error_log "Invalid vault name. Must be 2-50 characters, start with letter, end with letter/number, contain only letters, numbers, and hyphens."
        fi
    done
}

# Function to select resource group for private endpoint
select_private_endpoint_resource_group() {
    echo
    echo -e "${YELLOW}Select Resource Group for Private Endpoint:${NC}"
    echo "------------------------------------------"
    echo -e "${BLUE}The private endpoint can be created in any resource group.${NC}"
    echo -e "${BLUE}Common choices: same as vault, same as VNet, or dedicated networking RG.${NC}"
    echo
    
    # Get all resource groups in the subscription
    local all_rgs=$(az group list --query "[].name" -o tsv | sort)
    
    if [ -z "$all_rgs" ]; then
        error_log "No resource groups found in subscription."
        exit 1
    fi
    
    local counter=1
    declare -A pe_rg_map
    
    # Add vault's resource group as first option
    printf "%2d. %s (same as vault)\n" $counter "$RESOURCE_GROUP"
    pe_rg_map[$counter]="$RESOURCE_GROUP"
    ((counter++))
    
    # Add VNet's resource group if different from vault's
    if [ "$VNET_RESOURCE_GROUP" != "$RESOURCE_GROUP" ]; then
        printf "%2d. %s (same as VNet)\n" $counter "$VNET_RESOURCE_GROUP"
        pe_rg_map[$counter]="$VNET_RESOURCE_GROUP"
        ((counter++))
    fi
    
    # Add other resource groups
    while read -r rg_name; do
        if [ "$rg_name" != "$RESOURCE_GROUP" ] && [ "$rg_name" != "$VNET_RESOURCE_GROUP" ]; then
            printf "%2d. %s\n" $counter "$rg_name"
            pe_rg_map[$counter]="$rg_name"
            ((counter++))
        fi
    done <<< "$all_rgs"
    
    echo
    while true; do
        read -p "Please select a resource group for the private endpoint (1-$((counter-1))): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$counter" ]; then
            PRIVATE_ENDPOINT_RG=${pe_rg_map[$choice]}
            log "Selected private endpoint resource group: $PRIVATE_ENDPOINT_RG"
            
            # Now select DNS zone resource group
            select_dns_zone_resource_group
            break
        else
            error_log "Invalid selection. Please enter a number between 1 and $((counter-1))."
        fi
    done
}

# Function to select resource group for private DNS zone
select_dns_zone_resource_group() {
    echo
    echo -e "${YELLOW}Select Resource Group for Private DNS Zone:${NC}"
    echo "-------------------------------------------"
    echo -e "${BLUE}Private DNS zones can be shared across multiple private endpoints.${NC}"
    echo -e "${BLUE}Consider using a dedicated networking or shared services resource group.${NC}"
    echo
    
    # Get all resource groups in the subscription
    local all_rgs=$(az group list --query "[].name" -o tsv | sort)
    
    if [ -z "$all_rgs" ]; then
        error_log "No resource groups found in subscription."
        exit 1
    fi
    
    local counter=1
    declare -A dns_rg_map
    
    # Add private endpoint's resource group as first option
    printf "%2d. %s (same as private endpoint)\n" $counter "$PRIVATE_ENDPOINT_RG"
    dns_rg_map[$counter]="$PRIVATE_ENDPOINT_RG"
    ((counter++))
    
    # Add VNet's resource group if different from private endpoint's
    if [ "$VNET_RESOURCE_GROUP" != "$PRIVATE_ENDPOINT_RG" ]; then
        printf "%2d. %s (same as VNet)\n" $counter "$VNET_RESOURCE_GROUP"
        dns_rg_map[$counter]="$VNET_RESOURCE_GROUP"
        ((counter++))
    fi
    
    # Add vault's resource group if different from private endpoint's and VNet's
    if [ "$RESOURCE_GROUP" != "$PRIVATE_ENDPOINT_RG" ] && [ "$RESOURCE_GROUP" != "$VNET_RESOURCE_GROUP" ]; then
        printf "%2d. %s (same as vault)\n" $counter "$RESOURCE_GROUP"
        dns_rg_map[$counter]="$RESOURCE_GROUP"
        ((counter++))
    fi
    
    # Add other resource groups
    while read -r rg_name; do
        if [ "$rg_name" != "$PRIVATE_ENDPOINT_RG" ] && [ "$rg_name" != "$VNET_RESOURCE_GROUP" ] && [ "$rg_name" != "$RESOURCE_GROUP" ]; then
            printf "%2d. %s\n" $counter "$rg_name"
            dns_rg_map[$counter]="$rg_name"
            ((counter++))
        fi
    done <<< "$all_rgs"
    
    echo
    while true; do
        read -p "Please select a resource group for the private DNS zone (1-$((counter-1))): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$counter" ]; then
            DNS_ZONE_RG=${dns_rg_map[$choice]}
            log "Selected private DNS zone resource group: $DNS_ZONE_RG"
            break
        else
            error_log "Invalid selection. Please enter a number between 1 and $((counter-1))."
        fi
    done
}

# Function to select VNet and subnet for private endpoint
select_vnet_subnet() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE} PRIVATE ENDPOINT CONFIGURATION${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    log "Fetching virtual networks in region: $LOCATION across all resource groups..."
    
    # Get VNets from entire subscription in the selected region
    local vnet_data=$(az network vnet list --query "[?location=='$LOCATION'].{Name:name,ResourceGroup:resourceGroup}" -o json)
    
    if [ "$vnet_data" == "[]" ] || [ -z "$vnet_data" ]; then
        warn_log "No virtual networks found in region $LOCATION."
        echo
        echo -e "${YELLOW}Note: Without a virtual network, the vault will only be accessible via${NC}"
        echo -e "${YELLOW}service endpoints or public network access (if enabled).${NC}"
        echo
        read -p "Do you want to skip private endpoint configuration? (y/N): " skip_pe
        if [[ "$skip_pe" =~ ^[Yy]$ ]]; then
            VNET_NAME=""
            VNET_RESOURCE_GROUP=""
            SUBNET_NAME=""
            PRIVATE_ENDPOINT_RG=""
            DNS_ZONE_RG=""
            return
        else
            error_log "Virtual network is required for private endpoint configuration."
            exit 1
        fi
    fi
    
    echo
    echo -e "${YELLOW}Available virtual networks for private endpoint (region: $LOCATION):${NC}"
    echo "----------------------------------------------------------------"
    
    local counter=1
    declare -A vnet_map
    declare -A vnet_rg_map
    
    # Parse JSON data and create mappings
    while IFS= read -r line; do
        local vnet_name=$(echo "$line" | jq -r '.Name')
        local vnet_rg=$(echo "$line" | jq -r '.ResourceGroup')
        if [ "$vnet_name" != "null" ] && [ "$vnet_rg" != "null" ]; then
            printf "%2d. %s (Resource Group: %s)\n" $counter "$vnet_name" "$vnet_rg"
            vnet_map[$counter]=$vnet_name
            vnet_rg_map[$counter]=$vnet_rg
            ((counter++))
        fi
    done < <(echo "$vnet_data" | jq -c '.[]')
    
    printf "%2d. Skip private endpoint configuration\n" $counter
    vnet_map[$counter]="SKIP"
    
    echo
    while true; do
        read -p "Please select a virtual network for the private endpoint (1-$counter): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$counter" ]; then
            if [ "${vnet_map[$choice]}" == "SKIP" ]; then
                log "Skipping private endpoint configuration."
                VNET_NAME=""
                VNET_RESOURCE_GROUP=""
                SUBNET_NAME=""
                PRIVATE_ENDPOINT_RG=""
                DNS_ZONE_RG=""
                return
            else
                VNET_NAME=${vnet_map[$choice]}
                VNET_RESOURCE_GROUP=${vnet_rg_map[$choice]}
                log "Selected VNet for private endpoint: $VNET_NAME (Resource Group: $VNET_RESOURCE_GROUP)"
                
                # Now select resource group for private endpoint
                select_private_endpoint_resource_group
                break
            fi
        else
            error_log "Invalid selection. Please enter a number between 1 and $counter."
        fi
    done
    
    # Now select subnet
    log "Fetching subnets in VNet: $VNET_NAME for private endpoint placement..."
    
    local subnets=$(az network vnet subnet list --resource-group "$VNET_RESOURCE_GROUP" --vnet-name "$VNET_NAME" --query "[].name" -o tsv | sort)
    
    if [ -z "$subnets" ]; then
        error_log "No subnets found in VNet $VNET_NAME."
        exit 1
    fi
    
    echo
    echo -e "${YELLOW}Available subnets for private endpoint deployment:${NC}"
    echo "------------------------------------------------"
    echo -e "${BLUE}Note: The private endpoint will be created in the selected subnet${NC}"
    echo -e "${BLUE}and will consume one IP address from the subnet's address space.${NC}"
    echo
    
    counter=1
    declare -A subnet_map
    
    while read -r subnet_name; do
        printf "%2d. %s\n" $counter "$subnet_name"
        subnet_map[$counter]=$subnet_name
        ((counter++))
    done <<< "$subnets"
    
    echo
    while true; do
        read -p "Please select a subnet for the private endpoint (1-$((counter-1))): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$counter" ]; then
            SUBNET_NAME=${subnet_map[$choice]}
            log "Selected subnet for private endpoint: $SUBNET_NAME"
            break
        else
            error_log "Invalid selection. Please enter a number between 1 and $((counter-1))."
        fi
    done
}

# Function to create resource group if needed
create_resource_group() {
    if [ "$CREATE_NEW_RG" == "yes" ]; then
        log "Creating resource group: $RESOURCE_GROUP in $LOCATION..."
        
        if az group create --name "$RESOURCE_GROUP" --location "$LOCATION" &> /dev/null; then
            success_log "Resource group $RESOURCE_GROUP created successfully."
        else
            error_log "Failed to create resource group $RESOURCE_GROUP."
            exit 1
        fi
    else
        log "Using existing resource group: $RESOURCE_GROUP"
    fi
}

# Function to create Recovery Services Vault with zone redundancy
create_recovery_vault() {
    log "Creating Recovery Services Vault: $VAULT_NAME..."
    
    # Create vault with disabled public access
    if az backup vault create \
        --name "$VAULT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --public-network-access Disable > /dev/null 2>&1; then
        success_log "Recovery Services Vault $VAULT_NAME created successfully."
    else
        error_log "Failed to create Recovery Services Vault $VAULT_NAME."
        log "Attempting to get detailed error information..."
        az backup vault create \
            --name "$VAULT_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --public-network-access Disable
        exit 1
    fi
    
    # Wait a moment for vault to be fully provisioned
    log "Waiting for vault provisioning to complete..."
    sleep 15
    
    # Set selected storage redundancy
    log "Configuring $STORAGE_REDUNDANCY storage for vault..."
    if az backup vault backup-properties set \
        --name "$VAULT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --backup-storage-redundancy "$STORAGE_REDUNDANCY" > /dev/null 2>&1; then
        success_log "$STORAGE_REDUNDANCY storage configured successfully."
    else
        warn_log "Failed to set $STORAGE_REDUNDANCY storage. This might be due to region limitations."
        log "Attempting to get detailed error information..."
        az backup vault backup-properties set \
            --name "$VAULT_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --backup-storage-redundancy "$STORAGE_REDUNDANCY"
    fi
    
    # Verify storage redundancy configuration
    log "Verifying storage redundancy configuration..."
    local storage_info=$(az backup vault backup-properties show --name "$VAULT_NAME" --resource-group "$RESOURCE_GROUP" --query "[0].properties.storageModelType" -o tsv 2>/dev/null)
    
    if [ "$storage_info" == "$STORAGE_REDUNDANCY" ]; then
        success_log "$STORAGE_REDUNDANCY storage confirmed for vault $VAULT_NAME."
    elif [ "$storage_info" == "ZoneRedundant" ]; then
        if [ "$STORAGE_REDUNDANCY" != "ZoneRedundant" ]; then
            warn_log "Storage configured as Zone-Redundant instead of requested $STORAGE_REDUNDANCY"
        fi
    elif [ "$storage_info" == "GeoRedundant" ]; then
        if [ "$STORAGE_REDUNDANCY" == "ZoneRedundant" ]; then
            warn_log "Storage configured as Geo-Redundant (Zone redundancy not available in this region)"
        elif [ "$STORAGE_REDUNDANCY" != "GeoRedundant" ]; then
            warn_log "Storage configured as Geo-Redundant instead of requested $STORAGE_REDUNDANCY"
        fi
    elif [ "$storage_info" == "LocallyRedundant" ]; then
        if [ "$STORAGE_REDUNDANCY" != "LocallyRedundant" ]; then
            warn_log "Storage configured as Locally-Redundant instead of requested $STORAGE_REDUNDANCY"
        fi
    elif [ -z "$storage_info" ]; then
        warn_log "Unable to verify storage configuration. Please check manually using: az backup vault backup-properties show --name $VAULT_NAME --resource-group $RESOURCE_GROUP"
    else
        warn_log "Storage redundancy: $storage_info (Requested: $STORAGE_REDUNDANCY)"
    fi
}

# Function to create private endpoint
create_private_endpoint() {
    if [ -z "$VNET_NAME" ] || [ -z "$SUBNET_NAME" ]; then
        warn_log "Skipping private endpoint creation - no VNet/subnet configured."
        return
    fi
    
    local private_endpoint_name="pe-${VAULT_NAME}"
    local connection_name="${private_endpoint_name}-connection"
    
    log "Creating private endpoint: $private_endpoint_name..."
    
    # Get vault resource ID
    local vault_id=$(az backup vault show --name "$VAULT_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    
    if [ -z "$vault_id" ]; then
        error_log "Failed to get vault resource ID."
        exit 1
    fi
    
    # Create private endpoint in selected resource group
    log "Creating private endpoint in resource group: $PRIVATE_ENDPOINT_RG"
    log "Connecting to VNet: $VNET_NAME in resource group: $VNET_RESOURCE_GROUP"
    
    if az network private-endpoint create \
        --name "$private_endpoint_name" \
        --resource-group "$PRIVATE_ENDPOINT_RG" \
        --location "$LOCATION" \
        --subnet "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$SUBNET_NAME" \
        --private-connection-resource-id "$vault_id" \
        --group-ids "AzureSiteRecovery" \
        --connection-name "$connection_name" > /dev/null 2>&1; then
        success_log "Private endpoint $private_endpoint_name created successfully."
    else
        error_log "Failed to create private endpoint $private_endpoint_name."
        log "Attempting to get detailed error information..."
        az network private-endpoint create \
            --name "$private_endpoint_name" \
            --resource-group "$PRIVATE_ENDPOINT_RG" \
            --location "$LOCATION" \
            --subnet "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$SUBNET_NAME" \
            --private-connection-resource-id "$vault_id" \
            --group-ids "AzureSiteRecovery" \
            --connection-name "$connection_name"
        exit 1
    fi
    
    # Create or get private DNS zone
    log "Setting up private DNS zone integration..."
    
    local dns_zone_name="privatelink.siterecovery.windowsazure.com"
    
    # Check if private DNS zone exists in selected resource group, create if not
    local existing_zone=$(az network private-dns zone show --name "$dns_zone_name" --resource-group "$DNS_ZONE_RG" --query "name" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$existing_zone" ]; then
        log "Creating private DNS zone: $dns_zone_name in resource group: $DNS_ZONE_RG"
        if az network private-dns zone create \
            --name "$dns_zone_name" \
            --resource-group "$DNS_ZONE_RG" > /dev/null 2>&1; then
            success_log "Private DNS zone created successfully in $DNS_ZONE_RG."
        else
            warn_log "Failed to create private DNS zone in $DNS_ZONE_RG. Trying to find existing zone in other resource groups..."
            # Try to find the zone in other resource groups
            existing_zone=$(az network private-dns zone list --query "[?name=='$dns_zone_name'].{Name:name,ResourceGroup:resourceGroup}" -o json 2>/dev/null)
            if [ "$existing_zone" != "[]" ] && [ -n "$existing_zone" ]; then
                local found_dns_zone_rg=$(echo "$existing_zone" | jq -r '.[0].ResourceGroup' 2>/dev/null || echo "")
                if [ -n "$found_dns_zone_rg" ] && [ "$found_dns_zone_rg" != "null" ]; then
                    log "Found existing private DNS zone in resource group: $found_dns_zone_rg"
                    DNS_ZONE_RG="$found_dns_zone_rg"
                else
                    warn_log "Could not determine DNS zone resource group. Skipping DNS integration."
                    return
                fi
            else
                warn_log "Could not create or find private DNS zone. Skipping DNS integration."
                return
            fi
        fi
    else
        log "Using existing private DNS zone: $dns_zone_name in resource group: $DNS_ZONE_RG"
    fi
    
    # Create DNS zone group to link private endpoint with DNS zone
    log "Linking private endpoint to DNS zone in resource group: $DNS_ZONE_RG..."
    local zone_id="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$DNS_ZONE_RG/providers/Microsoft.Network/privateDnsZones/$dns_zone_name"
    
    if az network private-endpoint dns-zone-group create \
        --name "default" \
        --resource-group "$PRIVATE_ENDPOINT_RG" \
        --endpoint-name "$private_endpoint_name" \
        --private-dns-zone "$zone_id" \
        --zone-name "siterecovery" > /dev/null 2>&1; then
        success_log "Private DNS zone integration configured successfully."
    else
        warn_log "Private DNS zone group creation failed. Attempting detailed error..."
        az network private-endpoint dns-zone-group create \
            --name "default" \
            --resource-group "$PRIVATE_ENDPOINT_RG" \
            --endpoint-name "$private_endpoint_name" \
            --private-dns-zone "$zone_id" \
            --zone-name "siterecovery"
    fi
}

# Function to display summary
display_summary() {
    echo
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN} DEPLOYMENT SUMMARY${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e "Region: ${BLUE}$LOCATION${NC}"
    echo -e "Resource Group: ${BLUE}$RESOURCE_GROUP${NC}"
    echo -e "Vault Name: ${BLUE}$VAULT_NAME${NC}"
    echo -e "Storage Redundancy: ${GREEN}$STORAGE_REDUNDANCY${NC}"
    echo -e "Public Access: ${RED}Disabled${NC}"
    if [ -n "$VNET_NAME" ]; then
        echo -e "VNet: ${BLUE}$VNET_NAME${NC} (RG: ${BLUE}$VNET_RESOURCE_GROUP${NC})"
        echo -e "Subnet: ${BLUE}$SUBNET_NAME${NC}"
        echo -e "Private Endpoint: ${GREEN}Configured${NC} (RG: ${BLUE}$PRIVATE_ENDPOINT_RG${NC})"
        echo -e "Private DNS Zone: ${GREEN}Configured${NC} (RG: ${BLUE}$DNS_ZONE_RG${NC})"
    else
        echo -e "Private Endpoint: ${YELLOW}Skipped${NC}"
        echo -e "Private DNS Zone: ${YELLOW}Skipped${NC}"
    fi
    echo -e "${GREEN}================================${NC}"
    echo
}

# Main execution function
main() {
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${BLUE} Azure Site Recovery Vault Setup Script${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo
    
    check_azure_login
    select_region
    select_storage_redundancy
    select_resource_group
    generate_vault_name
    select_vnet_subnet
    
    echo
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo "---------------------"
    echo "Region: $LOCATION"
    echo "Storage Redundancy: $STORAGE_REDUNDANCY"
    echo "Resource Group: $RESOURCE_GROUP $([ "$CREATE_NEW_RG" == "yes" ] && echo "(new)" || echo "(existing)")"
    echo "Vault Name: $VAULT_NAME"
    if [ -n "$VNET_NAME" ]; then
        echo "VNet: $VNET_NAME (Resource Group: $VNET_RESOURCE_GROUP)"
        echo "Subnet: $SUBNET_NAME"
        echo "Private Endpoint RG: $PRIVATE_ENDPOINT_RG"
        echo "Private DNS Zone RG: $DNS_ZONE_RG"
    else
        echo "VNet: None (no private endpoint)"
        echo "Subnet: None"
        echo "Private Endpoint RG: None"
        echo "Private DNS Zone RG: None"
    fi
    echo
    
    read -p "Proceed with deployment? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log "Deployment cancelled by user."
        exit 0
    fi
    
    echo
    log "Starting deployment..."
    
    create_resource_group
    create_recovery_vault
    create_private_endpoint
    
    display_summary
    success_log "Azure Site Recovery Vault deployment completed successfully!"
}

# Run main function
main "$@"
