#!/usr/bin/env bash
# ==============================================================================
# Script: export_crowdsec_decisions.sh
# Purpose: Export active CrowdSec decisions (IP, Country, Reason, Action)
#          to Prometheus textfile format for Grafana table visualization.
# ==============================================================================
set -euo pipefail

TEXTFILE_DIR="/var/lib/alloy/textfile"
OUTPUT_FILE="${TEXTFILE_DIR}/crowdsec_decisions.prom"
TMP_FILE="${OUTPUT_FILE}.$$"

# Ensure output directory exists
mkdir -p "$TEXTFILE_DIR"

if ! command -v cscli >/dev/null 2>&1; then
  exit 0
fi

# Fetch decisions in JSON format
raw_json="$(cscli decisions list -o json 2>/dev/null || true)"

python3 -c "
import json, sys

raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

print('# HELP crowdsec_active_decision Active CrowdSec ban decision with IP and country.')
print('# TYPE crowdsec_active_decision gauge')

if not data:
    # No active decisions
    sys.exit(0)

for d in data:
    for dec in d.get('decisions', []):
        ip = dec.get('value', '')
        scenario = dec.get('scenario', 'manual')
        action = dec.get('type', 'ban')
        origin = dec.get('origin', 'crowdsec')
        # Extract country / source info if present
        source = d.get('source', {})
        country = source.get('cn', '') or 'Unknown'
        as_name = source.get('as_name', '') or ''
        
        # Clean label strings for Prometheus format
        def clean(s):
            return str(s).replace('\"', '\\\"').replace('\n', ' ')

        print(f'crowdsec_active_decision{{ip=\"{clean(ip)}\",country=\"{clean(country)}\",as_name=\"{clean(as_name)}\",reason=\"{clean(scenario)}\",action=\"{clean(action)}\",origin=\"{clean(origin)}\"}} 1')
" <<< "$raw_json" > "$TMP_FILE"

# Atomic rename to prevent race conditions during scraper reads
mv -f "$TMP_FILE" "$OUTPUT_FILE"
chmod 0644 "$OUTPUT_FILE"
