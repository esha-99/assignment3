#!/usr/bin/env bash
set -uo pipefail

# Load config
CONFIG_FILE="./config.cfg"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config.cfg in $(pwd). Create it and re-run." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Basic checks
if [[ -z "$REPO_PATH" || -z "$MONITOR_TARGET" ]]; then
  echo "REPO_PATH and MONITOR_TARGET must be set in config.cfg" >&2
  exit 1
fi

# Ensure logfile exists
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"

log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOGFILE"
}

# Move to repo
if ! cd "$REPO_PATH"; then
  log "ERROR: cannot cd to repo path: $REPO_PATH"
  exit 2
fi

# Validate git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "ERROR: $REPO_PATH is not a git repository."
  exit 3
fi

# Compute deterministic checksum of target (sort filenames to make order stable)
compute_checksum() {
  # If target is a single file
  if [[ -f "$MONITOR_TARGET" ]]; then
    sha256sum "$MONITOR_TARGET" | awk '{print $1}'
    return
  fi

  # If directory or '.', find files, skip .git directory
  find "$MONITOR_TARGET" -type f -not -path '*/.git/*' -not -name 'config.cfg' -print0 2>/dev/null \
    | xargs -0 sha256sum 2>/dev/null \
    | sort -k2 \
    | sha256sum \
    | awk '{print $1}'
}

# initial checksum
OLD_SUM=$(compute_checksum)
log "Monitoring '$MONITOR_TARGET' in repo: $REPO_PATH"
log "Initial checksum: $OLD_SUM"

# Function to send email via SendGrid
send_email() {
  local subject="$EMAIL_SUBJECT"
  local body="$1"
  # build JSON payload
  # Build 'to' array
  IFS=',' read -ra ADDR <<< "$COLLAB_EMAILS"
  to_json=""
  for e in "${ADDR[@]}"; do
    e_trimmed="$(echo "$e" | xargs)"
    to_json+="{\"email\":\"$e_trimmed\"},"
  done
  to_json="${to_json%,}"  # remove trailing comma

  payload=$(cat <<EOF
{
  "personalizations":[{"to":[ $to_json ]}],
  "from":{"email":"$SENDER_EMAIL"},
  "subject":"$subject",
  "content":[{"type":"text/plain","value":"$body"}]
}
EOF
)

  # call SendGrid
  http_code=$(curl -s -o /tmp/sendgrid_resp.txt -w "%{http_code}" \
    --request POST "https://api.sendgrid.com/v3/mail/send" \
    --header "Authorization: Bearer $SENDGRID_API_KEY" \
    --header "Content-Type: application/json" \
    --data "$payload")

  if [[ "$http_code" =~ ^2 ]]; then
    log "SendGrid: email sent successfully (HTTP $http_code)"
    return 0
  else
    log "SendGrid: failed to send email (HTTP $http_code). Response:"
    log "$(cat /tmp/sendgrid_resp.txt)"
    return 1
  fi
}

# main loop
while true; do
  sleep "${POLL_INTERVAL:-5}"
  NEW_SUM=$(compute_checksum)

  if [[ "$NEW_SUM" != "$OLD_SUM" ]]; then
    log "Change detected! old=$OLD_SUM new=$NEW_SUM"

    # Stage changes only in target to avoid unrelated files
    git add --all "$MONITOR_TARGET" || {
      log "git add failed"
      OLD_SUM=$NEW_SUM
      continue
    }

    # Only commit if there are staged changes
    if git diff --cached --quiet; then
      log "No staged changes to commit."
      OLD_SUM=$NEW_SUM
      continue
    fi

    # Build commit message listing changed files
    changed_files=$(git diff --cached --name-only)
    commit_msg="Auto-commit: changes detected in $MONITOR_TARGET on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Files:
$changed_files"
    if git commit -m "$commit_msg"; then
      log "Committed: $changed_files"
    else
      log "git commit failed."
      OLD_SUM=$NEW_SUM
      continue
    fi

    # Push
    if git push "$REMOTE_NAME" "$BRANCH_NAME"; then
      log "git push succeeded to $REMOTE_NAME/$BRANCH_NAME"
    else
      log "ERROR: git push failed. Attempting to show remote status..."
      git remote -v
      OLD_SUM=$NEW_SUM
      continue
    fi

    # Send email
    email_body="Auto-deploy notification:
Repository: $(basename "$REPO_PATH")
Target: $MONITOR_TARGET
Committed files:
$changed_files
Commit message:
$commit_msg
Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    if send_email "$email_body"; then
      log "Notification email sent."
    else
      log "WARNING: Notification email failed to send."
    fi

    OLD_SUM=$NEW_SUM
  fi
done
