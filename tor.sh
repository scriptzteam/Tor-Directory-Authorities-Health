#!/usr/bin/env bash
set -euo pipefail

ONIONOO_URL="https://onionoo.torproject.org/details"
OUT_DIR=""

if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR"
  PREFIX="$OUT_DIR/"
else
  PREFIX=""
fi

STATS_MD="${PREFIX}STATS.md"
JSON_RAW="onionoo_raw.json"
PARSED_AUTH="dirauths_parsed.tmp"

echo "[*] Downloading Onionoo details..."
curl -sL "$ONIONOO_URL" -o "$JSON_RAW"

echo "[*] Filtering Tor Directory Authorities (IPv4 & Uptime)..."

# Safely parse uptime, checking both object paths or defaulting to live consensus state
jq -r '
  .relays[] |
  select(.flags != null and (.flags | index("Authority") != null)) |
  .nickname as $nick |
  .fingerprint as $fp |
  (.running // false) as $running |
  (.advertised_bandwidth // 0) as $bw |
  (.country // "xx") as $country |
  # Safely handle uptime fields (fallback to 1.0/100% if running and uptime key is missing)
  (
    if .uptime != null and .uptime["1w"] != null then 
      .uptime["1w"] 
    elif $running then 
      1.0 
    else 
      0.0 
    end
  ) as $uptime_val |
  ($uptime_val * 100) as $uptime_pct |
  (.or_addresses[]?) as $addr |
  ($addr | sub("^\\["; "") | sub("]:[0-9]+$"; "") | sub(":[0-9]+$"; "")) as $ip |
  select(($ip | contains(".")) and (($ip | contains(":")) | not)) |
  ($addr | capture(":(?<port>[0-9]+)$").port) as $port |
  "\($nick) \($fp) \($running) \($bw) \($country) \($uptime_pct) \($ip) \($port)"
' "$JSON_RAW" > "$PARSED_AUTH"

rm -f "$JSON_RAW"

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
TABLE_ROWS=""
TOTAL_AUTH=0
ONLINE_AUTH=0
TOTAL_BW_BYTES=0

echo "[*] Probing Directory Authorities..."

while read -r nick fp running bw country uptime_pct ip port; do
  [ -z "$nick" ] && continue
  TOTAL_AUTH=$((TOTAL_AUTH + 1))
  TOTAL_BW_BYTES=$((TOTAL_BW_BYTES + bw))

  # Format advertised bandwidth to MB/s
  if [ "$bw" -gt 0 ]; then
    bw_formatted=$(awk -v b="$bw" 'BEGIN {printf "%.2f MB/s", b / 1000000}')
  else
    bw_formatted="0.00 MB/s"
  fi

  # Format uptime percentage
  uptime_formatted=$(awk -v u="$uptime_pct" 'BEGIN {printf "%.1f%%", u}')
  country_upper=$(echo "$country" | tr '[:lower:]' '[:upper:]')
  
  status="🔴 Offline"
  latency="N/A"

  if [ "$running" = "true" ]; then
    # Primary Check: High-precision TCP socket probe
    start_ns=$(date +%s%N)
    if timeout 3 nc -z -w 3 "$ip" "$port" &>/dev/null; then
      end_ns=$(date +%s%N)
      latency_ms=$(( (end_ns - start_ns) / 1000000 ))
      
      status="🟢 Online (TCP)"
      latency="${latency_ms} ms"
      ONLINE_AUTH=$((ONLINE_AUTH + 1))
    else
      # Fallback Check: High-precision HTTP check
      start_ns=$(date +%s%N)
      if curl -s --max-time 3 "http://$ip:$port" &>/dev/null; then
        end_ns=$(date +%s%N)
        latency_ms=$(( (end_ns - start_ns) / 1000000 ))
        
        status="🟢 Online (HTTP Fallback)"
        latency="${latency_ms} ms"
        ONLINE_AUTH=$((ONLINE_AUTH + 1))
      else
        status="🔴 Unreachable / Filtered"
        latency="Timeout"
      fi
    fi
  fi

  TABLE_ROWS+="| \`$nick\` | \`$ip:$port\` | $country_upper | $uptime_formatted | $bw_formatted | $status | $latency |"$'\n'

done < "$PARSED_AUTH"

rm -f "$PARSED_AUTH"

# Format total combined bandwidth
TOTAL_BW_FORMATTED=$(awk -v b="$TOTAL_BW_BYTES" 'BEGIN {printf "%.2f MB/s", b / 1000000}')

echo "[*] Generating README.md dashboard..."

cat << EOF > "${PREFIX}README.md"
# 🛡️ Tor Directory Authority Watcher

Automated status monitor tracking health, reachability, country origin, 1-week uptime, bandwidth, and response latencies of official **Tor Directory Authorities** via GitHub Actions.

- **Last Checked:** $TIMESTAMP
- **Total Authorities Tracked:** $TOTAL_AUTH
- **Online / Responding:** $ONLINE_AUTH / $TOTAL_AUTH
- **Total Advertised Bandwidth:** $TOTAL_BW_FORMATTED

## 📊 Live Directory Authority Status

| Nickname | Address & Port | Country | Uptime (1w) | Bandwidth | Status | Latency |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
$TABLE_ROWS

---
*Auto-updated continuously by GitHub Actions.*
EOF

# --- STATS.md Historical Log ---
NEW_STAT_ROW="| $TIMESTAMP | $ONLINE_AUTH / $TOTAL_AUTH | $TOTAL_BW_FORMATTED |"

if [ ! -f "$STATS_MD" ]; then
  cat << EOF > "$STATS_MD"
# Historical Directory Authority Uptime Log

| Timestamp (UTC) | Healthy / Total | Total Advertised BW |
| :--- | :--- | :--- |
$NEW_STAT_ROW
EOF
else
  awk -v new_row="$NEW_STAT_ROW" '
    /\| :---/ {
      print
      print new_row
      next
    }
    {print}
  ' "$STATS_MD" > stats_tmp.md && mv stats_tmp.md "$STATS_MD"
fi

echo "[+] Success! Directory Authority status report updated."
