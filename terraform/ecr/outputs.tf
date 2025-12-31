# Outputs for ECR Repositories

output "litellm_ecr_repository_url" {
  description = "ECR repository URL for LiteLLM"
  value       = aws_ecr_repository.litellm.repository_url
}

output "openwebui_ecr_repository_url" {
  description = "ECR repository URL for OpenWebUI"
  value       = aws_ecr_repository.openwebui.repository_url
}

output "litellm_ecr_repository_name" {
  description = "ECR repository name for LiteLLM"
  value       = aws_ecr_repository.litellm.name
}

output "openwebui_ecr_repository_name" {
  description = "ECR repository name for OpenWebUI"
  value       = aws_ecr_repository.openwebui.name
}
