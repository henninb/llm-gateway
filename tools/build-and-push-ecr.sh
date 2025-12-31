#!/bin/sh
# Build and push Docker images to AWS ECR
# Usage: ./tools/build-and-push-ecr.sh [tag]

set -e

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${1:-latest}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

printf "%b========================================%b\n" "$CYAN" "$NC"
printf "%b  LLM Gateway - ECR Image Builder%b\n" "$CYAN" "$NC"
printf "%b========================================%b\n" "$CYAN" "$NC"
printf "%bAWS Region: %s%b\n" "$GREEN" "$AWS_REGION" "$NC"
printf "%bAWS Account: %s%b\n" "$GREEN" "$AWS_ACCOUNT_ID" "$NC"
printf "%bImage Tag: %s%b\n" "$GREEN" "$IMAGE_TAG" "$NC"
printf "\n"

# Login to ECR
printf "%bLogging in to AWS ECR...%b\n" "$YELLOW" "$NC"
aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ECR Repository URLs
LITELLM_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/llm-gateway/litellm"
OPENWEBUI_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/llm-gateway/openwebui"

# Build and push LiteLLM image
printf "\n"
printf "%b========================================%b\n" "$YELLOW" "$NC"
printf "%bBuilding LiteLLM image...%b\n" "$YELLOW" "$NC"
printf "%b========================================%b\n" "$YELLOW" "$NC"
docker build -t "${LITELLM_REPO}:${IMAGE_TAG}" -f Dockerfile .

printf "%bPushing LiteLLM image to ECR...%b\n" "$YELLOW" "$NC"
docker push "${LITELLM_REPO}:${IMAGE_TAG}"

# Tag as latest if not already
if [ "${IMAGE_TAG}" != "latest" ]; then
    printf "%bTagging LiteLLM as latest...%b\n" "$YELLOW" "$NC"
    docker tag "${LITELLM_REPO}:${IMAGE_TAG}" "${LITELLM_REPO}:latest"
    docker push "${LITELLM_REPO}:latest"
fi

printf "%b✓ LiteLLM image pushed successfully%b\n" "$GREEN" "$NC"

# Build and push OpenWebUI image
printf "\n"
printf "%b========================================%b\n" "$YELLOW" "$NC"
printf "%bBuilding OpenWebUI image...%b\n" "$YELLOW" "$NC"
printf "%b========================================%b\n" "$YELLOW" "$NC"
docker build -t "${OPENWEBUI_REPO}:${IMAGE_TAG}" -f Dockerfile.openwebui .

printf "%bPushing OpenWebUI image to ECR...%b\n" "$YELLOW" "$NC"
docker push "${OPENWEBUI_REPO}:${IMAGE_TAG}"

# Tag as latest if not already
if [ "${IMAGE_TAG}" != "latest" ]; then
    printf "%bTagging OpenWebUI as latest...%b\n" "$YELLOW" "$NC"
    docker tag "${OPENWEBUI_REPO}:${IMAGE_TAG}" "${OPENWEBUI_REPO}:latest"
    docker push "${OPENWEBUI_REPO}:latest"
fi

printf "%b✓ OpenWebUI image pushed successfully%b\n" "$GREEN" "$NC"

# Summary
printf "\n"
printf "%b========================================%b\n" "$CYAN" "$NC"
printf "%b  Build Complete!%b\n" "$CYAN" "$NC"
printf "%b========================================%b\n" "$CYAN" "$NC"
printf "%bLiteLLM Image:%b\n" "$GREEN" "$NC"
printf "  %s:%s\n" "$LITELLM_REPO" "$IMAGE_TAG"
printf "\n"
printf "%bOpenWebUI Image:%b\n" "$GREEN" "$NC"
printf "  %s:%s\n" "$OPENWEBUI_REPO" "$IMAGE_TAG"
printf "\n"
printf "%bNext steps:%b\n" "$YELLOW" "$NC"
printf "  1. cd terraform/eks\n"
printf "  2. terraform init\n"
printf "  3. terraform plan\n"
printf "  4. terraform apply\n"
printf "\n"
