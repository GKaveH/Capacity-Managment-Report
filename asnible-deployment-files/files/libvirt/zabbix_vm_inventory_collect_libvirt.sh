#!/bin/bash

# Define the output file name
OUTPUT_FILE="vm_inventory.json"

# Start the JSON array
echo "[" > "$OUTPUT_FILE"

# ---- Host CPU / Memory (exact commands you want) ----
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
TOTAL_CPUS="$(nproc)"

# Your command prints: "<number> GB"
# We extract only the number (as integer)
TOTAL_MEM_GB="$(sudo dmidecode -t memory \
  | grep -i "Size:" \
  | grep -v "No Module" \
  | awk '{sum+=$2} END {print sum}' \
  | tr -d '[:space:]'
)"

# If for any reason it's empty, fallback to 0 (keep JSON valid)
if [[ -z "$TOTAL_MEM_GB" ]]; then
  TOTAL_MEM_GB=0
fi

# ---- CephFS only (as storages_fs) ----
# We only include the /cephfs mount row from df, in bytes, in the same shape you showed.
CEPHFS_JSON="$(
  df -P -B1 2>/dev/null \
    | awk 'NR==1{next} $6=="/cephfs" {printf "[{\"name\":\"%s\",\"type\":\"fs\",\"status\":\"active\",\"total\":%s,\"used\":%s,\"avail\":%s,\"pct\":\"%s\",\"fs\":\"%s\",\"mount\":\"%s\"}]", $6,$2,$3,$4,$5,$1,$6}'
)"
if [[ -z "${CEPHFS_JSON:-}" ]]; then
  CEPHFS_JSON="[]"
fi

# ---- Count VMs BEFORE writing host (fix trailing comma when 0 VMs) ----
vms=$(virsh list --all --name)
vm_count=$(echo "$vms" | wc -w)
current_vm_idx=0

# If no VMs => write only host (NO trailing comma), close JSON, exit
if [[ "$vm_count" -eq 0 ]]; then
  echo "  {\"host\": \"${HOSTNAME}\", \"total_cpus\": ${TOTAL_CPUS}, \"total_memory_gb\": ${TOTAL_MEM_GB}, \"ceph_pools\": [], \"storages_fs\": ${CEPHFS_JSON}, \"ceph_vm_provisioned_by_pool_gb\": {}}" >> "$OUTPUT_FILE"
  echo "]" >> "$OUTPUT_FILE"
  chmod 644 "$OUTPUT_FILE"
  echo "Inventory has been saved to $OUTPUT_FILE (0 VMs)"
  exit 0
fi

# Add host object as the first element (comma because VMs come after)
echo "  {\"host\": \"${HOSTNAME}\", \"total_cpus\": ${TOTAL_CPUS}, \"total_memory_gb\": ${TOTAL_MEM_GB}, \"ceph_pools\": [], \"storages_fs\": ${CEPHFS_JSON}, \"ceph_vm_provisioned_by_pool_gb\": {}}," >> "$OUTPUT_FILE"

# -----------------------------
# DO NOT CHANGE ANYTHING BELOW
# -----------------------------

for vm in $vms; do
    [[ -z "$vm" ]] && continue
    ((current_vm_idx++))

    # Fetch basic VM info
    status=$(virsh dominfo "$vm" | awk -F: '/State/ {gsub(/^[ \t]+/, "", $2); print $2}')
    vcpu=$(virsh dominfo "$vm" | awk -F: '/CPU\(s\)/ {gsub(/ /, "", $2); print $2}')
    ram_kib=$(virsh dumpxml "$vm" | awk -F"[<>]" '/<currentMemory/ {print $3}')
    ram_gb=$((ram_kib / 1024 / 1024))

    # Fetch RBD sources
    rbd_sources=$(virsh dumpxml "$vm" | awk '/<disk/,/<\/disk>/' | grep "<source protocol='rbd'" | sed -n "s/.*name='\([^']*\)'.*/\1/p")

    # Start building the VM object in JSON
    echo "  {" >> "$OUTPUT_FILE"
    echo "    \"vm_name\": \"$vm\"," >> "$OUTPUT_FILE"
    echo "    \"status\": \"$status\"," >> "$OUTPUT_FILE"
    echo "    \"vcpu\": $vcpu," >> "$OUTPUT_FILE"
    echo "    \"ram_gb\": $ram_gb," >> "$OUTPUT_FILE"

    # Process Disks
    echo "    \"disks\": [" >> "$OUTPUT_FILE"

    disk_list=""
    if [[ -n "$rbd_sources" ]]; then
        disk_index=0
        letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)

        total_disks=$(echo "$rbd_sources" | wc -l)
        current_disk_idx=0

        while IFS= read -r full_rbd; do
            ((current_disk_idx++))
            rbd_pool=$(echo "$full_rbd" | cut -d'/' -f1)
            rbd_image=$(echo "$full_rbd" | cut -d'/' -f2-)

            # Get size from RBD
            rbd_info=$(sudo rbd info "$rbd_pool/$rbd_image" 2>/dev/null | grep "size")
            size_num=$(echo "$rbd_info" | awk '{print $2}')
            size_unit=$(echo "$rbd_info" | awk '{print $3}')

            # Unit conversion to Bytes
            case "$size_unit" in
                KiB) size_bytes=$(awk "BEGIN {print $size_num * 1024}") ;;
                MiB) size_bytes=$(awk "BEGIN {print $size_num * 1024 * 1024}") ;;
                GiB) size_bytes=$(awk "BEGIN {print $size_num * 1024 * 1024 * 1024}") ;;
                TiB) size_bytes=$(awk "BEGIN {print $size_num * 1024 * 1024 * 1024 * 1024}") ;;
                *) size_bytes=0 ;;
            esac

            size_gb=$(awk "BEGIN {printf \"%.0f\", $size_bytes / 1024 / 1024 / 1024}")
            device_name="vd${letters[$disk_index]}"

            # Add disk object
            echo "      {" >> "$OUTPUT_FILE"
            echo "        \"device\": \"$device_name\"," >> "$OUTPUT_FILE"
            echo "        \"size_gb\": $size_gb," >> "$OUTPUT_FILE"
            echo "        \"path\": \"$full_rbd\"" >> "$OUTPUT_FILE"

            if [[ $current_disk_idx -lt $total_disks ]]; then
                echo "      }," >> "$OUTPUT_FILE"
            else
                echo "      }" >> "$OUTPUT_FILE"
            fi

            ((disk_index++))
        done <<< "$rbd_sources"
    fi

    echo "    ]" >> "$OUTPUT_FILE"

    # Close VM object
    if [[ $current_vm_idx -lt $vm_count ]]; then
        echo "  }," >> "$OUTPUT_FILE"
    else
        echo "  }" >> "$OUTPUT_FILE"
    fi
done

# End the JSON array
echo "]" >> "$OUTPUT_FILE"
chmod 644 "$OUTPUT_FILE"
echo "Inventory has been saved to $OUTPUT_FILE"
