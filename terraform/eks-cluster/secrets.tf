# AWS Secrets Manager Secret for API Keys
# This secret is created as part of cluster infrastructure
# and will be populated separately via Makefile

variable "secrets_manager_secret_name" {
  description = "AWS Secrets Manager secret name containing API keys"
  type        = string
  default     = "llm-gateway/api-keys"
}

resource "aws_secretsmanager_secret" "api_keys" {
  name                    = var.secrets_manager_secret_name
  description             = "API keys for LLM Gateway (Perplexity, LiteLLM Master Key, WebUI Secret)"
  recovery_window_in_days = 0 # Force immediate deletion to allow recreation

  tags = {
    Name        = "llm-gateway-api-keys"
    Project     = "llm-gateway"
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}
