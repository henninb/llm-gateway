# CloudFlare IP Ranges Security Group for NLB
# This security group restricts access to only CloudFlare's proxy IPs
# Prevents direct access to the NLB, forcing all traffic through CloudFlare

# Fetch CloudFlare IPv4 ranges
data "http" "cloudflare_ips_v4" {
  url = "https://www.cloudflare.com/ips-v4"
}

# Fetch CloudFlare IPv6 ranges
data "http" "cloudflare_ips_v6" {
  url = "https://www.cloudflare.com/ips-v6"
}

# Parse CloudFlare IPs into lists
locals {
  cloudflare_ipv4_cidrs = split("\n", trimspace(data.http.cloudflare_ips_v4.response_body))
  cloudflare_ipv6_cidrs = split("\n", trimspace(data.http.cloudflare_ips_v6.response_body))
}

# Security group for NLB - only allow CloudFlare IPs
# Note: Uses data.aws_eks_cluster.cluster defined in main.tf
resource "aws_security_group" "cloudflare_only" {
  name_prefix = "${var.cluster_name}-cloudflare-nlb-"
  description = "Allow HTTPS traffic only from CloudFlare proxy IPs"
  vpc_id      = data.aws_eks_cluster.cluster.vpc_config[0].vpc_id

  tags = {
    Name        = "${var.cluster_name}-cloudflare-only"
    Environment = var.environment
    Purpose     = "CloudFlare-NLB-Restriction"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Allow HTTPS from CloudFlare IPv4 ranges
resource "aws_security_group_rule" "cloudflare_ipv4_https" {
  count = length(local.cloudflare_ipv4_cidrs)

  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [local.cloudflare_ipv4_cidrs[count.index]]
  security_group_id = aws_security_group.cloudflare_only.id
  description       = "HTTPS from CloudFlare IPv4 range ${count.index + 1}"
}

# Allow HTTPS from CloudFlare IPv6 ranges
resource "aws_security_group_rule" "cloudflare_ipv6_https" {
  count = length(local.cloudflare_ipv6_cidrs)

  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  ipv6_cidr_blocks  = [local.cloudflare_ipv6_cidrs[count.index]]
  security_group_id = aws_security_group.cloudflare_only.id
  description       = "HTTPS from CloudFlare IPv6 range ${count.index + 1}"
}

# Allow all outbound traffic (required for NLB health checks)
resource "aws_security_group_rule" "cloudflare_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cloudflare_only.id
  description       = "Allow all outbound traffic"
}

# Output the security group ID for reference
output "cloudflare_security_group_id" {
  description = "Security group ID that only allows CloudFlare IPs"
  value       = aws_security_group.cloudflare_only.id
}

output "cloudflare_ipv4_count" {
  description = "Number of CloudFlare IPv4 ranges configured"
  value       = length(local.cloudflare_ipv4_cidrs)
}

output "cloudflare_ipv6_count" {
  description = "Number of CloudFlare IPv6 ranges configured"
  value       = length(local.cloudflare_ipv6_cidrs)
}
