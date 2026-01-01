# AWS Secrets Manager Secret
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

# Data source to read secret values
data "aws_secretsmanager_secret_version" "api_keys" {
  secret_id = aws_secretsmanager_secret.api_keys.id
}

# Output for manual secret population
output "secrets_manager_secret_name" {
  description = "Name of the Secrets Manager secret - populate with API keys manually"
  value       = aws_secretsmanager_secret.api_keys.name
}

output "secrets_manager_populate_command" {
  description = "Command to populate the secret with API keys"
  value       = <<-EOT
    aws secretsmanager put-secret-value \
      --secret-id ${aws_secretsmanager_secret.api_keys.name} \
      --secret-string '{
        "PERPLEXITY_API_KEY": "your-perplexity-api-key",
        "LITELLM_MASTER_KEY": "your-litellm-master-key",
        "WEBUI_SECRET_KEY": "your-webui-secret-key"
      }'
  EOT
}
