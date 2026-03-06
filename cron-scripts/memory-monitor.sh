#!/bin/bash
# Memory monitor - runs every 10 minutes

LOG_FILE="/root/.openclaw/workspace/cron-logs/memory-$(date +%Y%m%d-%H%M%S).log"
echo "=== Memory Check: $(date) ===" > "$LOG_FILE"

python3 /root/.openclaw/workspace/memory-monitor.py 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}

if [ $EXIT_CODE -eq 1 ]; then
    echo -e "\n*** ALERT TRIGGERED ***" >> "$LOG_FILE"
    /root/.openclaw/workspace/restart-browser.sh 2>&1 | tee -a "$LOG_FILE"
fi

echo -e "\n=== Check complete: $(date) ===" >> "$LOG_FILE"
