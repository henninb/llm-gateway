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

test-all: ## Run all tests (setup validation, model tests, guardrails)
	@echo "Running complete test suite..."
	@echo ""
	@make validate-setup
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
	@echo ""
	@echo "=========================================="
	@echo "✓ EKS Cluster created successfully!"
	@echo "=========================================="
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure kubectl:              make eks-cluster-kubeconfig"
	@echo "  2. Install External Secrets:       make eks-install-external-secrets"
	@echo "  3. Install AWS LB Controller:      make eks-install-aws-lb-controller"
	@echo "  4. Populate secrets:               make eks-secrets-populate"
	@echo "  5. Apply External Secrets:         make eks-external-secrets-apply"
	@echo "  6. Plan EKS deployment:            make eks-plan"
	@echo "  7. Apply EKS deployment:           make eks-apply"
	@echo ""

eks-cluster-destroy: ## Destroy EKS cluster infrastructure
	@cd terraform/eks-cluster && terraform destroy

eks-cluster-kubeconfig: ## Configure kubectl for EKS cluster
	@aws eks update-kubeconfig --region $(AWS_REGION) --name llm-gateway-eks
	@echo ""
	@echo "✓ kubectl configured for EKS cluster"
	@echo ""
	@echo "Next step: make eks-install-external-secrets"
	@echo ""

eks-install-aws-lb-controller: ## Install AWS Load Balancer Controller (required for Ingress/ALB)
	@echo "Getting IAM role ARN from eks-cluster Terraform output..."
	@ROLE_ARN=$$(cd terraform/eks-cluster && terraform output -raw aws_load_balancer_controller_role_arn 2>/dev/null); \
	if [ -z "$$ROLE_ARN" ]; then \
		echo "Error: Could not get aws_load_balancer_controller_role_arn from Terraform output"; \
		echo "Please run 'make eks-cluster-apply' first"; \
		exit 1; \
	fi; \
	echo "AWS Load Balancer Controller Role ARN: $$ROLE_ARN"; \
	echo "Adding EKS Helm repository..."; \
	helm repo add eks https://aws.github.io/eks-charts || true; \
	helm repo update; \
	echo "Installing AWS Load Balancer Controller..."; \
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
		-n kube-system \
		--set clusterName=llm-gateway-eks \
		--set serviceAccount.create=true \
		--set serviceAccount.name=aws-load-balancer-controller \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$$ROLE_ARN" \
		--set region=$(AWS_REGION) \
		--set vpcId=$$(aws eks describe-cluster --name llm-gateway-eks --region $(AWS_REGION) --query 'cluster.resourcesVpcConfig.vpcId' --output text) \
		--wait; \
	echo "✓ AWS Load Balancer Controller installed successfully"; \
	echo ""; \
	echo "Verifying installation..."; \
	kubectl get deployment -n kube-system aws-load-balancer-controller; \
	echo ""; \
	echo "Next step: make eks-secrets-populate"

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
			echo ""; \
			echo "Next step: make eks-external-secrets-apply"; \
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
			echo ""; \
			echo "Next step: make eks-external-secrets-apply"; \
		else \
			echo "✗ Failed to populate secrets"; \
			exit 1; \
		fi; \
	fi

# EKS Deployment Targets
eks-install-external-secrets: ## Install External Secrets Operator (required before eks-apply)
	@echo "Cleaning up any existing External Secrets CRDs..."
	@kubectl delete crd -l app.kubernetes.io/name=external-secrets 2>/dev/null || true
	@kubectl get crd | grep external-secrets.io | awk '{print $$1}' | xargs -r kubectl delete crd 2>/dev/null || true
	@echo "Adding External Secrets Helm repository..."
	@helm repo add external-secrets https://charts.external-secrets.io || true
	@helm repo update
	@echo "Installing External Secrets Operator (includes CRDs)..."
	@helm upgrade --install external-secrets external-secrets/external-secrets \
		-n external-secrets-system \
		--create-namespace \
		--set installCRDs=true \
		--wait
	@echo "✓ External Secrets Operator installed successfully"
	@echo ""
	@echo "Verifying installation..."
	@kubectl get pods -n external-secrets-system
	@echo ""
	@echo "Next step: make eks-install-aws-lb-controller"
	@echo ""

eks-init: ## Initialize Terraform for EKS deployment
	@cd terraform/eks && terraform init

eks-plan: ## Plan Terraform changes for EKS
	@cd terraform/eks && terraform plan

eks-apply: eks-secrets-populate ## Apply Terraform to deploy to EKS (auto-populates secrets first)
	@cd terraform/eks && terraform apply
	@echo ""
	@echo "=========================================="
	@echo "✓ EKS deployment applied successfully!"
	@echo "=========================================="
	@echo ""
	@echo "Your LLM Gateway is now running on EKS"
	@echo ""
	@echo "Next steps:"
	@echo "  - Check pod status:           kubectl get pods -n llm-gateway"
	@echo "  - View logs:                  kubectl logs -n llm-gateway -l app=litellm"
	@echo "  - Get ALB URL:                kubectl get ingress -n llm-gateway"
	@echo "  - Configure CloudFlare DNS:   make eks-verify-cloudflare-dns"
	@echo ""

eks-external-secrets-apply: ## Apply External Secrets manifests to Kubernetes (run after eks-secrets-populate, before eks-plan)
	@echo "=========================================="
	@echo "Preparing External Secrets configuration..."
	@echo "=========================================="
	@echo ""
	@echo "Step 1/3: Ensuring namespace and IAM role exist..."
	@cd terraform/eks && \
	if [ ! -d .terraform ]; then \
		echo "Initializing Terraform..."; \
		terraform init; \
	fi; \
	echo "Creating namespace and IAM role (if needed)..."; \
	terraform apply \
		-target=kubernetes_namespace.llm_gateway \
		-target=aws_iam_role.external_secrets \
		-target=aws_iam_policy.external_secrets \
		-target=aws_iam_role_policy_attachment.external_secrets \
		-auto-approve
	@echo ""
	@echo "Step 2/3: Getting IAM role ARN..."
	@ROLE_ARN=$$(cd terraform/eks && terraform output -raw external_secrets_role_arn 2>/dev/null); \
	if [ -z "$$ROLE_ARN" ]; then \
		echo "Error: Could not get external_secrets_role_arn from Terraform output"; \
		exit 1; \
	fi; \
	echo "External Secrets Role ARN: $$ROLE_ARN"; \
	echo ""; \
	echo "Step 3/3: Applying External Secrets manifests..."; \
	cat k8s/external-secrets.yaml | \
		sed "s|\$${EXTERNAL_SECRETS_ROLE_ARN}|$$ROLE_ARN|g" | \
		sed "s|\$${AWS_REGION}|$(AWS_REGION)|g" | \
		kubectl apply -f -; \
	echo "✓ External Secrets manifests applied successfully"; \
	echo ""; \
	echo "Waiting for ExternalSecret to sync (this may take a few seconds)..."; \
	sleep 5; \
	kubectl get externalsecret -n llm-gateway api-keys; \
	echo ""; \
	echo "Checking if api-keys secret was created..."; \
	kubectl get secret -n llm-gateway api-keys 2>/dev/null && \
		echo "✓ Secret 'api-keys' created successfully" || \
		echo "⚠ Secret not yet created - check: kubectl get externalsecret -n llm-gateway api-keys"; \
	echo ""; \
	echo "==========================================";\
	echo "✓ External Secrets configured!";\
	echo "==========================================";\
	echo "";\
	echo "The api-keys secret is now synced from AWS Secrets Manager";\
	echo "";\
	echo "Next step: make eks-plan";\
	echo ""

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

eks-allow-ip: ## Add IP/CIDR to unified ALB security group (Usage: make eks-allow-ip IP=1.2.3.4/32 DESC="Office")
	@if [ -z "$(IP)" ]; then \
		echo "Error: IP parameter is required"; \
		echo "Usage: make eks-allow-ip IP=1.2.3.4/32 DESC=\"Optional description\""; \
		echo ""; \
		echo "Note: SG parameter is deprecated (now using unified security group)"; \
		exit 1; \
	fi; \
	if [ -n "$(SG)" ]; then \
		echo "⚠️  Warning: SG parameter is deprecated and will be ignored"; \
		echo "   Using unified ALB security group for all access"; \
	fi; \
	SG_ID=$$(cd terraform/eks && terraform output -raw alb_security_group_id 2>/dev/null); \
	if [ -z "$$SG_ID" ]; then \
		echo "Error: Could not find unified ALB security group ID"; \
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
	echo "Adding IP $$IP_CIDR to unified ALB security group ($$SG_ID)..."; \
	if aws ec2 authorize-security-group-ingress \
		--group-id $$SG_ID \
		--ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges="[{CidrIp=$$IP_CIDR,Description=\"$$DESC\"}]" \
		--region $(AWS_REGION) 2>&1; then \
		echo "✓ Successfully added IP $$IP_CIDR to unified ALB security group"; \
		echo ""; \
		echo "Current HTTPS rules:"; \
		aws ec2 describe-security-groups --group-ids $$SG_ID --region $(AWS_REGION) \
			--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].[CidrIp,Description]' \
			--output table; \
	else \
		echo "Note: Rule may already exist or there was an error"; \
	fi

eks-revoke-ip: ## Remove IP/CIDR from unified ALB security group (Usage: make eks-revoke-ip IP=1.2.3.4/32)
	@if [ -z "$(IP)" ]; then \
		echo "Error: IP parameter is required"; \
		echo "Usage: make eks-revoke-ip IP=1.2.3.4/32"; \
		echo ""; \
		echo "Note: SG parameter is deprecated (now using unified security group)"; \
		exit 1; \
	fi; \
	if [ -n "$(SG)" ]; then \
		echo "⚠️  Warning: SG parameter is deprecated and will be ignored"; \
		echo "   Using unified ALB security group for all access"; \
	fi; \
	SG_ID=$$(cd terraform/eks && terraform output -raw alb_security_group_id 2>/dev/null); \
	if [ -z "$$SG_ID" ]; then \
		echo "Error: Could not find unified ALB security group ID"; \
		echo "Make sure terraform/eks is initialized and applied"; \
		exit 1; \
	fi; \
	IP_CIDR="$(IP)"; \
	if ! echo "$$IP_CIDR" | grep -q "/"; then \
		IP_CIDR="$$IP_CIDR/32"; \
		echo "Note: Added /32 to IP address: $$IP_CIDR"; \
	fi; \
	echo "Removing IP $$IP_CIDR from unified ALB security group ($$SG_ID)..."; \
	if aws ec2 revoke-security-group-ingress \
		--group-id $$SG_ID \
		--ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges="[{CidrIp=$$IP_CIDR}]" \
		--region $(AWS_REGION) 2>&1; then \
		echo "✓ Successfully removed IP $$IP_CIDR from unified ALB security group"; \
		echo ""; \
		echo "Current HTTPS rules:"; \
		aws ec2 describe-security-groups --group-ids $$SG_ID --region $(AWS_REGION) \
			--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].[CidrIp,Description]' \
			--output table; \
	else \
		echo "✗ Failed to remove IP $$IP_CIDR (may not exist)"; \
		exit 1; \
	fi

eks-list-ips: ## List all IPs/CIDRs allowed in the unified ALB security group
	@echo "========================================"; \
	echo "  ALB Security Group Access Rules"; \
	echo "========================================"; \
	echo ""; \
	ALB_SG_ID=$$(cd terraform/eks && terraform output -raw alb_security_group_id 2>/dev/null); \
	if [ -z "$$ALB_SG_ID" ]; then \
		echo "Error: Could not find unified ALB security group ID"; \
		echo "Make sure terraform/eks is initialized and applied"; \
		exit 1; \
	fi; \
	echo "🔒 Unified ALB Security Group ($$ALB_SG_ID):"; \
	echo "   Allows access from both CloudFlare IPs and authorized ISP ranges"; \
	echo "   Works in both CloudFlare proxy mode and direct access mode"; \
	echo ""; \
	echo "HTTPS Rules (Port 443):"; \
	HTTPS_COUNT=$$(aws ec2 describe-security-groups --group-ids $$ALB_SG_ID --region $(AWS_REGION) \
		--query 'length(SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[])' \
		--output text 2>/dev/null || echo "0"); \
	if [ "$$HTTPS_COUNT" -gt 0 ]; then \
		aws ec2 describe-security-groups --group-ids $$ALB_SG_ID --region $(AWS_REGION) \
			--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[*].[CidrIp,Description]' \
			--output table; \
		CF_COUNT=$$(aws ec2 describe-security-groups --group-ids $$ALB_SG_ID --region $(AWS_REGION) \
			--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[?contains(Description, `CloudFlare`) == `true`] | length(@)' \
			--output text 2>/dev/null || echo "0"); \
		ISP_COUNT=$$(aws ec2 describe-security-groups --group-ids $$ALB_SG_ID --region $(AWS_REGION) \
			--query 'SecurityGroups[0].IpPermissions[?FromPort==`443`].IpRanges[?contains(Description, `T-Mobile`) == `true`] | length(@)' \
			--output text 2>/dev/null || echo "0"); \
		echo ""; \
		echo "   📊 Summary: $$HTTPS_COUNT total HTTPS rules"; \
		echo "   ☁️  CloudFlare IP ranges: $$CF_COUNT (auto-managed by Terraform)"; \
		echo "   📱 ISP ranges (T-Mobile): $$ISP_COUNT"; \
		echo "   ➕ Additional custom IPs: $$((HTTPS_COUNT - CF_COUNT - ISP_COUNT))"; \
	else \
		echo "   (No HTTPS rules found)"; \
	fi; \
	echo ""; \
	echo "HTTP Rules (Port 80 - for HTTP→HTTPS redirect):"; \
	HTTP_COUNT=$$(aws ec2 describe-security-groups --group-ids $$ALB_SG_ID --region $(AWS_REGION) \
		--query 'length(SecurityGroups[0].IpPermissions[?FromPort==`80`].IpRanges[])' \
		--output text 2>/dev/null || echo "0"); \
	if [ "$$HTTP_COUNT" -gt 0 ]; then \
		echo "   ✓ $$HTTP_COUNT HTTP rules configured (redirects to HTTPS)"; \
	else \
		echo "   (No HTTP redirect configured)"; \
	fi; \
	echo ""; \
	echo "========================================"; \
	echo "To add/remove IPs:"; \
	echo "  make eks-allow-ip IP=1.2.3.4/32 DESC=\"Office\""; \
	echo "  make eks-revoke-ip IP=1.2.3.4/32"; \
	echo ""; \
	echo "Note: SG parameter is no longer needed (unified security group)"; \
	echo "========================================"
