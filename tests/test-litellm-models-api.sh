#!/bin/sh

# Test script for all LiteLLM models
# Tests Perplexity, Amazon Nova, and Meta Llama models
#
# This test validates basic model connectivity (6 models across 3 providers).
# For guardrail testing, see test-guardrails.py.
#
# Usage:
#   ./tests/test-litellm-models-api.sh                           # Use default endpoint (http://localhost:4000)
#   ./tests/test-litellm-models-api.sh http://192.168.1.10:4000  # Use custom endpoint
#   ./tests/test-litellm-models-api.sh http://example.com:4000   # Use remote endpoint
#   make test-litellm-models                                     # Use Makefile target

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default endpoint (can be overridden via command line argument)
ENDPOINT="${1:-http://localhost:4000}"

# Get API key from environment or .secrets file
if [ -z "$LITELLM_MASTER_KEY" ]; then
  if [ -f ".secrets" ]; then
    . ./.secrets
  fi
fi

if [ -z "$LITELLM_MASTER_KEY" ]; then
  echo -e "${RED}ERROR: LITELLM_MASTER_KEY not set${NC}"
  echo "Set it via: export LITELLM_MASTER_KEY=your-key"
  echo "Or create a .secrets file with: LITELLM_MASTER_KEY=your-key"
  exit 1
fi

# Extract host and port from endpoint
ENDPOINT_HOST="$(echo "$ENDPOINT" | sed -E 's|^https?://([^:/]+).*|\1|')"
ENDPOINT_PORT="$(echo "$ENDPOINT" | sed -E 's|^https?://[^:]+:([0-9]+).*|\1|')"

# If port not found in URL, assume default port based on protocol
if [ "$ENDPOINT_PORT" = "$ENDPOINT" ]; then
  if echo "$ENDPOINT" | grep -q "^https://"; then
    ENDPOINT_PORT=443
  else
    ENDPOINT_PORT=4000
  fi
fi

# Validate that port is available and service is responding
echo "Checking if endpoint is available: $ENDPOINT"
MAX_RETRIES=30
RETRY_DELAY=2
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
  # Check if port is open
  if command -v nc >/dev/null 2>&1; then
    # Use netcat if available
    if nc -z -w 2 "$ENDPOINT_HOST" "$ENDPOINT_PORT" 2>/dev/null; then
      echo -e "${GREEN}✓ Port $ENDPOINT_PORT is open${NC}"

      # Try to hit health endpoint
      health_response="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$ENDPOINT/health" 2>/dev/null)"
      if [ "$health_response" = "200" ] || [ "$health_response" = "404" ]; then
        echo -e "${GREEN}✓ Service is responding${NC}"
        break
      else
        echo -e "${YELLOW}Port is open but service not ready yet (attempt $((retry_count + 1))/$MAX_RETRIES)${NC}"
      fi
    else
      echo -e "${YELLOW}Waiting for port $ENDPOINT_PORT to be available (attempt $((retry_count + 1))/$MAX_RETRIES)${NC}"
    fi
  else
    # Fallback: try curl directly
    if curl -s --max-time 2 "$ENDPOINT/health" >/dev/null 2>&1 || curl -s --max-time 2 "$ENDPOINT/v1/models" >/dev/null 2>&1; then
      echo -e "${GREEN}✓ Service is responding${NC}"
      break
    else
      echo -e "${YELLOW}Waiting for service at $ENDPOINT (attempt $((retry_count + 1))/$MAX_RETRIES)${NC}"
    fi
  fi

  retry_count=$((retry_count + 1))
  if [ $retry_count -lt $MAX_RETRIES ]; then
    sleep $RETRY_DELAY
  fi
done

if [ $retry_count -eq $MAX_RETRIES ]; then
  echo -e "${RED}ERROR: Service at $ENDPOINT is not available after $((MAX_RETRIES * RETRY_DELAY)) seconds${NC}"
  echo "Please ensure:"
  echo "  1. The service is running (try: make local-deploy or make eks-port-forward)"
  echo "  2. The endpoint is correct: $ENDPOINT"
  echo "  3. Port $ENDPOINT_PORT is accessible from this machine"
  exit 1
fi

echo ""
echo "Testing all LiteLLM models"
echo "Endpoint: $ENDPOINT"
echo ""

# Track test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
FAILED_MODELS=""

# Function to test a model
test_model() {
  model_name=$1
  test_prompt=$2

  echo -n "Testing $model_name... "

  response="$(curl -s "$ENDPOINT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -d "{\"model\":\"$model_name\",\"messages\":[{\"role\":\"user\",\"content\":\"$test_prompt\"}],\"max_tokens\":50}")"

  # Check if response contains an error
  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    error_msg="$(echo "$response" | jq -r '.error.message // .error')"

    # Check for specific Anthropic use case error
    if echo "$error_msg" | grep -q "use case details have not been submitted"; then
      echo -e "${YELLOW}NEEDS APPROVAL${NC}"
      echo "  → Submit Anthropic use case form: https://console.aws.amazon.com/bedrock/"
      return 1
    else
      echo -e "${RED}FAILED${NC}"
      echo "  Error: $error_msg"
      return 1
    fi
  fi

  # Check if response has content
  if echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    content="$(echo "$response" | jq -r '.choices[0].message.content')"
    echo -e "${GREEN}OK${NC}"
    echo "  Response: ${content:0:60}..."
    return 0
  else
    echo -e "${RED}FAILED${NC}"
    echo "  Unexpected response format"
    return 1
  fi
}

# Wrapper function to track test results
run_test() {
  model_name=$1
  prompt=$2

  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  if test_model "$model_name" "$prompt"; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
  else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    if [ -z "$FAILED_MODELS" ]; then
      FAILED_MODELS="$model_name"
    else
      FAILED_MODELS="$FAILED_MODELS
$model_name"
    fi
  fi
}

# Test Perplexity models (API key required)
echo "=== Perplexity Models (Primary - API Key Required) ==="
run_test "perplexity-sonar" "hi"
sleep 2  # Avoid rate limits
run_test "perplexity-sonar-pro" "Say hello in one sentence"
echo ""

# Test Amazon Nova models (NO payment validation required)
echo "=== Amazon Nova Models (AWS Native - No Payment Required) ==="
run_test "nova-micro" "hi"
sleep 2  # Avoid rate limits
run_test "nova-lite" "hi"
sleep 2
run_test "nova-pro" "hi"
echo ""

# Test Llama models (Meta - may need approval)
echo "=== Llama Models (Meta) ==="
run_test "llama3-2-1b" "hi"
echo ""

echo "=== Test Summary ==="
echo ""
echo "Total tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -gt 0 ]; then
  echo "Failed models:"
  echo "$FAILED_MODELS" | while IFS= read -r model; do
    if [ -n "$model" ]; then
      echo "  - $model"
    fi
  done
  echo ""
fi

echo "Active Models:"
echo "  ✓ Perplexity (perplexity-sonar, perplexity-sonar-pro)"
echo "  ✓ Amazon Nova (nova-micro, nova-lite, nova-pro) - No payment required"
echo "  ✓ Meta Llama (llama3-2-1b) - May need approval"
echo ""

# Exit with failure if any tests failed
if [ $FAILED_TESTS -gt 0 ]; then
  echo -e "${RED}Some tests failed. See details above.${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
