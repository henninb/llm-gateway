# VPC Endpoints for secure AWS service access (no internet required)
# This restricts LiteLLM to only communicate with specific AWS services via private network

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.eks_vpc.id

  # Allow HTTPS from VPC CIDR (EKS pods)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints-sg"
  }
}

# VPC Endpoint for AWS Bedrock Runtime
# Allows LiteLLM to call Bedrock API without internet access
resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.eks_vpc.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-bedrock-runtime-endpoint"
  }
}

# VPC Endpoint for Secrets Manager (used by External Secrets Operator)
# Allows ESO to sync secrets without internet access
resource "aws_vpc_endpoint" "secrets_manager" {
  vpc_id              = aws_vpc.eks_vpc.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-secretsmanager-endpoint"
  }
}

# Cost impact: ~$7.20/month per endpoint (2 endpoints = ~$14.40/month)
# - Each interface endpoint: $0.01/hour = ~$7.20/month
# - Data processing: $0.01/GB (minimal cost for API calls)
#
# Security benefit:
# - AWS traffic stays private (never touches internet)
# - Reduces attack surface
# - Can now restrict egress to only Perplexity API
