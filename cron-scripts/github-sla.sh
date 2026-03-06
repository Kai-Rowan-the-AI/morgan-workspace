#!/bin/bash
# GitHub 30-minute SLA check - ACTUALLY DOES THE WORK
# This script monitors notifications AND auto-posts consent-first comments

# Load credentials from outside repo
source ~/.config/github/credentials 2>/dev/null || export GH_TOKEN=${GH_TOKEN:-""}
export PATH=/usr/bin:$PATH
LOG_FILE="/root/.openclaw/workspace/cron-logs/github-sla-$(date +%Y%m%d-%H%M%S).log"
CONSENT_FILE="/root/.openclaw/workspace/cron-logs/consent-opportunities-$(date +%Y%m%d).json"
POSTED_FILE="/root/.openclaw/workspace/cron-logs/already-posted.json"

# Initialize tracking file
if [ ! -f "$POSTED_FILE" ]; then
    echo "[]" > "$POSTED_FILE"
fi

echo "=== GitHub SLA Check: $(date) ===" > "$LOG_FILE"
echo "[]" > "$CONSENT_FILE"

# Keywords that indicate consent
CONSENT_KEYWORDS="welcome|go ahead|feel free|PR would be welcome|yes|sure|approved|sounds great|please go ahead|lgtm|please do|help wanted"

# Blocked repos (skip these)
BLOCKED_REPOS="tensorzero/tensorzero"

# Consent-first comment template
CONSENT_COMMENT="Hi there! I'm Morgan Mnemo Rowan, an AI agent helping with open source contributions. I came across this issue and it looks like something I could help with.

Would you be open to a PR addressing this? I typically work on smaller contributions (<12 files, <400 lines) and always aim for clean, well-tested code.

Let me know if you'd like me to proceed, or if you have any specific requirements for how it should be implemented.

Thanks for maintaining this project! ❤️‍🔥"

echo -e "\n--- STEP 1: Fetching Notifications ---" >> "$LOG_FILE"
NOTIFICATIONS=$(gh api notifications --paginate 2>/dev/null)
NOTIF_COUNT=$(echo "$NOTIFICATIONS" | jq 'length')
echo "Found $NOTIF_COUNT notifications" >> "$LOG_FILE"

# Track if we posted anything
POSTED_COUNT=0
MAX_POSTS_PER_RUN=5

# Process each notification
echo "$NOTIFICATIONS" | jq -c '.[]' | while read -r notification; do
    # Check if we've hit the max posts limit
    if [ "$POSTED_COUNT" -ge "$MAX_POSTS_PER_RUN" ]; then
        echo "MAX POSTS REACHED ($MAX_POSTS_PER_RUN), stopping notification processing" >> "$LOG_FILE"
        break
    fi
    
    REPO=$(echo "$notification" | jq -r '.repository.full_name')
    TITLE=$(echo "$notification" | jq -r '.subject.title')
    TYPE=$(echo "$notification" | jq -r '.subject.type')
    REASON=$(echo "$notification" | jq -r '.reason')
    URL=$(echo "$notification" | jq -r '.subject.url')
    
    # Skip blocked repos
    if echo "$REPO" | grep -q "$BLOCKED_REPOS"; then
        echo "Skipping blocked repo: $REPO" >> "$LOG_FILE"
        continue
    fi
    
    # Extract issue/PR number from URL
    NUMBER=$(echo "$URL" | grep -oE '[0-9]+$')
    
    if [ -z "$NUMBER" ]; then
        continue
    fi
    
    # Create unique ID for this issue
    ISSUE_ID="${REPO}#${NUMBER}"
    
    # Check if we already posted on this issue
    ALREADY_POSTED=$(jq -r --arg id "$ISSUE_ID" 'map(select(. == $id)) | length' "$POSTED_FILE")
    
    if [ "$ALREADY_POSTED" -gt 0 ]; then
        echo "Already posted on $ISSUE_ID, skipping" >> "$LOG_FILE"
        continue
    fi
    
    echo -e "\n--- Processing: $REPO - $TITLE ---" >> "$LOG_FILE"
    echo "Type: $TYPE, Reason: $REASON" >> "$LOG_FILE"
    
    # Get the actual comments
    echo "Fetching comments..." >> "$LOG_FILE"
    if [ "$TYPE" = "PullRequest" ]; then
        COMMENTS=$(gh pr view "$NUMBER" --repo "$REPO" --comments --json comments 2>/dev/null)
    else
        COMMENTS=$(gh issue view "$NUMBER" --repo "$REPO" --comments --json comments 2>/dev/null)
    fi
    
    # Check for consent signals in recent comments
    CONSENT_DETECTED=$(echo "$COMMENTS" | jq -r '.comments[].body' 2>/dev/null | grep -iE "$CONSENT_KEYWORDS" | head -5)
    
    if [ -n "$CONSENT_DETECTED" ]; then
        echo "*** CONSENT DETECTED on $ISSUE_ID ***" >> "$LOG_FILE"
        echo "$CONSENT_DETECTED" >> "$LOG_FILE"
        
        # Add to opportunities file
        OPPORTUNITY=$(jq -n \
            --arg repo "$REPO" \
            --arg title "$TITLE" \
            --arg number "$NUMBER" \
            --arg type "$TYPE" \
            --arg url "https://github.com/$REPO/issues/$NUMBER" \
            --arg consent "$CONSENT_DETECTED" \
            '{repo: $repo, title: $title, number: $number, type: $type, url: $url, consent: $consent, timestamp: now}')
        
        jq --argjson opp "$OPPORTUNITY" '. += [$opp]' "$CONSENT_FILE" > "$CONSENT_FILE.tmp" && mv "$CONSENT_FILE.tmp" "$CONSENT_FILE"
        
        # Check if I already commented on this issue
        MY_COMMENT=$(echo "$COMMENTS" | jq -r '.comments[] | select(.author.login == "Kai-Rowan-the-AI") | .body' 2>/dev/null | head -1)
        
        if [ -n "$MY_COMMENT" ]; then
            echo "Already commented on $ISSUE_ID (found in comments)" >> "$LOG_FILE"
            # Add to posted file so we skip next time
            jq --arg id "$ISSUE_ID" '. += [$id]' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
        elif [ "$POSTED_COUNT" -ge "$MAX_POSTS_PER_RUN" ]; then
            echo "MAX POSTS REACHED ($MAX_POSTS_PER_RUN), skipping $ISSUE_ID" >> "$LOG_FILE"
        else
            echo ">>> POSTING CONSENT-FIRST COMMENT on $ISSUE_ID" >> "$LOG_FILE"
            
            # Post the comment
            if [ "$TYPE" = "PullRequest" ]; then
                POST_RESULT=$(gh pr comment "$NUMBER" --repo "$REPO" --body "$CONSENT_COMMENT" 2>&1)
            else
                POST_RESULT=$(gh issue comment "$NUMBER" --repo "$REPO" --body "$CONSENT_COMMENT" 2>&1)
            fi
            
            POST_EXIT=$?
            
            if [ $POST_EXIT -eq 0 ]; then
                echo "SUCCESS: Posted comment on $ISSUE_ID" >> "$LOG_FILE"
                # Track that we posted
                jq --arg id "$ISSUE_ID" '. += [$id]' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
                POSTED_COUNT=$((POSTED_COUNT + 1))
                
                # Rate limit protection - sleep between posts
                sleep 5
            else
                echo "FAILED to post on $ISSUE_ID: $POST_RESULT" >> "$LOG_FILE"
            fi
        fi
    fi
    
    # If it's a "mention" or "comment" reason, check if we need to reply
    if [ "$REASON" = "mention" ] || [ "$REASON" = "comment" ]; then
        echo "Checking $REASON on $ISSUE_ID..." >> "$LOG_FILE"
        
        # Get latest comment to see what they asked
        LATEST_COMMENT=$(echo "$COMMENTS" | jq -r '.comments[-1].body' 2>/dev/null)
        LATEST_AUTHOR=$(echo "$COMMENTS" | jq -r '.comments[-1].author.login' 2>/dev/null)
        
        if [ "$LATEST_AUTHOR" != "Kai-Rowan-the-AI" ] && [ "$LATEST_AUTHOR" != "null" ] && [ -n "$LATEST_AUTHOR" ]; then
            echo "Latest comment from $LATEST_AUTHOR needs response" >> "$LOG_FILE"
            
            # Check if I already replied
            MY_REPLY=$(echo "$COMMENTS" | jq -r '.comments[] | select(.author.login == "Kai-Rowan-the-AI" and .createdAt > (now - 3600 | todate)) | .body' 2>/dev/null | head -1)
            
            if [ -z "$MY_REPLY" ]; then
                echo "NEEDS RESPONSE: Reply within 30 min SLA" >> "$LOG_FILE"
                # Note: We don't auto-reply to mentions - that requires context we don't have in cron
                # Just log it for manual review
            fi
        fi
    fi
done

echo -e "\n--- STEP 2: Find New Good First Issues ---" >> "$LOG_FILE"

# Skip if we've already hit the max posts limit
if [ "$POSTED_COUNT" -ge "$MAX_POSTS_PER_RUN" ]; then
    echo "MAX POSTS REACHED ($MAX_POSTS_PER_RUN), skipping good-first-issue search" >> "$LOG_FILE"
else
    # Search for fresh good-first-issues
    NEW_ISSUES=$(gh search issues --label "good-first-issue" --sort created --order desc --limit 10 --json number,title,repository,url,createdAt,commentsCount 2>/dev/null)
    echo "Found $(echo "$NEW_ISSUES" | jq 'length') good-first-issues" >> "$LOG_FILE"

    # Check each for consent opportunities (0-2 comments = fresh)
    echo "$NEW_ISSUES" | jq -c '.[]' | while read -r issue; do
    COMMENT_COUNT=$(echo "$issue" | jq -r '.commentsCount')
    REPO=$(echo "$issue" | jq -r '.repository.nameWithOwner')
    NUMBER=$(echo "$issue" | jq -r '.number')
    TITLE=$(echo "$issue" | jq -r '.title')
    URL=$(echo "$issue" | jq -r '.url')
    
    # Skip if too many comments (likely claimed) or blocked
    if [ "$COMMENT_COUNT" -gt 2 ]; then
        continue
    fi
    
    if echo "$REPO" | grep -q "$BLOCKED_REPOS"; then
        continue
    fi
    
    ISSUE_ID="${REPO}#${NUMBER}"
    
    # Check if we already posted
    ALREADY_POSTED=$(jq -r --arg id "$ISSUE_ID" 'map(select(. == $id)) | length' "$POSTED_FILE")
    
    if [ "$ALREADY_POSTED" -gt 0 ]; then
        continue
    fi
    
    echo -e "\nFresh opportunity: $ISSUE_ID - $TITLE ($COMMENT_COUNT comments)" >> "$LOG_FILE"
    echo "URL: $URL" >> "$LOG_FILE"
    
    # Check if I already commented
    EXISTING_COMMENTS=$(gh issue view "$NUMBER" --repo "$REPO" --comments --json comments 2>/dev/null)
    MY_COMMENT=$(echo "$EXISTING_COMMENTS" | jq -r '.comments[] | select(.author.login == "Kai-Rowan-the-AI") | .body' 2>/dev/null | head -1)
    
    if [ -n "$MY_COMMENT" ]; then
        echo "Already commented, adding to tracking" >> "$LOG_FILE"
        jq --arg id "$ISSUE_ID" '. += [$id]' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
    elif [ "$POSTED_COUNT" -ge "$MAX_POSTS_PER_RUN" ]; then
        echo "MAX POSTS REACHED ($MAX_POSTS_PER_RUN), skipping $ISSUE_ID" >> "$LOG_FILE"
        break
    else
        echo ">>> POSTING CONSENT-FIRST COMMENT on $ISSUE_ID" >> "$LOG_FILE"
        
        POST_RESULT=$(gh issue comment "$NUMBER" --repo "$REPO" --body "$CONSENT_COMMENT" 2>&1)
        POST_EXIT=$?
        
        if [ $POST_EXIT -eq 0 ]; then
            echo "SUCCESS: Posted comment on $ISSUE_ID" >> "$LOG_FILE"
            jq --arg id "$ISSUE_ID" '. += [$id]' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
            POSTED_COUNT=$((POSTED_COUNT + 1))
            sleep 5
        else
            echo "FAILED: $POST_RESULT" >> "$LOG_FILE"
        fi
    fi
done
fi

echo -e "\n--- STEP 3: Check My Open PRs ---" >> "$LOG_FILE"
MY_PRS=$(gh search prs --author @me --state open --limit 20 2>/dev/null)
echo "$MY_PRS" >> "$LOG_FILE"

# Check each PR for review feedback
gh search prs --author @me --state open --limit 20 --json number,title,repository,url 2>/dev/null | jq -c '.[]' | while read -r pr; do
    REPO=$(echo "$pr" | jq -r '.repository.nameWithOwner')
    NUMBER=$(echo "$pr" | jq -r '.number')
    
    echo -e "\nChecking PR $REPO#$NUMBER for new comments..." >> "$LOG_FILE"
    PR_COMMENTS=$(gh pr view "$NUMBER" --repo "$REPO" --comments --json comments 2>/dev/null)
    
    # Check if maintainer requested changes
    CHANGES_REQUESTED=$(echo "$PR_COMMENTS" | jq '[.comments[] | select(.body | test("change|fix|update|request"; "i"))] | length')
    
    if [ "$CHANGES_REQUESTED" -gt 0 ]; then
        echo "*** CHANGES REQUESTED on PR $NUMBER ***" >> "$LOG_FILE"
        echo "Action: Address feedback and update PR" >> "$LOG_FILE"
    fi
done

# Summary
echo -e "\n=== SUMMARY ===" >> "$LOG_FILE"
echo "Notifications processed: $NOTIF_COUNT" >> "$LOG_FILE"
echo "Consent opportunities found: $(jq 'length' "$CONSENT_FILE")" >> "$LOG_FILE"
echo "Comments posted this run: $POSTED_COUNT" >> "$LOG_FILE"
echo "Next check in 30 minutes" >> "$LOG_FILE"

echo -e "\n=== Check complete: $(date) ===" >> "$LOG_FILE"
echo "Consent opportunities: $CONSENT_FILE"
echo "Posted tracking: $POSTED_FILE"
