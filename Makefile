# Variables
ENDPOINT ?= http://localhost:4000
AWS_REGION ?= us-east-1

.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "LLM Gateway - Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
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
	@docker run --rm -it --network llm-gateway-network -p 4000:4000 alpine/socat TCP-LISTEN:4000,fork,reuseaddr TCP:litellm:4000

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
