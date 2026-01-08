#!/bin/sh

# cURL Examples for LiteLLM API Testing
# Simple curl commands to test LiteLLM model access
#
# Usage:
#   export LITELLM_MASTER_KEY=your-key
#   source tests/curl-examples.sh

# Ensure API key is set
if [ -z "$LITELLM_MASTER_KEY" ]; then
  echo "ERROR: LITELLM_MASTER_KEY not set"
  echo "Set it via: export LITELLM_MASTER_KEY=your-key"
  return 1 2>/dev/null || exit 1
fi

# Default to localhost, can be overridden
ENDPOINT="${LITELLM_ENDPOINT:-http://localhost:4000}"

echo "LiteLLM API cURL Examples"
echo "Endpoint: $ENDPOINT"
echo ""

# Example 1: Test Amazon Nova Pro (AWS Bedrock)
echo "=== Example 1: Test Amazon Nova Pro ==="
echo "Command:"
echo "curl $ENDPOINT/v1/chat/completions \\"
echo "  -H 'Authorization: Bearer \$LITELLM_MASTER_KEY' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\":\"nova-pro\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}]}'"
echo ""

curl -s "$ENDPOINT/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"nova-pro","messages":[{"role":"user","content":"Say hello"}]}' | jq .

echo ""
echo ""

# Example 2: Test Meta Llama 3.2 1B
echo "=== Example 2: Test Meta Llama 3.2 1B ==="
echo "Command:"
echo "curl $ENDPOINT/v1/chat/completions \\"
echo "  -H 'Authorization: Bearer \$LITELLM_MASTER_KEY' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\":\"llama3-2-1b\",\"messages\":[{\"role\":\"user\",\"content\":\"What is AI?\"}]}'"
echo ""

curl -s "$ENDPOINT/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3-2-1b","messages":[{"role":"user","content":"What is AI?"}]}' | jq .

echo ""
echo ""

# Example 3: Test Perplexity Sonar Pro
echo "=== Example 3: Test Perplexity Sonar Pro ==="
echo "Command:"
echo "curl $ENDPOINT/v1/chat/completions \\"
echo "  -H 'Authorization: Bearer \$LITELLM_MASTER_KEY' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\":\"perplexity-sonar-pro\",\"messages\":[{\"role\":\"user\",\"content\":\"Current AI trends\"}]}'"
echo ""

curl -s "$ENDPOINT/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"perplexity-sonar-pro","messages":[{"role":"user","content":"Current AI trends"}]}' | jq .

echo ""
echo ""

# Example 4: Test with max_tokens and temperature
echo "=== Example 4: Advanced Options (max_tokens, temperature) ==="
echo "Command:"
echo "curl $ENDPOINT/v1/chat/completions \\"
echo "  -H 'Authorization: Bearer \$LITELLM_MASTER_KEY' \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\":\"nova-lite\",\"messages\":[{\"role\":\"user\",\"content\":\"Tell me a joke\"}],\"max_tokens\":100,\"temperature\":0.7}'"
echo ""

curl -s "$ENDPOINT/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"nova-lite","messages":[{"role":"user","content":"Tell me a joke"}],"max_tokens":100,"temperature":0.7}' | jq .

echo ""
echo ""

# Example 5: Test health endpoint
echo "=== Example 5: Health Check ==="
echo "Command:"
echo "curl $ENDPOINT/health \\"
echo "  -H 'Authorization: Bearer \$LITELLM_MASTER_KEY'"
echo ""

curl -s "$ENDPOINT/health" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq .

echo ""
echo ""

echo "Available Models:"
echo "  AWS Bedrock:"
echo "    - nova-micro     (Amazon Nova Micro - fastest, cheapest)"
echo "    - nova-lite      (Amazon Nova Lite - balanced)"
echo "    - nova-pro       (Amazon Nova Pro - most capable)"
echo "    - llama3-2-1b    (Meta Llama 3.2 1B)"
echo ""
echo "  Perplexity:"
echo "    - perplexity-sonar       (Real-time web search)"
echo "    - perplexity-sonar-pro   (Advanced research)"
echo ""
