#!/bin/bash

# Script to create On-Demand Capacity Reservations (ODCR) for VMs in a resource group
# This script analyzes existing VMs and creates capacity reservations based on their sizes and availability zones

set -e

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [-n <crg-name>] [-d|--dry-run] [-h]

Options:
    -n, --crg-name        Capacity Reservation Group name (optional, defaults to <rg-name>-crg)
    -d, --dry-run         Show what would be created without making actual changes
    -h, --help            Display this help message

The script will:
1. Use your current Azure CLI subscription
2. Let you choose from available resource groups
3. Automatically detect the region from the selected resource group

Examples:
    $0
    $0 -n myCustomCRG
    $0 --dry-run
    $0 -n myCustomCRG --dry-run

EOF
    exit 1
}

# Function to check if Azure CLI is installed and user is logged in
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check if Azure CLI is installed
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check if user is logged in
    if ! az account show &> /dev/null; then
        print_error "You are not logged in to Azure CLI. Please run 'az login' first."
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Function to display current subscription info
show_current_subscription() {
    print_info "Getting current Azure CLI subscription..."
    
    local sub_info
    sub_info=$(az account show --output json 2>/dev/null)
    
    if [[ -z "$sub_info" ]]; then
        print_error "Unable to get current subscription information"
        exit 1
    fi
    
    local sub_id sub_name
    sub_id=$(echo "$sub_info" | jq -r '.id')
    sub_name=$(echo "$sub_info" | jq -r '.name')
    
    print_success "Using subscription: $sub_name ($sub_id)"
}

# Global variables for resource group selection
SELECTED_RG_NAME=""
SELECTED_RG_LOCATION=""

# Function to list and select resource group
select_resource_group() {
    print_info "Fetching available resource groups..."
    
    local rg_list
    rg_list=$(az group list --query '[].{name:name, location:location}' --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to fetch resource groups. Error: $rg_list"
        return 1
    fi
    
    if [[ "$rg_list" == "[]" || -z "$rg_list" ]]; then
        print_error "No resource groups found in current subscription"
        return 1
    fi
    print_info "Available Resource Groups:"
    printf "%-5s %-40s %s\n" "No." "Resource Group" "Location"
    printf "%-5s %-40s %s\n" "---" "--------------" "--------"
    
    local rg_array=()
    local counter=1
    
    # Check if jq can parse the JSON
    if ! echo "$rg_list" | jq empty 2>/dev/null; then
        print_error "Invalid JSON response from Azure CLI: $rg_list"
        return 1
    fi
    
    while IFS= read -r rg; do
        if [[ -z "$rg" || "$rg" == "null" ]]; then
            continue
        fi
        
        local name location
        name=$(echo "$rg" | jq -r '.name // "unknown"')
        location=$(echo "$rg" | jq -r '.location // "unknown"')
        
        printf "%-5s %-40s %s\n" "$counter" "$name" "$location"
        rg_array+=("$name:$location")
        ((counter++))
    done <<< "$(echo "$rg_list" | jq -c '.[]' 2>/dev/null)"
    
    if [[ ${#rg_array[@]} -eq 0 ]]; then
        print_error "No valid resource groups found to display"
        return 1
    fi
    while true; do
        read -p "Please select a resource group (enter number): " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#rg_array[@]} ]]; then
            local selected_rg="${rg_array[$((selection-1))]}"
            IFS=':' read -r SELECTED_RG_NAME SELECTED_RG_LOCATION <<< "$selected_rg"
            
            print_success "Selected: $SELECTED_RG_NAME (Location: $SELECTED_RG_LOCATION)"
            return 0
        else
            print_error "Invalid selection. Please enter a number between 1 and ${#rg_array[@]}"
        fi
    done
}

# Function to validate resource group and get VMs
validate_resource_group_and_get_vms() {
    local rg_name="$1"
    
    print_info "Validating resource group '$rg_name' and checking for VMs..."
    
    if ! az group show --name "$rg_name" --output table &> /dev/null; then
        print_error "Resource group '$rg_name' not found or not accessible"
        exit 1
    fi
    
    # Check if there are VMs in the resource group
    local vm_count
    vm_count=$(az vm list --resource-group "$rg_name" --query 'length(@)' --output tsv)
    
    if [[ "$vm_count" -eq 0 ]]; then
        print_warning "No VMs found in resource group '$rg_name'"
        print_info "Resource groups with VMs:"
        az vm list --query 'group_by(@, &resourceGroup)[].{resourceGroup: key, count: length(value)}' --output table
        exit 0
    fi
    
    print_success "Resource group '$rg_name' validated with $vm_count VMs"
}

# Function to get VM information from resource group
get_vm_info() {
    local rg_name="$1"
    
    print_info "Querying VMs in resource group '$rg_name'..." >&2
    
    az vm list --resource-group "$rg_name" --query '[].{name:name, size:hardwareProfile.vmSize, zone:zones[0], location:location}' --output json 2>/dev/null
}

# Function to analyze VM distribution by size and zone
analyze_vm_distribution() {
    local vm_info="$1"
    
    print_info "Analyzing VM distribution by size and availability zone..."
    
    # Validate JSON input first
    if ! echo "$vm_info" | jq empty 2>/dev/null; then
        print_error "Invalid VM information JSON"
        return 1
    fi
    
    local processed_count=0
    local analysis_json="["
    local first=true
    
    # Get VM count for processing
    local vm_count=$(echo "$vm_info" | jq '. | length')
    print_info "Found $vm_count VM(s) to process"
    
    # Process VMs using jq directly to avoid shell loop issues
    local vm_data
    vm_data=$(echo "$vm_info" | jq -r '.[] | "\(.name)|\(.size)|\(.zone // "no-zone")|\(.location)"')
    
    while IFS='|' read -r vm_name size zone location; do
        if [[ -z "$vm_name" ]]; then
            continue
        fi
        
        print_info "Found VM: $vm_name (Size: $size, Zone: $zone, Location: $location)"
        
        # Skip if zone is "no-zone" or "null"
        if [[ "$zone" == "no-zone" || "$zone" == "null" ]]; then
            print_warning "VM $vm_name is not in an availability zone, skipping capacity reservation"
            continue
        fi
        
        # Add to JSON
        if [[ "$first" == "true" ]]; then
            first=false
        else
            analysis_json="$analysis_json,"
        fi
        
        analysis_json="$analysis_json{\"size\":\"$size\",\"zone\":\"$zone\",\"count\":1,\"available_zones\":\"$zone\"}"
        ((processed_count++))
        
    done <<< "$vm_data"
    
    analysis_json="$analysis_json]"
    
    if [[ $processed_count -eq 0 ]]; then
        print_warning "No VMs with availability zones were found for capacity reservation"
        analysis_json="[]"
    else
        print_success "Processed $processed_count VM(s) for capacity reservation"
        
        # Display summary
        print_info "VM Distribution Summary:"
        printf "%-20s %-10s %-15s\n" "VM Size" "Zone" "Count"
        printf "%-20s %-10s %-15s\n" "--------" "----" "-----"
        
        while IFS='|' read -r vm_name size zone location; do
            if [[ -z "$vm_name" || "$zone" == "no-zone" || "$zone" == "null" ]]; then
                continue
            fi
            printf "%-20s %-10s %-15s\n" "$size" "$zone" "1"
        done <<< "$vm_data"
    fi
    
    echo "$analysis_json"
}

# Function to validate capacity reservation prerequisites
validate_capacity_reservation_prerequisites() {
    local rg_name="$1"
    local region="$2"
    
    print_info "Validating capacity reservation prerequisites..."
    
    # Check if Microsoft.Compute resource provider is registered
    local compute_provider_state
    compute_provider_state=$(az provider show --namespace Microsoft.Compute --query "registrationState" -o tsv 2>/dev/null)
    
    if [[ "$compute_provider_state" != "Registered" ]]; then
        print_error "Microsoft.Compute resource provider is not registered"
        print_info "Please run: az provider register --namespace Microsoft.Compute"
        return 1
    fi
    
    # Test if we can list capacity reservation groups (tests permissions)
    print_info "Testing capacity reservation permissions..."
    if ! az capacity reservation group list -g "$rg_name" > /dev/null 2>&1; then
        local test_error
        test_error=$(az capacity reservation group list -g "$rg_name" 2>&1)
        print_error "Cannot access capacity reservations. Possible permission issue."
        print_error "Error details: $test_error"
        return 1
    fi
    
    # Check if the region supports capacity reservations by trying to list available VM sizes
    print_info "Validating region '$region' supports capacity reservations..."
    if ! az vm list-sizes --location "$region" > /dev/null 2>&1; then
        print_error "Cannot list VM sizes in region '$region'"
        return 1
    fi
    
    print_success "Capacity reservation prerequisites validated successfully"
    return 0
}

# Function to test capacity reservation creation with a simple test
test_capacity_reservation_creation() {
    local rg_name="$1"
    local region="$2" 
    local crg_name="$3"
    local zones="$4"
    
    print_info "Testing capacity reservation creation with a minimal test..."
    
    local test_reservation_name="test-reservation-$(date +%s)"
    local test_output
    
    # Get the first zone from the zones parameter, or use no zone if empty
    local test_zone=""
    if [[ -n "$zones" ]]; then
        test_zone=$(echo "$zones" | cut -d' ' -f1)
    fi
    
    # Try to create a small test reservation
    if [[ -n "$test_zone" ]]; then
        test_output=$(az capacity reservation create \
            -g "$rg_name" \
            -n "$test_reservation_name" \
            -c "$crg_name" \
            -s "Standard_B1s" \
            --capacity 1 \
            -z "$test_zone" 2>&1)
    else
        test_output=$(az capacity reservation create \
            -g "$rg_name" \
            -n "$test_reservation_name" \
            -c "$crg_name" \
            -s "Standard_B1s" \
            --capacity 1 2>&1)
    fi
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        print_success "Test reservation creation successful"
        # Clean up the test reservation
        az capacity reservation delete -g "$rg_name" -n "$test_reservation_name" -c "$crg_name" --yes > /dev/null 2>&1
        return 0
    else
        print_error "Test reservation creation failed"
        print_error "Error details: $test_output"
        
        # Parse common error patterns
        if echo "$test_output" | grep -i "quota\|limit" > /dev/null; then
            print_warning "This appears to be a quota/capacity limit issue"
        elif echo "$test_output" | grep -i "permission\|authorization\|forbidden" > /dev/null; then
            print_warning "This appears to be a permission issue"
        elif echo "$test_output" | grep -i "not.*supported\|not.*available" > /dev/null; then
            print_warning "Capacity reservations may not be supported in this region or for this VM size"
        elif echo "$test_output" | grep -i "availability zone" > /dev/null; then
            print_warning "This appears to be an availability zone configuration issue"
        fi
        
        return 1
    fi
}

# Function to create capacity reservation group
create_capacity_reservation_group() {
    local rg_name="$1"
    local region="$2"
    local crg_name="$3"
    local zones="$4"  # Comma-separated list of zones
    
    print_info "Creating Capacity Reservation Group '$crg_name' in region '$region' with zones: $zones..."
    
    local create_output
    if [[ -n "$zones" ]]; then
        # Create CRG with specific zones
        create_output=$(az capacity reservation group create -n "$crg_name" -g "$rg_name" -l "$region" -z $zones 2>&1)
    else
        # Create CRG without zones (for non-zonal deployments)
        create_output=$(az capacity reservation group create -n "$crg_name" -g "$rg_name" -l "$region" 2>&1)
    fi
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        print_success "Capacity Reservation Group '$crg_name' created successfully"
    else
        # Check if it already exists
        if az capacity reservation group show -n "$crg_name" -g "$rg_name" > /dev/null 2>&1; then
            print_warning "Capacity Reservation Group '$crg_name' already exists"
        else
            print_error "Failed to create Capacity Reservation Group '$crg_name'"
            print_error "Error details: $create_output"
            return 1
        fi
    fi
}

# Global associative array to track reservations for VM association
declare -A RESERVATION_MAP

# Function to validate capacity reservations exist
validate_reservations_exist() {
    local rg_name="$1"
    local crg_name="$2"
    
    print_info "Validating that capacity reservations were created successfully..."
    
    # Check if the capacity reservation group exists
    if ! az capacity reservation group show -g "$rg_name" -n "$crg_name" > /dev/null 2>&1; then
        print_error "Capacity Reservation Group '$crg_name' not found"
        return 1
    fi
    
    # Get list of reservations in the group
    local reservations
    reservations=$(az capacity reservation list -g "$rg_name" --capacity-reservation-group "$crg_name" --query '[].name' -o tsv 2>/dev/null)
    
    if [[ -z "$reservations" ]]; then
        print_error "No capacity reservations found in group '$crg_name'"
        return 1
    fi
    
    local reservation_count
    reservation_count=$(echo "$reservations" | wc -l)
    print_success "Found $reservation_count capacity reservation(s) in group '$crg_name'"
    
    return 0
}

# Function to associate VMs with capacity reservations
associate_vms_to_reservations() {
    local rg_name="$1"
    local crg_name="$2"
    local vm_info="$3"
    
    print_info "Associating VMs with capacity reservations..."
    
    # Check if RESERVATION_MAP is populated
    if [[ ${#RESERVATION_MAP[@]} -eq 0 ]]; then
        print_error "RESERVATION_MAP is empty! Cannot associate VMs."
        return 1
    fi
    
    # Get subscription ID once at the beginning
    local subscription_id
    subscription_id=$(az account show --query id -o tsv 2>&1)
    if [[ $? -ne 0 ]]; then
        print_error "Failed to get subscription ID: $subscription_id"
        return 1
    fi
    
    local crg_resource_id="/subscriptions/$subscription_id/resourceGroups/$rg_name/providers/Microsoft.Compute/capacityReservationGroups/$crg_name"
    
    # Pre-process VM data to avoid repeated jq parsing
    local vm_data_processed=()
    while IFS='|' read -r vm_name vm_size vm_zone; do
        if [[ -z "$vm_name" || "$vm_zone" == "null" || "$vm_zone" == "no-zone" ]]; then
            continue
        fi
        vm_data_processed+=("$vm_name|$vm_size|$vm_zone")
    done <<< "$(echo "$vm_info" | jq -r '.[] | "\(.name)|\(.size)|\(.zone // "no-zone")"')"
    
    local total_vms=${#vm_data_processed[@]}
    print_info "Total VMs to associate: $total_vms"
    
    if [[ $total_vms -eq 0 ]]; then
        print_warning "No VMs found to associate with capacity reservations"
        return 0
    fi
    
    # Check existing associations in batch to reduce API calls
    print_info "Checking existing VM associations in batch..."
    local existing_associations
    existing_associations=$(az vm list -g "$rg_name" --query '[].{name:name, crg:capacityReservation.capacityReservationGroup.id}' -o json 2>/dev/null)
    
    local successful_associations=0
    local failed_associations=0
    
    # Disable exit on error for the duration of this function to prevent early termination
    set +e
    
    # Process VMs
    for ((i=0; i<${#vm_data_processed[@]}; i++)); do
        IFS='|' read -r vm_name vm_size vm_zone <<< "${vm_data_processed[i]}"
        
        print_info "Processing VM $((i+1)) of $total_vms: $vm_name (Size: $vm_size, Zone: $vm_zone)"
        
        # Check if VM is already associated using pre-fetched data
        local existing_association=""
        if [[ -n "$existing_associations" ]]; then
            existing_association=$(echo "$existing_associations" | jq -r ".[] | select(.name==\"$vm_name\") | .crg // \"\"")
        fi
        
        if [[ -n "$existing_association" && "$existing_association" != "null" && "$existing_association" != "" ]]; then
            print_warning "VM '$vm_name' is already associated with a capacity reservation group, skipping..."
            ((successful_associations++))
            continue
        fi
        
        # Find the corresponding reservation
        local key="${vm_size}_${vm_zone}"
        local reservation_name="${RESERVATION_MAP[$key]}"
        
        if [[ -z "$reservation_name" ]]; then
            print_error "No reservation found for VM $vm_name (Size: $vm_size, Zone: $vm_zone)"
            ((failed_associations++))
            continue
        fi
        
        print_info "Associating VM '$vm_name' with reservation '$reservation_name'..."
        
        # Associate VM with capacity reservation
        local update_output
        update_output=$(az vm update -g "$rg_name" -n "$vm_name" --capacity-reservation-group "$crg_resource_id" 2>&1)
        local update_exit_code=$?
        
        if [[ $update_exit_code -eq 0 ]]; then
            print_success "Successfully associated VM '$vm_name' with reservation '$reservation_name'"
            ((successful_associations++))
        else
            print_error "Failed to associate VM '$vm_name' with capacity reservation"
            print_error "Update error details: $update_output"
            ((failed_associations++))
        fi
        
        # Reduced delay to speed up processing while still avoiding rate limiting
        sleep 0.5
        
    done
    
    # Re-enable exit on error
    set -e
    
    print_info "VM Association Summary:"
    print_success "Successfully associated: $successful_associations VMs"
    if [[ $failed_associations -gt 0 ]]; then
        print_error "Failed associations: $failed_associations VMs"
        print_warning "Check the error messages above for details on failed associations"
    else
        print_success "All VMs successfully associated with capacity reservations!"
    fi
}

# Function to create capacity reservations
create_capacity_reservations() {
    local rg_name="$1"
    local crg_name="$2"
    local analysis_data="$3"
    
    print_info "Creating capacity reservations..."
    
    while IFS= read -r item; do
        local size zone count available_zones
        size=$(echo "$item" | jq -r '.size')
        zone=$(echo "$item" | jq -r '.zone')
        count=$(echo "$item" | jq -r '.count')
        available_zones=$(echo "$item" | jq -r '.available_zones')
        
        # Skip if zone is "no-zone" (VMs not in availability zones)
        if [[ "$zone" == "no-zone" ]]; then
            print_warning "Skipping VMs of size '$size' as they are not deployed in availability zones"
            continue
        fi
        
        # Extract SKU size by removing "Standard_" prefix
        local sku_size="${size#Standard_}"
        local reservation_name="${crg_name}-${sku_size}-z${zone}"
        
        print_info "Creating reservation '$reservation_name' for VM size '$size' in zone '$zone' with $count instances..."
        
        # Capture the output and error from the command
        local create_output
        create_output=$(az capacity reservation create \
            -g "$rg_name" \
            -n "$reservation_name" \
            -c "$crg_name" \
            -s "$size" \
            --capacity "$count" \
            -z "$zone" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            print_success "Created reservation '$reservation_name' (Size: $size, Zone: $zone, Capacity: $count)"
            
            # Store reservation mapping for VM association
            local key="${size}_${zone}"
            RESERVATION_MAP["$key"]="$reservation_name"
        else
            print_error "Failed to create reservation '$reservation_name'"
            print_error "Error details: $create_output"
            print_warning "Continuing with next reservation..."
        fi
        
    done <<< "$(echo "$analysis_data" | jq -c '.[]')"
}

# Main function
main() {
    local crg_name=""
    local dry_run=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--crg-name)
                crg_name="$2"
                shift 2
                ;;
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    print_info "Starting On-Demand Capacity Reservation creation process..."
    
    # Execute the process
    check_prerequisites
    
    # Show current subscription
    show_current_subscription
    
    # Let user select resource group
    if ! select_resource_group; then
        print_error "Failed to select resource group"
        exit 1
    fi
    
    # Set default CRG name if not provided
    if [[ -z "$crg_name" ]]; then
        crg_name="${SELECTED_RG_NAME}-crg"
    fi
    
    print_info "Configuration Summary:"
    print_info "Subscription: $(az account show --query 'name' -o tsv)"
    print_info "Resource Group: $SELECTED_RG_NAME"
    print_info "Region: $SELECTED_RG_LOCATION"
    print_info "Capacity Reservation Group: $crg_name"
    
    # Validate and process
    validate_resource_group_and_get_vms "$SELECTED_RG_NAME"
    
    print_info "Getting VM information..."
    local vm_info
    vm_info=$(get_vm_info "$SELECTED_RG_NAME")
    
    print_info "Analyzing VM distribution..."
    
    # Check if vm_info is valid JSON
    if ! echo "$vm_info" | jq empty 2>/dev/null; then
        print_error "Invalid JSON returned from VM query: $vm_info"
        exit 1
    fi
    
    # Simple direct processing instead of function call
    local vm_count=$(echo "$vm_info" | jq '. | length')
    print_info "Found $vm_count VM(s) to analyze"
    
    if [[ $vm_count -eq 0 ]]; then
        print_warning "No VMs found in resource group"
        exit 0
    fi
    
    # Create analysis data by aggregating VMs by size and zone
    print_info "Aggregating VMs by size and availability zone..."
    
    # Use associative arrays to count VMs by size+zone combination
    declare -A vm_counts
    declare -A size_zone_map
    
    while read -r vm_name vm_size vm_zone vm_location; do
        if [[ -z "$vm_name" ]]; then continue; fi
        
        print_info "Processing VM: $vm_name (Size: $vm_size, Zone: $vm_zone)"
        
        if [[ "$vm_zone" == "null" || "$vm_zone" == "no-zone" ]]; then
            print_warning "VM $vm_name is not in an availability zone, skipping"
            continue
        fi
        
        # Create a unique key for size+zone combination
        local key="${vm_size}_${vm_zone}"
        
        # Increment count for this size+zone combination
        if [[ -n "${vm_counts[$key]}" ]]; then
            vm_counts[$key]=$((vm_counts[$key] + 1))
        else
            vm_counts[$key]=1
            size_zone_map[$key]="${vm_size}|${vm_zone}"
        fi
        
    done <<< "$(echo "$vm_info" | jq -r '.[] | "\(.name) \(.size) \(.zone // "no-zone") \(.location)"')"
    
    # Build analysis data from aggregated counts and collect unique zones
    local analysis_data="["
    local first=true
    declare -A unique_zones
    
    for key in "${!vm_counts[@]}"; do
        local size_zone="${size_zone_map[$key]}"
        local vm_size="${size_zone%|*}"
        local vm_zone="${size_zone#*|}"
        local count="${vm_counts[$key]}"
        
        print_info "Found $count VM(s) of size '$vm_size' in zone '$vm_zone'"
        
        # Collect unique zones
        unique_zones["$vm_zone"]=1
        
        if [[ "$first" == "true" ]]; then
            first=false
        else
            analysis_data="$analysis_data,"
        fi
        
        analysis_data="$analysis_data{\"size\":\"$vm_size\",\"zone\":\"$vm_zone\",\"count\":$count,\"available_zones\":\"$vm_zone\"}"
    done
    
    analysis_data="$analysis_data]"
    
    # Create zones parameter for CRG
    local zones_param=""
    local zones_list=()
    for zone in "${!unique_zones[@]}"; do
        zones_list+=("$zone")
    done
    
    # Sort zones for consistent ordering
    IFS=$'\n' sorted_zones=($(sort <<<"${zones_list[*]}"))
    unset IFS
    
    if [[ ${#sorted_zones[@]} -gt 0 ]]; then
        zones_param=$(IFS=' '; echo "${sorted_zones[*]}")
        print_info "Detected availability zones: $zones_param"
    fi
    
    # Check if this is a dry run
    if [[ "$dry_run" == "true" ]]; then
        print_info "=== DRY RUN MODE - No changes will be made ==="
        print_info "The following actions would be performed:"
        print_info "1. Create Capacity Reservation Group: $crg_name"
        print_info "2. Create the following capacity reservations:"
        
        for key in "${!vm_counts[@]}"; do
            local size_zone="${size_zone_map[$key]}"
            local vm_size="${size_zone%|*}"
            local vm_zone="${size_zone#*|}"
            local count="${vm_counts[$key]}"
            print_info "   - Size: $vm_size, Zone: $vm_zone, Capacity: $count"
        done
        
        print_info "3. Associate the following VMs with capacity reservations:"
        while read -r vm_name vm_size vm_zone vm_location; do
            if [[ -z "$vm_name" || "$vm_zone" == "null" || "$vm_zone" == "no-zone" ]]; then
                continue
            fi
            print_info "   - VM: $vm_name (Size: $vm_size, Zone: $vm_zone)"
        done <<< "$(echo "$vm_info" | jq -r '.[] | "\(.name) \(.size) \(.zone // "no-zone") \(.location)"')"
        
        print_warning "This was a dry run. No actual changes were made."
        print_info "To execute these changes, run the script without --dry-run option."
    else
        # Show confirmation prompt with summary of what will be created
        print_info "=== CONFIRMATION - The following actions will be performed ==="
        print_info "Subscription: $(az account show --query 'name' -o tsv)"
        print_info "Resource Group: $SELECTED_RG_NAME"
        print_info "Region: $SELECTED_RG_LOCATION"
        print_info "Capacity Reservation Group: $crg_name"
        print_info "1. Create Capacity Reservation Group: $crg_name"
        print_info "2. Create the following capacity reservations:"
        
        for key in "${!vm_counts[@]}"; do
            local size_zone="${size_zone_map[$key]}"
            local vm_size="${size_zone%|*}"
            local vm_zone="${size_zone#*|}"
            local count="${vm_counts[$key]}"
            local sku_size="${vm_size#Standard_}"
            print_info "   - Name: ${crg_name}-${sku_size}-z${vm_zone}"
            print_info "     Size: $vm_size, Zone: $vm_zone, Capacity: $count"
        done
        
        print_info "3. Associate the following VMs with capacity reservations:"
        while read -r vm_name vm_size vm_zone vm_location; do
            if [[ -z "$vm_name" || "$vm_zone" == "null" || "$vm_zone" == "no-zone" ]]; then
                continue
            fi
            local sku_size="${vm_size#Standard_}"
            print_info "   - VM: $vm_name → Reservation: ${crg_name}-${sku_size}-z${vm_zone}"
        done <<< "$(echo "$vm_info" | jq -r '.[] | "\(.name) \(.size) \(.zone // "no-zone") \(.location)"')"
        
        print_warning "This will create Azure resources."
        
        # Get user confirmation
        while true; do
            read -p "Do you want to proceed with creating these capacity reservations? (y/n): " yn
            case $yn in
                [Yy]* )
                    print_info "Proceeding with capacity reservation creation..."
                    break
                    ;;
                [Nn]* )
                    print_info "Operation cancelled by user."
                    exit 0
                    ;;
                * )
                    print_error "Please answer yes (y) or no (n)."
                    ;;
            esac
        done
        
        print_info "Creating capacity reservations..."
        
        # Validate prerequisites before attempting creation
        if ! validate_capacity_reservation_prerequisites "$SELECTED_RG_NAME" "$SELECTED_RG_LOCATION"; then
            print_error "Prerequisite validation failed. Cannot proceed."
            exit 1
        fi
        
        create_capacity_reservation_group "$SELECTED_RG_NAME" "$SELECTED_RG_LOCATION" "$crg_name" "$zones_param"
        
        # Test capacity reservation creation before processing all VMs
        if ! test_capacity_reservation_creation "$SELECTED_RG_NAME" "$SELECTED_RG_LOCATION" "$crg_name" "$zones_param"; then
            print_error "Capacity reservation test failed. This indicates there may be issues with quota, permissions, or regional support."
            print_warning "Continuing anyway, but expect similar failures..."
        fi
        
        create_capacity_reservations "$SELECTED_RG_NAME" "$crg_name" "$analysis_data"
        
        # Validate reservations were created successfully
        if validate_reservations_exist "$SELECTED_RG_NAME" "$crg_name"; then
            # Associate VMs with their capacity reservations
            print_info "Proceeding with VM associations..."
            associate_vms_to_reservations "$SELECTED_RG_NAME" "$crg_name" "$vm_info"
            
            print_success "On-Demand Capacity Reservation creation and VM association process completed!"
            print_info "You can view your capacity reservations using:"
            print_info "az capacity reservation list -g $SELECTED_RG_NAME --capacity-reservation-group $crg_name"
            print_info "To verify VM associations, check VM properties with:"
            print_info "az vm show -g $SELECTED_RG_NAME -n <vm-name> --query capacityReservation"
        else
            print_error "Capacity reservations validation failed, but attempting VM associations anyway..."
            print_warning "Some reservations may not have been created successfully"
            associate_vms_to_reservations "$SELECTED_RG_NAME" "$crg_name" "$vm_info"
            
            print_warning "Process completed with some issues - check the logs above for details"
        fi
    fi
}

# Run main function with all arguments
main "$@"
