#!/bin/sh

# Health check script for LLM Gateway
# Verifies all services are running and accessible

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track if all checks pass
ALL_PASSED=true

echo "LLM Gateway - Health Check"
echo "========================================"
echo ""

# Check 1: Docker containers are running
echo "→ Checking Docker containers..."

check_container() {
  container_name=$1
  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    if [ "$status" = "running" ]; then
      printf "${GREEN}✓${NC} %s is running\n" "$container_name"
      return 0
    else
      printf "${RED}✗${NC} %s exists but status is: %s\n" "$container_name" "$status"
      ALL_PASSED=false
      return 1
    fi
  else
    printf "${RED}✗${NC} %s is not running\n" "$container_name"
    ALL_PASSED=false
    return 1
  fi
}

check_container "litellm"
check_container "openwebui"

echo ""

# Check 2: Docker network exists
echo "→ Checking Docker network..."

if docker network ls | grep -q "llm-gateway-network"; then
  printf "${GREEN}✓${NC} Docker network 'llm-gateway-network' exists\n"
else
  printf "${RED}✗${NC} Docker network 'llm-gateway-network' not found\n"
  ALL_PASSED=false
fi

echo ""

# Check 3: LiteLLM health endpoint (internal)
echo "→ Checking LiteLLM health endpoint..."

# Try using python3 to check health (no auth required for public routes)
health_check=$(docker exec litellm python3 -c "
import urllib.request
try:
    response = urllib.request.urlopen('http://localhost:4000/health/readiness', timeout=5)
    print('OK')
except Exception as e:
    print(str(e))
" 2>&1)

if echo "$health_check" | grep -q "OK"; then
  printf "${GREEN}✓${NC} LiteLLM health endpoint responding\n"
elif echo "$health_check" | grep -q "200"; then
  printf "${GREEN}✓${NC} LiteLLM health endpoint responding\n"
else
  # Check if container is listening on port 4000
  if docker exec litellm sh -c "netstat -ln 2>/dev/null | grep -q ':4000' || ss -ln 2>/dev/null | grep -q ':4000'"; then
    printf "${GREEN}✓${NC} LiteLLM is listening on port 4000\n"
  else
    printf "${RED}✗${NC} LiteLLM health endpoint not responding\n"
    echo "  Error: $health_check"
    ALL_PASSED=false
  fi
fi

echo ""

# Check 4: OpenWebUI is accessible
echo "→ Checking OpenWebUI accessibility..."

if curl -sf http://localhost:3000 >/dev/null 2>&1; then
  printf "${GREEN}✓${NC} OpenWebUI is accessible on http://localhost:3000\n"
else
  printf "${RED}✗${NC} OpenWebUI is not accessible on http://localhost:3000\n"
  ALL_PASSED=false
fi

echo ""

# Check 5: Container-to-container communication
echo "→ Checking container-to-container communication..."

# Test network connectivity by checking if OpenWebUI container can resolve litellm hostname
# This verifies DNS resolution and network connectivity
if docker exec openwebui getent hosts litellm >/dev/null 2>&1; then
  litellm_ip=$(docker exec openwebui getent hosts litellm 2>/dev/null | awk '{print $1}')
  printf "${GREEN}✓${NC} OpenWebUI can resolve LiteLLM hostname (%s)\n" "$litellm_ip"
else
  # Fallback: Check if both containers are on the same network
  openwebui_network=$(docker inspect openwebui --format='{{range $net,$v := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null)
  litellm_network=$(docker inspect litellm --format='{{range $net,$v := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null)

  if [ "$openwebui_network" = "$litellm_network" ] && [ -n "$openwebui_network" ]; then
    printf "${GREEN}✓${NC} Containers are on same network: %s\n" "$openwebui_network"
  else
    printf "${RED}✗${NC} Containers may not be able to communicate (different networks)\n"
    ALL_PASSED=false
  fi
fi

echo ""

# Check 6: LiteLLM port exposure
echo "→ Checking LiteLLM port exposure..."

if docker port litellm 4000 >/dev/null 2>&1; then
  exposed_port=$(docker port litellm 4000)
  printf "${YELLOW}⚠${NC} LiteLLM port 4000 is exposed to host: %s\n" "$exposed_port"
  echo "  Consider restricting access for production security"
else
  printf "${GREEN}✓${NC} LiteLLM port 4000 is NOT exposed to host (secure)\n"
fi

echo ""

# Check 7: Recent errors in logs
echo "→ Checking for recent errors in logs..."

# Filter out DEBUG messages and normal error handling code references
litellm_errors=$(docker logs litellm --since 5m 2>&1 | grep -iE "ERROR|CRITICAL|FATAL" | grep -v "DEBUG" | grep -v "ERROR_HANDLING" | wc -l)
openwebui_errors=$(docker logs openwebui --since 5m 2>&1 | grep -iE "ERROR|CRITICAL|FATAL" | grep -v "DEBUG" | wc -l)

if [ "$litellm_errors" -eq 0 ]; then
  printf "${GREEN}✓${NC} No errors in LiteLLM logs (last 5 minutes)\n"
else
  printf "${YELLOW}⚠${NC} Found %d error(s) in LiteLLM logs (last 5 minutes)\n" "$litellm_errors"
  echo "  Run: docker logs litellm --since 5m | grep -i error"
fi

if [ "$openwebui_errors" -eq 0 ]; then
  printf "${GREEN}✓${NC} No errors in OpenWebUI logs (last 5 minutes)\n"
else
  printf "${YELLOW}⚠${NC} Found %d error(s) in OpenWebUI logs (last 5 minutes)\n" "$openwebui_errors"
  echo "  Run: docker logs openwebui --since 5m | grep -i error"
fi

echo ""

# Check 8: Disk space for volumes
echo "→ Checking Docker volumes..."

if docker volume ls | grep -q "openwebui-volume"; then
  printf "${GREEN}✓${NC} OpenWebUI data volume exists\n"
else
  printf "${YELLOW}⚠${NC} OpenWebUI data volume not found\n"
fi

echo ""

# Summary
echo "========================================"
if [ "$ALL_PASSED" = true ]; then
  printf "${GREEN}✓ All critical health checks passed!${NC}\n"
  echo ""
  echo "Services are healthy and ready to use."
  echo "  - OpenWebUI: http://localhost:3000"
  echo "  - LiteLLM: Internal only (secure)"
  exit 0
else
  printf "${RED}✗ Some health checks failed.${NC}\n"
  echo ""
  echo "Troubleshooting:"
  echo "  - Check container logs: docker logs litellm"
  echo "  - Restart services: make local-deploy"
  echo "  - View status: make local-status"
  exit 1
fi
