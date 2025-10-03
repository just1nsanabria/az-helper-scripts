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
Usage: $0 [-n <crg-name>] [-h]

Options:
    -n, --crg-name        Capacity Reservation Group name (optional, defaults to <rg-name>-crg)
    -h, --help            Display this help message

The script will:
1. Use your current Azure CLI subscription
2. Let you choose from available resource groups
3. Automatically detect the region from the selected resource group

Examples:
    $0
    $0 -n myCustomCRG

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
    
    echo ""
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
    
    echo ""
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
        echo ""
        print_info "Resource groups with VMs:"
        az vm list --query '[].resourceGroup' --output tsv | sort | uniq -c | while read count rg; do
            echo "  $rg: $count VMs"
        done
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
        echo ""
        print_info "VM Distribution Summary:"
        printf "%-20s %-10s %-15s\n" "VM Size" "Zone" "Count"
        printf "%-20s %-10s %-15s\n" "--------" "----" "-----"
        
        while IFS='|' read -r vm_name size zone location; do
            if [[ -z "$vm_name" || "$zone" == "no-zone" || "$zone" == "null" ]]; then
                continue
            fi
            printf "%-20s %-10s %-15s\n" "$size" "$zone" "1"
        done <<< "$vm_data"
        echo ""
    fi
    
    echo "$analysis_json"
}

# Function to associate VMs with capacity reservation group
associate_vms_with_capacity_reservation() {
    local rg_name="$1"
    local crg_name="$2"
    
    print_info "Associating VMs with capacity reservation group '$crg_name'..."
    
    # Get all VMs in the resource group
    local vm_list
    vm_list=$(az vm list -g "$rg_name" --query '[].{name:name, zone:zones[0], size:hardwareProfile.vmSize}' -o json)
    
    if [[ $(echo "$vm_list" | jq '. | length') -eq 0 ]]; then
        print_warning "No VMs found to associate"
        return 0
    fi
    
    local associated_count=0
    local skipped_count=0
    
    while read -r vm_name vm_zone vm_size; do
        if [[ -z "$vm_name" ]]; then continue; fi
        
        print_info "Associating VM: $vm_name (Size: $vm_size, Zone: $vm_zone)"
        
        # Skip VMs not in availability zones
        if [[ "$vm_zone" == "null" || "$vm_zone" == "no-zone" ]]; then
            print_warning "VM $vm_name is not in an availability zone, skipping association"
            ((skipped_count++))
            continue
        fi
        
        # Update the VM to use the capacity reservation group
        local update_output
        update_output=$(az vm update \
            -g "$rg_name" \
            -n "$vm_name" \
            --capacity-reservation-group "$crg_name" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            print_success "Successfully associated VM '$vm_name' with capacity reservation group"
            ((associated_count++))
        else
            print_error "Failed to associate VM '$vm_name' with capacity reservation group"
            print_error "Error details: $update_output"
        fi
        
    done <<< "$(echo "$vm_list" | jq -r '.[] | "\(.name) \(.zone // "no-zone") \(.size)"')"
    
    echo ""
    print_info "VM Association Summary:"
    print_info "Successfully associated: $associated_count VMs"
    if [[ $skipped_count -gt 0 ]]; then
        print_warning "Skipped (not in availability zones): $skipped_count VMs"
    fi
    echo ""
}

# Function to create capacity reservation group
create_capacity_reservation_group() {
    local rg_name="$1"
    local region="$2"
    local crg_name="$3"
    
    print_info "Creating Capacity Reservation Group '$crg_name' in region '$region'..."
    
    # Get the zones used by VMs in the resource group
    local zones_used
    zones_used=$(az vm list -g "$rg_name" --query '[].zones[0]' -o tsv 2>/dev/null | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')
    
    if [[ -n "$zones_used" ]]; then
        print_info "Creating capacity reservation group with zones: $zones_used"
        local create_output
        create_output=$(az capacity reservation group create -n "$crg_name" -g "$rg_name" -l "$region" --zones $zones_used 2>&1)
        local exit_code=$?
    else
        print_info "Creating capacity reservation group (no zones)"
        local create_output
        create_output=$(az capacity reservation group create -n "$crg_name" -g "$rg_name" -l "$region" 2>&1)
        local exit_code=$?
    fi
    
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

# Function to create capacity reservations
create_capacity_reservations() {
    local rg_name="$1"
    local crg_name="$2"
    local analysis_data="$3"
    
    print_info "Creating capacity reservations..."
    
    local reservation_counter=1
    
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
        
        local reservation_name="${crg_name}-reservation-${reservation_counter}"
        
        print_info "Creating reservation '$reservation_name' for VM size '$size' in zone '$zone' with $count instances..."
        
        local create_output
        create_output=$(az capacity reservation create \
            -g "$rg_name" \
            -n "$reservation_name" \
            -c "$crg_name" \
            -s "$size" \
            --capacity "$count" \
            -z "$zone" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            print_success "Created reservation '$reservation_name' (Size: $size, Zone: $zone, Capacity: $count)"
        else
            print_error "Failed to create reservation '$reservation_name'"
            print_error "Error details: $create_output"
        fi
        
        ((reservation_counter++))
        
    done <<< "$(echo "$analysis_data" | jq -c '.[]')"
}

# Main function
main() {
    local crg_name=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--crg-name)
                crg_name="$2"
                shift 2
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
    echo ""
    
    # Execute the process
    check_prerequisites
    
    # Show current subscription
    show_current_subscription
    echo ""
    
    # Let user select resource group
    if ! select_resource_group; then
        print_error "Failed to select resource group"
        exit 1
    fi
    
    # Set default CRG name if not provided
    if [[ -z "$crg_name" ]]; then
        crg_name="${SELECTED_RG_NAME}-crg"
    fi
    
    echo ""
    print_info "Configuration Summary:"
    print_info "Subscription: $(az account show --query 'name' -o tsv)"
    print_info "Resource Group: $SELECTED_RG_NAME"
    print_info "Region: $SELECTED_RG_LOCATION"
    print_info "Capacity Reservation Group: $crg_name"
    echo ""
    
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
    
    # Create analysis data directly
    local analysis_data="["
    local first=true
    
    while read -r vm_name vm_size vm_zone vm_location; do
        if [[ -z "$vm_name" ]]; then continue; fi
        
        print_info "Processing VM: $vm_name (Size: $vm_size, Zone: $vm_zone)"
        
        if [[ "$vm_zone" == "null" || "$vm_zone" == "no-zone" ]]; then
            print_warning "VM $vm_name is not in an availability zone, skipping"
            continue
        fi
        
        if [[ "$first" == "true" ]]; then
            first=false
        else
            analysis_data="$analysis_data,"
        fi
        
        analysis_data="$analysis_data{\"size\":\"$vm_size\",\"zone\":\"$vm_zone\",\"count\":1,\"available_zones\":\"$vm_zone\"}"
        
    done <<< "$(echo "$vm_info" | jq -r '.[] | "\(.name) \(.size) \(.zone // "no-zone") \(.location)"')"
    
    analysis_data="$analysis_data]"
    
    print_info "Creating capacity reservations..."
    create_capacity_reservation_group "$SELECTED_RG_NAME" "$SELECTED_RG_LOCATION" "$crg_name"
    create_capacity_reservations "$SELECTED_RG_NAME" "$crg_name" "$analysis_data"
    
    # Associate VMs with the capacity reservation group
    associate_vms_with_capacity_reservation "$SELECTED_RG_NAME" "$crg_name"
    
    echo ""
    print_success "On-Demand Capacity Reservation creation process completed!"
    print_info "You can view your capacity reservations using:"
    print_info "az capacity reservation list -g $SELECTED_RG_NAME --capacity-reservation-group $crg_name"
    echo ""
    print_info "You can view VM associations using:"
    print_info "az vm show -g $SELECTED_RG_NAME -n <vm-name> --query 'capacityReservation'"
}

# Run main function with all arguments
main "$@"
