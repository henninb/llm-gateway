# Terraform Configuration for ECR Repositories
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWS Provider
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "llm-gateway"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# ECR Repository for LiteLLM
resource "aws_ecr_repository" "litellm" {
  name                 = "llm-gateway/litellm"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "llm-gateway-litellm"
  }
}

# ECR Repository for OpenWebUI
resource "aws_ecr_repository" "openwebui" {
  name                 = "llm-gateway/openwebui"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "llm-gateway-openwebui"
  }
}

# Lifecycle policy to keep only the latest image
resource "aws_ecr_lifecycle_policy" "litellm" {
  repository = aws_ecr_repository.litellm.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only latest image"
      selection = {
        tagStatus     = "any"
        countType     = "imageCountMoreThan"
        countNumber   = 1
      }
      action = {
        type = "expire"
      }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "openwebui" {
  repository = aws_ecr_repository.openwebui.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only latest image"
      selection = {
        tagStatus     = "any"
        countType     = "imageCountMoreThan"
        countNumber   = 1
      }
      action = {
        type = "expire"
      }
    }]
  })
}
