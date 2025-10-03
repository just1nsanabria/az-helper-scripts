#!/bin/bash

# VMSS Recreation Script
# This script discovers existing VMSS in your subscription and recreates them in a target region
# with updated nomenclature (e.g., EUS2 -> SCUS, WUS2 -> EUS2, etc.)

set -e

# Global variables
SOURCE_REGION_CODE=""
SOURCE_LOCATION=""
TARGET_REGION_CODE=""
TARGET_LOCATION=""
TARGET_RG=""
TARGET_ZONES=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to validate prerequisites
validate_prerequisites() {
    print_info "Validating prerequisites..."
    
    # Check if Azure CLI is installed and logged in
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check if logged in to Azure
    if ! az account show &> /dev/null; then
        print_error "Not logged in to Azure. Please run 'az login' first."
        exit 1
    fi
    
    print_success "Prerequisites validated successfully"
}

# Function to get available Azure regions
get_available_regions() {
    print_info "Getting available Azure regions..."
    az account list-locations --query "[].{Name:name, DisplayName:displayName}" --output table 2>/dev/null || {
        print_error "Failed to get Azure regions. Please check your Azure CLI login."
        exit 1
    }
}

# Function to validate and get source region
get_source_region() {
    echo ""
    print_info "SELECT SOURCE REGION"
    print_info "Available Azure regions:"
    get_available_regions
    
    echo ""
    print_info "Common region codes: eastus2 (EUS2), southcentralus (SCUS), westus2 (WUS2), centralus (CUS), etc."
    echo ""
    
    while true; do
        read -p "Enter source Azure region to migrate FROM (e.g., swedencentral, eastus2, westus2): " SOURCE_LOCATION
        
        if [[ -z "$SOURCE_LOCATION" ]]; then
            print_error "Source region cannot be empty"
            continue
        fi
        
        # Validate the region exists
        if az account list-locations --query "[?name=='$SOURCE_LOCATION']" --output tsv | grep -q "$SOURCE_LOCATION"; then
            print_success "Source region '$SOURCE_LOCATION' validated successfully"
            break
        else
            print_error "Invalid region '$SOURCE_LOCATION'. Please enter a valid Azure region name."
        fi
    done
    
    # Determine source region code mapping
    case "$SOURCE_LOCATION" in
        "southcentralus") SOURCE_REGION_CODE="SCUS" ;;
        "eastus2") SOURCE_REGION_CODE="EUS2" ;;
        "westus2") SOURCE_REGION_CODE="WUS2" ;;
        "centralus") SOURCE_REGION_CODE="CUS" ;;
        "eastus") SOURCE_REGION_CODE="EUS" ;;
        "westus") SOURCE_REGION_CODE="WUS" ;;
        "northcentralus") SOURCE_REGION_CODE="NCUS" ;;
        "westcentralus") SOURCE_REGION_CODE="WCUS" ;;
        "eastus2euap") SOURCE_REGION_CODE="EUS2E" ;;
        "swedencentral") SOURCE_REGION_CODE="SDC" ;;
        "norwayeast") SOURCE_REGION_CODE="NOE" ;;
        "francecentral") SOURCE_REGION_CODE="FRC" ;;
        "germanywestcentral") SOURCE_REGION_CODE="GWC" ;;
        "uksouth") SOURCE_REGION_CODE="UKS" ;;
        "switzerlandnorth") SOURCE_REGION_CODE="SZN" ;;
        *) 
            print_warning "Unknown region code mapping for '$SOURCE_LOCATION'"
            read -p "Enter the source region code (e.g., SCUS, EUS2, WUS2, SDC): " SOURCE_REGION_CODE
            if [[ -z "$SOURCE_REGION_CODE" ]]; then
                print_error "Source region code cannot be empty"
                exit 1
            fi
            ;;
    esac
    
    print_success "Source region code set to: $SOURCE_REGION_CODE"
}

# Function to validate and get target region
get_target_region() {
    echo ""
    print_info "SELECT TARGET REGION"
    print_info "Available Azure regions:"
    get_available_regions
    
    echo ""
    print_info "Common region codes: eastus2 (EUS2), southcentralus (SCUS), westus2 (WUS2), centralus (CUS), etc."
    echo ""
    
    while true; do
        read -p "Enter target Azure region to migrate TO (e.g., southcentralus, eastus2, westus2): " TARGET_LOCATION
        
        if [[ -z "$TARGET_LOCATION" ]]; then
            print_error "Target region cannot be empty"
            continue
        fi
        
        # Validate the region exists
        if az account list-locations --query "[?name=='$TARGET_LOCATION']" --output tsv | grep -q "$TARGET_LOCATION"; then
            print_success "Target region '$TARGET_LOCATION' validated successfully"
            break
        else
            print_error "Invalid region '$TARGET_LOCATION'. Please enter a valid Azure region name."
        fi
    done
    
    # Determine region code mapping
    case "$TARGET_LOCATION" in
        "southcentralus") TARGET_REGION_CODE="SCUS" ;;
        "eastus2") TARGET_REGION_CODE="EUS2" ;;
        "westus2") TARGET_REGION_CODE="WUS2" ;;
        "centralus") TARGET_REGION_CODE="CUS" ;;
        "eastus") TARGET_REGION_CODE="EUS" ;;
        "westus") TARGET_REGION_CODE="WUS" ;;
        "northcentralus") TARGET_REGION_CODE="NCUS" ;;
        "westcentralus") TARGET_REGION_CODE="WCUS" ;;
        "eastus2euap") TARGET_REGION_CODE="EUS2E" ;;
        *) 
            print_warning "Unknown region code mapping for '$TARGET_LOCATION'"
            read -p "Enter the region code (e.g., SCUS, EUS2, WUS2): " TARGET_REGION_CODE
            if [[ -z "$TARGET_REGION_CODE" ]]; then
                print_error "Region code cannot be empty"
                exit 1
            fi
            ;;
    esac
    
    print_success "Target region code set to: $TARGET_REGION_CODE"
}

# Function to get target zones selection
get_target_zones() {
    echo ""
    print_info "Zone selection for target VMSS:"
    print_info "Available options:"
    print_info "  1. No zones (single zone deployment)"
    print_info "  2. Zone 1 only"
    print_info "  3. Zone 2 only" 
    print_info "  4. Zone 3 only"
    print_info "  5. Zones 1 and 2"
    print_info "  6. Zones 1 and 3"
    print_info "  7. Zones 2 and 3"
    print_info "  8. All zones (1, 2, and 3)"
    print_info "  9. Custom zone selection"
    
    echo ""
    while true; do
        read -p "Select zone configuration (1-9): " zone_choice
        
        case "$zone_choice" in
            1)
                TARGET_ZONES=""
                print_success "Selected: No zones (single zone deployment)"
                break
                ;;
            2)
                TARGET_ZONES="1"
                print_success "Selected: Zone 1 only"
                break
                ;;
            3)
                TARGET_ZONES="2"
                print_success "Selected: Zone 2 only"
                break
                ;;
            4)
                TARGET_ZONES="3"
                print_success "Selected: Zone 3 only"
                break
                ;;
            5)
                TARGET_ZONES="1 2"
                print_success "Selected: Zones 1 and 2"
                break
                ;;
            6)
                TARGET_ZONES="1 3"
                print_success "Selected: Zones 1 and 3"
                break
                ;;
            7)
                TARGET_ZONES="2 3"
                print_success "Selected: Zones 2 and 3"
                break
                ;;
            8)
                TARGET_ZONES="1 2 3"
                print_success "Selected: All zones (1, 2, and 3)"
                break
                ;;
            9)
                echo ""
                print_info "Enter zones separated by spaces (e.g., '1 3' or '2'):"
                read -p "Custom zones: " custom_zones
                
                # Validate custom zones
                if [[ -n "$custom_zones" ]]; then
                    # Check if all entries are valid zone numbers (1, 2, or 3)
                    valid_zones=true
                    for zone in $custom_zones; do
                        if [[ ! "$zone" =~ ^[1-3]$ ]]; then
                            valid_zones=false
                            break
                        fi
                    done
                    
                    if $valid_zones; then
                        # Remove duplicates and sort
                        TARGET_ZONES=$(echo "$custom_zones" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
                        print_success "Selected custom zones: $TARGET_ZONES"
                        break
                    else
                        print_error "Invalid zones. Please enter only numbers 1, 2, or 3."
                    fi
                else
                    print_error "No zones entered. Please try again."
                fi
                ;;
            *)
                print_error "Invalid choice. Please enter a number between 1-9."
                ;;
        esac
    done
}

# Function to get target resource group from user
get_target_resource_group() {
    echo ""
    print_info "Please specify the target resource group for the new VMSS:"
    
    # List existing resource groups in target region
    print_info "Available resource groups in $TARGET_LOCATION region:"
    az group list --query "[?location=='$TARGET_LOCATION'].{Name:name}" --output table 2>/dev/null || true
    
    echo ""
    read -p "Enter target resource group name: " TARGET_RG
    
    if [[ -z "$TARGET_RG" ]]; then
        print_error "Resource group name cannot be empty"
        exit 1
    fi
    
    # Check if resource group exists
    if ! az group show --name "$TARGET_RG" &> /dev/null; then
        print_warning "Resource group '$TARGET_RG' does not exist."
        read -p "Do you want to create it in $TARGET_LOCATION? (y/N): " create_rg
        
        if [[ "$create_rg" == "y" || "$create_rg" == "Y" ]]; then
            print_info "Creating resource group '$TARGET_RG' in $TARGET_LOCATION..."
            az group create --name "$TARGET_RG" --location "$TARGET_LOCATION"
            print_success "Resource group created successfully"
        else
            print_error "Cannot proceed without a valid resource group"
            exit 1
        fi
    fi
}

# Function to discover existing VMSS with region patterns
discover_vmss() {
    print_info "Discovering existing VMSS in source region ($SOURCE_LOCATION)..." >&2
    
    # Get all VMSS in subscription, filtered by source location
    VMSS_LIST=$(az vmss list --query "[?location=='$SOURCE_LOCATION'].{Name:name, ResourceGroup:resourceGroup, Location:location}" --output json 2>/dev/null)
    
    # Check if command failed or returned empty/invalid JSON
    if [[ $? -ne 0 ]] || [[ -z "$VMSS_LIST" ]] || [[ "$VMSS_LIST" == "null" ]]; then
        print_error "Failed to retrieve VMSS list from Azure. Please check your subscription and permissions." >&2
        exit 1
    fi
    
    if [[ "$VMSS_LIST" == "[]" ]]; then
        print_warning "No VMSS found in source region '$SOURCE_LOCATION'" >&2
        exit 0
    fi
    
    # Validate JSON before processing
    if ! echo "$VMSS_LIST" | jq empty 2>/dev/null; then
        print_error "Invalid JSON returned from Azure CLI. Raw output: $VMSS_LIST" >&2
        exit 1
    fi
    
    # Try to filter for VMSS with common region codes in their names
    # First, try to find VMSS with any region code patterns
    REGION_CODED_VMSS=$(echo "$VMSS_LIST" | jq '[.[] | select(.Name | test("(EUS2|WUS2|SCUS|CUS|EUS|WUS|NCUS|WCUS|SDC|NOE|FRC|GWC|UKS|SZN)"))]' 2>/dev/null)
    
    if [[ -n "$REGION_CODED_VMSS" && "$REGION_CODED_VMSS" != "[]" ]]; then
        # Found VMSS with region codes in names
        FILTERED_VMSS="$REGION_CODED_VMSS"
        print_info "Found VMSS with region codes in their names (will transform region codes in names):" >&2
        echo "$FILTERED_VMSS" | jq -r '.[] | "- \(.Name) (RG: \(.ResourceGroup))"' >&2 2>/dev/null
    else
        # No region codes found, offer to migrate all VMSS from source region
        print_warning "No VMSS found with region codes in their names in '$SOURCE_LOCATION'" >&2
        print_info "All VMSS in source region '$SOURCE_LOCATION':" >&2
        echo "$VMSS_LIST" | jq -r '.[] | "- \(.Name) (RG: \(.ResourceGroup))"' >&2 2>/dev/null || {
            print_error "Error displaying VMSS list" >&2
            exit 1
        }
        
        echo -n "Do you want to proceed with all VMSS in $SOURCE_LOCATION? (y/N): " >&2
        read proceed_all
        if [[ "$proceed_all" != "y" && "$proceed_all" != "Y" ]]; then
            exit 0
        fi
        FILTERED_VMSS="$VMSS_LIST"
    fi
    
    if [[ $? -ne 0 ]] || [[ -z "$FILTERED_VMSS" ]]; then
        print_error "Error processing VMSS data." >&2
        exit 1
    fi
    
    echo "" >&2
    print_success "Found VMSS in source region ($SOURCE_LOCATION):" >&2
    echo "$FILTERED_VMSS" | jq -r '.[] | "- \(.Name) (RG: \(.ResourceGroup), Location: \(.Location))"' >&2 2>/dev/null || {
        print_error "Error displaying filtered VMSS list" >&2
        exit 1
    }
    
    echo "$FILTERED_VMSS"
}

# Function to get VMSS configuration
get_vmss_config() {
    local vmss_name="$1"
    local resource_group="$2"
    
    print_info "Getting configuration for VMSS: $vmss_name" >&2
    
    # Get VMSS details
    VMSS_CONFIG=$(az vmss show --name "$vmss_name" --resource-group "$resource_group" --output json 2>/dev/null)
    
    if [[ $? -ne 0 ]] || [[ -z "$VMSS_CONFIG" ]] || [[ "$VMSS_CONFIG" == "null" ]]; then
        print_error "Failed to get configuration for VMSS: $vmss_name" >&2
        return 1
    fi
    
    # Validate JSON
    if ! echo "$VMSS_CONFIG" | jq empty 2>/dev/null; then
        print_error "Invalid JSON configuration for VMSS: $vmss_name" >&2
        return 1
    fi
    
    echo "$VMSS_CONFIG"
}

# Function to create new VMSS name with target region
create_new_vmss_name() {
    local original_name="$1"
    
    # Replace source region code with target region code
    if [[ -n "$SOURCE_REGION_CODE" && -n "$TARGET_REGION_CODE" ]]; then
        NEW_NAME=$(echo "$original_name" | sed "s/$SOURCE_REGION_CODE/$TARGET_REGION_CODE/g")
    else
        # Fallback: try to replace common region codes
        NEW_NAME="$original_name"
        for region in EUS2 WUS2 SCUS CUS EUS WUS NCUS WCUS; do
            if [[ "$original_name" == *"$region"* && "$region" != "$TARGET_REGION_CODE" ]]; then
                NEW_NAME=$(echo "$original_name" | sed "s/$region/$TARGET_REGION_CODE/g")
                break
            fi
        done
    fi
    
    echo "$NEW_NAME"
}

# Function to create VMSS in target region
create_vmss_in_target_region() {
    local vmss_config="$1"
    local new_name="$2"
    
    print_info "Creating VMSS: $new_name in $TARGET_LOCATION region..." >&2
    
    # Extract key configuration parameters
    ORCHESTRATION_MODE=$(echo "$vmss_config" | jq -r '.orchestrationMode // "Flexible"')
    
    # Use selected target zones instead of source zones
    ZONES="$TARGET_ZONES"
    
    # Extract platform fault domain count if available
    FAULT_DOMAINS=$(echo "$vmss_config" | jq -r '.platformFaultDomainCount // 1')
    
    print_info "Configuration extracted:" >&2
    print_info "  Orchestration Mode: $ORCHESTRATION_MODE" >&2
    print_info "  Target Zones: ${ZONES:-"None"}" >&2
    print_info "  Platform Fault Domain Count: $FAULT_DOMAINS" >&2
    
    # Build the create command using your specified format
    CREATE_CMD="az vmss create"
    CREATE_CMD="$CREATE_CMD --name '$new_name'"
    CREATE_CMD="$CREATE_CMD --resource-group '$TARGET_RG'"
    CREATE_CMD="$CREATE_CMD --orchestration-mode '$ORCHESTRATION_MODE'"
    CREATE_CMD="$CREATE_CMD --platform-fault-domain-count $FAULT_DOMAINS"
    CREATE_CMD="$CREATE_CMD --single-placement-group false"
    
    # Add zones if they exist
    if [[ -n "$ZONES" ]]; then
        CREATE_CMD="$CREATE_CMD --zones $ZONES"
    fi
    
    print_info "Executing: $CREATE_CMD" >&2
    
    # Execute the command
    eval "$CREATE_CMD" >&2
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        print_success "VMSS '$new_name' created successfully in $TARGET_LOCATION" >&2
        return 0
    else
        print_error "Failed to create VMSS '$new_name' (exit code: $exit_code)" >&2
        return 1
    fi
}

# Main execution function
main() {
    echo "=========================================="
    echo "    VMSS Recreation Script (Multi-Region)"
    echo "=========================================="
    echo ""
    
    validate_prerequisites
    get_source_region
    get_target_region
    
    # Discover VMSS
    VMSS_DATA=$(discover_vmss)
    
    if [[ -z "$VMSS_DATA" || "$VMSS_DATA" == "[]" ]]; then
        print_warning "No suitable VMSS found for recreation"
        exit 0
    fi
    
    get_target_resource_group
    get_target_zones
    
    # Process each VMSS
    VMSS_COUNT=$(echo "$VMSS_DATA" | jq length)
    print_info "Found $VMSS_COUNT VMSS to migrate"
    
    echo ""
    print_info "Recreation plan:"
    print_info "  Source location: $SOURCE_LOCATION"
    print_info "  Source region code: $SOURCE_REGION_CODE"
    print_info "  Target location: $TARGET_LOCATION"
    print_info "  Target region code: $TARGET_REGION_CODE"
    print_info "  Target resource group: $TARGET_RG"
    print_info "  Target zones: ${TARGET_ZONES:-"None (single zone)"}"
    echo ""
    read -p "Do you want to proceed with creating these VMSS in $TARGET_LOCATION region? (y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "Operation cancelled by user"
        exit 0
    fi
    
    echo ""
    SUCCESS_COUNT=0
    FAILED_COUNT=0
    
    # Disable exit on error for the processing loop
    set +e
    
    for i in $(seq 0 $((VMSS_COUNT-1))); do
        VMSS_NAME=$(echo "$VMSS_DATA" | jq -r ".[$i].Name")
        VMSS_RG=$(echo "$VMSS_DATA" | jq -r ".[$i].ResourceGroup")
        NEW_VMSS_NAME=$(create_new_vmss_name "$VMSS_NAME")
        
        echo ""
        print_info "Processing VMSS $((i+1))/$VMSS_COUNT: $VMSS_NAME -> $NEW_VMSS_NAME"
        
        # Check if target VMSS already exists
        if az vmss show --name "$NEW_VMSS_NAME" --resource-group "$TARGET_RG" &> /dev/null; then
            print_warning "VMSS '$NEW_VMSS_NAME' already exists in target resource group. Skipping..."
            continue
        fi
        
        # Get source VMSS configuration
        VMSS_CONFIG=$(get_vmss_config "$VMSS_NAME" "$VMSS_RG")
        
        if [[ -n "$VMSS_CONFIG" ]]; then
            if create_vmss_in_target_region "$VMSS_CONFIG" "$NEW_VMSS_NAME"; then
                ((SUCCESS_COUNT++))
            else
                ((FAILED_COUNT++))
            fi
        else
            print_error "Skipping VMSS '$VMSS_NAME' due to configuration retrieval failure"
            ((FAILED_COUNT++))
        fi
    done
    
    # Re-enable exit on error
    set -e
    
    echo ""
    echo "========================================="
    print_success "Recreation Summary:"
    print_success "  Successfully created: $SUCCESS_COUNT VMSS"
    if [[ $FAILED_COUNT -gt 0 ]]; then
        print_error "  Failed to create: $FAILED_COUNT VMSS"
    fi
    echo "========================================="
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
