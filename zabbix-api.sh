#!/bin/bash
set -euo pipefail

ZBX_URL="https://zabbix.kavehkiani.com/api_jsonrpc.php"
TOKEN_FILE="./zbx_api_token"

# inventory hosts that have vm.inventory.get
INVENTORY_HOSTS_FILE="./inventory_hosts.txt"
INVENTORY_ITEM_KEY="vm.inventory.get"

# CPU: prefer direct util; fallback to idle => util=100-idle
CPU_UTIL_KEY="system.cpu.util"
CPU_IDLE_KEY='system.cpu.util[,idle]'
MEM_KEY="vm.memory.utilization"

# ---- 30d window (unix seconds) ----
NOW_TS=$(date +%s)
FROM_30D=$((NOW_TS - 30*24*3600))

TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || { echo "❌ Token empty: $TOKEN_FILE" >&2; exit 1; }

[[ -f "$INVENTORY_HOSTS_FILE" ]] || {
  echo "❌ Inventory hosts file not found: $INVENTORY_HOSTS_FILE" >&2
  exit 1
}

api() {
  curl -sS -X POST \
    -H 'Content-Type: application/json-rpc' \
    -H "Authorization: Bearer $TOKEN" \
    -d "$1" \
    "$ZBX_URL"
}

die_if_error() {
  if echo "$1" | jq -e '.error' >/dev/null 2>&1; then
    echo "❌ Zabbix API error:" >&2
    echo "$1" | jq >&2
    exit 1
  fi
}

# Find hostid by exact host, then fuzzy host, then fuzzy name
get_hostid_any() {
  local needle="$1"
  local res hostid

  res=$(api '{
    "jsonrpc":"2.0","method":"host.get",
    "params":{"output":["hostid","host","name"],"filter":{"host":["'"$needle"'"]}},
    "id":1
  }'); die_if_error "$res"
  hostid=$(echo "$res" | jq -r '.result[0].hostid // empty')
  [[ -n "$hostid" ]] && { echo "$hostid"; return 0; }

  res=$(api '{
    "jsonrpc":"2.0","method":"host.get",
    "params":{"output":["hostid","host","name"],"search":{"host":"'"$needle"'"}, "searchByAny": true},
    "id":2
  }'); die_if_error "$res"
  hostid=$(echo "$res" | jq -r '.result[0].hostid // empty')
  [[ -n "$hostid" ]] && { echo "$hostid"; return 0; }

  res=$(api '{
    "jsonrpc":"2.0","method":"host.get",
    "params":{"output":["hostid","host","name"],"search":{"name":"'"$needle"'"}, "searchByAny": true},
    "id":3
  }'); die_if_error "$res"
  hostid=$(echo "$res" | jq -r '.result[0].hostid // empty')
  [[ -n "$hostid" ]] && { echo "$hostid"; return 0; }

  echo ""
}

# keys_json must be a JSON array like ["k1","k2",...]
get_lastvalues_map() {
  local hostid="$1"
  local keys_json="$2"
  local res
  res=$(api '{
    "jsonrpc":"2.0","method":"item.get",
    "params":{
      "output":["key_","lastvalue"],
      "hostids":["'"$hostid"'"],
      "filter":{"key_": '"$keys_json"'}
    },
    "id":4
  }')
  die_if_error "$res"

  echo "$res" | jq -c '
    .result
    | map({(.key_): (.lastvalue // "")})
    | add // {}
  '
}

# keys_json must be a JSON array like ["k1","k2",...]
get_itemids_map() {
  local hostid="$1"
  local keys_json="$2"
  local res
  res=$(api '{
    "jsonrpc":"2.0","method":"item.get",
    "params":{
      "output":["key_","itemid"],
      "hostids":["'"$hostid"'"],
      "filter":{"key_": '"$keys_json"'}
    },
    "id":5
  }')
  die_if_error "$res"

  echo "$res" | jq -c '
    .result
    | map({(.key_): (.itemid // "")})
    | add // {}
  '
}

# Weighted avg from trend.get for ONE itemid over last 30 days
get_trend_avg() {
  local itemid="$1"
  [[ -n "$itemid" ]] || { echo "null"; return 0; }

  local res
  res=$(api '{
    "jsonrpc":"2.0",
    "method":"trend.get",
    "params":{
      "output":["value_avg","num"],
      "itemids":["'"$itemid"'"],
      "time_from": '"$FROM_30D"',
      "time_till": '"$NOW_TS"'
    },
    "id":6
  }')
  die_if_error "$res"

  echo "$res" | jq -r '
    .result
    | map({v:(.value_avg|tonumber), n:(.num|tonumber)})
    | if length==0 then null
      else ((map(.v * .n) | add) / (map(.n) | add))
      end
  '
}

# -------------------------
# Load inventory hosts + location mapping (portable: macOS bash 3.2 + ubuntu)
# Supports:
#   - location line alone: sea_dev
#   - host line alone (inherits current location)
#   - "location,host" in one line
# -------------------------

INVENTORY_HOSTS=()
HOSTS_LOC_HOST=()
HOSTS_LOC_LOC=()
current_loc=""

is_location_token() {
  [[ "$1" =~ ^[a-z0-9]+_[a-z0-9]+$ ]]
}

set_host_location() {
  local host="$1"
  local loc="$2"
  [[ -n "$host" ]] || return 0
  [[ -n "$loc"  ]] || loc="unknown"
  INVENTORY_HOSTS+=("$host")
  HOSTS_LOC_HOST+=("$host")
  HOSTS_LOC_LOC+=("$loc")
}

get_location_for_host() {
  local host="$1"
  local i
  for ((i=0; i<${#HOSTS_LOC_HOST[@]}; i++)); do
    if [[ "${HOSTS_LOC_HOST[$i]}" == "$host" ]]; then
      echo "${HOSTS_LOC_LOC[$i]}"
      return 0
    fi
  done
  echo "unknown"
}

while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%%#*}"
  line="$(printf '%s' "$line" | xargs)"
  [[ -z "$line" ]] && continue

  if [[ "$line" == *","* ]]; then
    loc="$(printf '%s' "$line" | cut -d',' -f1 | xargs)"
    host="$(printf '%s' "$line" | cut -d',' -f2- | xargs)"
    if is_location_token "$loc"; then
      current_loc="$loc"
    fi
    set_host_location "$host" "$current_loc"
    continue
  fi

  if is_location_token "$line"; then
    current_loc="$line"
    continue
  fi

  set_host_location "$line" "$current_loc"

done < "$INVENTORY_HOSTS_FILE"

if [[ ${#INVENTORY_HOSTS[@]} -eq 0 ]]; then
  echo "❌ No inventory hosts found in $INVENTORY_HOSTS_FILE" >&2
  exit 1
fi

# Enrich a single VM json object (expects vm_name, disks[].device)
enrich_vm() {
  local vm_json="$1"
  local vm_name
  vm_name=$(echo "$vm_json" | jq -r '.vm_name // empty')

  if [[ -z "$vm_name" ]]; then
    echo "$vm_json" | jq -c '. + {"zbx_host_found": false, "zbx_error": "missing vm_name"}'
    return 0
  fi

  local vm_hostid
  vm_hostid="$(get_hostid_any "$vm_name")"
  if [[ -z "$vm_hostid" ]]; then
    echo "$vm_json" | jq -c '. + {"zbx_host_found": false}'
    return 0
  fi

  # device list from inventory
  local devs_json
  devs_json=$(echo "$vm_json" | jq -c '[.disks[]?.device] | map(tostring) | unique')

  # build keys list (for lastvalue + itemid lookups)
  local keys_json
  keys_json=$(jq -nc \
    --arg cpuu "$CPU_UTIL_KEY" \
    --arg cpui "$CPU_IDLE_KEY" \
    --arg mem "$MEM_KEY" \
    --argjson devs "$devs_json" \
    '
    [$cpuu,$cpui,$mem] + ($devs | map("vfs.dev.util[\(.)]"))
    ')

  local kv_map
  kv_map="$(get_lastvalues_map "$vm_hostid" "$keys_json")"

  local itemids_map
  itemids_map="$(get_itemids_map "$vm_hostid" "$keys_json")"

  # ---- AVG 30d for CPU/MEM ----
  local cpu_avg_30d="null"
  local ram_avg_30d="null"

  local cpu_itemid idle_itemid mem_itemid
  cpu_itemid="$(echo "$itemids_map" | jq -r --arg k "$CPU_UTIL_KEY" '.[$k] // empty')"
  idle_itemid="$(echo "$itemids_map" | jq -r --arg k "$CPU_IDLE_KEY" '.[$k] // empty')"
  mem_itemid="$(echo "$itemids_map" | jq -r --arg k "$MEM_KEY" '.[$k] // empty')"

  if [[ -n "$cpu_itemid" ]]; then
    cpu_avg_30d="$(get_trend_avg "$cpu_itemid")"
  elif [[ -n "$idle_itemid" ]]; then
    idle_avg="$(get_trend_avg "$idle_itemid")"
    if [[ "$idle_avg" != "null" ]]; then
      cpu_avg_30d="$(awk "BEGIN {print 100 - $idle_avg}")"
    fi
  fi

  if [[ -n "$mem_itemid" ]]; then
    ram_avg_30d="$(get_trend_avg "$mem_itemid")"
  fi

  # ---- AVG 30d for each disk vfs.dev.util[vdX] ----
  local disk_avg_obj='{}'
  while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    key="vfs.dev.util[$dev]"
    itemid="$(echo "$itemids_map" | jq -r --arg k "$key" '.[$k] // empty')"
    avg="null"
    if [[ -n "$itemid" ]]; then
      avg="$(get_trend_avg "$itemid")"
    fi
    disk_avg_obj="$(echo "$disk_avg_obj" | jq -c \
      --arg k "${dev}_utilization_avg_30d" \
      --argjson v "${avg:-null}" \
      '. + {($k): $v}' )"
  done < <(echo "$devs_json" | jq -r '.[]?')

  # inject fields (lastvalue + avg30d)
  echo "$vm_json" | jq -c \
    --arg cpuu "$CPU_UTIL_KEY" \
    --arg cpui "$CPU_IDLE_KEY" \
    --arg mem "$MEM_KEY" \
    --argjson devs "$devs_json" \
    --argjson kv "$kv_map" \
    --argjson diskavg "$disk_avg_obj" \
    --argjson cpuavg "${cpu_avg_30d:-null}" \
    --argjson ramavg "${ram_avg_30d:-null}" \
    '
    def to_num(x):
      if (x == null) or (x == "") then null
      else (x|tostring|tonumber? // null)
      end;

    def cpu_calc:
      if to_num($kv[$cpuu]) != null then to_num($kv[$cpuu])
      elif to_num($kv[$cpui]) != null then (100 - to_num($kv[$cpui]))
      else null end;

    . + {
      "zbx_host_found": true,
      "cpu_utilization": cpu_calc,
      "ram_utilization": to_num($kv[$mem]),
      "cpu_utilization_avg_30d": $cpuavg,
      "ram_utilization_avg_30d": $ramavg
    }
    + (
      $devs
      | map({
          (("\(.)_utilization")): to_num($kv[("vfs.dev.util[\(.)]")])
        })
      | add // {}
    )
    + $diskavg
    '
}

# ---- read inventory from multiple hosts and merge into one JSON array
TMP_INV="$(mktemp)"
echo '[]' > "$TMP_INV"

for INVENTORY_HOST in "${INVENTORY_HOSTS[@]}"; do
  INV_LOC="$(get_location_for_host "$INVENTORY_HOST")"

  INV_HOSTID="$(get_hostid_any "$INVENTORY_HOST")"
  if [[ -z "$INV_HOSTID" ]]; then
    echo "❌ Inventory host not found: $INVENTORY_HOST" >&2
    exit 1
  fi

  INV_ITEM_RES=$(api '{
    "jsonrpc":"2.0","method":"item.get",
    "params":{
      "output":["itemid","key_","lastvalue","lastclock"],
      "hostids":["'"$INV_HOSTID"'"],
      "filter":{"key_":"'"$INVENTORY_ITEM_KEY"'"}
    },
    "id":10
  }')
  die_if_error "$INV_ITEM_RES"

  LASTVALUE=$(echo "$INV_ITEM_RES" | jq -r '.result[0].lastvalue // empty')
  if [[ -z "$LASTVALUE" || "$LASTVALUE" == "null" ]]; then
    echo "❌ Inventory lastvalue empty for $INVENTORY_ITEM_KEY on $INVENTORY_HOST" >&2
    echo "$INV_ITEM_RES" | jq >&2
    exit 1
  fi

  if ! jq -e . >/dev/null 2>&1 <<<"$LASTVALUE"; then
    echo "❌ Inventory lastvalue is not valid JSON on $INVENTORY_HOST (first 200 chars):" >&2
    echo "$LASTVALUE" | head -c 200 >&2
    echo >&2
    exit 1
  fi

  # normalize to array
  # - VM objects: ensure host + location exists
  # - host-meta objects: ensure location exists
  TMP_ONE="$(mktemp)"
  echo "$LASTVALUE" | jq -c --arg invhost "$INVENTORY_HOST" --arg loc "$INV_LOC" '
    def add_host_loc_if_vm:
      if (type == "object") and has("vm_name") then
        (if (has("host")|not) then . + {host: $invhost} else . end)
        | (if (has("location")|not) then . + {location: $loc} else . end)
      else
        .
      end;

    def add_loc_if_hostmeta:
      if (type == "object") and has("host") and (has("vm_name")|not) and (has("vms")|not) then
        (if (has("location")|not) then . + {location: $loc} else . end)
      else
        .
      end;

    if type == "array" then
      map(add_host_loc_if_vm | add_loc_if_hostmeta)
    else
      [ (add_host_loc_if_vm | add_loc_if_hostmeta) ]
    end
  ' > "$TMP_ONE"

  jq -s '.[0] + .[1]' "$TMP_INV" "$TMP_ONE" > "${TMP_INV}.new"
  mv "${TMP_INV}.new" "$TMP_INV"
  rm -f "$TMP_ONE"
done

jq -e . "$TMP_INV" >/dev/null 2>&1 || {
  echo "❌ Internal merged inventory JSON became invalid." >&2
  exit 1
}

# ---- detect schema using ANY element (not only [0]) ----
INV_TYPE=$(jq -r 'type' "$TMP_INV")
[[ "$INV_TYPE" == "array" ]] || { echo "❌ Expected merged inventory to be an array." >&2; exit 1; }

ANY_HOSTBLOCK=$(jq -r 'any(.[]; (type=="object") and has("host") and has("vms"))' "$TMP_INV")
ANY_VMOBJ=$(jq -r 'any(.[]; (type=="object") and has("vm_name"))' "$TMP_INV")

if [[ "$ANY_HOSTBLOCK" == "true" ]]; then
  # host blocks
  host_count=$(jq 'length' "$TMP_INV")
  out="[]"
  for ((i=0; i<host_count; i++)); do
    host_block=$(jq -c ".[$i]" "$TMP_INV")
    is_hb=$(echo "$host_block" | jq -r '(type=="object") and (has("host") and has("vms"))')
    if [[ "$is_hb" != "true" ]]; then
      out=$(echo "$out" | jq -c ". + [$host_block]")
      continue
    fi

    vms=$(echo "$host_block" | jq -c '.vms // []')
    vm_count=$(echo "$vms" | jq 'length')

    new_vms="[]"
    for ((j=0; j<vm_count; j++)); do
      vm=$(echo "$vms" | jq -c ".[$j]")
      vm_enriched="$(enrich_vm "$vm")"
      new_vms=$(echo "$new_vms" | jq -c ". + [$vm_enriched]")
    done

    new_host_block=$(echo "$host_block" | jq -c --argjson nv "$new_vms" '.vms = $nv')
    out=$(echo "$out" | jq -c ". + [$new_host_block]")
  done
  echo "$out" | jq .

elif [[ "$ANY_VMOBJ" == "true" ]]; then
  # flat/mixed list: keep host cpu/mem objects, enrich only VM objects
  count=$(jq 'length' "$TMP_INV")
  out="[]"
  for ((i=0; i<count; i++)); do
    obj=$(jq -c ".[$i]" "$TMP_INV")
    has_vm=$(echo "$obj" | jq -r 'type=="object" and has("vm_name")')
    if [[ "$has_vm" == "true" ]]; then
      obj="$(enrich_vm "$obj")"
    fi
    out=$(echo "$out" | jq -c ". + [$obj]")
  done
  echo "$out" | jq .

else
  echo "❌ Unknown array schema in inventory JSON." >&2
  jq '.[0]' "$TMP_INV" >&2
  exit 1
fi

rm -f "$TMP_INV"
