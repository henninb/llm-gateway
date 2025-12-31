# General Configuration
variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "llm-gateway-eks"
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster (for IRSA)"
  type        = string
}

# Namespace Configuration
variable "namespace" {
  description = "Kubernetes namespace for LLM Gateway"
  type        = string
  default     = "llm-gateway"
}

# Image Configuration
variable "use_ecr_images" {
  description = "Use ECR images instead of public images"
  type        = bool
  default     = false
}

variable "ecr_image_tag" {
  description = "Docker image tag to use from ECR"
  type        = string
  default     = "latest"
}

# LiteLLM Configuration
variable "litellm_cpu_request" {
  description = "CPU request for LiteLLM container"
  type        = string
  default     = "250m"
}

variable "litellm_cpu_limit" {
  description = "CPU limit for LiteLLM container"
  type        = string
  default     = "500m"
}

variable "litellm_memory_request" {
  description = "Memory request for LiteLLM container"
  type        = string
  default     = "512Mi"
}

variable "litellm_memory_limit" {
  description = "Memory limit for LiteLLM container"
  type        = string
  default     = "1Gi"
}

# OpenWebUI Configuration
variable "openwebui_cpu_request" {
  description = "CPU request for OpenWebUI container"
  type        = string
  default     = "500m"
}

variable "openwebui_cpu_limit" {
  description = "CPU limit for OpenWebUI container"
  type        = string
  default     = "1000m"
}

variable "openwebui_memory_request" {
  description = "Memory request for OpenWebUI container"
  type        = string
  default     = "1Gi"
}

variable "openwebui_memory_limit" {
  description = "Memory limit for OpenWebUI container"
  type        = string
  default     = "2Gi"
}

# TLS/HTTPS Configuration
variable "acm_certificate_arn" {
  description = "ARN of ACM certificate for HTTPS (optional). If not provided, LoadBalancer will use HTTP only."
  type        = string
  default     = ""
}

variable "openwebui_storage_size" {
  description = "Size of EBS volume for OpenWebUI data"
  type        = string
  default     = "10Gi"
}

# API Keys (will be pulled from AWS Secrets Manager)
variable "secrets_manager_secret_name" {
  description = "AWS Secrets Manager secret name containing API keys"
  type        = string
  default     = "llm-gateway/api-keys"
}

# CloudFront Configuration (optional)
variable "cloudfront_enabled" {
  description = "Enable CloudFront distribution for OpenWebUI"
  type        = bool
  default     = false
}

variable "cloudfront_domain_name" {
  description = "Custom domain name for CloudFront (requires ACM certificate)"
  type        = string
  default     = ""
}
