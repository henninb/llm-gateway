#!/bin/sh
# CloudFlare DNS Setup Script
# Automatically verifies and creates DNS records for the OpenWebUI service

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="${1:-openwebui.bhenning.com}"
ZONE_NAME=$(echo "$DOMAIN" | rev | cut -d. -f1-2 | rev)  # Extract bhenning.com from openwebui.bhenning.com
RECORD_NAME=$(echo "$DOMAIN" | cut -d. -f1)  # Extract openwebui from openwebui.bhenning.com

printf "%b=== CloudFlare DNS Setup for %s ===%b\n" "$BLUE" "$DOMAIN" "$NC"
printf "\n"

# Check for authentication credentials
if [ -z "$CF_API_TOKEN" ] && [ -z "$CF_API_KEY" ]; then
  printf "%b✗ Error: CloudFlare credentials not set%b\n" "$RED" "$NC"
  printf "\n"
  printf "You need either:\n"
  printf "  Option 1 (Recommended): API Token\n"
  printf "    1. Go to: https://dash.cloudflare.com/profile/api-tokens\n"
  printf "    2. Click 'Create Token' using 'Edit zone DNS' template\n"
  printf "    3. Add to .secrets file: CF_API_TOKEN=your-token-here\n"
  printf "\n"
  printf "  Option 2: Global API Key (legacy)\n"
  printf "    1. Already have it (37 hex characters)\n"
  printf "    2. Add to .secrets file:\n"
  printf "       CF_API_KEY=your-global-api-key\n"
  printf "       CF_EMAIL=your-cloudflare-email\n"
  printf "\n"
  exit 1
fi

# Determine authentication method and set up headers
if [ -n "$CF_API_TOKEN" ]; then
  # Clean the token
  CF_API_TOKEN=$(echo "$CF_API_TOKEN" | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d '\n' | tr -d '\r')
  AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
  AUTH_TYPE="API Token"
elif [ -n "$CF_API_KEY" ]; then
  # Clean the key
  CF_API_KEY=$(echo "$CF_API_KEY" | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d '\n' | tr -d '\r')
  CF_EMAIL=$(echo "$CF_EMAIL" | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d '\n' | tr -d '\r')

  if [ -z "$CF_EMAIL" ]; then
    printf "%b✗ Error: CF_EMAIL required when using CF_API_KEY%b\n" "$RED" "$NC"
    printf "Add to .secrets file: CF_EMAIL=your-cloudflare-email\n"
    exit 1
  fi

  AUTH_HEADER_1="X-Auth-Email: $CF_EMAIL"
  AUTH_HEADER_2="X-Auth-Key: $CF_API_KEY"
  AUTH_TYPE="Global API Key"
fi

printf "  Authentication: %b%s%b\n" "$GREEN" "$AUTH_TYPE" "$NC"
printf "\n"

# Step 1: Get LoadBalancer hostname from Kubernetes
printf "1. Getting LoadBalancer hostname from Kubernetes...\n"
LB_HOSTNAME=$(kubectl get svc openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -z "$LB_HOSTNAME" ]; then
  printf "  %b✗ Error: Could not get LoadBalancer hostname%b\n" "$RED" "$NC"
  printf "  Make sure the openwebui service is deployed: kubectl get svc -n llm-gateway\n"
  exit 1
fi

printf "  LoadBalancer: %b%s%b\n" "$GREEN" "$LB_HOSTNAME" "$NC"
printf "\n"

# Step 2: Get CloudFlare Zone ID
printf "2. Looking up CloudFlare zone ID for %s...\n" "$ZONE_NAME"
if [ -n "$CF_API_TOKEN" ]; then
  ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json")
else
  ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
    -H "$AUTH_HEADER_1" \
    -H "$AUTH_HEADER_2" \
    -H "Content-Type: application/json")
fi

ZONE_ID=$(echo "$ZONE_RESPONSE" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)

if [ -z "$ZONE_ID" ]; then
  printf "  %b✗ Error: Could not find zone %s%b\n" "$RED" "$ZONE_NAME" "$NC"
  printf "  Response: %s\n" "$ZONE_RESPONSE"
  exit 1
fi

printf "  Zone ID: %b%s%b\n" "$GREEN" "$ZONE_ID" "$NC"
printf "\n"

# Step 3: Check if DNS record exists
printf "3. Checking if DNS record exists for %s...\n" "$DOMAIN"
if [ -n "$CF_API_TOKEN" ]; then
  RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN&type=CNAME" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json")
else
  RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN&type=CNAME" \
    -H "$AUTH_HEADER_1" \
    -H "$AUTH_HEADER_2" \
    -H "Content-Type: application/json")
fi

RECORD_ID=$(echo "$RECORD_RESPONSE" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
EXISTING_CONTENT=$(echo "$RECORD_RESPONSE" | grep -o '"content":"[^"]*' | head -1 | cut -d'"' -f4)

if [ -n "$RECORD_ID" ]; then
  printf "  %b✓ DNS record exists%b\n" "$GREEN" "$NC"
  printf "  Record ID: %s\n" "$RECORD_ID"
  printf "  Current target: %s\n" "$EXISTING_CONTENT"

  # Check if it points to the correct target
  if [ "$EXISTING_CONTENT" = "$LB_HOSTNAME" ]; then
    printf "  %b✓ Record points to correct LoadBalancer%b\n" "$GREEN" "$NC"
  else
    printf "  %b⚠ Record points to different target%b\n" "$YELLOW" "$NC"
    printf "\n"
    printf "4. Updating DNS record to point to %s...\n" "$LB_HOSTNAME"

    if [ -n "$CF_API_TOKEN" ]; then
      UPDATE_RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$LB_HOSTNAME\"}")
    else
      UPDATE_RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "$AUTH_HEADER_1" \
        -H "$AUTH_HEADER_2" \
        -H "Content-Type: application/json" \
        --data "{\"content\":\"$LB_HOSTNAME\"}")
    fi

    if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
      printf "  %b✓ DNS record updated successfully%b\n" "$GREEN" "$NC"
    else
      printf "  %b✗ Failed to update DNS record%b\n" "$RED" "$NC"
      printf "  Response: %s\n" "$UPDATE_RESPONSE"
      exit 1
    fi
  fi
else
  printf "  %b⚠ DNS record does not exist%b\n" "$YELLOW" "$NC"
  printf "\n"
  printf "4. Creating DNS record...\n"

  if [ -n "$CF_API_TOKEN" ]; then
    CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -H "$AUTH_HEADER" \
      -H "Content-Type: application/json" \
      --data "{
        \"type\":\"CNAME\",
        \"name\":\"$RECORD_NAME\",
        \"content\":\"$LB_HOSTNAME\",
        \"ttl\":1,
        \"proxied\":false
      }")
  else
    CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -H "$AUTH_HEADER_1" \
      -H "$AUTH_HEADER_2" \
      -H "Content-Type: application/json" \
      --data "{
        \"type\":\"CNAME\",
        \"name\":\"$RECORD_NAME\",
        \"content\":\"$LB_HOSTNAME\",
        \"ttl\":1,
        \"proxied\":false
      }")
  fi

  if echo "$CREATE_RESPONSE" | grep -q '"success":true'; then
    printf "  %b✓ DNS record created successfully%b\n" "$GREEN" "$NC"
    NEW_RECORD_ID=$(echo "$CREATE_RESPONSE" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    printf "  Record ID: %s\n" "$NEW_RECORD_ID"
  else
    printf "  %b✗ Failed to create DNS record%b\n" "$RED" "$NC"
    printf "  Response: %s\n" "$CREATE_RESPONSE"
    exit 1
  fi
fi

printf "\n"

# Step 4: Verify DNS resolution (with retry)
printf "5. Verifying DNS resolution...\n"

# Check local DNS
DNS_RESULT=$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || true)

if [ -n "$DNS_RESULT" ]; then
  printf "  Local DNS: %b✓ Resolves to: %s%b\n" "$GREEN" "$DNS_RESULT" "$NC"
else
  printf "  Local DNS: %b⚠ Not yet propagated%b\n" "$YELLOW" "$NC"

  # Check CloudFlare DNS directly
  CF_DNS_RESULT=$(dig @1.1.1.1 +short "$DOMAIN" 2>/dev/null | tail -1 || true)

  if [ -n "$CF_DNS_RESULT" ]; then
    printf "  CloudFlare DNS: %b✓ Resolves to: %s%b\n" "$GREEN" "$CF_DNS_RESULT" "$NC"
    printf "\n"
    printf "  %b→ Your local DNS cache is stale. Clear it with:%b\n" "$YELLOW" "$NC"
    printf "    sudo systemctl restart NetworkManager\n"
    printf "    # or if using systemd-resolved: sudo resolvectl flush-caches\n"
  else
    printf "  CloudFlare DNS: %b⚠ Not yet propagated (wait a few minutes)%b\n" "$YELLOW" "$NC"
  fi
fi

printf "\n"

# Step 5: Check CNAME
printf "6. Checking CNAME record...\n"
CNAME_RESULT=$(dig +short CNAME "$DOMAIN" 2>/dev/null || true)

if [ -n "$CNAME_RESULT" ]; then
  printf "  CNAME: %s -> %s\n" "$DOMAIN" "$CNAME_RESULT"
  if echo "$CNAME_RESULT" | grep -q "$LB_HOSTNAME"; then
    printf "  %b✓ CNAME points to correct LoadBalancer%b\n" "$GREEN" "$NC"
  else
    printf "  %b⚠ CNAME points to different target%b\n" "$YELLOW" "$NC"
    printf "\n"
    printf "  %b→ Clearing local DNS cache...%b\n" "$YELLOW" "$NC"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
      printf "  Running: sudo systemctl restart NetworkManager\n"
      sudo systemctl restart NetworkManager
      printf "  %b✓ NetworkManager restarted%b\n" "$GREEN" "$NC"
    elif command -v resolvectl >/dev/null 2>&1; then
      printf "  Running: sudo resolvectl flush-caches\n"
      sudo resolvectl flush-caches
      printf "  %b✓ DNS cache flushed%b\n" "$GREEN" "$NC"
    else
      printf "  %b⚠ Could not detect DNS cache service%b\n" "$YELLOW" "$NC"
      printf "  Please manually restart your DNS service\n"
    fi
  fi
else
  printf "  %b⚠ No CNAME record found in DNS yet%b\n" "$YELLOW" "$NC"
  printf "  This is normal - DNS propagation can take a few minutes\n"
fi

printf "\n"

# Step 7: Test HTTPS connectivity
printf "7. Testing HTTPS connectivity...\n"

# Get IP to test with
TEST_IP=$(dig @1.1.1.1 +short "$DOMAIN" 2>/dev/null | tail -1 || true)

if [ -n "$TEST_IP" ]; then
  # Test with explicit IP resolution (bypasses DNS cache)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    --resolve "$DOMAIN:443:$TEST_IP" "https://$DOMAIN" 2>/dev/null || echo "000")

  if echo "$HTTP_CODE" | grep -q "^[23]"; then
    printf "  %b✓ HTTPS endpoint is reachable (HTTP %s)%b\n" "$GREEN" "$HTTP_CODE" "$NC"
  elif [ "$HTTP_CODE" = "000" ]; then
    printf "  %b⚠ HTTPS connection failed%b\n" "$YELLOW" "$NC"
    printf "  Check security group allows traffic from your IP\n"
  else
    printf "  %b⚠ HTTPS endpoint returned HTTP %s%b\n" "$YELLOW" "$HTTP_CODE" "$NC"
  fi
else
  printf "  %b⚠ Cannot test - no IP resolution available%b\n" "$YELLOW" "$NC"
fi

printf "\n"

# Summary
printf "%b=== Summary ===%b\n" "$BLUE" "$NC"
printf "Domain: %b%s%b\n" "$GREEN" "$DOMAIN" "$NC"
printf "Points to: %b%s%b\n" "$GREEN" "$LB_HOSTNAME" "$NC"
printf "\n"
printf "You can now access OpenWebUI at:\n"
printf "  %bhttps://%s%b\n" "$GREEN" "$DOMAIN" "$NC"
printf "\n"
