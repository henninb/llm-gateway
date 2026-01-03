#!/bin/sh

# CloudFlare IP Ranges Verification Script
# Verifies that the NLB security group is configured with current CloudFlare IPs
# CloudFlare occasionally updates their IP ranges, so this should be run periodically

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-llm-gateway-eks}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SG_NAME_PREFIX="${CLUSTER_NAME}-cloudflare-nlb-"

printf "%b=== CloudFlare IP Ranges Verification ===%b\n" "$BLUE" "$NC"
printf "\n"

# Fetch current CloudFlare IP ranges
printf "1. Fetching current CloudFlare IP ranges...\n"
CF_IPV4=$(curl -s https://www.cloudflare.com/ips-v4)
CF_IPV6=$(curl -s https://www.cloudflare.com/ips-v6)

CF_IPV4_COUNT=$(echo "$CF_IPV4" | wc -l | tr -d ' ')
CF_IPV6_COUNT=$(echo "$CF_IPV6" | wc -l | tr -d ' ')

printf "  IPv4 ranges: %b%d%b\n" "$GREEN" "$CF_IPV4_COUNT" "$NC"
printf "  IPv6 ranges: %b%d%b\n" "$GREEN" "$CF_IPV6_COUNT" "$NC"
printf "\n"

# Find the security group
printf "2. Finding CloudFlare security group...\n"
SG_ID=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters "Name=group-name,Values=${SG_NAME_PREFIX}*" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null)

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  printf "  %b✗ Security group not found%b\n" "$RED" "$NC"
  printf "\n"
  printf "The CloudFlare security group hasn't been created yet.\n"
  printf "Run %bmake eks-apply%b to create it.\n" "$GREEN" "$NC"
  printf "\n"
  exit 1
fi

printf "  Security Group ID: %b%s%b\n" "$GREEN" "$SG_ID" "$NC"
printf "\n"

# Get security group rules
printf "3. Checking configured IP ranges in security group...\n"
SG_IPV4_COUNT=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --group-ids "$SG_ID" \
  --query 'length(SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[])' \
  --output text 2>/dev/null || echo "0")

SG_IPV6_COUNT=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --group-ids "$SG_ID" \
  --query 'length(SecurityGroups[0].IpPermissions[?FromPort==`443`].Ipv6Ranges[])' \
  --output text 2>/dev/null || echo "0")

printf "  Configured IPv4 ranges: %b%s%b\n" "$YELLOW" "$SG_IPV4_COUNT" "$NC"
printf "  Configured IPv6 ranges: %b%s%b\n" "$YELLOW" "$SG_IPV6_COUNT" "$NC"
printf "\n"

# Compare counts
printf "4. Comparing with CloudFlare published ranges...\n"
IPV4_MATCH="false"
IPV6_MATCH="false"

if [ "$SG_IPV4_COUNT" = "$CF_IPV4_COUNT" ]; then
  printf "  IPv4: %b✓ Match%b (%s ranges)\n" "$GREEN" "$NC" "$CF_IPV4_COUNT"
  IPV4_MATCH="true"
else
  printf "  IPv4: %b✗ Mismatch%b (configured: %s, current: %s)\n" "$RED" "$NC" "$SG_IPV4_COUNT" "$CF_IPV4_COUNT"
fi

if [ "$SG_IPV6_COUNT" = "$CF_IPV6_COUNT" ]; then
  printf "  IPv6: %b✓ Match%b (%s ranges)\n" "$GREEN" "$NC" "$CF_IPV6_COUNT"
  IPV6_MATCH="true"
else
  printf "  IPv6: %b✗ Mismatch%b (configured: %s, current: %s)\n" "$RED" "$NC" "$SG_IPV6_COUNT" "$CF_IPV6_COUNT"
fi
printf "\n"

# Verify specific ranges (sample check)
printf "5. Verifying sample IP ranges...\n"
FIRST_IPV4=$(echo "$CF_IPV4" | head -1)
SG_CIDRS=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --group-ids "$SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`443\`].IpRanges[].CidrIp" \
  --output text 2>/dev/null)

SAMPLE_CHECK_PASSED="false"
if echo "$SG_CIDRS" | grep -q "$FIRST_IPV4"; then
  printf "  Sample check: %b✓ %s is configured%b\n" "$GREEN" "$FIRST_IPV4" "$NC"
  SAMPLE_CHECK_PASSED="true"
else
  printf "  Sample check: %b✗ %s is NOT configured%b\n" "$RED" "$FIRST_IPV4" "$NC"
fi
printf "\n"

# Summary
printf "%b=== Summary ===%b\n" "$BLUE" "$NC"
if [ "$IPV4_MATCH" = "true" ] && [ "$IPV6_MATCH" = "true" ] && [ "$SAMPLE_CHECK_PASSED" = "true" ]; then
  printf "%b✓ Security group is up-to-date with current CloudFlare IP ranges%b\n" "$GREEN" "$NC"
  printf "\n"
  exit 0
else
  printf "%b⚠ Security group needs to be updated%b\n" "$YELLOW" "$NC"
  printf "\n"
  printf "CloudFlare has updated their IP ranges. Update your security group:\n"
  printf "  1. Run: %bcd terraform/eks%b\n" "$GREEN" "$NC"
  printf "  2. Run: %bterraform apply%b\n" "$GREEN" "$NC"
  printf "\n"
  printf "Or use the Makefile command:\n"
  printf "  %bmake eks-apply%b\n" "$GREEN" "$NC"
  printf "\n"
  exit 1
fi
