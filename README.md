# LLM Gateway

A production-ready, secure, and cost-optimized LLM gateway deployed on AWS EKS with comprehensive security controls and multi-provider AI model support.

## Overview

LLM Gateway is a unified interface for accessing multiple AI model providers (AWS Bedrock, Perplexity) through a single endpoint. Built with security, cost optimization, and production best practices in mind, it demonstrates enterprise-grade cloud architecture and DevOps practices.

## Architecture

### Production (AWS EKS)

```
┌─────────────────────────────────────────────────────────────────┐
│                         AWS EKS Cluster                          │
│                                                                   │
│  ┌────────────────────┐          ┌─────────────────────┐        │
│  │   OpenWebUI Pod    │          │   LiteLLM Pod       │        │
│  │  (Web Interface)   │──────────│   (LLM Proxy)       │        │
│  │                    │          │   + Guardrails      │        │
│  │  Port: 8080        │          │   Port: 4000        │        │
│  └────────┬───────────┘          └──────────┬──────────┘        │
│           │                                  │                   │
│           │                                  │                   │
│  Network Policies (Zero-Trust Isolation)    │                   │
│           │                                  │                   │
└───────────┼──────────────────────────────────┼───────────────────┘
            │                                  │
            │                                  ├──> AWS Bedrock
    ┌───────▼────────┐                        │    (Nova, Llama, etc.)
    │                │                        │
    │   NLB (HTTPS)  │                        └──> Perplexity API
    │   Port: 443    │
    │  CloudFlare    │  ← Only CloudFlare IPs allowed
    │  IPs Only SG   │
    └───────┬────────┘
            │
            │
    ┌───────▼────────┐
    │   CloudFlare   │
    │   DNS Only     │
    └───────┬────────┘
            │
            ▼
    openwebui.bhenning.com

```

### Local Development (Docker Compose)

```
┌──────────────────────────────────────────────────────┐
│              Docker Compose Network                   │
│                                                        │
│  ┌────────────────┐          ┌─────────────────────┐ │
│  │   OpenWebUI    │──────────│     LiteLLM         │ │
│  │  Port: 3000    │          │     Port: 4000      │ │
│  │                │          │   + Guardrails      │ │
│  └────────────────┘          └─────────────────────┘ │
│                                       │                │
└───────────────────────────────────────┼────────────────┘
         │                              │
         │                              ├──> AWS Bedrock
         └─> http://localhost:3000      └──> Perplexity API
```

**Key Differences:**
- **EKS**: Exposed via NLB with HTTPS and CloudFlare restriction
- **Local**: Direct localhost access (no external exposure)
- **Both**: Same architecture - LiteLLM with native passthrough guardrails

## Key Features

### Security
- **Zero-Trust Networking**: Kubernetes NetworkPolicies enforce pod-to-pod isolation
- **IRSA (IAM Roles for Service Accounts)**: AWS service authentication without static credentials
- **Non-Root Containers**: All containers run as unprivileged users (UID 1000)
- **HTTPS/TLS**: ACM certificate with NLB SSL termination
- **AWS Metadata Service Blocking**: Prevents SSRF attacks
- **Rate Limiting**: Built-in request throttling
- **Input Validation**: Parameter sanitization and validation

### Cost Optimization
- **SPOT Instances**: 50-90% cost savings on compute (t3.medium, t3a.medium, t2.medium)
- **Single NAT Gateway**: ~$32/month savings vs multi-AZ NAT
- **Resource Quotas**: Prevent resource waste
- **ECR for Container Images**: Eliminates Docker Hub rate limits

### Multi-Provider Support
- **AWS Bedrock**: Nova Pro, Llama 3.2
- **Perplexity**: Sonar Pro, Sonar Deep Research
- **Unified API**: OpenAI-compatible endpoint for all models

### Features
- **Arena Mode**: Blind model comparison (3 models: Perplexity, AWS, Meta)
- **Custom Guardrails**: Extensible content filtering system (example implementation included)
- **Persistent Storage**: User data and conversations stored in EBS volumes
- **Auto-Scaling**: EKS node group scales based on demand
- **Health Checks**: Kubernetes liveness/readiness probes
- **Automated DNS Management**: CloudFlare API integration for DNS setup

## Prerequisites

### Local Development
- Docker and Docker Compose
- AWS credentials with Bedrock access
- Perplexity API key

### AWS EKS Deployment
- Terraform >= 1.0
- AWS CLI configured
- kubectl
- AWS account with permissions for:
  - EKS, VPC, EC2, IAM, ACM, Secrets Manager, ECR

## Quick Start - Local Development

1. Clone the repository:
```bash
git clone https://github.com/henninb/llm-gateway.git
cd llm-gateway
```

2. Create `.secrets` file:
```bash
cat > .secrets <<EOF
# Required for AWS Bedrock access
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_REGION=us-east-1

# Required for LiteLLM and OpenWebUI
LITELLM_MASTER_KEY=$(openssl rand -hex 32)
WEBUI_SECRET_KEY=$(openssl rand -hex 32)

# Required for Perplexity models
PERPLEXITY_API_KEY=your-perplexity-key

# Optional: For automated CloudFlare DNS management
# Get from: https://dash.cloudflare.com/profile/api-tokens
# Or use Global API Key from: https://dash.cloudflare.com/profile/api-tokens
CF_API_KEY=your-cloudflare-api-key
CF_EMAIL=your-cloudflare-email
EOF
```

3. Start the services:
```bash
make local-deploy
```

4. Access OpenWebUI at http://localhost:3000

**Note**: Local and EKS deployments use the same architecture. Custom guardrails use LiteLLM's native passthrough mode (`on_flagged_action: "passthrough"`), which returns HTTP 200 with violation messages instead of HTTP 400 errors. This prevents chat context corruption in the UI while maintaining security controls.

### Available Makefile Commands

The project includes a comprehensive Makefile with the following commands:

```bash
# Show all available commands
make help

# Local Development
make local-deploy          # Deploy containers locally with docker-compose
make local-status          # Show status of Docker containers
make local-port-forward    # Forward LiteLLM port to localhost:4000
make local-destroy         # Destroy local environment

# Testing
make validate-setup        # Validate required tools are installed
make test-health          # Check service health and connectivity
make test-litellm-models  # Test all LiteLLM models (7 models across 3 providers)
make test-guardrails      # Test custom guardrails (pre_call and post_call hooks)
make test-all             # Run all tests (setup, health, models, guardrails)

# Cost & IAM Reporting
make aws-costs            # Generate AWS cost report (shell)
make aws-costs-py         # Generate AWS cost report (Python, rich formatting)
make iam-report           # Show IAM roles and security architecture

# ECR Infrastructure
make ecr-init             # Initialize Terraform for ECR
make ecr-plan             # Plan ECR changes
make ecr-apply            # Create ECR repositories
make ecr-destroy          # Destroy ECR repositories
make ecr-login            # Login to AWS ECR
make ecr-build-push       # Build and push Docker images to ECR

# EKS Cluster Infrastructure
make eks-cluster-init     # Initialize Terraform for EKS cluster
make eks-cluster-plan     # Plan EKS cluster changes
make eks-cluster-apply    # Create EKS cluster
make eks-cluster-destroy  # Destroy EKS cluster
make eks-cluster-kubeconfig  # Configure kubectl for EKS

# EKS Application Deployment
make eks-init             # Initialize Terraform for EKS deployment
make eks-plan             # Plan EKS deployment changes
make eks-apply            # Deploy applications to EKS
make eks-destroy          # Destroy EKS deployment
make eks-secrets-populate # Populate AWS Secrets Manager with API keys
make eks-port-forward     # Forward LiteLLM from EKS to localhost:4000
make eks-verify-cloudflare # Verify CloudFlare IP ranges in NLB security group
make eks-verify-cloudflare-dns # Auto-setup/verify CloudFlare DNS (recommended)
make eks-test-cloudflare-restriction # Test NLB only accepts CloudFlare IPs
```

## AWS EKS Deployment

### Step 1: Setup Infrastructure

```bash
# 1. Create ECR repositories
make ecr-init
make ecr-apply

# 2. Build and push Docker images
make ecr-login
make ecr-build-push

# 3. Create EKS cluster
make eks-cluster-init
make eks-cluster-apply
```

### Step 2: Configure kubectl

```bash
make eks-cluster-kubeconfig
```

### Step 3: Create Secrets in AWS Secrets Manager

First, create a `.secrets` file in the project root with your API keys (see Quick Start section above for format).

Then populate AWS Secrets Manager:
```bash
# From project root directory
make eks-secrets-populate
```

This will load the secrets from your `.secrets` file and store them in AWS Secrets Manager under the secret `llm-gateway/api-keys`.

### Step 4: Deploy Applications

```bash
# Update terraform.tfvars with your ACM certificate ARN
vim terraform/eks/terraform.tfvars

# Apply EKS application deployment
make eks-init
make eks-apply
```

### Step 5: Configure DNS

#### Automated Setup (Recommended)

The automated approach uses the CloudFlare API to create and manage DNS records:

```bash
# Ensure CF_API_KEY and CF_EMAIL are in your .secrets file
# Then run automated DNS setup
make eks-verify-cloudflare-dns

# Or specify a custom domain
DOMAIN=openwebui.bhenning.com make eks-verify-cloudflare-dns
```

This command will:
1. Check if DNS record exists
2. Create CNAME record if missing (pointing to LoadBalancer)
3. Update CNAME if it points to wrong target
4. Verify DNS propagation
5. Test HTTPS connectivity

**How to get CloudFlare credentials:**
- **API Token** (recommended): Go to https://dash.cloudflare.com/profile/api-tokens → Create Token → Use "Edit zone DNS" template
- **Global API Key** (legacy): Go to https://dash.cloudflare.com/profile/api-tokens → View Global API Key

Add to your `.secrets` file:
```bash
CF_API_KEY=your-global-api-key-or-token
CF_EMAIL=your-cloudflare-email
```

#### Manual Setup (Alternative)

If you prefer manual DNS configuration:

1. Get the LoadBalancer DNS name:
```bash
kubectl get svc openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

2. Create a CNAME record in CloudFlare:
   - Type: CNAME
   - Name: openwebui (or your subdomain)
   - Target: [LoadBalancer DNS from step 1]
   - Proxy status: DNS only (gray cloud icon)

3. Verify configuration:
```bash
dig +short openwebui.bhenning.com
curl -I https://openwebui.bhenning.com
```

### Step 6: Verify CloudFlare Security

The NLB is automatically configured with a security group that **ONLY allows CloudFlare IP ranges**, preventing direct access from non-CloudFlare sources.

#### Verify Security Configuration

Test that the NLB properly restricts access to CloudFlare IPs only:

```bash
# Test that non-CloudFlare IPs cannot access NLB directly
make eks-test-cloudflare-restriction
```

This test will:
1. Check your public IP address
2. Verify it's not in CloudFlare IP ranges
3. Attempt direct connection to NLB (should timeout/fail)
4. Verify only CloudFlare security group is attached
5. Confirm access through domain works (via CloudFlare)

**Expected result**: `✅ SUCCESS: NLB is properly restricted to CloudFlare IPs`

#### Keep CloudFlare IP Ranges Updated

CloudFlare occasionally updates their IP ranges. Verify and update monthly:

```bash
# Check if CloudFlare IP ranges are current
make eks-verify-cloudflare

# If outdated, update with:
make eks-apply
```

#### (Optional) Additional CloudFlare Security

Additional security features available with CloudFlare:
- ✅ Geo-restriction (US-only access with HTTP 403 for blocked users)
- ✅ DDoS protection and WAF
- ✅ CloudFlare proxy mode (orange cloud)
- ✅ No additional AWS costs (uses CloudFlare free/pro plan)

To enable these features, configure CloudFlare firewall rules and enable proxy mode (orange cloud) in your DNS settings.

## Configuration

### LiteLLM Configuration

Edit `config/litellm_config.yaml` to:
- Add/remove AI models
- Configure rate limits
- Set budget limits
- Customize CORS policies

### Custom Guardrails (Example Implementation)

The project includes a **demonstration** of custom content filtering using LiteLLM's guardrails system. This example blocks specific content patterns in both user inputs and model outputs while preventing chat context corruption.

**Example guardrail** (`config/custom_guardrail.py`):
- Blocks user messages containing specific keywords/patterns (pre_call hook)
- Blocks LLM responses containing prohibited content (post_call hook)
- Sanitizes conversation history to prevent bypass attempts
- Returns user-friendly error messages via passthrough mode
- Works identically in both local (Docker) and EKS deployments

**How it works:**
1. **Pre-call hook**: Checks incoming user messages before sending to LLM
2. **History sanitization**: Removes previously blocked message pairs from context
3. **Conversation validation**: Ensures proper message structure (user/assistant alternation)
4. **Post-call hook**: Filters LLM responses for prohibited content
5. **Passthrough mode**: Returns HTTP 200 with violation message (prevents UI context corruption)
6. **Streaming support**: Works with both streaming and non-streaming requests

**Technical Details:**
- Uses `ModifyResponseException` with `on_flagged_action: "passthrough"`
- Includes patch for LiteLLM v1.80.11 streaming bug (see `LITELLM-BUG.md`)
- Maintains chat context integrity across both local and production environments

**Configure in** `config/litellm_config.yaml`:
```yaml
guardrails:
  - guardrail_name: "custom-content-filter"
    litellm_params:
      guardrail: custom_guardrail.YourGuardrailClass
      mode: ["pre_call", "post_call"]  # Filter both input and output
      default_on: true
      on_flagged_action: "passthrough"  # Return 200 with error message
```

**Customize the example:**
1. Edit `config/custom_guardrail.py`
2. Modify the `patterns` list with your content rules
3. Adjust blocking logic in `async_pre_call_hook()` and `async_post_call_success_hook()`
4. Redeploy: `make local-deploy` or `make eks-apply`

**Test guardrails:**
```bash
# Run comprehensive guardrail test suite
make test-guardrails

# Or run directly
python3 tests/test-guardrails.py

# Tests verify (5 tests per model, 10 total):
# PRE_CALL TESTS:
# - Direct blocking of prohibited user input
# - Bypass prevention via history sanitization
# - Normal conversations work unaffected
# POST_CALL TESTS:
# - LLM output filtering (non-streaming)
# - LLM output filtering (streaming mode)
```

This implementation demonstrates enterprise-grade content filtering that can be adapted for:
- PII detection and redaction
- Prompt injection prevention
- Company policy enforcement
- Compliance requirements (GDPR, HIPAA, etc.)
- Output safety and content moderation

### Terraform Variables

Key variables in `terraform/eks/terraform.tfvars`:
- `cluster_name`: EKS cluster name
- `aws_region`: AWS region
- `acm_certificate_arn`: ACM certificate for HTTPS
- `use_ecr_images`: Use ECR instead of Docker Hub
- `ecr_image_tag`: Image tag to deploy

## Security Features

### Network Policies
- **LiteLLM**: Only accepts traffic from OpenWebUI pods
- **OpenWebUI**: Only communicates with LiteLLM and AWS Secrets Manager
- **DNS**: Both pods can resolve DNS via kube-system
- **Metadata Service**: Blocked to prevent SSRF attacks

### IRSA (IAM Roles for Service Accounts)
- LiteLLM pod has IAM role with:
  - Bedrock InvokeModel permissions
  - Secrets Manager read access (Perplexity API key)
- No static AWS credentials stored in pods

### Container Security
- Non-root user (UID 1000)
- Read-only root filesystem where possible
- Security context constraints
- Health checks for availability

### HTTPS/TLS
- ACM certificate management
- NLB SSL termination
- Automatic certificate renewal

## Cost Breakdown

Estimated monthly costs (us-east-1):
- EKS Control Plane: ~$73
- EC2 SPOT Instances (2x t3.medium): ~$15-30
- NAT Gateway: ~$32
- EBS Volumes: ~$8
- Network Load Balancer: ~$16
- Data Transfer: Variable

**Total: ~$144-179/month**

Cost optimizations implemented:
- Single NAT gateway vs multi-AZ (~$32/month savings)
- SPOT instances vs on-demand (~$30-60/month savings)
- ECR vs Docker Hub (avoids rate limits)

## Usage

### Access the UI
Navigate to: https://openwebui.bhenning.com

### Arena Mode (Blind Model Comparison)
1. Click "Arena" in the sidebar
2. Enter your prompt
3. Two random models will respond
4. Vote for the better response
5. Models are revealed after voting

### Available Models
- **AWS Bedrock Nova**: nova-micro, nova-lite, nova-pro
- **AWS Bedrock Llama**: llama3-2-1b, llama3-2-3b
- **Perplexity**: perplexity-sonar, perplexity-sonar-pro

### API Access
You can also access LiteLLM directly via OpenAI-compatible API:

```bash
curl https://openwebui.bhenning.com/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nova-pro",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Testing

The project includes comprehensive test suites for validating guardrails, model connectivity, and security controls.

### Complete Test Suite

Run all tests with a single command:

```bash
make test-all
```

This runs:
1. **Setup validation**: Verifies required tools are installed
2. **Health checks**: Validates service connectivity
3. **Model tests**: Tests all 7 LiteLLM models across 3 providers
4. **Guardrail tests**: Validates pre_call and post_call content filtering

### Guardrails Testing

Test the custom content filtering system with comprehensive pre_call and post_call validation:

```bash
# Run guardrail test suite
make test-guardrails

# Or run directly
python3 tests/test-guardrails.py
```

The test suite validates (5 tests per model, 10 total):

**PRE_CALL TESTS (Input Filtering):**
1. **Direct blocking**: User input with prohibited content is blocked
2. **Bypass prevention**: Conversation history sanitization prevents circumvention
3. **Normal operation**: Regular conversations work without interference

**POST_CALL TESTS (Output Filtering):**
4. **Output filtering (non-streaming)**: LLM responses with prohibited content are blocked
5. **Output filtering (streaming)**: Same as above but validates streaming bug fix

Tests run against both:
- **AWS Bedrock model**: llama3-2-3b
- **Perplexity model**: perplexity-sonar

**Example output:**
```
PRE_CALL TESTS (Input Filtering)
✅ PASS: Direct mention blocked (200 OK with BLOCKED message)
✅ PASS: Bypass prevented (history sanitized)
✅ PASS: Normal conversation works

POST_CALL TESTS (Output Filtering)
✅ PASS: LLM output blocked (post_call hook working)
✅ PASS: LLM output blocked in streaming mode (patch working)

Model 'llama3-2-3b' Results: 5/5 tests passed
🎉 All tests passed! (10/10)
```

### Model Connectivity Testing

Test all configured LiteLLM models (7 models across 3 providers):

```bash
# Test all models
make test-litellm-models

# Test with shell script
./tests/test-litellm-models-api.sh

# Test with Python script
python3 tests/test-litellm-models-api.py

# Test with custom endpoint
ENDPOINT=http://192.168.1.10:4000 python3 tests/test-litellm-models-api.py
```

This validates:
- ✅ AWS Bedrock access (Nova, Llama models)
- ✅ Perplexity API access
- ✅ IRSA authentication (no static AWS keys)
- ✅ Multi-provider unified API

### Production Deployment Testing

**Important**: LiteLLM is not exposed to the internet for security reasons. It's only accessible internally to OpenWebUI or via port-forwarding.

```bash
# Terminal 1: Start port-forwarding
make eks-port-forward

# Terminal 2: Run model tests
make test-litellm-models

# Terminal 3: Run guardrail tests
make test-guardrails
```

This validates:
- ✅ IRSA authentication (no static AWS keys)
- ✅ Multi-provider access (AWS Bedrock + Perplexity)
- ✅ Zero-trust network policies (LiteLLM internal-only)
- ✅ Production EKS deployment
- ✅ All 7 configured models
- ✅ Pre_call and post_call guardrails

#### Manual cURL Testing

```bash
# Run interactive curl examples
export LITELLM_MASTER_KEY=your-key
source tests/curl-examples.sh
```

Or test individual models:

```bash
# Test Amazon Nova Pro (AWS Bedrock via IRSA)
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-pro","messages":[{"role":"user","content":"Say hello"}]}'

# Test Meta Llama 3.2 3B (AWS Bedrock via IRSA)
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3-2-3b","messages":[{"role":"user","content":"What is AI?"}]}'

# Test Perplexity Sonar Pro (API key from Secrets Manager)
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"perplexity-sonar-pro","messages":[{"role":"user","content":"Current AI trends"}]}'
```

#### Python Testing Example

```python
import os
import requests

LITELLM_URL = "http://localhost:4000/v1/chat/completions"
API_KEY = os.environ["LITELLM_MASTER_KEY"]

response = requests.post(
    LITELLM_URL,
    headers={"Authorization": f"Bearer {API_KEY}"},
    json={
        "model": "nova-pro",
        "messages": [{"role": "user", "content": "Hello!"}]
    }
)

print(response.json())
```

## Operations & Monitoring

### Cost Reporting

The project includes tools to monitor AWS infrastructure costs:

```bash
# Generate cost report with rich formatting (Python)
make aws-costs-py

# Generate cost report (shell script)
make aws-costs

# Specify AWS region (default: us-east-1)
AWS_REGION=us-west-2 make aws-costs-py
```

The cost reports show:
- Month-to-date costs for current resources
- Daily cost breakdown
- Cost by service (EKS, EC2, NAT Gateway, etc.)
- Previous month comparison

**Note**: AWS Cost Explorer API charges $0.01 per request.

### IAM Security Architecture Report

View all IAM roles and security architecture details:

```bash
# Generate IAM roles report
make iam-report

# Specify cluster name and region
CLUSTER_NAME=llm-gateway-eks AWS_REGION=us-east-1 make iam-report
```

This report displays:
1. **EKS Cluster Management Roles**: Roles for EKS control plane and worker nodes
2. **IRSA (IAM Roles for Service Accounts)**: Zero-trust authentication architecture
   - EBS CSI Driver role for persistent volume management
   - LiteLLM role for AWS Bedrock access
3. **Security Architecture Summary**: Zero static credentials, least privilege, audit trail
4. **IRSA Technical Flow**: How pods authenticate to AWS services
5. **Cost Implications**: IAM roles are free (only pay for actual AWS service usage)

### Port Forwarding for Local Testing

Test LiteLLM locally by forwarding from Kubernetes:

```bash
# Forward from EKS cluster to localhost:4000
make eks-port-forward

# Forward from local Docker to localhost:4000
make local-port-forward
```

Both commands forward LiteLLM to `localhost:4000` for testing with curl or Python scripts. Press Ctrl+C to stop forwarding.

### DNS Management & Verification

#### Automated DNS Setup (Recommended)

Automatically create and verify CloudFlare DNS records:

```bash
# Setup/verify DNS using CloudFlare API
make eks-verify-cloudflare-dns

# Or specify custom domain
DOMAIN=openwebui.bhenning.com make eks-verify-cloudflare-dns
```

This command:
1. **Authenticates** with CloudFlare using credentials from `.secrets`
2. **Checks** if DNS record exists
3. **Creates** CNAME record if missing
4. **Updates** record if pointing to wrong target
5. **Verifies** DNS propagation (local and CloudFlare DNS)
6. **Tests** HTTPS connectivity

**Automatic actions:**
- ✅ Creates CNAME → LoadBalancer hostname
- ✅ Sets TTL to auto (1 = automatic)
- ✅ Disables CloudFlare proxy (DNS only mode)
- ✅ Validates with both local DNS and CloudFlare DNS (1.1.1.1)

**Requirements:**
- `CF_API_KEY` and `CF_EMAIL` in `.secrets` file
- See Step 5 in deployment guide for credential setup

#### Manual DNS Check

For manual verification without CloudFlare API:

```bash
# Check LoadBalancer hostname
kubectl get svc openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Verify DNS resolves
dig +short openwebui.bhenning.com

# Test HTTPS
curl -I https://openwebui.bhenning.com
```

### CloudFlare Security Verification

The NLB is configured with a security group that **only accepts traffic from CloudFlare IP ranges**. This prevents direct access bypassing CloudFlare.

#### Test Access Restriction

Verify that the NLB blocks non-CloudFlare IPs:

```bash
# Test that NLB only accepts CloudFlare IPs
make eks-test-cloudflare-restriction
```

This test:
1. **Identifies your public IP** address
2. **Checks** if IP is in CloudFlare ranges
3. **Attempts** direct connection to NLB (should fail/timeout)
4. **Verifies** only CloudFlare security group is attached
5. **Confirms** access through domain works (via CloudFlare)

**Expected result**: `✅ SUCCESS: NLB is properly restricted to CloudFlare IPs`

If the test fails, it indicates:
- Your IP is actually in CloudFlare ranges (inconclusive)
- Security group allows additional IPs (configuration issue)
- VPC default security group is attached (needs investigation)

#### Verify IP Ranges Are Current

CloudFlare occasionally updates their IP ranges. Verify monthly:

```bash
# Check CloudFlare IP ranges are up-to-date
make eks-verify-cloudflare
```

This command:
1. Fetches current CloudFlare IPv4 and IPv6 ranges from cloudflare.com
2. Compares with configured security group rules (count and sample check)
3. Validates specific IP ranges are present
4. Provides update instructions if outdated

**If ranges are outdated:**
```bash
# Update security group with latest CloudFlare IPs
make eks-apply
```

**Recommendation**: Run `make eks-verify-cloudflare` monthly, as CloudFlare updates their IP ranges periodically.

## Troubleshooting

### DNS Issues

#### DNS Not Resolving

If `dig +short openwebui.bhenning.com` returns nothing:

```bash
# Check CloudFlare DNS directly (bypasses local cache)
dig @1.1.1.1 +short openwebui.bhenning.com

# If CloudFlare DNS works but local doesn't, clear DNS cache:
sudo systemctl restart NetworkManager

# Or if using systemd-resolved:
sudo resolvectl flush-caches
```

#### Local DNS Cache Stale

If CloudFlare DNS shows the correct IP but your local `dig` doesn't:

```bash
# Restart NetworkManager (most Linux distributions)
sudo systemctl restart NetworkManager

# Or flush systemd-resolved cache
sudo resolvectl flush-caches

# Verify DNS now resolves
dig +short openwebui.bhenning.com
```

#### Access Site Despite DNS Issues

You can access the site directly using the LoadBalancer hostname:

```bash
# Get LoadBalancer hostname
LB=$(kubectl get svc openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Access directly
curl https://$LB
# Or in browser: https://a9d0ae51cec214c1e83976f219737243-058ee2da301031a2.elb.us-east-1.amazonaws.com
```

### Check Pod Status
```bash
kubectl get pods -n llm-gateway
```

### View Logs
```bash
# LiteLLM logs
kubectl logs -n llm-gateway -l app=litellm --tail=100

# OpenWebUI logs
kubectl logs -n llm-gateway -l app=openwebui --tail=100
```

### Test Network Policies
```bash
# Describe network policies
kubectl describe networkpolicy -n llm-gateway

# Verify VPC CNI network policy support
kubectl get daemonset -n kube-system aws-node -o yaml | grep -A 5 "ENABLE_NETWORK_POLICY"
```

### HTTPS Issues
```bash
# Check certificate
openssl s_client -connect openwebui.bhenning.com:443 -servername openwebui.bhenning.com

# Check LoadBalancer
kubectl describe svc openwebui -n llm-gateway
```

### IRSA Issues
```bash
# Verify service account annotations
kubectl get sa litellm -n llm-gateway -o yaml

# Check pod environment
kubectl exec -n llm-gateway -it $(kubectl get pod -n llm-gateway -l app=litellm -o jsonpath='{.items[0].metadata.name}') -- env | grep AWS
```

## Maintenance

### Update Images
```bash
# Build and push new images
make ecr-login
make ecr-build-push

# Update deployments
make eks-apply
```

### Rotate Secrets
```bash
# Update secrets in AWS Secrets Manager (all keys stored in one secret)
aws secretsmanager put-secret-value \
  --secret-id llm-gateway/api-keys \
  --secret-string '{
    "PERPLEXITY_API_KEY": "new-perplexity-key",
    "LITELLM_MASTER_KEY": "new-litellm-key",
    "WEBUI_SECRET_KEY": "new-webui-key"
  }'

# Restart pods to pick up new secrets
kubectl rollout restart deployment litellm -n llm-gateway
kubectl rollout restart deployment openwebui -n llm-gateway
```

### Scale Cluster
```bash
# Edit terraform/eks-cluster/terraform.tfvars
node_desired_size = 3
node_max_size     = 5

# Apply changes
cd terraform/eks-cluster
terraform apply
```

## Future Enhancements

- [x] **Custom guardrails/content filtering** (example implementation included)
- [x] **Automated CloudFlare DNS management** (via API)
- [ ] Prometheus + Grafana observability stack
- [ ] Custom function calling tools
- [ ] RAG with vector database (Pinecone/Weaviate)
- [ ] Cost analytics dashboard
- [ ] Automated API key rotation
- [ ] Advanced content moderation (PII detection, prompt injection prevention)
- [ ] Multi-region deployment
- [ ] OAuth/SSO authentication

## Architecture Decisions

### Why LiteLLM?
- Unified interface for multiple providers
- Built-in rate limiting and caching
- Cost tracking and budgeting
- OpenAI-compatible API

### Why EKS?
- Managed Kubernetes control plane
- IRSA for secure AWS authentication
- Integration with AWS services
- Auto-scaling capabilities

### Why SPOT Instances?
- 50-90% cost savings vs on-demand
- Suitable for stateless workloads
- Multiple instance types for availability

### Why Network Policies?
- Defense-in-depth security
- Zero-trust networking
- Limit blast radius of compromises
- Production best practice

## License

This project is for demonstration and educational purposes.

## Author

Brian Henning
- GitHub: [@henninb](https://github.com/henninb)

## Acknowledgments

- [LiteLLM](https://github.com/BerriAI/litellm) - Universal LLM proxy
- [OpenWebUI](https://github.com/open-webui/open-webui) - Web interface for LLMs
- AWS Bedrock team for managed AI services
