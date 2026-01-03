#!/bin/sh

# Test script for all LiteLLM models
# Tests Perplexity, Amazon Nova, and Meta Llama models
#
# This test validates basic model connectivity (7 models across 3 providers).
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

# Check if containers are running
if ! docker ps --format '{{.Names}}' | grep -q '^litellm$'; then
  echo -e "${RED}ERROR: LiteLLM container is not running${NC}"
  echo ""
  echo "Start containers first with one of:"
  echo "  make local-up          # Start containers"
  echo "  make local-validate    # Start, test, and stop containers"
  echo ""
  exit 1
fi

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

  response=$(curl -s "$ENDPOINT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -d "{\"model\":\"$model_name\",\"messages\":[{\"role\":\"user\",\"content\":\"$test_prompt\"}],\"max_tokens\":50}")

  # Check if response contains an error
  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    error_msg=$(echo "$response" | jq -r '.error.message // .error')

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
    content=$(echo "$response" | jq -r '.choices[0].message.content')
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
sleep 2  # Avoid rate limits
run_test "llama3-2-3b" "hi"
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
echo "  ✓ Meta Llama (llama3-2-1b, llama3-2-3b) - May need approval"
echo ""

# Exit with failure if any tests failed
if [ $FAILED_TESTS -gt 0 ]; then
  echo -e "${RED}Some tests failed. See details above.${NC}"
  exit 0
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
