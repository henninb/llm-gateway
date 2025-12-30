# Variables
ENDPOINT ?= http://localhost:4000
AWS_REGION ?= us-east-1

# local-build:
	# docker build -t llm-gateway:local .

local-deploy:
	@if [ -f .secrets ]; then \
		set -a && . ./.secrets && set +a && docker-compose up -d; \
	else \
		docker-compose up -d; \
	fi

local-status:
	docker ps -a

port-forward: ## Forward LiteLLM port 4000 to localhost (Ctrl+C to stop)
	@echo "Forwarding localhost:4000 -> litellm:4000 (press Ctrl+C to stop)"
	@docker run --rm -it --network llm-gateway-network -p 4000:4000 alpine/socat TCP-LISTEN:4000,fork,reuseaddr TCP:litellm:4000

test-models: ## Test all LiteLLM models (optionally set ENDPOINT=http://host:port)
	@if [ -f .secrets ]; then \
		set -a && . ./.secrets && set +a && ./tests/test-models.sh $(ENDPOINT); \
	else \
		./tests/test-models.sh $(ENDPOINT); \
	fi

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
