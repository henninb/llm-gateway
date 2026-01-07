# ISP Security Group for ALB
# Restricts access to specific ISP CIDR ranges
# Allows access even when IP changes within the ISP's network

# Security group for ALB - only allow specified ISP ranges
resource "aws_security_group" "isp_restricted" {
  name_prefix = "${var.cluster_name}-isp-alb-"
  description = "Allow HTTPS traffic only from authorized ISP ranges"
  vpc_id      = data.aws_eks_cluster.cluster.vpc_config[0].vpc_id

  tags = {
    Name        = "${var.cluster_name}-isp-restricted"
    Environment = var.environment
    Purpose     = "ISP-ALB-Restriction"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Allow HTTPS from T-Mobile USA (AS21928)
# CIDR: 172.58.0.0/15 covers regional T-Mobile block (~131K IPs)
# This should handle IP changes within the same region
resource "aws_security_group_rule" "isp_tmobile_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["172.58.0.0/15"]
  security_group_id = aws_security_group.isp_restricted.id
  description       = "HTTPS from T-Mobile USA regional block"
}

# Optionally add more ISP ranges here (uncomment and modify as needed)
# resource "aws_security_group_rule" "isp_additional_https" {
#   type              = "ingress"
#   from_port         = 443
#   to_port           = 443
#   protocol          = "tcp"
#   cidr_blocks       = ["YOUR.OTHER.CIDR/XX"]
#   security_group_id = aws_security_group.isp_restricted.id
#   description       = "HTTPS from additional ISP/location"
# }

# Allow all outbound traffic (required for ALB to reach pods)
resource "aws_security_group_rule" "isp_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.isp_restricted.id
  description       = "Allow all outbound traffic"
}

# Allow ALB to reach worker nodes on container port
# This allows the ALB security group to connect to pods running on worker nodes
resource "aws_security_group_rule" "worker_node_from_alb" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cloudflare_only.id
  security_group_id        = data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  description              = "Allow ALB (with CloudFlare SG) to reach OpenWebUI pods on port 8080"
}

# Output the security group ID for reference
output "isp_security_group_id" {
  description = "Security group ID that only allows authorized ISP ranges"
  value       = aws_security_group.isp_restricted.id
}
