# External Secrets Operator Configuration
# This replaces the direct kubernetes_secret resource to avoid storing secrets in Terraform state
#
# Prerequisites:
# 1. Install External Secrets Operator: kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml
# 2. Install the operator: helm install external-secrets external-secrets/external-secrets -n external-secrets-system --create-namespace
# 3. Apply this Terraform configuration

# IAM Role for External Secrets Operator to access AWS Secrets Manager
data "aws_iam_policy_document" "external_secrets_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume_role.json

  tags = {
    Name = "${var.cluster_name}-external-secrets-role"
  }
}

# IAM Policy for External Secrets to read from Secrets Manager
data "aws_iam_policy_document" "external_secrets_policy" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [
      data.aws_secretsmanager_secret.api_keys.arn
    ]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets"
  description = "Policy for External Secrets Operator to access Secrets Manager"
  policy      = data.aws_iam_policy_document.external_secrets_policy.json
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  policy_arn = aws_iam_policy.external_secrets.arn
  role       = aws_iam_role.external_secrets.name
}

# NOTE: Kubernetes resources (ServiceAccount, SecretStore, ExternalSecret) are now applied via kubectl
# instead of Terraform to avoid API discovery issues with kubernetes_manifest resources.
# See k8s/external-secrets.yaml and run: make eks-external-secrets-apply
#
# The Kubernetes manifests are applied after Terraform creates the IAM role below.

# Output for verification
output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = aws_iam_role.external_secrets.arn
}
