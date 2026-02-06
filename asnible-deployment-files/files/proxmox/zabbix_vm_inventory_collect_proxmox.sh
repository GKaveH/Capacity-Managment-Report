#!/bin/bash
set -u

OUTPUT_FILE="vm_inventory.json"
TMP_FILE="$(mktemp)"

# sanity: must be on proxmox node
if ! command -v qm >/dev/null 2>&1; then
  echo "ERROR: 'qm' command not found. You are not running on a Proxmox VE node." >&2
  echo "Tip: run this on the Proxmox host (not inside an LXC/VM)." >&2
  exit 1
fi

if ! command -v pvesm >/dev/null 2>&1; then
  echo "ERROR: 'pvesm' command not found. This does not look like a full Proxmox VE node." >&2
  exit 1
fi

# ---- Host CPU / Memory (exact keys you want) ----
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

# total_cpus = threads/logical CPUs
TOTAL_CPUS="$(nproc 2>/dev/null || echo 0)"
[[ -z "${TOTAL_CPUS:-}" ]] && TOTAL_CPUS=0

# total_memory_gb from your dmidecode method (extract number from "<sum> GB")
TOTAL_MEM_GB="$(
  sudo dmidecode -t memory 2>/dev/null \
    | grep "Size" \
    | grep -v "No " \
    | awk '{sum+=$2} END {print sum " GB"}' \
    | awk '{print $1}' \
    | tr -d '[:space:]' \
    || true
)"
[[ -z "${TOTAL_MEM_GB:-}" ]] && TOTAL_MEM_GB=0

# ---- Storage usage from Proxmox (dynamic: 1 disk or 10 disks) ----
STORAGES_JSON="$(
  pvesm status 2>/dev/null | awk '
    NR==1 {next}
    {
      name=$1; type=$2; status=$3; total=$4; used=$5; avail=$6; pct=$7;
      gsub(/ /,"",pct);
      printf "%s{\"name\":\"%s\",\"type\":\"%s\",\"status\":\"%s\",\"total\":%s,\"used\":%s,\"avail\":%s,\"pct\":\"%s\"}",
             (i++?",":""), name,type,status,total,used,avail,pct
    }
    END {print ""}
  ' | sed 's/^/[/; s/$/]/'
)"
[[ -z "${STORAGES_JSON:-}" ]] && STORAGES_JSON="[]"

echo "[" > "$TMP_FILE"

# VMIDs
mapfile -t vmids < <(qm list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')
vm_count=${#vmids[@]}

# Host object first (comma only if VMs exist)
if [[ $vm_count -eq 0 ]]; then
  echo "  {\"host\": \"${HOSTNAME}\", \"total_cpus\": ${TOTAL_CPUS}, \"total_memory_gb\": ${TOTAL_MEM_GB}, \"storages\": ${STORAGES_JSON}}" >> "$TMP_FILE"
  echo "]" >> "$TMP_FILE"
  mv -f "$TMP_FILE" "$OUTPUT_FILE"
  chmod 644 "$OUTPUT_FILE"
  echo "Inventory has been saved to $OUTPUT_FILE (0 VMs)"
  exit 0
fi

# Host object + comma (because VM objects follow)
echo "  {\"host\": \"${HOSTNAME}\", \"total_cpus\": ${TOTAL_CPUS}, \"total_memory_gb\": ${TOTAL_MEM_GB}, \"storages\": ${STORAGES_JSON}}," >> "$TMP_FILE"

current_vm_idx=0

for vmid in "${vmids[@]}"; do
  ((current_vm_idx++))

  vm_cfg="$(qm config "$vmid" 2>/dev/null || true)"

  vm_name="$(echo "$vm_cfg" | awk -F': ' '/^name:/ {print $2; exit}')"
  [[ -z "${vm_name:-}" ]] && vm_name="vm-${vmid}"

  status="$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || true)"
  [[ -z "${status:-}" ]] && status="unknown"

  vcpu="$(echo "$vm_cfg" | awk -F': ' '/^cores:/ {print $2; exit}')"
  [[ -z "${vcpu:-}" ]] && vcpu=0

  mem_mb="$(echo "$vm_cfg" | awk -F': ' '/^memory:/ {print $2; exit}')"
  [[ -z "${mem_mb:-}" ]] && mem_mb=0
  ram_gb=$(( mem_mb / 1024 ))

  {
    echo "  {"
    echo "    \"vm_name\": \"${vm_name}\","
    echo "    \"vmid\": ${vmid},"
    echo "    \"status\": \"${status}\","
    echo "    \"vcpu\": ${vcpu},"
    echo "    \"ram_gb\": ${ram_gb},"
    echo "    \"disks\": ["
  } >> "$TMP_FILE"

  # disk lines (scsiX/sataX/ideX/virtioX)
  mapfile -t disk_lines < <(echo "$vm_cfg" | awk -F': ' '
    /^[a-z]+[0-9]+:/ {
      key=$1
      if (key ~ /^(scsi|sata|ide|virtio)[0-9]+$/) print $0
    }'
  )

  total_disks=${#disk_lines[@]}
  current_disk_idx=0

  for line in "${disk_lines[@]}"; do
    ((current_disk_idx++))

    key="$(echo "$line" | cut -d':' -f1)"
    val="$(echo "$line" | cut -d':' -f2- | sed 's/^ //')"

    storage_vol="$(echo "$val" | cut -d',' -f1)"
    storage="$(echo "$storage_vol" | cut -d':' -f1)"
    volid="$(echo "$storage_vol" | cut -d':' -f2-)"

    declared_size="$(echo "$val" | sed -n 's/.*size=\([^,]*\).*/\1/p')"
    size_gb=0

    if [[ -n "${declared_size:-}" ]]; then
      num="$(echo "$declared_size" | sed -E 's/([0-9.]+).*/\1/')"
      unit="$(echo "$declared_size" | sed -E 's/[0-9.]+(.*)/\1/' | tr -d ' ')"
      case "$unit" in
        T|TB) size_gb=$(awk "BEGIN {printf \"%.0f\", $num * 1024}") ;;
        G|GB) size_gb=$(awk "BEGIN {printf \"%.0f\", $num}") ;;
        M|MB) size_gb=$(awk "BEGIN {printf \"%.0f\", $num / 1024}") ;;
        *) size_gb=0 ;;
      esac
    fi

    # Try Ceph/RBD exact size if storage type is rbd in /etc/pve/storage.cfg and rbd exists
    rbd_path=""
    if command -v rbd >/dev/null 2>&1 && [[ -r /etc/pve/storage.cfg ]]; then
      pool="$(awk -v st="$storage" '
        $1=="rbd:" {inrbd=1; name=$2}
        inrbd && name==st && $1=="pool" {print $2; exit}
        $0 ~ /^$/ {inrbd=0}
      ' /etc/pve/storage.cfg 2>/dev/null || true)"

      if [[ -n "${pool:-}" ]]; then
        rbd_path="${pool}/${volid}"
        if rbd info "$rbd_path" >/dev/null 2>&1; then
          read -r size_num size_unit < <(rbd info "$rbd_path" 2>/dev/null | awk '/^size/ {print $2, $3; exit}')
          case "$size_unit" in
            KiB) size_gb=$(awk "BEGIN {printf \"%.0f\", $size_num / 1024 / 1024}") ;;
            MiB) size_gb=$(awk "BEGIN {printf \"%.0f\", $size_num / 1024}") ;;
            GiB) size_gb=$(awk "BEGIN {printf \"%.0f\", $size_num}") ;;
            TiB) size_gb=$(awk "BEGIN {printf \"%.0f\", $size_num * 1024}") ;;
          esac
        fi
      fi
    fi

    {
      echo "      {"
      echo "        \"device\": \"${key}\","
      echo "        \"size_gb\": ${size_gb},"
      echo "        \"storage\": \"${storage}\","
      echo "        \"volid\": \"${volid}\""$( [[ -n "$rbd_path" ]] && echo "," || echo "" )
      if [[ -n "$rbd_path" ]]; then
        echo "        \"rbd\": \"${rbd_path}\""
      fi
      if [[ $current_disk_idx -lt $total_disks ]]; then
        echo "      },"
      else
        echo "      }"
      fi
    } >> "$TMP_FILE"
  done

  {
    echo "    ]"
    if [[ $current_vm_idx -lt $vm_count ]]; then
      echo "  },"
    else
      echo "  }"
    fi
  } >> "$TMP_FILE"
done

echo "]" >> "$TMP_FILE"
mv -f "$TMP_FILE" "$OUTPUT_FILE"
chmod 644 "$OUTPUT_FILE"
echo "Inventory has been saved to $OUTPUT_FILE"
