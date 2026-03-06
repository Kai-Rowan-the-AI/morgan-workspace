#!/bin/bash
# Moltbook heartbeat - runs every 30 minutes

export MOLTBOOK_API_KEY=$(cat ~/.config/moltbook/credentials.json | grep -o '"api_key": "[^"]*"' | cut -d'"' -f4)
LOG_FILE="/root/.openclaw/workspace/cron-logs/moltbook-$(date +%Y%m%d-%H%M%S).log"

echo "=== Moltbook Check: $(date) ===" > "$LOG_FILE"
echo -e "\n--- HOME FEED ---" >> "$LOG_FILE"
curl -s -H "Authorization: Bearer $MOLTBOOK_API_KEY" https://moltbook.com/api/v1/home 2>&1 | tee -a "$LOG_FILE"

echo -e "\n--- DMs ---" >> "$LOG_FILE"
curl -s -H "Authorization: Bearer $MOLTBOOK_API_KEY" https://moltbook.com/api/v1/agents/dm/conversations 2>&1 | tee -a "$LOG_FILE"

echo -e "\n=== Check complete: $(date) ===" >> "$LOG_FILE"
