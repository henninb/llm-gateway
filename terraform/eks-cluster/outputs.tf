# Outputs for EKS Cluster

output "cluster_id" {
  description = "EKS cluster ID"
  value       = aws_eks_cluster.main.id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_security_group.eks_cluster.id
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN of the EKS cluster"
  value       = aws_iam_role.eks_cluster.arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version of the cluster"
  value       = aws_eks_cluster.main.version
}

output "vpc_id" {
  description = "VPC ID where EKS cluster is deployed"
  value       = aws_vpc.eks_vpc.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "node_group_id" {
  description = "EKS node group ID"
  value       = aws_eks_node_group.main.id
}

output "node_group_status" {
  description = "Status of the EKS node group"
  value       = aws_eks_node_group.main.status
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for EKS (used for IRSA)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "ebs_csi_driver_role_arn" {
  description = "IAM role ARN for EBS CSI driver"
  value       = aws_iam_role.ebs_csi_driver.arn
}

output "secrets_manager_secret_name" {
  description = "Name of the Secrets Manager secret for API keys"
  value       = aws_secretsmanager_secret.api_keys.name
}

output "secrets_manager_secret_arn" {
  description = "ARN of the Secrets Manager secret for API keys"
  value       = aws_secretsmanager_secret.api_keys.arn
}

# VPC Endpoints outputs
output "vpc_endpoint_bedrock_runtime_id" {
  description = "VPC endpoint ID for AWS Bedrock Runtime"
  value       = aws_vpc_endpoint.bedrock_runtime.id
}

output "vpc_endpoint_bedrock_runtime_dns" {
  description = "DNS entries for Bedrock Runtime VPC endpoint"
  value       = aws_vpc_endpoint.bedrock_runtime.dns_entry
}

output "vpc_endpoint_secrets_manager_id" {
  description = "VPC endpoint ID for AWS Secrets Manager"
  value       = aws_vpc_endpoint.secrets_manager.id
}

output "vpc_endpoint_secrets_manager_dns" {
  description = "DNS entries for Secrets Manager VPC endpoint"
  value       = aws_vpc_endpoint.secrets_manager.dns_entry
}

output "vpc_endpoints_summary" {
  description = "Summary of VPC endpoints for private AWS service access"
  value = {
    bedrock_runtime = {
      id           = aws_vpc_endpoint.bedrock_runtime.id
      service_name = aws_vpc_endpoint.bedrock_runtime.service_name
      state        = aws_vpc_endpoint.bedrock_runtime.state
    }
    secrets_manager = {
      id           = aws_vpc_endpoint.secrets_manager.id
      service_name = aws_vpc_endpoint.secrets_manager.service_name
      state        = aws_vpc_endpoint.secrets_manager.state
    }
  }
}
