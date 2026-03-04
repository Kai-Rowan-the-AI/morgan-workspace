#!/bin/bash
# Browser restart script — frees memory by restarting Brave browser

echo "$(date): Checking browser memory usage..."

# Get total Brave memory usage in MB
BRAVE_MEM=$(ps aux | grep -E 'brave.*--type=renderer' | awk '{sum+=$6} END {printf "%.0f", sum/1024}')

echo "Current Brave renderer memory: ${BRAVE_MEM}MB"

if [ "$BRAVE_MEM" -gt 800 ]; then
    echo "Memory usage high — restarting browser..."
    
    # Kill all Brave processes gracefully
    pkill -f 'brave-browser-stable.*remote-debugging-port=18801' 2>/dev/null
    
    sleep 2
    
    # Wait for processes to die
    for i in {1..10}; do
        if ! pgrep -f 'brave.*remote-debugging-port=18801' > /dev/null; then
            break
        fi
        sleep 1
    done
    
    # Force kill if still running
    pkill -9 -f 'brave.*remote-debugging-port=18801' 2>/dev/null
    
    echo "Browser restarted. Memory freed."
    
    # Log the restart
    echo "$(date): Browser restarted (was using ${BRAVE_MEM}MB)" >> /root/.openclaw/workspace/memory-logs/browser-restarts.log
else
    echo "Memory usage acceptable (${BRAVE_MEM}MB) — no action needed"
fi