# AWS Load Balancer Controller IAM Policy and Role

# Download the IAM policy document
data "http" "aws_load_balancer_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}

# Modify the policy to add missing DescribeListenerAttributes permission
locals {
  base_policy = jsondecode(data.http.aws_load_balancer_controller_policy.response_body)

  # Add DescribeListenerAttributes to the statement that has DescribeListeners
  updated_statements = [
    for statement in local.base_policy.Statement :
    contains(try(statement.Action, []), "elasticloadbalancing:DescribeListeners") ?
    merge(statement, {
      Action = concat(
        statement.Action,
        contains(statement.Action, "elasticloadbalancing:DescribeListenerAttributes") ? [] : ["elasticloadbalancing:DescribeListenerAttributes"]
      )
    }) : statement
  ]

  updated_policy = jsonencode(merge(local.base_policy, {
    Statement = local.updated_statements
  }))
}

# Create IAM policy for AWS Load Balancer Controller
resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${var.cluster_name}-aws-load-balancer-controller"
  description = "IAM policy for AWS Load Balancer Controller with DescribeListenerAttributes"
  policy      = local.updated_policy
}

# IAM role for AWS Load Balancer Controller using IRSA
resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "${var.cluster_name}-aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

# Output the role ARN
output "aws_load_balancer_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}
