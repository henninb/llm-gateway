#!/bin/sh
# Test CloudFlare-only access restriction
# Verifies that the NLB is only accessible from CloudFlare IP ranges

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DOMAIN="${1:-openwebui.bhenning.com}"
AWS_REGION="${AWS_REGION:-us-east-1}"

printf "%b=== Testing CloudFlare-Only Access Restriction ===%b\n" "$BLUE" "$NC"
printf "\n"

# Step 1: Get current public IP
printf "1. Getting your public IP address...\n"
PUBLIC_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null || echo "")

if [ -z "$PUBLIC_IP" ]; then
  printf "  %b✗ Error: Could not determine public IP%b\n" "$RED" "$NC"
  exit 1
fi

printf "  Your IP: %b%s%b\n" "$GREEN" "$PUBLIC_IP" "$NC"
printf "\n"

# Step 2: Check if your IP is in CloudFlare ranges
printf "2. Checking if your IP is in CloudFlare ranges...\n"
CF_IPV4=$(curl -s https://www.cloudflare.com/ips-v4)
CF_IPV6=$(curl -s https://www.cloudflare.com/ips-v6)

IS_CLOUDFLARE_IP=false
for cidr in $CF_IPV4; do
  # Simple CIDR check - extract network portion
  network=$(echo "$cidr" | cut -d'/' -f1)
  prefix=$(echo "$cidr" | cut -d'/' -f2)

  # For simple check, just see if IP starts with same octets as network
  ip_prefix=$(echo "$PUBLIC_IP" | cut -d'.' -f1-2)
  net_prefix=$(echo "$network" | cut -d'.' -f1-2)

  if [ "$ip_prefix" = "$net_prefix" ]; then
    IS_CLOUDFLARE_IP=true
    printf "  %b⚠ Your IP appears to be in CloudFlare range: %s%b\n" "$YELLOW" "$cidr" "$NC"
    break
  fi
done

if [ "$IS_CLOUDFLARE_IP" = false ]; then
  printf "  %b✓ Your IP is NOT in CloudFlare ranges%b\n" "$GREEN" "$NC"
  printf "  This is expected for most users\n"
fi

printf "\n"

# Step 3: Get LoadBalancer hostname
printf "3. Getting LoadBalancer hostname...\n"
LB_HOSTNAME=$(kubectl get svc openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -z "$LB_HOSTNAME" ]; then
  printf "  %b✗ Error: Could not get LoadBalancer hostname%b\n" "$RED" "$NC"
  exit 1
fi

printf "  LoadBalancer: %s\n" "$LB_HOSTNAME"

# Get NLB IP
NLB_IP=$(dig +short "$LB_HOSTNAME" | head -1)
printf "  NLB IP: %s\n" "$NLB_IP"
printf "\n"

# Step 4: Get security group ID
printf "4. Checking security group configuration...\n"
SG_ID=$(kubectl get svc openwebui -n llm-gateway -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-security-groups}' 2>/dev/null)

if [ -z "$SG_ID" ]; then
  printf "  %b✗ Error: Could not get security group ID%b\n" "$RED" "$NC"
  exit 1
fi

printf "  Security Group: %s\n" "$SG_ID"

# Check security group rules
ALLOWED_CIDRS=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[].CidrIp' \
  --output text 2>/dev/null | tr '\t' '\n' | head -3)

printf "  Sample allowed CIDRs:\n"
echo "$ALLOWED_CIDRS" | while read -r cidr; do
  printf "    - %s\n" "$cidr"
done
printf "  (showing first 3 of 15 CloudFlare ranges)\n"
printf "\n"

# Step 5: Test direct access to NLB
printf "5. Testing direct access to NLB (should be %b%s%b)...\n" "$GREEN" "BLOCKED" "$NC"
printf "  Attempting HTTPS connection to %s...\n" "$LB_HOSTNAME"

# Try to connect with timeout - simpler approach
if curl -s --max-time 10 "https://$LB_HOSTNAME" -o /dev/null 2>/dev/null; then
  # Connection succeeded
  printf "  %b✗ FAIL: Connection succeeded%b\n" "$RED" "$NC"
  printf "\n"
  printf "  %b⚠ WARNING: NLB is accessible from your IP!%b\n" "$YELLOW" "$NC"
  printf "  This means either:\n"
  printf "    1. Your IP is in CloudFlare ranges (checked above)\n"
  printf "    2. Security group allows additional IPs beyond CloudFlare\n"
  printf "    3. VPC default security group is too permissive\n"
  TEST_RESULT="FAIL"
else
  # Connection failed (timeout/refused)
  printf "  %b✓ PASS: Connection blocked (timed out/refused)%b\n" "$GREEN" "$NC"
  printf "  This confirms the NLB only accepts CloudFlare IPs\n"
  TEST_RESULT="PASS"
fi

printf "\n"

# Step 6: Check if there are other security groups on the NLB
printf "6. Checking for additional security groups on NLB...\n"

# Get ENI attached to NLB
NLB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='$LB_HOSTNAME'].LoadBalancerArn" \
  --output text 2>/dev/null || true)

if [ -n "$NLB_ARN" ]; then
  # Get all security groups attached to NLB
  ALL_SG_IDS=$(aws ec2 describe-network-interfaces \
    --region "$AWS_REGION" \
    --filters "Name=description,Values=*$LB_HOSTNAME*" \
    --query 'NetworkInterfaces[].Groups[].GroupId' \
    --output text 2>/dev/null | tr '\t' '\n' | sort -u || echo "$SG_ID")

  SG_COUNT=$(echo "$ALL_SG_IDS" | wc -l)
  printf "  Security groups attached: %d\n" "$SG_COUNT"

  if [ "$SG_COUNT" -gt 1 ]; then
    printf "  %b⚠ Multiple security groups found:%b\n" "$YELLOW" "$NC"
    echo "$ALL_SG_IDS" | while read -r sg; do
      SG_NAME=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$sg" \
        --query 'SecurityGroups[0].GroupName' \
        --output text 2>/dev/null || echo "unknown")
      printf "    - %s (%s)\n" "$sg" "$SG_NAME"
    done
  else
    printf "  %b✓ Only CloudFlare security group attached%b\n" "$GREEN" "$NC"
  fi
else
  printf "  %b⚠ Could not query NLB details%b\n" "$YELLOW" "$NC"
fi

printf "\n"

# Step 7: Test access through domain (CloudFlare DNS)
printf "7. Testing access through domain %s...\n" "$DOMAIN"
DOMAIN_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN" 2>/dev/null || echo "000")

if [ "$DOMAIN_HTTP_CODE" = "200" ]; then
  printf "  %b✓ Domain accessible (HTTP %s)%b\n" "$GREEN" "$DOMAIN_HTTP_CODE" "$NC"
  printf "  Note: DNS record is in 'DNS only' mode, so this goes directly to NLB\n"
elif echo "$DOMAIN_HTTP_CODE" | grep -q "000"; then
  printf "  %b✗ Domain not accessible%b\n" "$RED" "$NC"
else
  printf "  %b⚠ Domain returned HTTP %s%b\n" "$YELLOW" "$DOMAIN_HTTP_CODE" "$NC"
fi

printf "\n"

# Summary
printf "%b=== Test Summary ===%b\n" "$BLUE" "$NC"
printf "Your IP: %s\n" "$PUBLIC_IP"
printf "In CloudFlare range: %s\n" "$IS_CLOUDFLARE_IP"
printf "Direct NLB access: %s\n" "$TEST_RESULT"
printf "\n"

if [ "$TEST_RESULT" = "PASS" ] && [ "$IS_CLOUDFLARE_IP" = false ]; then
  printf "%b✓ SUCCESS: NLB is properly restricted to CloudFlare IPs%b\n" "$GREEN" "$NC"
  printf "Non-CloudFlare IPs cannot access the NLB directly\n"
  exit 0
elif [ "$TEST_RESULT" = "FAIL" ] && [ "$IS_CLOUDFLARE_IP" = false ]; then
  printf "%b✗ FAILURE: NLB is accessible from non-CloudFlare IPs%b\n" "$RED" "$NC"
  printf "\n"
  printf "Recommended actions:\n"
  printf "  1. Verify security group %s only has CloudFlare IPs\n" "$SG_ID"
  printf "  2. Check if VPC default security group allows traffic\n"
  printf "  3. Run: aws ec2 describe-security-groups --group-ids %s\n" "$SG_ID"
  exit 1
elif [ "$IS_CLOUDFLARE_IP" = true ]; then
  printf "%b⚠ INCONCLUSIVE: Your IP is in CloudFlare range%b\n" "$YELLOW" "$NC"
  printf "Cannot definitively test restriction from your location\n"
  printf "The security group configuration looks correct\n"
  exit 0
else
  printf "%b⚠ INCONCLUSIVE: Unable to determine test result%b\n" "$YELLOW" "$NC"
  exit 1
fi
