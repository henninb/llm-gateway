# IAM Role for Service Account (IRSA) for LiteLLM
# This allows LiteLLM to access AWS Bedrock

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Local variables to derive OIDC provider ARN from EKS cluster if not provided
locals {
  # Extract OIDC issuer URL from EKS cluster and convert to ARN
  oidc_provider_url = replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")
  oidc_provider_arn = var.oidc_provider_arn != "" ? var.oidc_provider_arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider_url}"
}

# Data source for OIDC provider (from eks-cluster)
data "aws_iam_openid_connect_provider" "eks" {
  arn = local.oidc_provider_arn
}

# IAM Policy for LiteLLM - Bedrock access
# Scoped to specific models defined in litellm_config.yaml
# Allows both foundation-model and inference-profile ARN formats
data "aws_iam_policy_document" "litellm_bedrock" {
  # Foundation models (all regions)
  # Using wildcard for region because cross-region inference can route to any AWS region
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = [
      # Amazon Nova models (all regions)
      "arn:aws:bedrock:*::foundation-model/amazon.nova-micro-v1:0",
      "arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0",
      "arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0",
      # Meta Llama 3.2 1B model with us. prefix (cross-region inference - all regions)
      "arn:aws:bedrock:*::foundation-model/us.meta.llama3-2-1b-instruct-v1:0",
      # Meta Llama 3.2 1B model without us. prefix (direct region access - all regions)
      "arn:aws:bedrock:*::foundation-model/meta.llama3-2-1b-instruct-v1:0"
    ]
  }

  # Inference profiles (all regions)
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = [
      # Amazon Nova models (inference profiles - all regions)
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/amazon.nova-micro-v1:0",
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/amazon.nova-lite-v1:0",
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/amazon.nova-pro-v1:0",
      # Meta Llama 3.2 1B model (inference profile with us. prefix - all regions)
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/us.meta.llama3-2-1b-instruct-v1:0",
      # Meta Llama 3.2 1B model (inference profile without us. prefix - all regions)
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/meta.llama3-2-1b-instruct-v1:0"
    ]
  }
}

resource "aws_iam_policy" "litellm_bedrock" {
  name        = "${var.cluster_name}-litellm-bedrock"
  description = "Policy for LiteLLM to invoke AWS Bedrock models"
  policy      = data.aws_iam_policy_document.litellm_bedrock.json
}

# IAM Role for LiteLLM Service Account
data "aws_iam_policy_document" "litellm_assume_role" {
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
      values   = ["system:serviceaccount:${kubernetes_namespace.llm_gateway.metadata[0].name}:litellm"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "litellm" {
  name               = "${var.cluster_name}-litellm-sa"
  assume_role_policy = data.aws_iam_policy_document.litellm_assume_role.json
}

# Attach Bedrock policy
resource "aws_iam_role_policy_attachment" "litellm_bedrock" {
  policy_arn = aws_iam_policy.litellm_bedrock.arn
  role       = aws_iam_role.litellm.name
}

# Kubernetes Service Account for LiteLLM with IAM role annotation
resource "kubernetes_service_account" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.litellm.arn
    }
  }
}
