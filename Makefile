# Variables
ENDPOINT ?= http://localhost:4000
AWS_REGION ?= us-east-1
CLUSTER_NAME ?= llm-gateway-eks
DOMAIN ?= openwebui.bhenning.com

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "LLM Gateway - Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-33s\033[0m %s\n", $$1, $$2}'
	@echo ""

validate-setup: ## Validate required tools are installed
	@sh tools/validate-setup.sh

local-deploy: ## Deploy containers locally with docker-compose
	@if [ -f .secrets ]; then \
		set -a && . ./.secrets && set +a && docker-compose up -d; \
	else \
		docker-compose up -d; \
	fi

local-status: ## Show status of Docker containers, networks, and volumes
	@echo "=== Docker Containers ==="
	@docker ps -a
	@echo ""
	@echo "=== Docker Networks ==="
	@docker network ls --filter name=llm-gateway
	@echo ""
	@echo "=== Docker Volumes ==="
	@docker volume ls --filter name=openwebui

local-port-forward: ## Forward proxy port 8000 to localhost (Ctrl+C to stop)
	@echo "Forwarding localhost:4000 -> litellm:4000 (press Ctrl+C to stop)"
	@docker run --rm -it --network llm-gateway-network -p 4000:4000 alpine/socat -d -d TCP-LISTEN:4000,fork,reuseaddr TCP:litellm:4000

local-destroy: ## Destroy local Docker containers, volumes, networks, and images
	@echo "Stopping and removing containers, volumes, and networks..."
	@docker-compose down -v --rmi local
	@echo "Cleaning up any remaining containers..."
	@docker rm -f litellm openwebui 2>/dev/null || true
	@echo "Cleaning up any orphaned networks..."
	@docker network rm llm-gateway-network 2>/dev/null || true
	@echo "Cleaning up volumes..."
	@docker volume rm openwebui-volume 2>/dev/null || true
	@echo "Local environment destroyed successfully!"

test-health: ## Check service health and connectivity
	@sh tests/test-health.sh

test-litellm-models: ## Test all LiteLLM models (optionally set ENDPOINT=http://host:port)
	@if [ -f .secrets ]; then \
		set -a && . ./.secrets && set +a && ./tests/test-litellm-models-api.sh $(ENDPOINT); \
	else \
		./tests/test-litellm-models-api.sh $(ENDPOINT); \
	fi

test-guardrails: ## Test custom guardrails (pre_call and post_call hooks)
	@if [ -f .secrets ]; then \
		set -a && . ./.secrets && set +a && python3 tests/test-guardrails.py; \
	else \
		python3 tests/test-guardrails.py; \
	fi

test-all: ## Run all tests (setup validation, health check, model tests, guardrails)
	@echo "Running complete test suite..."
	@echo ""
	@make validate-setup
	@echo ""
	@make test-health
	@echo ""
	@make test-litellm-models
	@echo ""
	@make test-guardrails

aws-costs: ## Generate AWS cost report for current resources (shell version)
	@AWS_REGION=$(AWS_REGION) sh tools/report-aws-costs.sh

aws-costs-py: ## Generate AWS cost report (Python version with rich formatting)
	@AWS_REGION=$(AWS_REGION) python3 tools/report-aws-costs.py

iam-report: ## Show IAM roles and security architecture for this project
	@CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) sh tools/report-iam-roles.sh

# ECR Infrastructure Targets
ecr-init: ## Initialize Terraform for ECR repositories
	@cd terraform/ecr && terraform init

ecr-plan: ## Plan Terraform changes for ECR
	@cd terraform/ecr && terraform plan

ecr-apply: ## Apply Terraform to create ECR repositories
	@cd terraform/ecr && terraform apply

ecr-destroy: ## Destroy ECR repositories
	@cd terraform/ecr && terraform destroy

# ECR Image Management
ecr-login: ## Login to AWS ECR
	@AWS_ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text) && \
	aws ecr get-login-password --region $(AWS_REGION) | \
	docker login --username AWS --password-stdin $$AWS_ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com

ecr-build-push: ## Build and push Docker images to ECR
	@./tools/build-and-push-ecr.sh latest

ecr-verify: ## Verify ECR images match local builds
	@echo "========================================"
	@echo "  ECR Image Verification"
	@echo "========================================"
	@AWS_ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text) && \
	echo "Local LiteLLM digest:" && \
	LOCAL_LITELLM=$$(docker inspect $$AWS_ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/llm-gateway/litellm:latest --format '{{index .RepoDigests 0}}' | cut -d'@' -f2) && \
	echo "  $$LOCAL_LITELLM" && \
	echo "" && \
	echo "ECR LiteLLM digest:" && \
	ECR_LITELLM=$$(aws ecr describe-images --repository-name llm-gateway/litellm --image-ids imageTag=latest --region $(AWS_REGION) --query 'imageDetails[0].imageDigest' --output text) && \
	echo "  $$ECR_LITELLM" && \
	echo "" && \
	if [ "$$LOCAL_LITELLM" = "$$ECR_LITELLM" ]; then \
		echo "✓ LiteLLM images MATCH"; \
	else \
		echo "✗ LiteLLM images DO NOT MATCH"; \
		exit 1; \
	fi && \
	echo "" && \
	echo "Local OpenWebUI digest:" && \
	LOCAL_OPENWEBUI=$$(docker inspect $$AWS_ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/llm-gateway/openwebui:latest --format '{{index .RepoDigests 0}}' | cut -d'@' -f2) && \
	echo "  $$LOCAL_OPENWEBUI" && \
	echo "" && \
	echo "ECR OpenWebUI digest:" && \
	ECR_OPENWEBUI=$$(aws ecr describe-images --repository-name llm-gateway/openwebui --image-ids imageTag=latest --region $(AWS_REGION) --query 'imageDetails[0].imageDigest' --output text) && \
	echo "  $$ECR_OPENWEBUI" && \
	echo "" && \
	if [ "$$LOCAL_OPENWEBUI" = "$$ECR_OPENWEBUI" ]; then \
		echo "✓ OpenWebUI images MATCH"; \
	else \
		echo "✗ OpenWebUI images DO NOT MATCH"; \
		exit 1; \
	fi && \
	echo "" && \
	echo "========================================" && \
	echo "  ✓ All images verified successfully!" && \
	echo "========================================"

# EKS Cluster Infrastructure Targets
eks-cluster-init: ## Initialize Terraform for EKS cluster creation
	@cd terraform/eks-cluster && terraform init

eks-cluster-plan: ## Plan Terraform changes for EKS cluster
	@cd terraform/eks-cluster && terraform plan

eks-cluster-apply: ## Apply Terraform to create EKS cluster
	@cd terraform/eks-cluster && terraform apply

eks-cluster-destroy: ## Destroy EKS cluster infrastructure
	@cd terraform/eks-cluster && terraform destroy

eks-cluster-kubeconfig: ## Configure kubectl for EKS cluster
	@aws eks update-kubeconfig --region $(AWS_REGION) --name llm-gateway-eks

# EKS Secrets Management
eks-secrets-ensure: ## Ensure AWS Secrets Manager secret exists (idempotent, creates if missing)
	@echo "Checking if Secrets Manager secret exists..."
	@if aws secretsmanager describe-secret --secret-id llm-gateway/api-keys --region $(AWS_REGION) >/dev/null 2>&1; then \
		echo "✓ Secret 'llm-gateway/api-keys' already exists"; \
	else \
		echo "Secret doesn't exist, creating via Terraform..."; \
		cd terraform/eks-cluster && \
		if [ ! -d .terraform ]; then \
			echo "Initializing Terraform for eks-cluster..."; \
			terraform init; \
		fi && \
		terraform apply -target=aws_secretsmanager_secret.api_keys -auto-approve && \
		echo "✓ Secret created successfully"; \
	fi

eks-secrets-populate: eks-secrets-ensure ## Populate AWS Secrets Manager with API keys (auto-sources .secrets if exists)
	@if [ -f .secrets ]; then \
		echo "Loading secrets from .secrets file..."; \
		set -a && . ./.secrets && set +a && \
		if [ -z "$$PERPLEXITY_API_KEY" ] || [ -z "$$LITELLM_MASTER_KEY" ] || [ -z "$$WEBUI_SECRET_KEY" ]; then \
			echo "Error: Required environment variables not set in .secrets file"; \
			echo "Please set: PERPLEXITY_API_KEY, LITELLM_MASTER_KEY, WEBUI_SECRET_KEY"; \
			exit 1; \
		fi; \
		echo "Populating AWS Secrets Manager with API keys..."; \
		if aws secretsmanager put-secret-value \
			--secret-id llm-gateway/api-keys \
			--region $(AWS_REGION) \
			--secret-string "$$(printf '{"PERPLEXITY_API_KEY":"%s","LITELLM_MASTER_KEY":"%s","WEBUI_SECRET_KEY":"%s"}' \
				"$$PERPLEXITY_API_KEY" "$$LITELLM_MASTER_KEY" "$$WEBUI_SECRET_KEY")"; then \
			echo "✓ Secrets populated successfully"; \
		else \
			echo "✗ Failed to populate secrets"; \
			exit 1; \
		fi; \
	else \
		if [ -z "$$PERPLEXITY_API_KEY" ] || [ -z "$$LITELLM_MASTER_KEY" ] || [ -z "$$WEBUI_SECRET_KEY" ]; then \
			echo "Error: .secrets file not found and environment variables not set"; \
			echo "Please either:"; \
			echo "  1. Create a .secrets file with the required variables, or"; \
			echo "  2. Set environment variables: PERPLEXITY_API_KEY, LITELLM_MASTER_KEY, WEBUI_SECRET_KEY"; \
			exit 1; \
		fi; \
		echo "Populating AWS Secrets Manager with API keys..."; \
		if aws secretsmanager put-secret-value \
			--secret-id llm-gateway/api-keys \
			--region $(AWS_REGION) \
			--secret-string "$$(printf '{"PERPLEXITY_API_KEY":"%s","LITELLM_MASTER_KEY":"%s","WEBUI_SECRET_KEY":"%s"}' \
				"$$PERPLEXITY_API_KEY" "$$LITELLM_MASTER_KEY" "$$WEBUI_SECRET_KEY")"; then \
			echo "✓ Secrets populated successfully"; \
		else \
			echo "✗ Failed to populate secrets"; \
			exit 1; \
		fi; \
	fi

# EKS Deployment Targets
eks-init: ## Initialize Terraform for EKS deployment
	@cd terraform/eks && terraform init

eks-plan: ## Plan Terraform changes for EKS
	@cd terraform/eks && terraform plan

eks-apply: eks-secrets-populate ## Apply Terraform to deploy to EKS (auto-populates secrets first)
	@cd terraform/eks && terraform apply

eks-destroy: ## Destroy EKS deployment
	@cd terraform/eks && terraform destroy

eks-port-forward: ## Forward LiteLLM from EKS to localhost:4000 (Ctrl+C to stop)
	@echo "Forwarding localhost:4000 -> llm-gateway/litellm:80 (press Ctrl+C to stop)"
	@kubectl port-forward -n llm-gateway svc/litellm 4000:80

eks-verify-cloudflare-dns: ## Verify/setup CloudFlare DNS (auto-sources .secrets if exists, optionally set DOMAIN=your-domain.com)
	@if [ -f .secrets ]; then \
		set -a && . ./.secrets && set +a && ./tools/setup-cloudflare-dns.sh $(DOMAIN); \
	else \
		./tools/setup-cloudflare-dns.sh $(DOMAIN); \
	fi

eks-allow-ip: ## Add IP/CIDR to ALB security group (Usage: make eks-allow-ip IP=1.2.3.4/32 SG=isp|cloudflare DESC="Office")
	@if [ -z "$(IP)" ]; then \
		echo "Error: IP parameter is required"; \
		echo "Usage: make eks-allow-ip IP=1.2.3.4/32 SG=isp|cloudflare DESC=\"Optional description\""; \
		echo ""; \
		echo "SG parameter options:"; \
		echo "  isp        - ISP-restricted security group (for direct ALB access)"; \
		echo "  cloudflare - CloudFlare security group (for CloudFlare proxy mode)"; \
		exit 1; \
	fi; \
	SG_TYPE="$(SG)"; \
	if [ -z "$$SG_TYPE" ]; then \
		SG_TYPE="isp"; \
		echo "Note: No SG specified, defaulting to ISP security group"; \
	fi; \
	if [ "$$SG_TYPE" = "isp" ]; then \
		SG_ID=$$(cd terraform/eks && terraform output -raw isp_security_group_id 2>/dev/null); \
		SG_NAME="ISP-restricted"; \
	elif [ "$$SG_TYPE" = "cloudflare" ]; then \
		SG_ID=$$(cd terraform/eks && terraform output -raw cloudflare_security_group_id 2>/dev/null); \
		SG_NAME="CloudFlare"; \
	else \
		echo "Error: Invalid SG type '$$SG_TYPE'. Must be 'isp' or 'cloudflare'"; \
		exit 1; \
	fi; \
	if [ -z "$$SG_ID" ]; then \
		echo "Error: Could not find $$SG_NAME security group ID"; \
		echo "Make sure terraform/eks is initialized and applied"; \
		exit 1; \
	fi; \
	IP_CIDR="$(IP)"; \
	if ! echo "$$IP_CIDR" | grep -q "/"; then \
		IP_CIDR="$$IP_CIDR/32"; \
		echo "Note: Added /32 to IP address: $$IP_CIDR"; \
	fi; \
	DESC="$(DESC)"; \
	if [ -z "$$DESC" ]; then \
		DESC="Additional IP access - $$IP_CIDR"; \
	fi; \
	echo "Adding IP $$IP_CIDR to $$SG_NAME security group ($$SG_ID)..."; \
	if aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges="[{CidrIp=$$IP_CIDR,Description=\"$$DESC\"}]" \
		--region $(AWS_REGION) 2>&1; then \
		echo "✓ Successfully added IP $$IP_CIDR to $$SG_NAME ALB security group"; \
		echo ""; \
		echo "Current HTTPS rules for $$SG_NAME:"; \
		aws ec2 describe-security-groups --group-ids $$SG_ID --region $(AWS_REGION) \
			--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].[CidrIp,Description]' \
			--output table; \
	else \
		echo "Note: Rule may already exist or there was an error"; \
	fi

eks-revoke-ip: ## Remove IP/CIDR from ALB security group (Usage: make eks-revoke-ip IP=1.2.3.4/32 SG=isp|cloudflare)
	@if [ -z "$(IP)" ]; then \
		echo "Error: IP parameter is required"; \
		echo "Usage: make eks-revoke-ip IP=1.2.3.4/32 SG=isp|cloudflare"; \
		echo ""; \
		echo "SG parameter options:"; \
		echo "  isp        - ISP-restricted security group (for direct ALB access)"; \
		echo "  cloudflare - CloudFlare security group (for CloudFlare proxy mode)"; \
		exit 1; \
	fi; \
	SG_TYPE="$(SG)"; \
	if [ -z "$$SG_TYPE" ]; then \
		SG_TYPE="isp"; \
		echo "Note: No SG specified, defaulting to ISP security group"; \
	fi; \
	if [ "$$SG_TYPE" = "isp" ]; then \
		SG_ID=$$(cd terraform/eks && terraform output -raw isp_security_group_id 2>/dev/null); \
		SG_NAME="ISP-restricted"; \
	elif [ "$$SG_TYPE" = "cloudflare" ]; then \
		SG_ID=$$(cd terraform/eks && terraform output -raw cloudflare_security_group_id 2>/dev/null); \
		SG_NAME="CloudFlare"; \
	else \
		echo "Error: Invalid SG type '$$SG_TYPE'. Must be 'isp' or 'cloudflare'"; \
		exit 1; \
	fi; \
	if [ -z "$$SG_ID" ]; then \
		echo "Error: Could not find $$SG_NAME security group ID"; \
		echo "Make sure terraform/eks is initialized and applied"; \
		exit 1; \
	fi; \
	IP_CIDR="$(IP)"; \
	if ! echo "$$IP_CIDR" | grep -q "/"; then \
		IP_CIDR="$$IP_CIDR/32"; \
		echo "Note: Added /32 to IP address: $$IP_CIDR"; \
	fi; \
	echo "Removing IP $$IP_CIDR from $$SG_NAME security group ($$SG_ID)..."; \
	if aws ec2 revoke-security-group-ingress \
		--group-id $$SG_ID \
		--ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges="[{CidrIp=$$IP_CIDR}]" \
		--region $(AWS_REGION) 2>&1; then \
		echo "✓ Successfully removed IP $$IP_CIDR from $$SG_NAME ALB security group"; \
		echo ""; \
		echo "Current HTTPS rules for $$SG_NAME:"; \
		aws ec2 describe-security-groups --group-ids $$SG_ID --region $(AWS_REGION) \
			--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].[CidrIp,Description]' \
			--output table; \
	else \
		echo "✗ Failed to remove IP $$IP_CIDR (may not exist)"; \
		exit 1; \
	fi

eks-list-ips: ## List all IPs/CIDRs allowed in both ALB security groups (ISP and CloudFlare)
	@echo "========================================"; \
	echo "  ALB Security Group Access Rules"; \
	echo "========================================"; \
	echo ""; \
	ISP_SG_ID=$$(cd terraform/eks && terraform output -raw isp_security_group_id 2>/dev/null); \
	CF_SG_ID=$$(cd terraform/eks && terraform output -raw cloudflare_security_group_id 2>/dev/null); \
	if [ -z "$$ISP_SG_ID" ] && [ -z "$$CF_SG_ID" ]; then \
		echo "Error: Could not find any security group IDs"; \
		echo "Make sure terraform/eks is initialized and applied"; \
		exit 1; \
	fi; \
	if [ -n "$$ISP_SG_ID" ]; then \
		echo "📋 ISP-Restricted Security Group ($$ISP_SG_ID):"; \
		echo "   Used when CloudFlare proxy is DISABLED (direct ALB access)"; \
		echo ""; \
		ISP_COUNT=$$(aws ec2 describe-security-groups --group-ids $$ISP_SG_ID --region $(AWS_REGION) \
			--query 'length(SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[])' \
			--output text 2>/dev/null || echo "0"); \
		if [ "$$ISP_COUNT" -gt 0 ]; then \
			aws ec2 describe-security-groups --group-ids $$ISP_SG_ID --region $(AWS_REGION) \
				--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].[CidrIp,Description]' \
				--output table; \
		else \
			echo "   (No custom IP rules - only base ISP ranges)"; \
		fi; \
		echo ""; \
	fi; \
	if [ -n "$$CF_SG_ID" ]; then \
		echo "☁️  CloudFlare Security Group ($$CF_SG_ID):"; \
		echo "   Used when CloudFlare proxy is ENABLED (currently active)"; \
		echo ""; \
		CF_COUNT=$$(aws ec2 describe-security-groups --group-ids $$CF_SG_ID --region $(AWS_REGION) \
			--query 'length(SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[])' \
			--output text 2>/dev/null || echo "0"); \
		if [ "$$CF_COUNT" -gt 0 ]; then \
			aws ec2 describe-security-groups --group-ids $$CF_SG_ID --region $(AWS_REGION) \
				--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].[CidrIp,Description]' \
				--output table; \
			echo "   ($$CF_COUNT CloudFlare IP ranges - auto-managed by Terraform)"; \
		else \
			echo "   (No IP rules found)"; \
		fi; \
		echo ""; \
	fi; \
	echo "========================================"; \
	echo "To add/remove IPs:"; \
	echo "  make eks-allow-ip IP=1.2.3.4/32 SG=isp DESC=\"Office\""; \
	echo "  make eks-allow-ip IP=1.2.3.4/32 SG=cloudflare DESC=\"Testing\""; \
	echo "  make eks-revoke-ip IP=1.2.3.4/32 SG=isp"; \
	echo "========================================"
