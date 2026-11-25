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

echo "[*] Filtering and sorting Tor Directory Authorities by Bandwidth..."

# Extract fields, clean IPv4 filter, and sort numerically by bandwidth descending (-k3,3nr)
jq -r '
  .relays[] |
  select(.flags != null and (.flags | index("Authority") != null)) |
  .nickname as $nick |
  (.running // false) as $running |
  (.advertised_bandwidth // 0) as $bw |
  (.country // "xx") as $country |
  (.or_addresses[]? | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+$"))) as $addr |
  ($addr | split(":")[0]) as $ip |
  ($addr | split(":")[1]) as $port |
  "\($nick)|\($running)|\($bw)|\($country)|\($ip)|\($port)"
' "$JSON_RAW" | sort -t'|' -k3,3nr > "$PARSED_AUTH"

rm -f "$JSON_RAW"

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
TABLE_ROWS=""
TOTAL_AUTH=0
ONLINE_AUTH=0
TOTAL_BW_BYTES=0

echo "[*] Probing Directory Authorities..."

while IFS='|' read -r nick running bw country ip port; do
  [ -z "$nick" ] && continue
  TOTAL_AUTH=$((TOTAL_AUTH + 1))
  TOTAL_BW_BYTES=$((TOTAL_BW_BYTES + bw))

  # Format advertised bandwidth to MB/s
  if [ "$bw" -gt 0 ]; then
    bw_formatted=$(awk -v b="$bw" 'BEGIN {printf "%.2f MB/s", b / 1048576}')
  else
    bw_formatted="0.00 MB/s"
  fi

  country_upper=$(echo "$country" | tr '[:lower:]' '[:upper:]')
  
  status="🔴 Offline"
  latency="N/A"

  if [ "$running" = "true" ]; then
    # Primary Check: High-precision TCP socket probe on the exact ORPort
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

  TABLE_ROWS+="| \`$nick\` | \`$ip:$port\` | $country_upper | $bw_formatted | $status | $latency |"$'\n'

done < "$PARSED_AUTH"

rm -f "$PARSED_AUTH"

# Format total combined bandwidth
TOTAL_BW_FORMATTED=$(awk -v b="$TOTAL_BW_BYTES" 'BEGIN {printf "%.2f MB/s", b / 1048576}')

echo "[*] Generating README.md dashboard..."

cat << EOF > "${PREFIX}README.md"
# 🛡️ Tor Directory Authority Health

Automated status monitor tracking health, reachability, country origin, bandwidth, and response latencies of official **Tor Directory Authorities**.

- **Last Checked:** $TIMESTAMP
- **Total Authorities Tracked:** $TOTAL_AUTH
- **Online / Responding:** $ONLINE_AUTH / $TOTAL_AUTH
- **Total Advertised Bandwidth:** $TOTAL_BW_FORMATTED

## 📊 Live Directory Authority Status

| Nickname | Address & Port | Country | Bandwidth | Status | Latency |
| :--- | :--- | :--- | :--- | :--- | :--- |
$TABLE_ROWS

---
*Auto-updated continuously.*
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

echo "[+] Success! Directory Authority status report updated and sorted by bandwidth."
