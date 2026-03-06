#!/bin/bash

# Targeting all VMs in subscription
vault_name=""
vault_rg=""
policy_name=""

vm_ids=$(az vm list --query "[].id" -o tsv)

for vm_id in $vm_ids; do
  vm_name=$(basename $vm_id)
  echo "Processing VM: $vm_name ($vm_id)"
  
  # Check if VM is already being backed up
  # Convert VM ID to lowercase for comparison
  vm_id_lower=$(echo "$vm_id" | tr '[:upper:]' '[:lower:]')
  
  backup_item=$(az backup item list \
    --resource-group $vault_rg \
    --vault-name $vault_name \
    --backup-management-type AzureIaasVM \
    --workload-type VM \
    -o json 2>/dev/null | jq -r --arg vmid "$vm_id_lower" '.[] | select((.properties.sourceResourceId | ascii_downcase) == $vmid or (.properties.virtualMachineId | ascii_downcase) == $vmid) | .name' | head -n 1)
  
  if [ -n "$backup_item" ]; then
    echo "  ⓘ VM is already being backed up (Backup Item: $backup_item). Skipping..."
    echo ""
    continue
  fi
  
  disk_ids=$(az vm show --ids $vm_id --query "storageProfile.dataDisks[].managedDisk.id" -o tsv)
  
  shared_disk_luns=()
  has_shared_disks=false
  
  for disk_id in $disk_ids; do
    if [ -n "$disk_id" ]; then
      max_shares=$(az disk show --ids $disk_id --query "maxShares" -o tsv 2>/dev/null)
      
      if [ -n "$max_shares" ] && [ "$max_shares" -gt 1 ]; then
        has_shared_disks=true
        lun=$(az vm show --ids $vm_id --query "storageProfile.dataDisks[?managedDisk.id=='$disk_id'].lun" -o tsv)
        if [ -n "$lun" ]; then
          shared_disk_luns+=($lun)
          echo "  Found shared disk at LUN $lun (maxShares: $max_shares)"
        fi
      fi
    fi
  done
  
  if [ "$has_shared_disks" = true ]; then
    echo "  VM has shared disks. Enabling backup with disk exclusion..."
    
    # Build exclude-all-data-disks flag and disk list
    exclude_disks=""
    for lun in "${shared_disk_luns[@]}"; do
      if [ -z "$exclude_disks" ]; then
        exclude_disks="$lun"
      else
        exclude_disks="$exclude_disks $lun"
      fi
    done
    
    az backup protection enable-for-vm \
      --vm $vm_id \
      --resource-group $vault_rg \
      --vault-name $vault_name \
      --policy-name $policy_name \
      --disk-list-setting exclude \
      --diskslist $exclude_disks
    
    if [ $? -eq 0 ]; then
      echo "  ✓ Backup enabled successfully (excluded LUNs: $exclude_disks)"
    else
      echo "  ✗ Failed to enable backup for $vm_name"
    fi
  else
    echo "  No shared disks found. Enabling standard backup..."
    
    az backup protection enable-for-vm \
      --vm $vm_id \
      --resource-group $vault_rg \
      --vault-name $vault_name \
      --policy-name $policy_name
    
    if [ $? -eq 0 ]; then
      echo "  ✓ Backup enabled successfully"
    else
      echo "  ✗ Failed to enable backup for $vm_name"
    fi
  fi
  
  echo ""
done

echo "Backup configuration completed for all VMs in subscription"
