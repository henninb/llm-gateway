# AWS Secrets Manager Secret (created by eks-cluster module)
# This module references the secret created by the cluster infrastructure

# Data source to reference the existing secret
data "aws_secretsmanager_secret" "api_keys" {
  name = var.secrets_manager_secret_name
}

# Data source to read secret values
data "aws_secretsmanager_secret_version" "api_keys" {
  secret_id = data.aws_secretsmanager_secret.api_keys.id
}

# Output for reference
output "secrets_manager_secret_name" {
  description = "Name of the Secrets Manager secret - populate with API keys via Makefile"
  value       = data.aws_secretsmanager_secret.api_keys.name
}

output "secrets_manager_populate_command" {
  description = "Command to populate the secret with API keys"
  value       = <<-EOT
    # Automated via Makefile: make eks-secrets-populate
    aws secretsmanager put-secret-value \
      --secret-id ${data.aws_secretsmanager_secret.api_keys.name} \
      --secret-string '{
        "PERPLEXITY_API_KEY": "your-perplexity-api-key",
        "LITELLM_MASTER_KEY": "your-litellm-master-key",
        "WEBUI_SECRET_KEY": "your-webui-secret-key"
      }'
  EOT
}
