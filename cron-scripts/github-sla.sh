#!/bin/bash
# GitHub 30-minute SLA check - ACTUALLY DOES THE WORK
# Enhanced version with smart features

set -o pipefail

# Load credentials
source ~/.config/github/credentials 2>/dev/null || export GH_TOKEN=${GH_TOKEN:-""}
export PATH=/usr/bin:$PATH

# Configuration
LOG_DIR="/root/.openclaw/workspace/cron-logs"
LOG_FILE="$LOG_DIR/github-sla-$(date +%Y%m%d-%H%M%S).log"
CONSENT_FILE="$LOG_DIR/consent-opportunities-$(date +%Y%m%d).json"
POSTED_FILE="$LOG_DIR/already-posted.json"
PR_FILE="$LOG_DIR/prs-created.json"
METRICS_FILE="$LOG_DIR/github-metrics.json"
FOLLOW_UP_FILE="$LOG_DIR/follow-ups.json"
STALE_FILE="$LOG_DIR/stale-issues.json"
SENTIMENT_FILE="$LOG_DIR/sentiment-analysis.json"
MERGE_CONFLICT_FILE="$LOG_DIR/merge-conflicts.json"

# Settings
MAX_POSTS_PER_RUN=5
MAX_PR_PER_RUN=2
MAX_LOG_AGE_DAYS=7
MAX_ISSUE_AGE_DAYS=30
FOLLOW_UP_DAYS=3
STALE_DAYS=14
BLOCKED_REPOS="tensorzero/tensorzero"

# Auto-PR settings (AGGRESSIVE MODE)
AUTO_PR_ENABLED=true
AUTO_PR_MAX_FILES=12
AUTO_PR_MAX_LINES=400
AUTO_PR_MIN_PRIORITY=60

# Keywords
CONSENT_KEYWORDS="welcome|go ahead|feel free|PR would be welcome|yes|sure|approved|sounds great|please go ahead|lgtm|please do|help wanted|proceed|start working|you can work|go for it|yes please|would appreciate"
REJECTION_KEYWORDS="no|don't|do not|won't|will not|already done|duplicate|not needed|not interested|no thanks|pass|decline|rejected|wontfix"
QUESTION_KEYWORDS="how|what|why|when|where|which|can you|could you|would you|do you"
URGENT_KEYWORDS="urgent|asap|critical|blocking|broken|crash|error|fail|regression"
BOT_USERS="coderabbitai|github-actions|dependabot|renovate|semantic-release|stale|allcontributors"

# My skills for matching
MY_SKILLS="python|javascript|typescript|rust|go|bash|react|vue|css|html|docker|fastapi|flask|django|node|express|api|cli|tui|testing|pytest|jest|vitest|sql|postgres|sqlite|redis|git|github|ci|cd|github-actions|linux|ubuntu|debian|arch"

# Language detection for comments
COMMENT_TEMPLATES_EN="Hi there! I'm Morgan Mnemo Rowan, an AI agent helping with open source contributions. I came across this issue and it looks like something I could help with.

Would you be open to a PR addressing this? I typically work on smaller contributions (<12 files, <400 lines) and always aim for clean, well-tested code.

Let me know if you'd like me to proceed, or if you have any specific requirements for how it should be implemented.

Thanks for maintaining this project! ❤️‍🔥"

# Initialize files
for file in "$POSTED_FILE" "$PR_FILE" "$METRICS_FILE" "$FOLLOW_UP_FILE" "$STALE_FILE" "$SENTIMENT_FILE" "$MERGE_CONFLICT_FILE"; do
    [ ! -f "$file" ] && echo "[]" > "$file"
done

echo "=== GitHub SLA Check: $(date) ===" > "$LOG_FILE"
echo "[]" > "$CONSENT_FILE"

# Helper: Log with timestamp
log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

# Helper: API call with retry
api_call() {
    local cmd="$1"
    local retries=3
    local delay=2
    
    for i in $(seq 1 $retries); do
        result=$(eval "$cmd" 2>&1)
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            echo "$result"
            return 0
        elif echo "$result" | grep -qi "rate limit"; then
            reset_time=$(echo "$result" | grep -oP '\d+' | head -1)
            if [ -n "$reset_time" ]; then
                wait_time=$((reset_time - $(date +%s) + 10))
                [ $wait_time -gt 0 ] && [ $wait_time -lt 3600 ] && sleep $wait_time
            else
                sleep $((delay * i))
            fi
        elif echo "$result" | grep -qiE "timeout|connection|500|502|503"; then
            log "Network/server error (attempt $i/$retries), retrying..."
            sleep $delay
            delay=$((delay * 2))
        else
            log "API error: ${result:0:150}"
            return 1
        fi
    done
    return 1
}

# Helper: Check if user is a bot
is_bot() {
    local username="$1"
    echo "$username" | grep -qiE "^($BOT_USERS)$"
}

# Helper: Calculate hours since
time_diff_hours() {
    local timestamp="$1"
    local now=$(date +%s)
    local then=$(date -d "$timestamp" +%s 2>/dev/null || echo "$now")
    echo $(( (now - then) / 3600 ))
}

# Helper: Calculate days since
time_diff_days() {
    local timestamp="$1"
    local now=$(date +%s)
    local then_ts=$(date -d "$timestamp" +%s 2>/dev/null || echo "$now")
    echo $(( (now - then_ts) / 86400 ))
}

# Helper: Calculate issue priority (0-100)
calculate_priority() {
    local title="$1"
    local body="$2"
    local comments="$3"
    local created_at="$4"
    local labels="$5"
    local score=50
    
    # Age factor
    local age_days=$(time_diff_days "$created_at")
    if [ "$age_days" -lt 1 ]; then
        score=$((score + 25))
    elif [ "$age_days" -lt 3 ]; then
        score=$((score + 15))
    elif [ "$age_days" -lt 7 ]; then
        score=$((score + 5))
    elif [ "$age_days" -gt 21 ]; then
        score=$((score - 15))
    fi
    
    # Activity factor
    if [ "$comments" -eq 0 ]; then
        score=$((score + 20))
    elif [ "$comments" -eq 1 ]; then
        score=$((score + 10))
    elif [ "$comments" -le 3 ]; then
        score=$((score + 5))
    elif [ "$comments" -gt 10 ]; then
        score=$((score - 20))
    fi
    
    # Label bonuses
    if echo "$labels" | grep -qiE "good.?first.issue|good-first-issue|beginner|easy|simple|starter"; then
        score=$((score + 20))
    fi
    if echo "$labels" | grep -qiE "help.?wanted|help-wanted|up.for.grabs"; then
        score=$((score + 15))
    fi
    if echo "$labels" | grep -qiE "bug|fix|error|crash"; then
        score=$((score + 10))
    fi
    if echo "$labels" | grep -qiE "documentation|docs|readme"; then
        score=$((score + 8))
    fi
    if echo "$labels" | grep -qiE "enhancement|feature|improvement"; then
        score=$((score + 5))
    fi
    
    # Skill match
    local combined="${title} ${body}"
    local matches=0
    for skill in $(echo "$MY_SKILLS" | tr '|' ' '); do
        if echo "$combined" | grep -qi "$skill"; then
            matches=$((matches + 1))
        fi
    done
    score=$((score + matches * 2))
    
    # Check for urgency in title
    if echo "$title" | grep -qiE "$URGENT_KEYWORDS"; then
        score=$((score + 15))
    fi
    
    # Penalty for assignment
    if echo "$labels" | grep -qiE "assigned|in.progress|claimed"; then
        score=$((score - 30))
    fi
    
    [ $score -gt 100 ] && score=100
    [ $score -lt 0 ] && score=0
    echo $score
}

# Helper: Analyze sentiment of text
analyze_sentiment() {
    local text="$1"
    local positive=0
    local negative=0
    local questions=0
    
    # Positive signals
    if echo "$text" | grep -qiE "thank|thanks|appreciate|great|awesome|nice|perfect|excellent|love|like"; then
        positive=$((positive + 1))
    fi
    
    # Negative signals
    if echo "$text" | grep -qiE "sorry|unfortunately|but|however|issue|problem|concern|worry"; then
        negative=$((negative + 1))
    fi
    
    # Questions
    if echo "$text" | grep -qiE "$QUESTION_KEYWORDS"; then
        questions=$((questions + 1))
    fi
    
    if [ $positive -gt $negative ]; then
        echo "positive"
    elif [ $negative -gt $positive ]; then
        echo "negative"
    elif [ $questions -gt 0 ]; then
        echo "questioning"
    else
        echo "neutral"
    fi
}

# Helper: Check for rejection
has_rejection() {
    local text="$1"
    echo "$text" | grep -qiE "$REJECTION_KEYWORDS"
}

# Helper: Check for consent
has_consent() {
    local text="$1"
    echo "$text" | grep -qiE "$CONSENT_KEYWORDS"
}

# Helper: Check for questions
has_questions() {
    local text="$1"
    echo "$text" | grep -qiE "$QUESTION_KEYWORDS"
}

# Helper: Detect duplicate issues across repos
detect_duplicates() {
    local title="$1"
    local repo="$2"
    
    # Normalize title for comparison
    local normalized=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    
    # Check against existing tracked issues
    jq -r '.[].title // empty' "$POSTED_FILE" 2>/dev/null | while read -r existing; do
        local existing_norm=$(echo "$existing" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        if [ "$normalized" = "$existing_norm" ] && [ -n "$normalized" ]; then
            echo "duplicate"
            return
        fi
    done
    echo "unique"
}

# Helper: Auto-create PR when consent is given (LLM-powered implementation)
auto_create_pr() {
    local repo="$1"
    local issue_num="$2"
    local issue_title="$3"
    local priority="$4"
    
    log "AUTO-PR: Starting LLM-powered PR creation for $repo#$issue_num"
    
    # Check if already has PR
    local existing_pr=$(api_call "gh pr list --repo $repo --search \"$issue_num\" --state open --json number")
    if [ -n "$existing_pr" ] && [ "$existing_pr" != "[]" ]; then
        log "AUTO-PR: PR already exists for this issue"
        return 1
    fi
    
    # Get issue details
    local issue_body=$(api_call "gh issue view $issue_num --repo $repo --json body" | jq -r '.body // empty')
    local issue_labels=$(api_call "gh issue view $issue_num --repo $repo --json labels" | jq -r '.labels | map(.name) | join(",")')
    
    # Check complexity
    if echo "$issue_body" | grep -qiE "refactor|restructure|architecture|breaking.change|migration|redesign"; then
        log "AUTO-PR: Issue too complex (refactor/architecture). Flagging for manual review."
        return 1
    fi
    
    log "AUTO-PR: Spawning sub-agent to implement fix..."
    
    # Create sub-agent session to implement the fix
    local session_key="auto-pr-$(date +%s)-$$"
    
    # Build the task for the sub-agent
    local task="IMPLEMENT FIX FOR GITHUB ISSUE

Repository: $repo
Issue: #$issue_num
Title: $issue_title
Labels: $issue_labels

Issue Body:
$issue_body

YOUR TASK:
1. Fork the repo to Kai-Rowan-the-AI if not already forked
2. Clone your fork
3. Create branch: auto-fix-issue-$issue_num
4. READ the codebase to understand structure
5. Implement the ACTUAL fix based on the issue description
6. Write tests if appropriate
7. Commit with descriptive message
8. Push branch
9. Create PR linking to issue #$issue_num
10. Comment on the issue with the PR URL

CONSTRAINTS:
- Max 12 files changed
- Max 400 lines changed
- Must include tests if issue is a bug
- Follow existing code style
- Write clear commit messages

Use gh CLI and git. GitHub token is available."

    # Spawn the sub-agent
    sessions_spawn "$task" "$session_key"
    
    log "AUTO-PR: Sub-agent spawned with session: $session_key"
    log "AUTO-PR: Implementation in progress (check sub-agents for status)"
    
    # Track that we attempted PR creation
    jq --argjson obj "{\"id\": \"$repo#$issue_num\", \"repo\": \"$repo\", \"number\": $issue_num, \"timestamp\": $(date +%s), \"status\": \"in_progress\", \"session\": \"$session_key\"}" '. += [$obj]' "$PR_FILE" > "$PR_FILE.tmp" && mv "$PR_FILE.tmp" "$PR_FILE"
    
    return 0
}

# Step 0: Clean old logs and data
log "STEP 0: Cleaning old data"
find "$LOG_DIR" -name "github-sla-*.log" -mtime +$MAX_LOG_AGE_DAYS -delete 2>/dev/null
find "$LOG_DIR" -name "consent-opportunities-*.json" -mtime +$MAX_LOG_AGE_DAYS -delete 2>/dev/null

# Clean stale entries from posted file (older than 90 days)
NOW=$(date +%s)
jq --argjson now "$NOW" '[.[] | select((.timestamp // 0) > ($now - 7776000))]' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"

# Clean up closed issues from tracking (check a sample)
log "Checking tracked issues for closures..."
CLOSED_COUNT=0
jq -r '.[] | "\(.repo)|\(.number)|\(.id)"' "$POSTED_FILE" 2>/dev/null | head -20 | while IFS='|' read -r repo num id; do
    [ -z "$repo" ] && continue
    STATE=$(api_call "gh issue view $num --repo $repo --json state" | jq -r '.state // empty')
    if [ "$STATE" = "CLOSED" ]; then
        log "Removing closed issue: $id"
        jq --arg id "$id" 'map(select(.id != $id))' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
        CLOSED_COUNT=$((CLOSED_COUNT + 1))
        sleep 1
    fi
done
[ $CLOSED_COUNT -gt 0 ] && log "Removed $CLOSED_COUNT closed issues"

log "Cleanup complete"

# Step 1: Process notifications
log "STEP 1: Processing notifications"
NOTIFICATIONS=$(api_call "gh api notifications --paginate")
NOTIF_COUNT=$(echo "$NOTIFICATIONS" | jq 'length // 0')
log "Found $NOTIF_COUNT notifications"

POSTED_COUNT=0
URGENT_COUNT=0
CONSENT_COUNT=0
QUESTION_COUNT=0
STALE_COUNT=0

if [ "$NOTIF_COUNT" -gt 0 ]; then
    while IFS= read -r notification; do
        [ -z "$notification" ] && continue
        
        if [ "$POSTED_COUNT" -ge "$MAX_POSTS_PER_RUN" ]; then
            log "MAX POSTS ($MAX_POSTS_PER_RUN) reached"
            break
        fi
        
        REPO=$(echo "$notification" | jq -r '.repository.full_name // empty')
        TITLE=$(echo "$notification" | jq -r '.subject.title // empty')
        TYPE=$(echo "$notification" | jq -r '.subject.type // empty')
        REASON=$(echo "$notification" | jq -r '.reason // empty')
        URL=$(echo "$notification" | jq -r '.subject.url // empty')
        
        [ -z "$REPO" ] && continue
        
        # Skip blocked
        if echo "$REPO" | grep -qE "$BLOCKED_REPOS"; then
            continue
        fi
        
        NUMBER=$(echo "$URL" | grep -oE '[0-9]+$')
        [ -z "$NUMBER" ] && continue
        
        ISSUE_ID="${REPO}#${NUMBER}"
        
        # Get issue details
        ISSUE_DATA=$(api_call "gh issue view $NUMBER --repo $REPO --json title,body,comments,createdAt,labels,state,assignees")
        [ -z "$ISSUE_DATA" ] && continue
        
        ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title // empty')
        ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r '.body // empty')
        COMMENTS_ARR=$(echo "$ISSUE_DATA" | jq -r '.comments // []')
        COMMENTS_COUNT=$(echo "$COMMENTS_ARR" | jq 'length')
        CREATED_AT=$(echo "$ISSUE_DATA" | jq -r '.createdAt // empty')
        LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels | map(.name) | join(",") // empty')
        STATE=$(echo "$ISSUE_DATA" | jq -r '.state // empty')
        ASSIGNED=$(echo "$ISSUE_DATA" | jq -r '.assignees | length // 0')
        
        # Skip closed
        [ "$STATE" = "CLOSED" ] && continue
        
        # Skip assigned
        if [ "$ASSIGNED" -gt 0 ]; then
            log "$ISSUE_ID: Already assigned, skipping"
            continue
        fi
        
        # Skip old issues
        ISSUE_AGE=$(time_diff_days "$CREATED_AT")
        if [ "$ISSUE_AGE" -gt "$MAX_ISSUE_AGE_DAYS" ]; then
            log "$ISSUE_ID: Too old ($ISSUE_AGE days), skipping"
            continue
        fi
        
        # Check for staleness (no activity)
        if [ "$COMMENTS_COUNT" -gt 0 ]; then
            LAST_COMMENT_TIME=$(echo "$COMMENTS_ARR" | jq -r '[-1].createdAt // empty')
            if [ -n "$LAST_COMMENT_TIME" ]; then
                DAYS_SINCE_COMMENT=$(time_diff_days "$LAST_COMMENT_TIME")
                if [ "$DAYS_SINCE_COMMENT" -gt "$STALE_DAYS" ]; then
                    log "$ISSUE_ID: Stale ($DAYS_SINCE_COMMENT days since last comment)"
                    STALE_COUNT=$((STALE_COUNT + 1))
                    jq --argjson obj "{\"id\": \"$ISSUE_ID\", \"repo\": \"$REPO\", \"number\": $NUMBER, \"days_stale\": $DAYS_SINCE_COMMENT}" '. += [$obj]' "$STALE_FILE" > "$STALE_FILE.tmp" && mv "$STALE_FILE.tmp" "$STALE_FILE"
                fi
            fi
        fi
        
        # Calculate priority
        PRIORITY=$(calculate_priority "$ISSUE_TITLE" "$ISSUE_BODY" "$COMMENTS_COUNT" "$CREATED_AT" "$LABELS")
        
        # Check tracking
        ALREADY_POSTED=$(jq -r --arg id "$ISSUE_ID" 'map(select(.id == $id)) | length' "$POSTED_FILE")
        
        if [ "$ALREADY_POSTED" -gt 0 ]; then
            # Check for new maintainer activity
            if [ "$REASON" = "mention" ] || [ "$REASON" = "comment" ]; then
                LATEST_COMMENT=$(echo "$COMMENTS_ARR" | jq -r '[-1] // empty')
                [ -z "$LATEST_COMMENT" ] || [ "$LATEST_COMMENT" = "null" ] && continue
                
                AUTHOR=$(echo "$LATEST_COMMENT" | jq -r '.author.login // empty')
                BODY=$(echo "$LATEST_COMMENT" | jq -r '.body // empty')
                TIME=$(echo "$LATEST_COMMENT" | jq -r '.createdAt // empty')
                
                if [ "$AUTHOR" != "Kai-Rowan-the-AI" ] && [ -n "$AUTHOR" ] && ! is_bot "$AUTHOR"; then
                    
                    # Check sentiment
                    SENTIMENT=$(analyze_sentiment "$BODY")
                    
                    # Check for rejection
                    if has_rejection "$BODY"; then
                        log "$ISSUE_ID: Maintainer declined ($SENTIMENT), removing"
                        jq --arg id "$ISSUE_ID" 'map(select(.id != $id))' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
                        continue
                    fi
                    
                    # Check for questions
                    if has_questions "$BODY"; then
                        log "$ISSUE_ID: Maintainer has questions ($SENTIMENT)"
                        QUESTION_COUNT=$((QUESTION_COUNT + 1))
                        continue
                    fi
                    
                    # Check for consent
                    if has_consent "$BODY"; then
                        HOURS=$(time_diff_hours "$TIME")
                        log "*** CONSENT on $ISSUE_ID (score: $PRIORITY, ${HOURS}h ago, $SENTIMENT) ***"
                        CONSENT_COUNT=$((CONSENT_COUNT + 1))
                        
                        OPPORTUNITY=$(jq -n \
                            --arg id "$ISSUE_ID" \
                            --arg repo "$REPO" \
                            --argjson num "$NUMBER" \
                            --arg title "$ISSUE_TITLE" \
                            --arg author "$AUTHOR" \
                            --argjson priority "$PRIORITY" \
                            --argjson hours "$HOURS" \
                            --arg sentiment "$SENTIMENT" \
                            '{id: $id, repo: $repo, number: $num, title: $title, author: $author, priority: $priority, hours: $hours, sentiment: $sentiment, action: "create_pr"}')
                        
                        jq --argjson opp "$OPPORTUNITY" '. += [$opp]' "$CONSENT_FILE" > "$CONSENT_FILE.tmp" && mv "$CONSENT_FILE.tmp" "$CONSENT_FILE"
                        
                        # AUTO-PR: Create PR immediately if enabled and meets criteria
                        if [ "$AUTO_PR_ENABLED" = true ] && [ "$PRIORITY" -ge "$AUTO_PR_MIN_PRIORITY" ]; then
                            PR_COUNT=$(jq 'length' "$PR_FILE")
                            if [ $PR_COUNT -lt $MAX_PR_PER_RUN ]; then
                                # Check if already has a PR
                                HAS_EXISTING=$(jq -r --arg id "$ISSUE_ID" 'map(select(.id == $id)) | length' "$PR_FILE")
                                if [ "$HAS_EXISTING" -eq 0 ]; then
                                    log ">>> AUTO-PR TRIGGERED for $ISSUE_ID"
                                    auto_create_pr "$REPO" "$NUMBER" "$ISSUE_TITLE" "$PRIORITY"
                                fi
                            else
                                log "AUTO-PR: Max PR limit reached ($MAX_PR_PER_RUN), skipping"
                            fi
                        fi
                    fi
                fi
            fi
            continue
        fi
        
        # New issue - evaluate
        log "Evaluating: $ISSUE_ID (priority: $PRIORITY)"
        
        # Skip low priority
        if [ "$PRIORITY" -lt 25 ]; then
            log "Priority too low ($PRIORITY), skipping"
            continue
        fi
        
        # Check for duplicates
        DUPLICATE_CHECK=$(detect_duplicates "$ISSUE_TITLE" "$REPO")
        if [ "$DUPLICATE_CHECK" = "duplicate" ]; then
            log "$ISSUE_ID: Duplicate title detected, skipping"
            continue
        fi
        
        # Get all comments text
        COMMENTS_TEXT=$(echo "$COMMENTS_ARR" | jq -r 'map(.body) | join(" ") // empty')
        
        # Check for existing consent in comments
        if has_consent "$COMMENTS_TEXT"; then
            log "Consent signals found in comments"
            
            OPPORTUNITY=$(jq -n \
                --arg id "$ISSUE_ID" \
                --arg repo "$REPO" \
                --argjson num "$NUMBER" \
                --argjson priority "$PRIORITY" \
                '{id: $id, repo: $repo, number: $num, priority: $priority, timestamp: now}')
            
            jq --argjson opp "$OPPORTUNITY" '. += [$opp]' "$CONSENT_FILE" > "$CONSENT_FILE.tmp" && mv "$CONSENT_FILE.tmp" "$CONSENT_FILE"
        fi
        
        # Post comment if under limit
        if [ "$POSTED_COUNT" -lt "$MAX_POSTS_PER_RUN" ]; then
            log ">>> Posting comment on $ISSUE_ID"
            
            POST_RESULT=$(gh issue comment "$NUMBER" --repo "$REPO" --body "$COMMENT_TEMPLATES_EN" 2>&1)
            
            if [ $? -eq 0 ]; then
                log "SUCCESS: Posted on $ISSUE_ID"
                jq --argjson obj "{\"id\": \"$ISSUE_ID\", \"repo\": \"$REPO\", \"number\": $NUMBER, \"priority\": $PRIORITY, \"timestamp\": $NOW, \"title\": \"$ISSUE_TITLE\"}" '. += [$obj]' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
                POSTED_COUNT=$((POSTED_COUNT + 1))
                sleep 5
            else
                log "FAILED: ${POST_RESULT:0:100}"
            fi
        else
            log "Max posts reached, queued for next run"
        fi
        
    done <<< "$(echo "$NOTIFICATIONS" | jq -c '.[]' 2>/dev/null)"
fi

# Step 2: Check my PRs
log "STEP 2: Checking my PRs"
MY_PRS=$(api_call "gh search prs --author @me --state open --limit 20 --json number,title,repository,url")

while IFS= read -r pr; do
    [ -z "$pr" ] && continue
    
    REPO=$(echo "$pr" | jq -r '.repository.nameWithOwner // empty')
    NUMBER=$(echo "$pr" | jq -r '.number // empty')
    [ -z "$REPO" ] || [ -z "$NUMBER" ] && continue
    
    PR_DATA=$(api_call "gh pr view $NUMBER --repo $REPO --json comments,reviews,mergeStateStatus,mergeable,headRefOid")
    [ -z "$PR_DATA" ] && continue
    
    # Check for merge conflicts
    MERGE_STATE=$(echo "$PR_DATA" | jq -r '.mergeStateStatus // empty')
    if [ "$MERGE_STATE" = "DIRTY" ] || [ "$MERGE_STATE" = "CONFLICTING" ]; then
        log "*** MERGE CONFLICT on $REPO#$NUMBER ***"
        jq --argjson obj "{\"repo\": \"$REPO\", \"number\": $NUMBER, \"detected\": $NOW}" '. += [$obj]' "$MERGE_CONFLICT_FILE" > "$MERGE_CONFLICT_FILE.tmp" && mv "$MERGE_CONFLICT_FILE.tmp" "$MERGE_CONFLICT_FILE"
    fi
    
    # Check reviews
    REVIEWS=$(echo "$PR_DATA" | jq -c '.reviews[]? // empty')
    if [ -n "$REVIEWS" ]; then
        while IFS= read -r review; do
            [ -z "$review" ] && continue
            
            AUTHOR=$(echo "$review" | jq -r '.author.login // empty')
            STATE=$(echo "$review" | jq -r '.state // empty')
            
            [ "$AUTHOR" = "Kai-Rowan-the-AI" ] && continue
            is_bot "$AUTHOR" && continue
            
            if [ "$STATE" = "CHANGES_REQUESTED" ]; then
                log "*** URGENT: Changes requested on $REPO#$NUMBER by $AUTHOR ***"
                URGENT_COUNT=$((URGENT_COUNT + 1))
            elif [ "$STATE" = "APPROVED" ]; then
                log "*** APPROVED: $REPO#$NUMBER by $AUTHOR ***"
            fi
        done <<< "$REVIEWS"
    fi
    
    # Check comments for feedback
    COMMENTS=$(echo "$PR_DATA" | jq -c '.comments[]? // empty')
    while IFS= read -r comment; do
        [ -z "$comment" ] && continue
        
        AUTHOR=$(echo "$comment" | jq -r '.author.login // empty')
        BODY=$(echo "$comment" | jq -r '.body // empty')
        
        [ "$AUTHOR" = "Kai-Rowan-the-AI" ] && continue
        is_bot "$AUTHOR" && continue
        
        if echo "$BODY" | grep -qiE "change|fix|update|request|needs work|please address|revise"; then
            log "*** Feedback on $REPO#$NUMBER by $AUTHOR ***"
            URGENT_COUNT=$((URGENT_COUNT + 1))
        fi
    done <<< "$COMMENTS"
    
done <<< "$(echo "$MY_PRS" | jq -c '.[]' 2>/dev/null)"

# Step 2.5: Proactive Discovery (ALWAYS run, regardless of posting limits)
log "STEP 2.5: Proactive discovery - finding new issues"

# Search for good-first-issues
log "Searching for good-first-issues..."
GFI_ISSUES=$(api_call "gh search issues --label \"good-first-issue\" --sort created --order desc --limit 50 --json number,title,repository,url,createdAt,commentsCount,body")

# Debug: log how many issues found
GFI_COUNT=$(echo "$GFI_ISSUES" | jq 'length // 0')
log "Found $GFI_COUNT good-first-issues from search"

if [ -n "$GFI_ISSUES" ] && [ "$GFI_COUNT" -gt 0 ]; then
    DISCOVERED_COUNT=0
    CHECKED_COUNT=0
    
    while IFS= read -r issue; do
        [ -z "$issue" ] && continue
        
        CHECKED_COUNT=$((CHECKED_COUNT + 1))
        
        COMMENT_COUNT=$(echo "$issue" | jq -r '.commentsCount // 0')
        REPO=$(echo "$issue" | jq -r '.repository.nameWithOwner // empty')
        NUMBER=$(echo "$issue" | jq -r '.number // empty')
        TITLE=$(echo "$issue" | jq -r '.title // empty')
        URL=$(echo "$issue" | jq -r '.url // empty')
        CREATED_AT=$(echo "$issue" | jq -r '.createdAt // empty')
        BODY=$(echo "$issue" | jq -r '.body // empty')
        
        [ -z "$REPO" ] || [ -z "$NUMBER" ] && continue
        
        ISSUE_ID="${REPO}#${NUMBER}"
        
        # Skip if too many comments (likely claimed)
        if [ "$COMMENT_COUNT" -gt 5 ]; then
            log "  Skipping $ISSUE_ID: Too many comments ($COMMENT_COUNT)"
            continue
        fi
        
        # Skip if blocked
        if echo "$REPO" | grep -qE "$BLOCKED_REPOS"; then
            log "  Skipping $ISSUE_ID: Blocked repo"
            continue
        fi
        
        # Skip if already in tracking
        ALREADY_TRACKED=$(jq -r --arg id "$ISSUE_ID" 'map(select(.id == $id)) | length' "$POSTED_FILE")
        if [ "$ALREADY_TRACKED" -gt 0 ]; then
            log "  Skipping $ISSUE_ID: Already tracked"
            continue
        fi
        
        # Calculate priority
        PRIORITY=$(calculate_priority "$TITLE" "$BODY" "$COMMENT_COUNT" "$CREATED_AT" "good-first-issue")
        log "  Checking $ISSUE_ID: priority=$PRIORITY, comments=$COMMENT_COUNT"
        
        # Lowered threshold to 50 for more visibility
        if [ "$PRIORITY" -ge 50 ]; then
            log "*** DISCOVERED: $ISSUE_ID (priority: $PRIORITY, $COMMENT_COUNT comments) ***"
            
            OPPORTUNITY=$(jq -n \
                --arg id "$ISSUE_ID" \
                --arg repo "$REPO" \
                --argjson num "$NUMBER" \
                --arg title "$TITLE" \
                --arg url "$URL" \
                --argjson priority "$PRIORITY" \
                --argjson comments "$COMMENT_COUNT" \
                '{id: $id, repo: $repo, number: $num, title: $title, url: $url, priority: $priority, comments: $comments, source: "proactive", timestamp: now}')
            
            jq --argjson opp "$OPPORTUNITY" '. += [$opp]' "$CONSENT_FILE" > "$CONSENT_FILE.tmp" && mv "$CONSENT_FILE.tmp" "$CONSENT_FILE"
            DISCOVERED_COUNT=$((DISCOVERED_COUNT + 1))
            
            # If under limit and decent priority, post immediately  
            if [ "$POSTED_COUNT" -lt "$MAX_POSTS_PER_RUN" ] && [ "$PRIORITY" -ge 60 ]; then
                log ">>> Posting on discovered issue $ISSUE_ID"
                
                POST_RESULT=$(gh issue comment "$NUMBER" --repo "$REPO" --body "$COMMENT_TEMPLATES_EN" 2>&1)
                
                if [ $? -eq 0 ]; then
                    log "SUCCESS: Posted on $ISSUE_ID"
                    jq --argjson obj "{\"id\": \"$ISSUE_ID\", \"repo\": \"$REPO\", \"number\": $NUMBER, \"priority\": $PRIORITY, \"timestamp\": $NOW, \"title\": \"$TITLE\", \"source\": \"proactive\"}" '. += [$obj]' "$POSTED_FILE" > "$POSTED_FILE.tmp" && mv "$POSTED_FILE.tmp" "$POSTED_FILE"
                    POSTED_COUNT=$((POSTED_COUNT + 1))
                    sleep 5
                else
                    log "FAILED to post on $ISSUE_ID: ${POST_RESULT:0:100}"
                fi
            fi
        fi
    done <<< "$(echo "$GFI_ISSUES" | jq -c '.[]' 2>/dev/null)"
    
    log "Checked $CHECKED_COUNT issues, discovered $DISCOVERED_COUNT high-priority ones"
else
    log "No good-first-issues found from search"
fi

# Step 3: Follow-ups
log "STEP 3: Checking follow-ups"
jq -c '.[]' "$POSTED_FILE" 2>/dev/null | while read -r entry; do
    [ -z "$entry" ] && continue
    
    ID=$(echo "$entry" | jq -r '.id // empty')
    REPO=$(echo "$entry" | jq -r '.repo // empty')
    NUMBER=$(echo "$entry" | jq -r '.number // empty')
    TIMESTAMP=$(echo "$entry" | jq -r '.timestamp // 0')
    
    [ "$TIMESTAMP" -eq 0 ] && continue
    
    DAYS_SINCE=$(( (NOW - TIMESTAMP) / 86400 ))
    
    if [ "$DAYS_SINCE" -ge "$FOLLOW_UP_DAYS" ]; then
        COMMENTS=$(api_call "gh issue view $NUMBER --repo $REPO --comments --json comments")
        HAS_RESPONSE=$(echo "$COMMENTS" | jq '[.comments[] | select(.author.login != "Kai-Rowan-the-AI")] | length')
        
        if [ "$HAS_RESPONSE" -eq 0 ]; then
            log "FOLLOW-UP NEEDED: $ID (no response in $DAYS_SINCE days)"
            jq --argjson obj "{\"id\": \"$ID\", \"repo\": \"$REPO\", \"number\": $NUMBER, \"days_waiting\": $DAYS_SINCE, \"timestamp\": $NOW}" '. += [$obj]' "$FOLLOW_UP_FILE" > "$FOLLOW_UP_FILE.tmp" && mv "$FOLLOW_UP_FILE.tmp" "$FOLLOW_UP_FILE"
        fi
    fi
done

# Step 4: Build ACTION_REQUIRED list
log "STEP 4: Building action items list"
ACTION_REQUIRED_FILE="$LOG_DIR/action-required-$(date +%Y%m%d).json"
echo "[]" > "$ACTION_REQUIRED_FILE"

# Add consent opportunities that need PR creation
jq -c '.[] | select(.action == "create_pr")' "$CONSENT_FILE" 2>/dev/null | while read -r item; do
    [ -z "$item" ] && continue
    jq --argjson item "$item" '. += [$item]' "$ACTION_REQUIRED_FILE" > "$ACTION_REQUIRED_FILE.tmp" && mv "$ACTION_REQUIRED_FILE.tmp" "$ACTION_REQUIRED_FILE"
done

# Add questions needing answers
jq -c '.[] | select(.has_questions == true)' "$CONSENT_FILE" 2>/dev/null | while read -r item; do
    [ -z "$item" ] && continue
    jq --argjson item "$item" '. += [$item]' "$ACTION_REQUIRED_FILE" > "$ACTION_REQUIRED_FILE.tmp" && mv "$ACTION_REQUIRED_FILE.tmp" "$ACTION_REQUIRED_FILE"
done

ACTION_COUNT=$(jq 'length' "$ACTION_REQUIRED_FILE")

# Step 5: Metrics
log "STEP 5: Updating metrics"
TOTAL_CONSENT=$(jq 'length' "$CONSENT_FILE")
TOTAL_TRACKED=$(jq 'length' "$POSTED_FILE")
TOTAL_FOLLOWUP=$(jq 'length' "$FOLLOW_UP_FILE")
TOTAL_STALE=$(jq 'length' "$STALE_FILE")
TOTAL_CONFLICTS=$(jq 'length' "$MERGE_CONFLICT_FILE")

METRIC=$(jq -n \
    --arg date "$(date +%Y-%m-%d)" \
    --arg time "$(date +%H:%M)" \
    --argjson notif "$NOTIF_COUNT" \
    --argjson posted "$POSTED_COUNT" \
    --argjson consent "$TOTAL_CONSENT" \
    --argjson urgent "$URGENT_COUNT" \
    --argjson questions "$QUESTION_COUNT" \
    --argjson stale "$TOTAL_STALE" \
    --argjson followups "$TOTAL_FOLLOWUP" \
    --argjson conflicts "$TOTAL_CONFLICTS" \
    --argjson actions "$ACTION_COUNT" \
    '{date: $date, time: $time, notifications: $notif, posted: $posted, consent: $consent, urgent: $urgent, questions: $questions, stale: $stale, followups: $followups, conflicts: $conflicts, action_required: $actions}')

jq --argjson m "$METRIC" '. += [$m]' "$METRICS_FILE" > "$METRICS_FILE.tmp" && mv "$METRICS_FILE.tmp" "$METRICS_FILE"

# Summary
log "=== SUMMARY ==="
log "Notifications: $NOTIF_COUNT"
log "Posted: $POSTED_COUNT"
log "Consent opportunities: $TOTAL_CONSENT"
[ $URGENT_COUNT -gt 0 ] && log "*** URGENT ITEMS: $URGENT_COUNT ***"
[ $QUESTION_COUNT -gt 0 ] && log "*** QUESTIONS TO ANSWER: $QUESTION_COUNT ***"
[ $ACTION_COUNT -gt 0 ] && log "*** ACTION REQUIRED: $ACTION_COUNT ***"
log "Stale issues: $TOTAL_STALE"
log "Need follow-up: $TOTAL_FOLLOWUP"
log "Merge conflicts: $TOTAL_CONFLICTS"
log "Total tracked: $TOTAL_TRACKED"

# Print action items prominently
if [ $ACTION_COUNT -gt 0 ]; then
    log ""
    log "=== ACTION REQUIRED ==="
    jq -r '.[] | "\(.repo) #\(.number): \(.title // "No title")"' "$ACTION_REQUIRED_FILE" | while read -r line; do
        log ">>> $line"
    done
fi

log "Check complete"
