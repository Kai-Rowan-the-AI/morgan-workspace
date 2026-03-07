#!/usr/bin/env python3
"""
LLM-powered PR implementation generator
Called by github-sla.sh to actually implement fixes
"""

import sys
import json
import os
import subprocess
import tempfile
import shutil

def run_command(cmd, cwd=None):
    """Run shell command and return output"""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
    return result.returncode == 0, result.stdout, result.stderr

def generate_fix_with_kimi(issue_title, issue_body, repo_files, file_contents):
    """Generate fix using kimi API via kimi tool"""
    
    # Construct prompt
    prompt = f"""You are an expert developer. I need you to implement a fix for this GitHub issue.

ISSUE TITLE: {issue_title}

ISSUE DESCRIPTION:
{issue_body[:2000]}

RELEVANT FILES IN REPO:
{chr(10).join(repo_files[:20])}

FILE CONTENTS (key files):
"""
    
    # Add file contents (limited)
    total_chars = len(prompt)
    for filepath, content in file_contents.items():
        if total_chars > 12000:  # Stay under token limit
            break
        file_section = f"\n\n=== {filepath} ===\n{content[:1500]}"
        prompt += file_section
        total_chars += len(file_section)
    
    prompt += """

YOUR TASK:
1. Analyze the issue and understand what needs to be fixed
2. Identify which file(s) need to be modified
3. Provide the exact code changes needed

RESPOND IN THIS JSON FORMAT:
{
  "analysis": "Brief analysis of the issue",
  "files_to_modify": ["file1.py", "file2.js"],
  "changes": [
    {
      "file": "file1.py",
      "action": "modify",
      "search": "exact text to find",
      "replace": "exact replacement text"
    }
  ],
  "confidence": 0.8
}

Only provide changes you're confident about. If unsure, set confidence < 0.5 and provide explanation."""

    # Write prompt to temp file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(prompt)
        prompt_file = f.name
    
    try:
        # Use kimi-search tool to get implementation guidance
        # Since we can't directly call the LLM from Python easily in this environment,
        # we'll return a structured response indicating what needs to be done
        
        return {
            "analysis": f"Issue: {issue_title}",
            "files_to_modify": [],
            "changes": [],
            "confidence": 0.3,
            "note": "LLM integration pending - this is a placeholder that needs the actual kimi API integration"
        }
    finally:
        os.unlink(prompt_file)

def main():
    if len(sys.argv) < 5:
        print("Usage: implement-fix.py <repo> <issue_num> <issue_title> <issue_body_file>")
        sys.exit(1)
    
    repo = sys.argv[1]
    issue_num = sys.argv[2]
    issue_title = sys.argv[3]
    issue_body_file = sys.argv[4]
    
    # Read issue body
    with open(issue_body_file, 'r') as f:
        issue_body = f.read()
    
    # Find relevant files in repo
    repo_path = "."
    repo_files = []
    file_contents = {}
    
    for root, dirs, files in os.walk(repo_path):
        # Skip hidden and common non-code directories
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ['node_modules', '__pycache__', 'venv', '.git']]
        
        for file in files:
            if file.endswith(('.py', '.js', '.ts', '.jsx', '.tsx', '.rs', '.go', '.md', '.json', '.yaml', '.yml')):
                filepath = os.path.join(root, file)
                rel_path = os.path.relpath(filepath, repo_path)
                repo_files.append(rel_path)
                
                # Read file content if it looks relevant
                if len(file_contents) < 10:  # Limit files read
                    try:
                        with open(filepath, 'r') as f:
                            content = f.read()
                            # Only include if file is reasonable size
                            if len(content) < 10000:
                                file_contents[rel_path] = content
                    except:
                        pass
    
    # Generate fix
    result = generate_fix_with_kimi(issue_title, issue_body, repo_files, file_contents)
    
    # Output result as JSON
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
