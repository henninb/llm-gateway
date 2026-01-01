# Variables
ENDPOINT ?= http://localhost:4000
AWS_REGION ?= us-east-1
CLUSTER_NAME ?= llm-gateway-eks
DOMAIN ?= openwebui.bhenning.com

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "LLM Gateway - Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'
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

local-port-forward: ## Forward LiteLLM port 4000 to localhost (Ctrl+C to stop)
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

test-models: ## Test all LiteLLM models (optionally set ENDPOINT=http://host:port)
	@if [ -f .secrets ]; then \
		set -a && . ./.secrets && set +a && ./tests/test-models.sh $(ENDPOINT); \
	else \
		./tests/test-models.sh $(ENDPOINT); \
	fi

test-all: ## Run all tests (setup validation, health check, model tests)
	@echo "Running complete test suite..."
	@echo ""
	@make validate-setup
	@echo ""
	@make test-health
	@echo ""
	@make test-models

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
eks-secrets-populate: ## Populate AWS Secrets Manager with API keys (auto-sources .secrets if exists)
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
			echo "The secret 'llm-gateway/api-keys' doesn't exist yet."; \
			echo "Run: cd terraform/eks && terraform init && terraform apply -target=aws_secretsmanager_secret.api_keys"; \
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
			echo "The secret 'llm-gateway/api-keys' doesn't exist yet."; \
			echo "Run: cd terraform/eks && terraform init && terraform apply -target=aws_secretsmanager_secret.api_keys"; \
			exit 1; \
		fi; \
	fi

# EKS Deployment Targets
eks-init: ## Initialize Terraform for EKS deployment
	@cd terraform/eks && terraform init

eks-plan: ## Plan Terraform changes for EKS
	@cd terraform/eks && terraform plan

eks-apply: ## Apply Terraform to deploy to EKS
	@cd terraform/eks && terraform apply

eks-destroy: ## Destroy EKS deployment
	@cd terraform/eks && terraform destroy

eks-port-forward: ## Forward LiteLLM from EKS to localhost:4000 (Ctrl+C to stop)
	@echo "Forwarding localhost:4000 -> llm-gateway/litellm:80 (press Ctrl+C to stop)"
	@kubectl port-forward -n llm-gateway svc/litellm 4000:80

eks-verify-dns: ## Verify CloudFlare DNS is configured (optionally set DOMAIN=your-domain.com)
	@echo "=== Verifying DNS Configuration for $(DOMAIN) ==="
	@echo ""
	@echo "1. Getting LoadBalancer hostname from Kubernetes..."
	@echo "  Command: kubectl get svc openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
	@LB_HOSTNAME=$$(kubectl get svc openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	if [ -z "$$LB_HOSTNAME" ]; then \
		echo "✗ Error: Could not get LoadBalancer hostname from Kubernetes"; \
		echo "  Make sure the openwebui service is deployed: kubectl get svc -n llm-gateway"; \
		exit 1; \
	fi; \
	echo "  LoadBalancer: $$LB_HOSTNAME"; \
	echo ""; \
	echo "2. Resolving $(DOMAIN)..."; \
	echo "  Command: dig +short $(DOMAIN)"; \
	DNS_RESULT=$$(dig +short $(DOMAIN) 2>/dev/null | head -1); \
	if [ -z "$$DNS_RESULT" ]; then \
		echo "✗ Error: $(DOMAIN) does not resolve to any address"; \
		echo ""; \
		echo "Action required:"; \
		echo "  1. Log into CloudFlare dashboard"; \
		echo "  2. Create CNAME record:"; \
		echo "     - Type: CNAME"; \
		echo "     - Name: $$(echo $(DOMAIN) | cut -d. -f1)"; \
		echo "     - Target: $$LB_HOSTNAME"; \
		echo "     - Proxy status: DNS only (gray cloud)"; \
		exit 1; \
	fi; \
	echo "  DNS resolves to: $$DNS_RESULT"; \
	echo ""; \
	echo "3. Checking CNAME record..."; \
	echo "  Command: dig +short CNAME $(DOMAIN)"; \
	CNAME_RESULT=$$(dig +short CNAME $(DOMAIN) 2>/dev/null); \
	if [ -n "$$CNAME_RESULT" ]; then \
		echo "  CNAME: $(DOMAIN) -> $$CNAME_RESULT"; \
		if echo "$$CNAME_RESULT" | grep -q "$$LB_HOSTNAME"; then \
			echo ""; \
			echo "✓ DNS Configuration is correct!"; \
			echo "  $(DOMAIN) points to the correct LoadBalancer"; \
		else \
			echo ""; \
			echo "⚠ Warning: CNAME points to different target"; \
			echo "  Expected: $$LB_HOSTNAME"; \
			echo "  Actual:   $$CNAME_RESULT"; \
			echo ""; \
			echo "Action required:"; \
			echo "  Update the CNAME record in CloudFlare to point to: $$LB_HOSTNAME"; \
		fi; \
	else \
		echo "  No CNAME record found (might be A record or CloudFlare proxied)"; \
		echo ""; \
		echo "⚠ Recommendation: Use CNAME record instead of A record"; \
		echo "  This allows the DNS to automatically follow LoadBalancer changes"; \
		echo ""; \
		echo "  Current IP: $$DNS_RESULT"; \
		echo "  LoadBalancer: $$LB_HOSTNAME"; \
	fi; \
	echo ""; \
	echo "4. Testing HTTPS connectivity..."; \
	echo "  Command: curl -s -o /dev/null -w \"%{http_code}\" --max-time 10 https://$(DOMAIN)"; \
	if curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://$(DOMAIN) 2>/dev/null | grep -q "^[23]"; then \
		echo "✓ HTTPS endpoint is reachable (returns 2xx or 3xx)"; \
	else \
		HTTP_CODE=$$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://$(DOMAIN) 2>/dev/null || echo "000"); \
		if [ "$$HTTP_CODE" = "000" ]; then \
			echo "✗ HTTPS endpoint is not reachable (connection failed)"; \
		else \
			echo "⚠ HTTPS endpoint returned HTTP $$HTTP_CODE"; \
		fi; \
	fi
