#!/bin/sh

# POSIX-compliant script to set OpenWebUI user system prompt
# Usage: ./set-openwebui-system-prompt.sh [OPTIONS]
#
# Options:
#   -e, --email EMAIL      User email (required)
#   -p, --prompt TEXT      System prompt text (mutually exclusive with -f)
#   -f, --file FILE        Read system prompt from file (mutually exclusive with -p)
#   -c, --container NAME   Docker container name (default: openwebui)
#   -w, --wait             Wait for container to be healthy before updating
#   -h, --help             Show this help message

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Defaults
CONTAINER="openwebui"
DB_PATH="/app/backend/data/webui.db"
WAIT_FOR_HEALTHY=false
PROMPT_FILE=""
PROMPT_TEXT=""
USER_EMAIL=""

# Default prompt file location (relative to script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_PROMPT_FILE="${SCRIPT_DIR}/../config/system-prompt.txt"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Set the default system prompt for an OpenWebUI user."
    echo ""
    echo "Options:"
    echo "  -e, --email EMAIL      User email (required)"
    echo "  -p, --prompt TEXT      System prompt text"
    echo "  -f, --file FILE        Read system prompt from file"
    echo "                         (default: config/system-prompt.txt)"
    echo "  -c, --container NAME   Docker container name (default: openwebui)"
    echo "  -w, --wait             Wait for container to be healthy"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Use default prompt file for user"
    echo "  $0 -e user@example.com"
    echo ""
    echo "  # Use custom prompt file"
    echo "  $0 -e user@example.com -f /path/to/prompt.txt"
    echo ""
    echo "  # Use inline prompt text"
    echo "  $0 -e user@example.com -p 'You are a helpful assistant.'"
    echo ""
    echo "  # Wait for container health before updating"
    echo "  $0 -e user@example.com -w"
    exit 0
}

error() {
    printf "${RED}Error:${NC} %s\n" "$1" >&2
    exit 1
}

info() {
    printf "${GREEN}→${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}!${NC} %s\n" "$1"
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -e|--email)
            USER_EMAIL="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_TEXT="$2"
            shift 2
            ;;
        -f|--file)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -c|--container)
            CONTAINER="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT_FOR_HEALTHY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
if [ -z "$USER_EMAIL" ]; then
    error "User email is required. Use -e or --email to specify."
fi

# Determine prompt source
if [ -n "$PROMPT_TEXT" ] && [ -n "$PROMPT_FILE" ]; then
    error "Cannot specify both --prompt and --file"
fi

if [ -z "$PROMPT_TEXT" ] && [ -z "$PROMPT_FILE" ]; then
    # Use default prompt file
    if [ -f "$DEFAULT_PROMPT_FILE" ]; then
        PROMPT_FILE="$DEFAULT_PROMPT_FILE"
        info "Using default prompt file: $PROMPT_FILE"
    else
        error "No prompt specified and default file not found: $DEFAULT_PROMPT_FILE"
    fi
fi

# Read prompt from file if specified
if [ -n "$PROMPT_FILE" ]; then
    if [ ! -f "$PROMPT_FILE" ]; then
        error "Prompt file not found: $PROMPT_FILE"
    fi
    PROMPT_TEXT="$(cat "$PROMPT_FILE")"
fi

# Check if docker is available
if ! command -v docker >/dev/null 2>&1; then
    error "Docker is not installed or not in PATH"
fi

# Check if container exists
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    error "Container '$CONTAINER' not found"
fi

# Wait for container to be healthy if requested
if [ "$WAIT_FOR_HEALTHY" = true ]; then
    info "Waiting for container '$CONTAINER' to be healthy..."
    max_attempts=60
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        health=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
        if [ "$health" = "healthy" ]; then
            info "Container is healthy"
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            error "Timeout waiting for container to become healthy (status: $health)"
        fi
        printf "."
        sleep 5
    done
    echo ""
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    error "Container '$CONTAINER' is not running"
fi

info "Setting system prompt for user: $USER_EMAIL"

# Escape the prompt for Python string
# Replace backslashes, then quotes, then newlines
ESCAPED_PROMPT=$(printf '%s' "$PROMPT_TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')

# Execute Python script in container to update the database
docker exec "$CONTAINER" python3 -c "
import sqlite3
import json
import sys

db_path = '${DB_PATH}'
email = '${USER_EMAIL}'
prompt = \"\"\"${ESCAPED_PROMPT}\"\"\"

try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Check if user exists
    cursor.execute('SELECT id, settings FROM user WHERE email = ?', (email,))
    row = cursor.fetchone()

    if not row:
        print(f'User not found: {email}', file=sys.stderr)
        print('Available users:', file=sys.stderr)
        cursor.execute('SELECT email FROM user')
        for user in cursor.fetchall():
            print(f'  - {user[0]}', file=sys.stderr)
        sys.exit(1)

    user_id, settings_json = row
    settings = json.loads(settings_json) if settings_json else {}

    # Update the system prompt
    if 'ui' not in settings:
        settings['ui'] = {}
    settings['ui']['system'] = prompt

    # Save back to database
    cursor.execute('UPDATE user SET settings = ? WHERE email = ?',
                   (json.dumps(settings), email))
    conn.commit()

    print(f'Successfully updated system prompt for {email}')
    print(f'Prompt length: {len(prompt)} characters')

except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
finally:
    conn.close()
"

if [ $? -eq 0 ]; then
    printf "${GREEN}✓${NC} System prompt updated successfully\n"
else
    exit 1
fi
