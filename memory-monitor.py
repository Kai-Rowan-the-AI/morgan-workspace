#!/usr/bin/env python3
"""
Memory Monitor for OpenClaw
Tracks memory usage and alerts before OOM kills processes
"""

import subprocess
import json
import os
import sys
from datetime import datetime

# Thresholds
WARNING_THRESHOLD = 70  # % of total memory
CRITICAL_THRESHOLD = 85  # % of total memory
OOM_THRESHOLD = 95  # % of total memory

# Process memory limits (in MB)
BROWSER_MEMORY_LIMIT = 800  # Restart browser if exceeds
GATEWAY_MEMORY_LIMIT = 1500  # Alert if gateway exceeds

def get_memory_info():
    """Get system memory usage"""
    try:
        with open('/proc/meminfo', 'r') as f:
            meminfo = f.read()
        
        mem_total = 0
        mem_available = 0
        
        for line in meminfo.split('\n'):
            if line.startswith('MemTotal:'):
                mem_total = int(line.split()[1]) * 1024  # Convert to bytes
            elif line.startswith('MemAvailable:'):
                mem_available = int(line.split()[1]) * 1024
        
        mem_used = mem_total - mem_available
        mem_percent = (mem_used / mem_total) * 100 if mem_total > 0 else 0
        
        return {
            'total': mem_total,
            'used': mem_used,
            'available': mem_available,
            'percent': mem_percent
        }
    except Exception as e:
        return {'error': str(e)}

def get_process_memory():
    """Get memory usage of key processes"""
    processes = {
        'openclaw-gateway': 0,
        'brave-browser': 0,
        'chrome': 0,
        'node': 0
    }
    
    try:
        # Get all processes
        result = subprocess.run(
            ['ps', 'aux', '--no-headers'],
            capture_output=True,
            text=True
        )
        
        for line in result.stdout.strip().split('\n'):
            parts = line.split()
            if len(parts) < 11:
                continue
            
            try:
                mem_percent = float(parts[3])
                rss_mb = int(parts[5]) / 1024  # Convert KB to MB
                command = ' '.join(parts[10:]).lower()
                
                if 'openclaw-gateway' in command:
                    processes['openclaw-gateway'] += rss_mb
                elif 'brave' in command and '--type=renderer' in command:
                    processes['brave-browser'] += rss_mb
                elif 'chrome' in command:
                    processes['chrome'] += rss_mb
                elif 'node' in command and 'openclaw' in command:
                    processes['node'] += rss_mb
            except (ValueError, IndexError):
                continue
        
        return processes
    except Exception as e:
        return {'error': str(e)}

def check_and_alert():
    """Check memory and generate alerts"""
    alerts = []
    actions = []
    
    # System memory
    mem_info = get_memory_info()
    if 'error' in mem_info:
        return {'error': mem_info['error']}
    
    mem_percent = mem_info['percent']
    
    if mem_percent >= OOM_THRESHOLD:
        alerts.append(f"🚨 CRITICAL: System memory at {mem_percent:.1f}% — OOM imminent!")
        actions.append("Consider killing browser processes immediately")
    elif mem_percent >= CRITICAL_THRESHOLD:
        alerts.append(f"⚠️ WARNING: System memory at {mem_percent:.1f}% — approaching OOM")
        actions.append("Restart browser processes to free memory")
    elif mem_percent >= WARNING_THRESHOLD:
        alerts.append(f"ℹ️ Notice: System memory at {mem_percent:.1f}%")
    
    # Process memory
    proc_mem = get_process_memory()
    if 'error' in proc_mem:
        return {'error': proc_mem['error']}
    
    if proc_mem.get('openclaw-gateway', 0) > GATEWAY_MEMORY_LIMIT:
        alerts.append(f"⚠️ OpenClaw gateway using {proc_mem['openclaw-gateway']:.0f}MB (limit: {GATEWAY_MEMORY_LIMIT}MB)")
    
    if proc_mem.get('brave-browser', 0) > BROWSER_MEMORY_LIMIT:
        alerts.append(f"⚠️ Brave browser using {proc_mem['brave-browser']:.0f}MB (limit: {BROWSER_MEMORY_LIMIT}MB)")
        actions.append("Browser memory high — restart recommended")
    
    return {
        'timestamp': datetime.now().isoformat(),
        'system_memory': {
            'percent': mem_percent,
            'used_mb': mem_info['used'] / (1024 * 1024),
            'total_mb': mem_info['total'] / (1024 * 1024)
        },
        'process_memory': proc_mem,
        'alerts': alerts,
        'actions': actions
    }

def main():
    result = check_and_alert()
    
    # Save to log file
    log_dir = '/root/.openclaw/workspace/memory-logs'
    os.makedirs(log_dir, exist_ok=True)
    
    log_file = f"{log_dir}/memory-{datetime.now().strftime('%Y-%m-%d')}.jsonl"
    with open(log_file, 'a') as f:
        f.write(json.dumps(result) + '\n')
    
    # Print alerts if any
    if result.get('alerts'):
        print(json.dumps({
            'status': 'ALERT',
            'alerts': result['alerts'],
            'actions': result['actions'],
            'memory_percent': result['system_memory']['percent']
        }))
        sys.exit(1)  # Non-zero exit for alerting
    else:
        print(json.dumps({'status': 'OK', 'memory_percent': result['system_memory']['percent']}))
        sys.exit(0)

if __name__ == '__main__':
    main()