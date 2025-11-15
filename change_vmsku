#!/bin/bash

source_sku_1=""
source_sku_2=""
target_sku=""
resource_group=""

for resource_group in "${resource_group[@]}"; do
    echo "Checking resource group: $resource_group"

    ## VMs with matching SKUs ##
    vm_list=$(az vm list --resource-group "$resource_group" --query "[?hardwareProfile.vmSize=='$source_sku_1' || hardwareProfile.vmSize=='$source_sku_2'].name" -o tsv)

    if [ -z "$vm_list" ]; then
        echo "No matching VMs found in $resource_group"
        continue
    fi

    for vm_name in $vm_list; do
        echo "Processing VM: $vm_name in $resource_group"

        ## Deallocate VM ##
        az vm deallocate --resource-group "$resource_group" --name "$vm_name"

        ## Update VM size ##
        az vm update --resource-group "$resource_group" --name "$vm_name" --set hardwareProfile.vmSize="$target_sku"

        ## Start VM ##
        az vm start --resource-group "$resource_group" --name "$vm_name"

        echo "✅ VM $vm_name updated to $target_sku"
    done
done
