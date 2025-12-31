#!/bin/sh

# POSIX-compliant setup validation script
# Checks if required tools are installed for LLM Gateway deployment

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Track if all checks pass
ALL_PASSED=true

echo "System - Setup Verification"
echo "========================================"
echo ""
echo "→ Checking required commands..."

# Function to check if a command exists and get version
check_command() {
  cmd=$1
  version_flag=$2
  display_name=${3:-$cmd}

  if command -v "$cmd" >/dev/null 2>&1; then
    version_output=$($cmd $version_flag 2>&1 | head -n1)
    printf "${GREEN}✓${NC} %s is installed (%s)\n" "$display_name" "$version_output"
    return 0
  else
    printf "${RED}✗${NC} %s is NOT installed\n" "$display_name"
    ALL_PASSED=false
    return 1
  fi
}

# Check required commands
check_command "aws" "--version" "aws"
check_command "terraform" "--version" "terraform"
check_command "docker" "--version" "docker"
check_command "kubectl" "version --client" "kubectl"
check_command "python3" "--version" "python3"

echo ""

# Optional tools
echo "→ Checking optional commands..."
check_command "jq" "--version" "jq" || true

# Special handling for curl - extract just version number
if command -v "curl" >/dev/null 2>&1; then
  version_output=$(curl --version 2>&1 | head -n1 | awk '{print $1, $2}')
  printf "${GREEN}✓${NC} %s is installed (%s)\n" "curl" "$version_output"
else
  printf "${RED}✗${NC} %s is NOT installed\n" "curl"
fi

check_command "make" "--version" "make" || true
check_command "docker-credential-pass" "version" "docker-credential-pass" || true

echo ""

# AWS Connectivity Check
echo "→ Checking AWS connectivity..."

if command -v "aws" >/dev/null 2>&1; then
  # Source .secrets file if it exists to load AWS credentials
  if [ -f ".secrets" ]; then
    . ./.secrets 2>/dev/null || true
  fi

  # Check if AWS credentials are configured
  if aws sts get-caller-identity >/dev/null 2>&1; then
    aws_identity=$(aws sts get-caller-identity --query 'Arn' --output text 2>&1)
    printf "${GREEN}✓${NC} AWS credentials are valid (%s)\n" "$aws_identity"
  else
    printf "${RED}✗${NC} AWS credentials not configured or invalid\n"
    echo "  Run: aws configure"
    echo "  Or set: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION"
    echo "  Or add credentials to .secrets file"
    ALL_PASSED=false
  fi
else
  printf "${RED}✗${NC} AWS CLI not installed (checked above)\n"
fi

echo ""

# Summary
if [ "$ALL_PASSED" = true ]; then
  printf "${GREEN}✓ All required tools are installed!${NC}\n"
  exit 0
else
  printf "${RED}✗ Some required tools are missing. Please install them before proceeding.${NC}\n"
  echo ""
  echo "Installation hints:"
  echo "  aws:       https://aws.amazon.com/cli/"
  echo "  terraform: https://www.terraform.io/downloads"
  echo "  docker:    https://docs.docker.com/get-docker/"
  echo "  kubectl:   https://kubernetes.io/docs/tasks/tools/"
  echo "  python3:   https://www.python.org/downloads/"
  echo ""
  echo "Optional (recommended):"
  echo "  docker-credential-pass: yay -S docker-credential-pass (AUR)"
  exit 1
fi
