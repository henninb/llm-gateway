# ECR Repositories - Reference existing repositories created by terraform/ecr
# These repositories must be created first using: cd terraform/ecr && terraform apply

data "aws_ecr_repository" "litellm" {
  name = "llm-gateway/litellm"
}

data "aws_ecr_repository" "openwebui" {
  name = "llm-gateway/openwebui"
}

# Output ECR repository URLs for reference
output "litellm_ecr_repository_url" {
  description = "ECR repository URL for LiteLLM"
  value       = data.aws_ecr_repository.litellm.repository_url
}

output "openwebui_ecr_repository_url" {
  description = "ECR repository URL for OpenWebUI"
  value       = data.aws_ecr_repository.openwebui.repository_url
}
