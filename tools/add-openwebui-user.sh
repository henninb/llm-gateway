#!/bin/sh

# POSIX-compliant script to add a new OpenWebUI user
# Usage: ./add-openwebui-user.sh [OPTIONS]
#
# Options:
#   -e, --email EMAIL      User email (required)
#   -n, --name NAME        Display name (required)
#   -p, --password PASS    Password (required, or use --password-stdin)
#   --password-stdin       Read password from stdin
#   -r, --role ROLE        User role: admin, user, pending (default: user)
#   -c, --container NAME   Docker container name (default: openwebui)
#   -w, --wait             Wait for container to be healthy before adding
#   --system-prompt FILE   Set system prompt from file after creating user
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
USER_EMAIL=""
USER_NAME=""
USER_PASSWORD=""
USER_ROLE="user"
PASSWORD_STDIN=false
SYSTEM_PROMPT_FILE=""

# Script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Add a new user to OpenWebUI."
    echo ""
    echo "Options:"
    echo "  -e, --email EMAIL      User email (required)"
    echo "  -n, --name NAME        Display name (required)"
    echo "  -p, --password PASS    Password (required, or use --password-stdin)"
    echo "  --password-stdin       Read password from stdin (for scripting)"
    echo "  -r, --role ROLE        User role: admin, user, pending (default: user)"
    echo "  -c, --container NAME   Docker container name (default: openwebui)"
    echo "  -w, --wait             Wait for container to be healthy"
    echo "  --system-prompt FILE   Set system prompt from file after creating user"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Add a regular user"
    echo "  $0 -e user@example.com -n 'John Doe' -p 'secretpass'"
    echo ""
    echo "  # Add an admin user"
    echo "  $0 -e admin@example.com -n 'Admin User' -p 'adminpass' -r admin"
    echo ""
    echo "  # Add user with password from stdin (for CI/CD)"
    echo "  echo 'secretpass' | $0 -e user@example.com -n 'John Doe' --password-stdin"
    echo ""
    echo "  # Add user and set system prompt"
    echo "  $0 -e user@example.com -n 'John Doe' -p 'pass' --system-prompt config/system-prompt.txt"
    echo ""
    echo "  # Wait for container and add user"
    echo "  $0 -e user@example.com -n 'John Doe' -p 'pass' -w"
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
        -n|--name)
            USER_NAME="$2"
            shift 2
            ;;
        -p|--password)
            USER_PASSWORD="$2"
            shift 2
            ;;
        --password-stdin)
            PASSWORD_STDIN=true
            shift
            ;;
        -r|--role)
            USER_ROLE="$2"
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
        --system-prompt)
            SYSTEM_PROMPT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Read password from stdin if requested
if [ "$PASSWORD_STDIN" = true ]; then
    USER_PASSWORD="$(cat)"
fi

# Validate required arguments
if [ -z "$USER_EMAIL" ]; then
    error "User email is required. Use -e or --email to specify."
fi

if [ -z "$USER_NAME" ]; then
    error "User name is required. Use -n or --name to specify."
fi

if [ -z "$USER_PASSWORD" ]; then
    error "Password is required. Use -p or --password to specify."
fi

# Validate role
case "$USER_ROLE" in
    admin|user|pending)
        ;;
    *)
        error "Invalid role: $USER_ROLE. Must be one of: admin, user, pending"
        ;;
esac

# Validate system prompt file if specified
if [ -n "$SYSTEM_PROMPT_FILE" ] && [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
    error "System prompt file not found: $SYSTEM_PROMPT_FILE"
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

info "Adding user: $USER_EMAIL ($USER_NAME) with role: $USER_ROLE"

# Execute Python script in container to add the user
docker exec "$CONTAINER" python3 -c "
import sqlite3
import json
import sys
import uuid
import time
import bcrypt

db_path = '${DB_PATH}'
email = '''${USER_EMAIL}'''
name = '''${USER_NAME}'''
password = '''${USER_PASSWORD}'''
role = '${USER_ROLE}'

try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Check if user already exists
    cursor.execute('SELECT id FROM user WHERE email = ?', (email,))
    if cursor.fetchone():
        print(f'User already exists: {email}', file=sys.stderr)
        sys.exit(1)

    # Generate user ID and timestamp
    user_id = str(uuid.uuid4())
    timestamp = int(time.time())

    # Hash password with bcrypt
    password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')

    # Insert into user table
    cursor.execute('''
        INSERT INTO user (id, name, email, role, profile_image_url, created_at, updated_at, last_active_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''', (user_id, name, email, role, '', timestamp, timestamp, timestamp))

    # Insert into auth table
    cursor.execute('''
        INSERT INTO auth (id, email, password, active)
        VALUES (?, ?, ?, ?)
    ''', (user_id, email, password_hash, 1))

    conn.commit()

    print(f'Successfully created user: {email}')
    print(f'User ID: {user_id}')
    print(f'Role: {role}')

except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
finally:
    conn.close()
"

result=$?

if [ $result -eq 0 ]; then
    printf "${GREEN}✓${NC} User created successfully\n"

    # Set system prompt if specified
    if [ -n "$SYSTEM_PROMPT_FILE" ]; then
        info "Setting system prompt from: $SYSTEM_PROMPT_FILE"
        "${SCRIPT_DIR}/set-openwebui-system-prompt.sh" -e "$USER_EMAIL" -f "$SYSTEM_PROMPT_FILE" -c "$CONTAINER"
    fi
else
    exit 1
fi
