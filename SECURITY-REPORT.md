# Bug Report: LLM Gateway Project

**Date:** 2026-01-07
**Analysis Scope:** Complete codebase (Infrastructure, Application, Configuration, Security)
**Total Issues:** 24

---

## Table of Contents

- [Critical Severity (4)](#-critical-severity)
- [High Severity (5)](#-high-severity)
- [Medium Severity (9)](#-medium-severity)
- [Low Severity (6)](#-low-severity-improvements)
- [Summary Statistics](#summary-statistics)

---

## 🔴 CRITICAL SEVERITY

### 1. AWS Credentials Exposure in Docker Compose

**Location:** `docker-compose.yml:14-17`

**Issue:**
```yaml
environment:
  - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
  - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
  - AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
```

AWS credentials are passed directly as environment variables, which can be exposed via:
- `docker inspect` command (visible to anyone with Docker access)
- Process listing (`ps aux | grep env`)
- Container logs if accidentally logged
- Docker history

**Risk:** Credential leakage, unauthorized AWS access, potential account compromise

**Recommendation:**
Use AWS credential helper or mount `~/.aws/credentials` as read-only volume instead:
```yaml
volumes:
  - ~/.aws:/home/litellm/.aws:ro
```

---

### 2. Overly Permissive IAM Bedrock Policy

**Location:** `terraform/eks/irsa-litellm.tf:27`

**Issue:**
```hcl
resources = ["*"] # Allow access to all Bedrock models
```

Wildcard resource grants access to ALL Bedrock models across ALL regions, violating least-privilege principle.

**Risk:**
- Unexpected costs if expensive models are accessed
- Access to models you didn't intend to expose
- Harder to audit which models are actually being used

**Recommendation:**
Scope to specific model ARNs:
```hcl
data "aws_iam_policy_document" "litellm_bedrock" {
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = [
      "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:model/amazon.nova-micro-v1:0",
      "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:model/amazon.nova-lite-v1:0",
      "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:model/amazon.nova-pro-v1:0",
      "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:model/us.meta.llama3-2-1b-instruct-v1:0"
    ]
  }
}
```

---

### 3. Secrets Manager Values in Terraform State

**Location:** `terraform/eks/kubernetes.tf:216-220`

**Issue:**
```hcl
data = {
  perplexity_api_key = jsondecode(data.aws_secretsmanager_secret_version.api_keys.secret_string)["PERPLEXITY_API_KEY"]
  litellm_master_key = jsondecode(data.aws_secretsmanager_secret_version.api_keys.secret_string)["LITELLM_MASTER_KEY"]
  webui_secret_key   = jsondecode(data.aws_secretsmanager_secret_version.api_keys.secret_string)["WEBUI_SECRET_KEY"]
}
```

Secrets are stored in plaintext in Terraform state file. If state is committed to git or shared insecurely, secrets are exposed.

**Risk:** Credential leakage if Terraform state is compromised

**Recommendation:**
Use External Secrets Operator to decouple secrets from Terraform:

1. Install External Secrets Operator via Helm
2. Remove `kubernetes_secret.api_keys` resource from Terraform
3. Replace with ExternalSecret resource:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: api-keys
  namespace: llm-gateway
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: api-keys
    creationPolicy: Owner
  data:
    - secretKey: perplexity_api_key
      remoteRef:
        key: llm-gateway-api-keys
        property: PERPLEXITY_API_KEY
    - secretKey: litellm_master_key
      remoteRef:
        key: llm-gateway-api-keys
        property: LITELLM_MASTER_KEY
    - secretKey: webui_secret_key
      remoteRef:
        key: llm-gateway-api-keys
        property: WEBUI_SECRET_KEY
```

---

### 4. Open CORS Configuration

**Location:** `config/litellm_config.yaml:86`

**Issue:**
```yaml
allowed_origins: ["*"]
```

Allows requests from ANY origin, enabling potential CSRF attacks and unauthorized API access from malicious websites.

**Risk:**
- Attackers can make requests to your API from their websites
- LITELLM_MASTER_KEY could be stolen via XSS on any website users visit
- API abuse from unauthorized domains

**Recommendation:**
Restrict to specific domains:
```yaml
allowed_origins: ["https://openwebui.bhenning.com"]
```

Or if using multiple domains:
```yaml
allowed_origins:
  - "https://openwebui.bhenning.com"
  - "http://localhost:3000"  # For local development
```

---

## 🟠 HIGH SEVERITY

### 5. Model Access Control Bypass Enabled

**Location:**
- `terraform/eks/openwebui.tf:135-137`
- `docker-compose.yml:47`

**Issue:**
```yaml
env {
  name  = "BYPASS_MODEL_ACCESS_CONTROL"
  value = "true"
}
```

Completely disables OpenWebUI's model access control system, allowing ALL users to access ALL models.

**Risk:**
- No way to restrict expensive models to specific users
- Can't enforce per-user model permissions
- Harder to track/limit usage per user

**Recommendation:**
Set to `"false"` and configure proper user roles/permissions in OpenWebUI admin panel:
```yaml
env {
  name  = "BYPASS_MODEL_ACCESS_CONTROL"
  value = "false"
}
```

---

### 6. Broad ISP CIDR Block

**Location:** `terraform/eks/alb-security-group.tf:106`

**Issue:**
```hcl
cidr_blocks = ["172.58.0.0/15"]  # ~131K IPs
```

T-Mobile CIDR block covers ~131,000 IP addresses, much broader than needed for a single user.

**Risk:**
- Allows access from ALL T-Mobile users in that region (not just you)
- Larger attack surface for brute force or scanning attacks
- Difficult to revoke access if your IP changes ISPs

**Recommendation:**
Use a more specific CIDR based on your actual IP range, or implement dynamic IP allowlisting:

**Option A:** Use /24 or /28 CIDR for your specific subnet:
```hcl
cidr_blocks = ["172.58.x.0/24"]  # Replace with your actual subnet
```

**Option B:** Use Makefile target for on-demand IP allowlisting (check if this exists):
```bash
make eks-add-my-ip
```

---

### 7. EKS Cluster Has Public API Endpoint

**Location:** `terraform/eks-cluster/main.tf:200-201`

**Issue:**
```hcl
vpc_config {
  subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
  endpoint_private_access = true
  endpoint_public_access  = true  # ⚠️ Attack surface
  security_group_ids      = [aws_security_group.eks_cluster.id]
}
```

Kubernetes API server is accessible from the internet, even though you have private access enabled.

**Risk:**
- Brute force attacks on Kubernetes API
- Exposed to CVEs targeting Kubernetes API server
- Additional attack surface

**Recommendation:**

**Option A:** Disable public access entirely (if you manage cluster from within VPC/VPN):
```hcl
endpoint_private_access = true
endpoint_public_access  = false
```

**Option B:** Restrict public access to known IPs:
```hcl
vpc_config {
  subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
  endpoint_private_access = true
  endpoint_public_access  = true
  public_access_cidrs     = ["YOUR_HOME_IP/32", "YOUR_OFFICE_IP/32"]
  security_group_ids      = [aws_security_group.eks_cluster.id]
}
```

---

### 8. Guardrail Regex Bypass Potential

**Location:** `config/custom_guardrail.py:20-24`

**Issue:**
```python
self.patterns = [
    r'\bduck(y|ies?|s)?\b',
    r'\bbunny|bunnies\b',
    r'\brabbit(s)?\b'
]
```

Simple regex patterns can be bypassed using:
- Unicode variations: "d‌ucky" (zero-width characters)
- Homoglyphs: "duсky" (Cyrillic 'с' instead of 'c')
- Leetspeak: "d_u_c_k" or "d.u.c.k"
- Base64 encoding: "Tell me about ZHVja3k="
- Spacing: "d u c k y"

**Risk:** Content filtering can be easily circumvented

**Recommendation:**

**Option A:** Use NLP-based content moderation (AWS Comprehend, Azure Content Safety):
```python
import boto3

def check_content_with_comprehend(text):
    comprehend = boto3.client('comprehend')
    response = comprehend.detect_pii_entities(
        Text=text,
        LanguageCode='en'
    )
    # Check for custom content policy
```

**Option B:** Add homoglyph normalization before checking:
```python
import unicodedata

def normalize_text(text):
    # Normalize unicode characters
    text = unicodedata.normalize('NFKD', text)
    # Remove zero-width characters
    text = ''.join(c for c in text if unicodedata.category(c) != 'Cf')
    # Convert to lowercase
    return text.lower()
```

**Option C:** Accept this as a demo guardrail limitation and document it

---

### 9. No Secrets Rotation Configured

**Location:**
- `terraform/eks-cluster/secrets.tf`
- `terraform/eks/secrets.tf`

**Issue:**
AWS Secrets Manager secrets are created but never rotated. Stale secrets increase risk if compromised.

**Risk:**
Long-lived credentials more likely to be leaked/compromised over time.

**Recommendation:**
Add automatic rotation to `terraform/eks-cluster/secrets.tf`:

```hcl
# Lambda function for secret rotation
resource "aws_lambda_function" "rotate_secret" {
  filename      = "lambda/rotate_secret.zip"
  function_name = "${var.cluster_name}-rotate-api-keys"
  role          = aws_iam_role.lambda_rotation.arn
  handler       = "rotate_secret.lambda_handler"
  runtime       = "python3.11"
  timeout       = 30
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_rotation" {
  name = "${var.cluster_name}-lambda-rotation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Attach necessary permissions
resource "aws_iam_role_policy_attachment" "lambda_rotation" {
  role       = aws_iam_role.lambda_rotation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_rotation_secrets" {
  name = "secrets-access"
  role = aws_iam_role.lambda_rotation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecretVersionStage"
      ]
      Resource = aws_secretsmanager_secret.api_keys.arn
    }]
  })
}

# Configure rotation
resource "aws_secretsmanager_secret_rotation" "api_keys" {
  secret_id           = aws_secretsmanager_secret.api_keys.id
  rotation_lambda_arn = aws_lambda_function.rotate_secret.arn

  rotation_rules {
    automatically_after_days = 90
  }
}
```

---

## 🟡 MEDIUM SEVERITY

### 10. Network Policy Allows Broad HTTPS Egress

**Location:** `terraform/eks/network-policies.tf:58-74`

**Issue:**
```hcl
egress {
  to {
    ip_block {
      cidr = "0.0.0.0/0"  # All destinations
      except = ["169.254.169.254/32"]
    }
  }
  ports {
    port     = "443"
    protocol = "TCP"
  }
}
```

LiteLLM pods can connect to ANY external HTTPS endpoint (except AWS metadata service).

**Risk:**
- Pods could exfiltrate data to attacker-controlled servers
- Compromised container could be used as proxy
- Harder to audit/restrict outbound connections

**Recommendation:**
Restrict to specific endpoints:

**Option A:** Use VPC endpoints for AWS services (recommended):
```hcl
# Add to terraform/eks-cluster/main.tf
resource "aws_vpc_endpoint" "bedrock" {
  vpc_id              = aws_vpc.eks_vpc.id
  service_name        = "com.amazonaws.us-east-1.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

# Then restrict network policy to VPC CIDR + Perplexity IPs
```

**Option B:** Maintain current broad egress but add egress logging/monitoring

---

### 11. CloudFlare IP Ranges Fetched at Plan Time

**Location:** `terraform/eks/alb-security-group.tf:6-8`

**Issue:**
```hcl
data "http" "cloudflare_ips_v4" {
  url = "https://www.cloudflare.com/ips-v4"
}
```

CloudFlare IP ranges are fetched during `terraform plan/apply` but can change over time. Your security groups won't update automatically.

**Risk:**
- CloudFlare adds new IP ranges → your site breaks (403 errors)
- CloudFlare removes old ranges → security groups contain stale rules

**Recommendation:**

**Option A:** Implement periodic refresh via Lambda:
```python
# Lambda function to sync CloudFlare IPs weekly
import boto3
import requests

def lambda_handler(event, context):
    ec2 = boto3.client('ec2')

    # Fetch current CloudFlare IPs
    ipv4_ranges = requests.get('https://www.cloudflare.com/ips-v4').text.split('\n')

    # Update security group rules
    sg_id = 'sg-xxxxx'  # Your ALB security group

    # Remove old rules and add new ones
    # ... implementation ...
```

**Option B:** Use CloudFlare Origin Pull certificates (current method works fine for now, just monitor for breakage)

**Option C:** Run `terraform apply` periodically (weekly) to refresh IPs

---

### 12. OpenWebUI Single Replica (No High Availability)

**Location:** `terraform/eks/openwebui.tf:35`

**Issue:**
```hcl
replicas = 1 # Single replica due to ReadWriteOnce volume
```

Single pod means zero availability during:
- Rolling updates
- Pod evictions
- Node failures
- Manual restarts

**Risk:** Service downtime during routine operations

**Recommendation:**

**Option A:** Use EFS instead of EBS (supports ReadWriteMany):
```hcl
# Add to terraform/eks/storage.tf
resource "aws_efs_file_system" "openwebui" {
  creation_token = "${var.cluster_name}-openwebui"
  encrypted      = true

  tags = {
    Name = "${var.cluster_name}-openwebui-efs"
  }
}

resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs"
  }
  storage_provisioner = "efs.csi.aws.com"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.openwebui.id
    directoryPerms   = "700"
  }
}

# Then change openwebui.tf PVC:
resource "kubernetes_persistent_volume_claim" "openwebui_data" {
  metadata {
    name      = "openwebui-data"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]  # Changed from ReadWriteOnce
    storage_class_name = "efs"              # Changed from ebs-gp3

    resources {
      requests = {
        storage = var.openwebui_storage_size
      }
    }
  }
}

# Update deployment replicas:
spec {
  replicas = 2  # Now possible with ReadWriteMany
  # ...
}
```

**Option B:** Accept downtime for cost savings (current approach is fine for dev/testing)

---

### 13. Very Long Liveness Probe Delay

**Location:** `terraform/eks/openwebui.tf:160`

**Issue:**
```hcl
liveness_probe {
  http_get {
    path = "/"
    port = 8080
  }
  initial_delay_seconds = 180 # 3 minutes!
  period_seconds        = 10
  timeout_seconds       = 5
  failure_threshold     = 3
}
```

Kubernetes won't restart a failed pod for 3 minutes after start, hiding startup failures.

**Risk:**
- Slow recovery from failed deployments
- Users experience long outages before pod restarts
- Harder to detect startup issues

**Recommendation:**
Reduce delay and optimize startup:
```hcl
liveness_probe {
  http_get {
    path = "/"
    port = 8080
  }
  initial_delay_seconds = 60  # Reduced from 180
  period_seconds        = 10
  timeout_seconds       = 5
  failure_threshold     = 3
}

readiness_probe {
  http_get {
    path = "/"
    port = 8080
  }
  initial_delay_seconds = 30  # Reduced from 60
  period_seconds        = 5
  timeout_seconds       = 3
  failure_threshold     = 3
}
```

Also investigate why startup takes so long (likely embedding model downloads) and consider:
- Pre-building embeddings into container image
- Using init container to download models
- Caching model downloads on persistent volume

---

### 14. No Horizontal Pod Autoscaling (HPA)

**Location:** Missing from `terraform/eks/`

**Issue:**
No auto-scaling configured for LiteLLM or OpenWebUI based on CPU/memory/custom metrics.

**Risk:**
- Performance degradation under high load
- Manual intervention required to scale
- Potential service outages during traffic spikes

**Recommendation:**
Add HPA resources to `terraform/eks/kubernetes.tf`:

```hcl
# HPA for LiteLLM
resource "kubernetes_horizontal_pod_autoscaler_v2" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.litellm.metadata[0].name
    }

    min_replicas = 1
    max_replicas = 5

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }

    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }

    behavior {
      scale_down {
        stabilization_window_seconds = 300
        policy {
          type          = "Percent"
          value         = 50
          period_seconds = 60
        }
      }
      scale_up {
        stabilization_window_seconds = 0
        policy {
          type          = "Percent"
          value         = 100
          period_seconds = 30
        }
      }
    }
  }
}
```

---

### 15. No Pod Disruption Budgets (PDB)

**Location:** Missing from `terraform/eks/`

**Issue:**
Kubernetes can terminate all pods simultaneously during node drains or cluster upgrades.

**Risk:** Complete service outage during maintenance operations

**Recommendation:**
Add PDB to `terraform/eks/kubernetes.tf`:

```hcl
# Pod Disruption Budget for LiteLLM
resource "kubernetes_pod_disruption_budget_v1" "litellm" {
  metadata {
    name      = "litellm-pdb"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
  }

  spec {
    min_available = "50%"  # Or use max_unavailable = 1

    selector {
      match_labels = {
        app = "litellm"
      }
    }
  }
}

# Pod Disruption Budget for OpenWebUI
resource "kubernetes_pod_disruption_budget_v1" "openwebui" {
  metadata {
    name      = "openwebui-pdb"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
  }

  spec {
    max_unavailable = 1  # Only if you implement multi-replica (see issue #12)

    selector {
      match_labels = {
        app = "openwebui"
      }
    }
  }
}
```

**Note:** For OpenWebUI, PDB only makes sense if you implement multi-replica deployment with EFS (see issue #12).

---

### 16. Guardrail Message Sanitization Race Condition

**Location:** `config/custom_guardrail.py:96-163`

**Issue:**
Complex message list manipulation logic with multiple iterations could have edge cases:
- Orphaned assistant messages
- Empty message list after sanitization
- Consecutive messages of same role

**Risk:**
- Guardrail bypass through carefully crafted message sequences
- LLM errors due to malformed conversation history
- Inconsistent filtering behavior

**Recommendation:**

**Option A:** Add comprehensive unit tests covering edge cases:
```python
# tests/test_guardrail_edge_cases.py
import pytest
from custom_guardrail import DuckiesBunniesGuardrail

def test_orphaned_assistant_message():
    guardrail = DuckiesBunniesGuardrail()
    data = {
        "messages": [
            {"role": "assistant", "content": "I like duckies"}
        ]
    }
    result = await guardrail.async_pre_call_hook({}, {}, data, "completion")
    # Should handle gracefully

def test_empty_messages_after_sanitization():
    # Test case where all messages are removed
    pass

def test_consecutive_same_role():
    # Test case with user->user or assistant->assistant
    pass
```

**Option B:** Simplify the sanitization logic:
```python
def sanitize_messages(self, messages):
    """Simplified message sanitization"""
    cleaned = []
    last_role = None

    for msg in messages:
        # Check for blocked content
        if self._contains_blocked_content(msg.get("content", "")):
            continue

        # Ensure alternating roles
        if msg.get("role") != last_role:
            cleaned.append(msg)
            last_role = msg.get("role")

    # Ensure starts with user message
    while cleaned and cleaned[0].get("role") != "user":
        cleaned.pop(0)

    return cleaned
```

---

### 17. No Database Configured for Audit Logging

**Location:** `config/litellm_config.yaml:84`

**Issue:**
```yaml
database_url: null
```

No persistent storage for LiteLLM requests/responses. Can't audit who accessed what, track usage, or investigate security incidents.

**Risk:**
- No audit trail for compliance/security investigations
- Can't track usage per user/model
- No historical data for cost attribution
- Difficult to detect abuse patterns

**Recommendation:**
Configure PostgreSQL for LiteLLM:

**Step 1:** Add PostgreSQL to infrastructure (`terraform/eks/database.tf`):
```hcl
resource "aws_db_instance" "litellm" {
  identifier     = "${var.cluster_name}-litellm"
  engine         = "postgres"
  engine_version = "15.5"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true

  db_name  = "litellm"
  username = "litellm"
  password = random_password.db_password.result

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.litellm.name

  backup_retention_period = 7
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.cluster_name}-litellm-final"

  tags = {
    Name = "${var.cluster_name}-litellm-db"
  }
}

resource "aws_db_subnet_group" "litellm" {
  name       = "${var.cluster_name}-litellm"
  subnet_ids = data.aws_eks_cluster.cluster.vpc_config[0].subnet_ids

  tags = {
    Name = "${var.cluster_name}-litellm-db-subnet-group"
  }
}

resource "random_password" "db_password" {
  length  = 32
  special = true
}

# Store DB password in Secrets Manager
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = data.aws_secretsmanager_secret.api_keys.id
  secret_string = jsonencode(merge(
    jsondecode(data.aws_secretsmanager_secret_version.api_keys.secret_string),
    {
      DATABASE_URL = "postgresql://${aws_db_instance.litellm.username}:${random_password.db_password.result}@${aws_db_instance.litellm.endpoint}/${aws_db_instance.litellm.db_name}"
    }
  ))
}
```

**Step 2:** Update `config/litellm_config.yaml`:
```yaml
general_settings:
  database_url: os.environ/DATABASE_URL
  # ... rest of config
```

**Step 3:** Add DATABASE_URL to LiteLLM deployment env vars

**Alternative:** Use CloudWatch Logs for basic audit logging (lighter weight)

---

### 18. No Resource Requests for LiteLLM

**Location:** `terraform/eks/kubernetes.tf:132-141`

**Issue:**
Resource requests/limits are defined via variables but defaults might not be set optimally.

**Recommendation:**
Review and tune based on actual usage patterns. Add to `terraform/eks/variables.tf`:

```hcl
variable "litellm_cpu_request" {
  description = "CPU request for LiteLLM pods"
  type        = string
  default     = "500m"  # 0.5 CPU core
}

variable "litellm_cpu_limit" {
  description = "CPU limit for LiteLLM pods"
  type        = string
  default     = "2000m"  # 2 CPU cores
}

variable "litellm_memory_request" {
  description = "Memory request for LiteLLM pods"
  type        = string
  default     = "1Gi"
}

variable "litellm_memory_limit" {
  description = "Memory limit for LiteLLM pods"
  type        = string
  default     = "2Gi"
}

variable "openwebui_cpu_request" {
  description = "CPU request for OpenWebUI pods"
  type        = string
  default     = "250m"
}

variable "openwebui_cpu_limit" {
  description = "CPU limit for OpenWebUI pods"
  type        = string
  default     = "1000m"
}

variable "openwebui_memory_request" {
  description = "Memory request for OpenWebUI pods"
  type        = string
  default     = "512Mi"
}

variable "openwebui_memory_limit" {
  description = "Memory limit for OpenWebUI pods"
  type        = string
  default     = "2Gi"
}
```

Monitor actual usage with:
```bash
kubectl top pods -n llm-gateway
```

---

## 🟢 LOW SEVERITY (Improvements)

### 19. Single NAT Gateway (Single Point of Failure)

**Location:** `terraform/eks-cluster/main.tf:96`

**Issue:**
```hcl
resource "aws_nat_gateway" "eks_nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id  # Only in first AZ
}
```

Already documented as cost optimization, but worth noting:
- NAT gateway failure = complete outage for private subnets
- No cross-AZ redundancy

**Risk:** Service outage if NAT gateway or its AZ fails

**Recommendation:**
For production, deploy NAT gateway in each AZ (adds ~$32/month per gateway):

```hcl
# Create EIP for each AZ
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.eks_igw]
}

# Create NAT Gateway in each public subnet
resource "aws_nat_gateway" "eks_nat" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.cluster_name}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.eks_igw]
}

# Create separate route table for each private subnet
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks_nat[count.index].id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt-${count.index + 1}"
  }
}

# Associate each private subnet with its own route table
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

**Cost Impact:** ~$32/month per NAT gateway (1 additional = $32/month total increase)

---

### 20. Dockerfile Runs with --detailed_debug in Production

**Location:** `Dockerfile:48`

**Issue:**
```dockerfile
CMD ["--config", "/app/config.yaml", "--port", "4000", "--detailed_debug"]
```

Detailed debug mode in production logs excessive information, potentially including sensitive data.

**Risk:**
- Performance overhead
- Log storage costs
- Potential exposure of sensitive data in logs

**Recommendation:**
Remove `--detailed_debug` from CMD and control via environment variable:

**Update Dockerfile:**
```dockerfile
# Default to non-debug mode
ENV LITELLM_LOG_LEVEL=INFO

# Run LiteLLM with configuration
ENTRYPOINT ["litellm"]
CMD ["--config", "/app/config.yaml", "--port", "4000"]
```

**Add to kubernetes.tf for debugging:**
```hcl
# Only add this env var when troubleshooting
# env {
#   name  = "LITELLM_LOG_LEVEL"
#   value = "DEBUG"
# }
```

---

### 21. No Terraform State Locking

**Location:** `terraform/eks/main.tf:20-25`

**Issue:**
```hcl
# Optional: Configure S3 backend for state management
# backend "s3" {
#   bucket = "your-terraform-state-bucket"
#   key    = "llm-gateway/eks/terraform.tfstate"
#   region = "us-east-1"
# }
```

Local Terraform state without S3 backend means:
- No state locking (concurrent applies can corrupt state)
- State file contains secrets (see issue #3)
- No team collaboration
- No state versioning/recovery

**Recommendation:**
Configure S3 backend with DynamoDB locking:

**Step 1:** Create state infrastructure (`terraform/backend/main.tf`):
```hcl
terraform {
  required_version = ">= 1.0"
}

provider "aws" {
  region = "us-east-1"
}

# S3 bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "llm-gateway-terraform-state-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name      = "Terraform State"
    Project   = "llm-gateway"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "llm-gateway-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name      = "Terraform State Locks"
    Project   = "llm-gateway"
    ManagedBy = "terraform"
  }
}

data "aws_caller_identity" "current" {}

output "s3_bucket_name" {
  value = aws_s3_bucket.terraform_state.id
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.terraform_locks.name
}
```

**Step 2:** Deploy backend infrastructure:
```bash
cd terraform/backend
terraform init
terraform apply
```

**Step 3:** Update all Terraform modules to use backend:
```hcl
# terraform/eks-cluster/main.tf
terraform {
  backend "s3" {
    bucket         = "llm-gateway-terraform-state-667778672048"  # Use your account ID
    key            = "llm-gateway/eks-cluster/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "llm-gateway-terraform-locks"
  }
}

# terraform/eks/main.tf
terraform {
  backend "s3" {
    bucket         = "llm-gateway-terraform-state-667778672048"
    key            = "llm-gateway/eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "llm-gateway-terraform-locks"
  }
}

# terraform/ecr/main.tf
terraform {
  backend "s3" {
    bucket         = "llm-gateway-terraform-state-667778672048"
    key            = "llm-gateway/ecr/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "llm-gateway-terraform-locks"
  }
}
```

**Step 4:** Migrate existing state:
```bash
# For each module
cd terraform/eks-cluster
terraform init -migrate-state
```

---

### 22. Stream Forced to False (Timeout Risk)

**Location:** `config/custom_guardrail.py:184`

**Issue:**
```python
# FORCE stream to false - this is CRITICAL for content filtering to work
data['stream'] = False
```

Forcing non-streaming mode for ALL requests (to enable output filtering) means:
- Long responses could timeout (600s limit in router_settings)
- Poor UX for users (no progressive display)
- Higher memory usage (entire response buffered)

**Risk:** Timeouts on long responses, degraded user experience

**Recommendation:**

**Option A:** Implement streaming-compatible filtering using `async_moderation_hook`:
```python
async def async_moderation_hook(
    self,
    data: dict,
    user_api_key_dict: UserAPIKeyAuth,
    call_type: Literal["completion", "embeddings", "image_generation"],
):
    """
    Called during streaming to check each chunk
    """
    # This hook IS called for streaming responses
    # Check each chunk as it arrives
    pass
```

**Option B:** Make streaming configurable per-model:
```python
# Only force non-streaming for models that need strict filtering
if self.strict_filtering_enabled(model):
    data['stream'] = False
```

**Option C:** Accept the trade-off (current approach is safest for guaranteed filtering)

**Option D:** Increase timeout in config/litellm_config.yaml:
```yaml
router_settings:
  timeout: 1200  # Increase from 600 to 1200 seconds (20 minutes)
```

---

### 23. No Network Policy for DNS (TCP)

**Location:** `terraform/eks/network-policies.tf:51-55`

**Issue:**
```hcl
egress {
  to {
    namespace_selector {
      match_labels = {
        "kubernetes.io/metadata.name" = "kube-system"
      }
    }
  }
  ports {
    port     = "53"
    protocol = "UDP"
  }
}
```

DNS egress only allows UDP on port 53, but some DNS queries use TCP (especially for large responses or DNSSEC).

**Risk:** DNS resolution failures for certain queries

**Recommendation:**
Add TCP/53 egress rule to both network policies:

```hcl
# Add to litellm network policy
egress {
  to {
    namespace_selector {
      match_labels = {
        "kubernetes.io/metadata.name" = "kube-system"
      }
    }
  }
  ports {
    port     = "53"
    protocol = "TCP"
  }
}

# Add same rule to openwebui network policy
egress {
  to {
    namespace_selector {
      match_labels = {
        "kubernetes.io/metadata.name" = "kube-system"
      }
    }
  }
  ports {
    port     = "53"
    protocol = "TCP"
  }
}
```

---

### 24. Health Checks Use TCP Socket (Not HTTP)

**Location:** `terraform/eks/kubernetes.tf:150-158`

**Issue:**
```hcl
liveness_probe {
  tcp_socket {
    port = 4000
  }
  initial_delay_seconds = 30
  period_seconds        = 10
  timeout_seconds       = 3
  failure_threshold     = 3
}
```

TCP socket check only verifies port is open, not that LiteLLM is actually healthy and responding.

**Risk:** False positives (port open but app crashed/hung)

**Recommendation:**
Use HTTP health check on LiteLLM's health endpoint:

```hcl
liveness_probe {
  http_get {
    path   = "/health"
    port   = 4000
    scheme = "HTTP"
  }
  initial_delay_seconds = 30
  period_seconds        = 10
  timeout_seconds       = 5
  failure_threshold     = 3
}

readiness_probe {
  http_get {
    path   = "/health/readiness"
    port   = 4000
    scheme = "HTTP"
  }
  initial_delay_seconds = 10
  period_seconds        = 5
  timeout_seconds       = 3
  failure_threshold     = 3
}
```

**Note:** Verify that `/health` and `/health/readiness` are in `public_routes` in `config/litellm_config.yaml` (they already are at line 81).

---

## Summary Statistics

| Severity | Count | Issues |
|----------|-------|--------|
| 🔴 Critical | 4 | #1, #2, #3, #4 |
| 🟠 High | 5 | #5, #6, #7, #8, #9 |
| 🟡 Medium | 9 | #10, #11, #12, #13, #14, #15, #16, #17, #18 |
| 🟢 Low | 6 | #19, #20, #21, #22, #23, #24 |
| **Total** | **24** | |

---

## Priority Recommendations

### Immediate Action Required (Critical)

1. **Fix AWS credential exposure** (#1) - Switch to volume mount or IAM roles
2. **Restrict IAM Bedrock policy** (#2) - Scope to specific model ARNs
3. **Remove secrets from Terraform state** (#3) - Use External Secrets Operator
4. **Lock down CORS** (#4) - Restrict to specific origins

### High Priority (This Week)

5. Disable model access control bypass (#5)
6. Narrow ISP CIDR block or implement dynamic IP allowlisting (#6)
7. Restrict or disable EKS public API endpoint (#7)
8. Improve guardrail bypass resistance (#8)
9. Configure secrets rotation (#9)

### Medium Priority (This Month)

10-18. Implement network restrictions, high availability, monitoring, and operational improvements

### Low Priority (As Needed)

19-24. Performance optimizations, observability enhancements, and best practice implementations

---

## Testing Checklist

After fixing issues, verify:

- [ ] Docker Compose starts without AWS credential warnings
- [ ] LiteLLM can still access Bedrock models with scoped IAM policy
- [ ] Kubernetes secrets sync correctly from AWS Secrets Manager
- [ ] CORS blocks requests from unauthorized origins
- [ ] Model access control properly restricts user permissions
- [ ] ALB security group blocks IPs outside allowed ranges
- [ ] EKS API endpoint is not publicly accessible (or restricted to known IPs)
- [ ] Guardrails still block test patterns
- [ ] Terraform apply succeeds with S3 backend
- [ ] Health checks properly detect unhealthy pods

---

**Generated:** 2026-01-07
**Analysis Tool:** Claude Code
**Project:** llm-gateway
