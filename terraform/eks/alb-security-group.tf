# Unified ALB Security Group
# Allows access from both CloudFlare IPs and authorized ISP ranges
# This provides flexibility to use either CloudFlare proxy mode or direct access

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

# Unified security group for ALB - allows both CloudFlare and ISP ranges
resource "aws_security_group" "alb_unified" {
  name_prefix = "${var.cluster_name}-alb-unified-"
  description = "Allow HTTPS traffic from CloudFlare IPs and authorized ISP ranges"
  vpc_id      = data.aws_eks_cluster.cluster.vpc_config[0].vpc_id

  tags = {
    Name        = "${var.cluster_name}-alb-unified"
    Environment = var.environment
    Purpose     = "ALB-Unified-Access"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# CloudFlare IP Ranges
# ============================================================================

# Allow HTTPS from CloudFlare IPv4 ranges
resource "aws_security_group_rule" "cloudflare_ipv4_https" {
  count = length(local.cloudflare_ipv4_cidrs)

  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [local.cloudflare_ipv4_cidrs[count.index]]
  security_group_id = aws_security_group.alb_unified.id
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
  security_group_id = aws_security_group.alb_unified.id
  description       = "HTTPS from CloudFlare IPv6 range ${count.index + 1}"
}

# Allow HTTP from CloudFlare IPv4 ranges (for HTTP→HTTPS redirect)
resource "aws_security_group_rule" "cloudflare_ipv4_http" {
  count = length(local.cloudflare_ipv4_cidrs)

  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [local.cloudflare_ipv4_cidrs[count.index]]
  security_group_id = aws_security_group.alb_unified.id
  description       = "HTTP from CloudFlare IPv4 range ${count.index + 1} (redirect to HTTPS)"
}

# Allow HTTP from CloudFlare IPv6 ranges (for HTTP→HTTPS redirect)
resource "aws_security_group_rule" "cloudflare_ipv6_http" {
  count = length(local.cloudflare_ipv6_cidrs)

  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  ipv6_cidr_blocks  = [local.cloudflare_ipv6_cidrs[count.index]]
  security_group_id = aws_security_group.alb_unified.id
  description       = "HTTP from CloudFlare IPv6 range ${count.index + 1} (redirect to HTTPS)"
}

# ============================================================================
# ISP Ranges (T-Mobile and additional authorized networks)
# ============================================================================

# Allow HTTPS from T-Mobile USA (AS21928)
# CIDR: 172.58.0.0/15 covers regional T-Mobile block (~131K IPs)
resource "aws_security_group_rule" "isp_tmobile_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["172.58.0.0/15"]
  security_group_id = aws_security_group.alb_unified.id
  description       = "HTTPS from T-Mobile USA regional block"
}

# Allow HTTP from T-Mobile USA (for HTTP→HTTPS redirect)
resource "aws_security_group_rule" "isp_tmobile_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["172.58.0.0/15"]
  security_group_id = aws_security_group.alb_unified.id
  description       = "HTTP from T-Mobile USA regional block (redirect to HTTPS)"
}

# ============================================================================
# Egress and Worker Node Access
# ============================================================================

# Allow all outbound traffic (required for ALB to reach pods)
resource "aws_security_group_rule" "alb_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_unified.id
  description       = "Allow all outbound traffic"
}

# Allow ALB to reach worker nodes on container port
# This allows the ALB security group to connect to pods running on worker nodes
resource "aws_security_group_rule" "worker_node_from_alb" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_unified.id
  security_group_id        = data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  description              = "Allow ALB to reach OpenWebUI pods on port 8080"
}

# ============================================================================
# Outputs
# ============================================================================

output "alb_security_group_id" {
  description = "Unified ALB security group ID (CloudFlare + ISP ranges)"
  value       = aws_security_group.alb_unified.id
}

output "cloudflare_ipv4_count" {
  description = "Number of CloudFlare IPv4 ranges configured"
  value       = length(local.cloudflare_ipv4_cidrs)
}

output "cloudflare_ipv6_count" {
  description = "Number of CloudFlare IPv6 ranges configured"
  value       = length(local.cloudflare_ipv6_cidrs)
}

# Compatibility outputs (for backward compatibility with Makefile)
output "cloudflare_security_group_id" {
  description = "Alias for alb_security_group_id (backward compatibility)"
  value       = aws_security_group.alb_unified.id
}

output "isp_security_group_id" {
  description = "Alias for alb_security_group_id (backward compatibility)"
  value       = aws_security_group.alb_unified.id
}
