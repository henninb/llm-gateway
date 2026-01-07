# LLM Gateway

A production-ready, secure, and cost-optimized LLM gateway deployed on AWS EKS with comprehensive security controls and multi-provider AI model support.

## Overview

LLM Gateway is a unified interface for accessing multiple AI model providers (AWS Bedrock, Perplexity) through a single endpoint. Built with security, cost optimization, and production best practices in mind, it demonstrates enterprise-grade cloud architecture and DevOps practices.

## Table of Contents

- [Project Structure](#project-structure)
- [Architecture](#architecture)
- [Key Features](#key-features)
- [Prerequisites](#prerequisites)
- [Quick Start - Local Development](#quick-start---local-development)
  - [Available Makefile Commands](#available-makefile-commands)
- [AWS EKS Deployment](#aws-eks-deployment)
- [Configuration](#configuration)
  - [LiteLLM Configuration](#litellm-configuration)
  - [Custom Guardrails](#custom-guardrails-example-implementation)
  - [Known Issues and Patches](#known-issues-and-patches)
  - [Terraform Variables](#terraform-variables)
- [Security Features](#security-features)
- [Cost Breakdown](#cost-breakdown)
- [Usage](#usage)
  - [Arena Mode](#arena-mode-blind-random-model-selection)
  - [Available Models](#available-models)
  - [API Access](#api-access)
- [Testing](#testing)
- [Operations & Monitoring](#operations--monitoring)
  - [Cost Reporting](#cost-reporting)
  - [IAM Security Architecture Report](#iam-security-architecture-report)
  - [Port Forwarding](#port-forwarding-for-local-testing)
  - [DNS Management](#dns-management--verification)
  - [IP Allowlisting](#ip-allowlisting-on-demand-access-control)
  - [ALB Configuration](#alb-configuration)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)
- [Additional Tools and Scripts](#additional-tools-and-scripts)
- [Future Enhancements](#future-enhancements)
- [Architecture Decisions](#architecture-decisions)
- [License](#license)
- [Author](#author)
- [Acknowledgments](#acknowledgments)

## Project Structure

```
llm-gateway/
├── config/                      # LiteLLM configuration and custom guardrails
│   ├── litellm_config.yaml     # Model definitions, guardrails, and LiteLLM settings
│   └── custom_guardrail.py     # Example content filtering implementation
├── patches/                     # LiteLLM bug fixes applied during Docker build
│   └── apply_litellm_fix.py    # Fix for ModifyResponseException streaming bug
├── terraform/                   # Infrastructure as Code
│   ├── ecr/                    # Container registry repositories
│   ├── eks-cluster/            # EKS cluster, VPC, and base infrastructure
│   └── eks/                    # Application deployment (LiteLLM, OpenWebUI)
├── tests/                       # Comprehensive test suites
│   ├── test-guardrails.py      # Pre/post-call content filtering tests
│   ├── test-litellm-models-api.sh  # Model connectivity tests (7 models)
│   ├── test-litellm-models-api.py  # Python version of model tests
│   ├── test-health.sh          # Service health checks
│   ├── test-production.sh      # Production deployment validation
│   └── curl-examples.sh        # Interactive API testing examples
├── tools/                       # Operational and reporting scripts
│   ├── build-and-push-ecr.sh   # Build and push Docker images to ECR
│   ├── setup-cloudflare-dns.sh # Automated DNS setup via CloudFlare API
│   ├── report-aws-costs.sh     # AWS cost reporting (shell version)
│   ├── report-aws-costs.py     # AWS cost reporting (Python, rich output)
│   ├── report-iam-roles.sh     # IAM security architecture report
│   ├── validate-setup.sh       # Validate required tools installed
│   ├── test-cloudflare-restriction.sh  # Test CloudFlare IP restrictions
│   └── verify-cloudflare-ips.sh    # Verify CloudFlare IP ranges
├── Dockerfile                   # LiteLLM container with bug patches
├── Dockerfile.openwebui         # OpenWebUI container configuration
├── docker-compose.yml           # Local development environment
├── Makefile                     # Comprehensive automation commands
├── .secrets.example             # Template for required secrets
├── BUG-LITELLM-STREAMING.md    # Documentation of LiteLLM streaming bug and patch
├── BUG-FORMAT-MISMATCH.md      # Explanation of JSON vs SSE response formats
├── CLOUDFLARE-CERT.md          # CloudFlare Origin Certificate setup guide
└── README.md                    # This file (project documentation)
```

**Terraform Modules:**
- **`terraform/ecr/`**: Creates ECR repositories for LiteLLM and OpenWebUI images (deployed first)
- **`terraform/eks-cluster/`**: Provisions EKS cluster, VPC, subnets, NAT gateway, IAM roles, and base infrastructure
- **`terraform/eks/`**: Deploys applications (LiteLLM, OpenWebUI), ALB ingress, security groups, network policies, and IRSA roles

**Key Files:**
- **`.secrets`**: Your local secrets file (create from `.secrets.example`, never commit to git)
- **`.secrets.example`**: Template for required secrets with instructions
- **`.gitignore`**: Protects sensitive files including `.secrets`, `*.pem` (CloudFlare certificates), and Terraform state
- **`Makefile`**: Comprehensive automation for all operations (run `make help` to see all commands)
- **`requirements.txt`**: Python dependencies for LiteLLM patches

**Documentation:**
- **`README.md`**: This file - comprehensive project documentation
- **`CLOUDFLARE-CERT.md`**: Guide for CloudFlare Origin Certificate setup and proxy mode
- **`BUG-LITELLM-STREAMING.md`**: LiteLLM streaming bug details and patch explanation
- **`BUG-FORMAT-MISMATCH.md`**: JSON dict vs SSE response format differences

**Legacy/Reference:**
- **`proxy.py`**: Legacy proxy solution for guardrail error handling (superseded by LiteLLM passthrough mode)

**Note:** The project now uses LiteLLM's native `on_flagged_action: "passthrough"` mode for guardrail error handling, making the legacy proxy solution unnecessary. The proxy.py file is kept for reference.

## Architecture

### Production (AWS EKS)

![AWS EKS Architecture](architecture.png)

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
- **EKS**: Exposed via ALB with HTTPS and CloudFlare DNS
- **Local**: Direct localhost access (no external exposure)
- **Both**: Same architecture - LiteLLM with native passthrough guardrails

## Key Features

### Security
- **Zero-Trust Networking**: Kubernetes NetworkPolicies enforce pod-to-pod isolation
- **Flexible Access Control**: Choose between ISP-based restrictions or CloudFlare proxy mode
  - **ISP-Based (Default)**: ALB security groups restrict HTTPS to authorized IP ranges (FREE)
  - **CloudFlare Proxy (Optional)**: DDoS protection, WAF, bot detection, and edge caching (see `CLOUDFLARE-CERT.md`)
- **On-Demand IP Allowlisting**: Add temporary IP/CIDR access with `make eks-allow-ip`
- **IRSA (IAM Roles for Service Accounts)**: AWS service authentication without static credentials
- **Non-Root Containers**: All containers run as unprivileged users (UID 1000)
- **HTTPS/TLS**: ACM certificate with ALB SSL termination (standard or CloudFlare Origin Certificate)
- **AWS Metadata Service Blocking**: Prevents SSRF attacks
- **Rate Limiting**: Built-in request throttling (ENABLE_RATE_LIMIT=true)
- **Input Validation**: Parameter sanitization and validation (LITELLM_DROP_PARAMS=true)

### Cost Optimization
- **SPOT Instances**: 50-90% cost savings on compute (t3.medium, t3a.medium, t2.medium)
- **Single NAT Gateway**: ~$32/month savings vs multi-AZ NAT
- **Resource Quotas**: Prevent resource waste
- **ECR for Container Images**: Eliminates Docker Hub rate limits

### Multi-Provider Support
- **AWS Bedrock Nova**: nova-micro, nova-lite, nova-pro
- **AWS Bedrock Llama**: llama3-2-1b, llama3-2-3b
- **Perplexity**: perplexity-sonar, perplexity-sonar-pro
- **Unified API**: OpenAI-compatible endpoint for all models

### Features
- **Arena Mode**: Blind random model selection for unbiased testing (currently disabled)
  - If enabled, would use 3 models: nova-lite, nova-pro, llama3-2-3b
  - OpenWebUI's Arena Mode randomly selects ONE model per request (not simultaneous multi-model comparison)
  - Models are hidden during conversation for unbiased evaluation
  - Configured via `ENABLE_EVALUATION_ARENA_MODELS` and `EVALUATION_ARENA_MODELS` environment variables
- **Custom Guardrails**: Extensible content filtering system with streaming support (example implementation included)
- **Persistent Storage**: User data and conversations stored in EBS volumes
- **Auto-Scaling**: EKS node group scales based on demand
- **Health Checks**: Kubernetes liveness/readiness probes
- **Automated DNS Management**: CloudFlare API integration for DNS-only setup
- **CloudFlare Proxy Ready**: Origin certificate workflow documented in `CLOUDFLARE-CERT.md`

## Prerequisites

### Local Development
- Docker and Docker Compose
- Python 3 with pip3 (for generating Fernet keys)
- AWS credentials with Bedrock access
- Perplexity API key

### AWS EKS Deployment
- Terraform >= 1.0
- AWS CLI configured
- kubectl
- Python 3 with pip3 (for generating Fernet keys)
- AWS account with permissions for:
  - EKS, VPC, EC2, IAM, ACM, Secrets Manager, ECR

## Quick Start - Local Development

1. Clone the repository:
```bash
git clone https://github.com/henninb/llm-gateway.git
cd llm-gateway
```

2. Install Python cryptography package (required for Fernet key generation):
```bash
pip3 install cryptography
```

3. Create `.secrets` file (template available in `.secrets.example`):
```bash
# Generate secure random keys
LITELLM_KEY=$(openssl rand -hex 32)
WEBUI_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")

# Create .secrets file
cat > .secrets <<EOF
# Required for AWS Bedrock access
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_REGION=us-east-1

# Required for LiteLLM and OpenWebUI
LITELLM_MASTER_KEY=${LITELLM_KEY}
WEBUI_SECRET_KEY=${WEBUI_KEY}

# Required for Perplexity models
PERPLEXITY_API_KEY=your-perplexity-key

# Optional: For automated CloudFlare DNS management
# Get from: https://dash.cloudflare.com/profile/api-tokens
# Or use Global API Key from: https://dash.cloudflare.com/profile/api-tokens
CF_API_KEY=your-cloudflare-api-key
CF_EMAIL=your-cloudflare-email
EOF
```

4. Start the services:
```bash
make local-deploy
```

5. Access OpenWebUI at http://localhost:3000

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
make ecr-verify           # Verify ECR images match local builds

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
make eks-verify-cloudflare-dns # Auto-setup/verify CloudFlare DNS (currently in proxy mode)

# EKS Security Group Management (ISP and CloudFlare)
make eks-list-ips                                             # List all IPs in both security groups
make eks-allow-ip IP=1.2.3.4/32 SG=isp DESC="Office"         # Add IP to ISP security group
make eks-allow-ip IP=1.2.3.4/32 SG=cloudflare DESC="Testing" # Add IP to CloudFlare security group
make eks-revoke-ip IP=1.2.3.4/32 SG=isp                      # Remove IP from ISP security group
make eks-revoke-ip IP=1.2.3.4/32 SG=cloudflare               # Remove IP from CloudFlare security group
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

# 2b. Verify images match (recommended)
make ecr-verify

# 3. Create EKS cluster
make eks-cluster-init
make eks-cluster-apply
```

### Step 2: Configure kubectl

```bash
make eks-cluster-kubeconfig
```

### Step 3: Create Secrets in AWS Secrets Manager

**Required secrets:**
- `PERPLEXITY_API_KEY` - API key from Perplexity (get from https://www.perplexity.ai/settings/api)
- `LITELLM_MASTER_KEY` - Authentication key for LiteLLM API (generate with `openssl rand -hex 32`)
- `WEBUI_SECRET_KEY` - Fernet encryption key for OpenWebUI (generate with the Python command below)

**Setup process:**

1. Create a `.secrets` file in the project root (use `.secrets.example` as template):
```bash
# Generate secure keys
LITELLM_KEY=$(openssl rand -hex 32)
WEBUI_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")

# Create .secrets file
cat > .secrets <<EOF
# AWS Credentials (for local Bedrock testing)
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_REGION=us-east-1

# Required for LiteLLM and OpenWebUI
LITELLM_MASTER_KEY=${LITELLM_KEY}
WEBUI_SECRET_KEY=${WEBUI_KEY}

# Required for Perplexity models
PERPLEXITY_API_KEY=your-perplexity-key

# Optional: CloudFlare API credentials for automated DNS
CF_API_KEY=your-cloudflare-api-key
CF_EMAIL=your-cloudflare-email
EOF
```

2. Populate AWS Secrets Manager (automatically creates secret if missing):
```bash
make eks-secrets-populate
```

This command:
- Reads secrets from your `.secrets` file
- Creates the AWS Secrets Manager secret `llm-gateway/api-keys` (if it doesn't exist)
- Stores all three required keys in a single JSON secret
- Validates that all required keys are present

**Important:** AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) are only needed for local testing. In EKS, pods use IRSA (IAM Roles for Service Accounts) to access AWS Bedrock without static credentials.

### Step 4: Request ACM Certificate

Request an SSL/TLS certificate from AWS Certificate Manager for your domain:

```bash
# Request certificate for your domain
aws acm request-certificate \
  --domain-name openwebui.bhenning.com \
  --validation-method DNS \
  --region us-east-1
```

After requesting, you'll need to add DNS validation records to your DNS provider:

```bash
# Get the validation CNAME records
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:YOUR_ACCOUNT:certificate/YOUR_CERT_ID \
  --region us-east-1
```

Add the CNAME validation record to your DNS provider (CloudFlare, Route53, etc.) and wait approximately 5-10 minutes for the certificate to be issued.

Verify certificate is issued:
```bash
# List certificates and check status
aws acm list-certificates --region us-east-1

# Should show Status: "ISSUED"
```

Save the certificate ARN for the next step.

### Step 5: Deploy Applications

```bash
# Update terraform.tfvars with your ACM certificate ARN (from Step 4)
vim terraform/eks/terraform.tfvars

# Apply EKS application deployment
make eks-init
make eks-apply
```

### Step 6: Configure DNS

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

1. Get the ALB DNS name:
```bash
kubectl get ingress openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

2. Create a CNAME record in CloudFlare:
   - Type: CNAME
   - Name: openwebui (or your subdomain)
   - Target: [ALB DNS from step 1]
   - Proxy status: Proxied (orange cloud icon - `proxied: true`)
   - **Note:** Requires CloudFlare Origin Certificate - see CLOUDFLARE-CERT.md

3. Verify configuration:
```bash
dig +short openwebui.bhenning.com
curl -I https://openwebui.bhenning.com
```

### Step 7: Verify DNS and HTTPS

Verify that your domain resolves and HTTPS works:

```bash
# Verify DNS resolves to ALB
dig +short openwebui.bhenning.com

# Test HTTPS connectivity
curl -I https://openwebui.bhenning.com
```

**Expected results:**
- DNS should resolve to CloudFlare IPs (104.x.x.x, 172.x.x.x)
- HTTPS should return HTTP 200 OK with CloudFlare headers (cf-ray)

#### CloudFlare Proxy Mode (Currently Enabled)

CloudFlare is currently configured in **proxy mode** (`proxied: true`), which provides:
- ✅ **DDoS protection and WAF** - CloudFlare's Layer 7 attack mitigation
- ✅ **Edge caching** - Static assets cached at 300+ data centers worldwide
- ✅ **Bot detection and rate limiting** - Automatic bot management
- ✅ **Geo-restriction capabilities** - Control access by country/region
- ✅ **Hidden origin** - ALB hostname not exposed to public
- ✅ **HTTP/3 and Brotli compression** - Modern protocol support
- ✅ **SSL/TLS encryption** - End-to-end encryption with CloudFlare Origin Certificates

**Current Architecture:**
```
Client → CloudFlare Edge (Universal SSL) → ALB (Origin Certificate) → EKS Pods
```

**Active Configuration:**
- **Certificate:** CloudFlare Origin Certificate (15-year validity)
- **Security Groups:** CloudFlare security group (allows CloudFlare IP ranges)
- **SSL/TLS Mode:** Full (strict) - validates origin certificate
- **Proxy Status:** Enabled (`proxied: true`)

**To disable CloudFlare proxy mode (switch to DNS-only):**

If you need to switch back to direct ALB access without CloudFlare protection:

1. **Switch security groups** back to ISP-restricted mode:
   - Update `terraform/eks/openwebui.tf` line 229: use `aws_security_group.isp_restricted.id`
   - Update `terraform/eks/isp-security-group.tf` line 65: use `aws_security_group.isp_restricted.id`
   - Apply changes: `cd terraform/eks && terraform apply`

2. **Disable CloudFlare proxy** in CloudFlare Dashboard:
   - Go to DNS → Records
   - Click on openwebui CNAME record
   - Disable proxy (gray cloud icon)

3. **Optional:** Switch back to AWS-issued ACM certificate (not required but cleaner)

See `CLOUDFLARE-CERT.md` for complete setup documentation if you need to set this up from scratch.

**Important Notes:**
- CloudFlare proxy requires CloudFlare Origin Certificates (ALB hostname doesn't match domain)
- Must update **both** ALB and worker node security groups or health checks will fail (HTTP 522 errors)
- Allow 30-60 seconds for CloudFlare edge propagation when toggling proxy mode
- See `CLOUDFLARE-CERT.md` troubleshooting section for common issues

## Configuration

### LiteLLM Configuration

Edit `config/litellm_config.yaml` to:
- Add/remove AI models
- Configure rate limits
- Set budget limits
- Customize CORS policies

### Custom Guardrails (Example Implementation)

The project includes a **demonstration** of custom content filtering using LiteLLM's guardrails system. This example blocks specific content patterns in both user inputs and model outputs while preventing chat context corruption.

**Example guardrail: "Duckies and Bunnies Detector"**

The included example (`config/custom_guardrail.py` - `DuckiesBunniesGuardrail` class) demonstrates a playful but fully functional content filter that:
- **Blocks mentions of duckies, bunnies, ducks, and rabbits** in both user input and LLM output
- Uses regex patterns: `\bduck|ducky|duckies\b` and `\bbunny|bunnies\b`
- Returns friendly error message: "⚠️ BLOCKED: Your message mentions duckies or bunnies. Discussions about cute animals may cause excessive happiness and distraction."
- Demonstrates enterprise-grade filtering patterns that can be adapted for real use cases (PII, prompt injection, compliance)

**Key features** (`config/custom_guardrail.py`):
- Blocks user messages containing specific keywords/patterns (pre_call hook)
- Blocks LLM responses containing prohibited content (post_call hook)
- Sanitizes conversation history to prevent bypass attempts
- Returns user-friendly error messages via passthrough mode
- Works identically in both local (Docker) and EKS deployments

**How it works:**
1. **Pre-call hook**: Checks incoming user messages before sending to LLM
2. **History sanitization**: Removes previously blocked message pairs from context
3. **Conversation validation**: Ensures proper message structure (user/assistant alternation)
4. **Streaming fix**: Forces stream=false when stream=true detected (LiteLLM limitation workaround)
5. **Post-call hook**: Filters LLM responses for prohibited content
6. **Passthrough mode**: Returns HTTP 200 with violation message (prevents UI context corruption)

**Technical Details:**
- Uses `ModifyResponseException` with `on_flagged_action: "passthrough"`
- Includes patch for LiteLLM v1.80.11 streaming bug (see `LITELLM-BUG.md`)
- Works around LiteLLM streaming limitation: post_call hooks don't execute for streaming responses
- Automatically forces non-streaming mode to enable output filtering
- Maintains chat context integrity across both local and production environments

**Configure in** `config/litellm_config.yaml`:
```yaml
guardrails:
  - guardrail_name: "duckies-bunnies-detector"  # Current example implementation
    litellm_params:
      guardrail: custom_guardrail.DuckiesBunniesGuardrail
      mode: ["pre_call", "post_call"]  # Filter both input and output
      default_on: true
      on_flagged_action: "passthrough"  # Return 200 with error message
```

**Customize the example for your use case:**
1. Edit `config/custom_guardrail.py`
2. Rename `DuckiesBunniesGuardrail` to your use case (e.g., `PIIDetector`, `PromptInjectionFilter`)
3. Modify the `patterns` list with your content rules (PII, profanity, company secrets, etc.)
4. Adjust blocking logic in `async_pre_call_hook()` and `async_post_call_success_hook()`
5. Update guardrail name and class in `config/litellm_config.yaml`
6. Redeploy: `make local-deploy` or `make eks-apply`

**Note:** The "duckies and bunnies" example is intentionally playful to demonstrate the filtering system without blocking real content during testing. Replace with production-appropriate rules for your deployment.

**Test the duckies and bunnies guardrail:**
```bash
# Run comprehensive guardrail test suite
make test-guardrails

# Or run directly
python3 tests/test-guardrails.py

# Tests verify (6 tests per model, 12 total):
# PRE_CALL TESTS:
# - Direct blocking of "duckies" and "bunnies" in user input
# - Bypass prevention via history sanitization (removes prior blocked messages)
# - Normal conversations work unaffected (no false positives)
# POST_CALL TESTS:
# - LLM output filtering (blocks responses containing "duck", "bunny", etc.)
# - LLM output filtering (streaming mode with stream=false forcing)
# - Indirect bypass prevention (blocks response to "what is bird that quacks?")
```

**Example test output:**
```
PRE_CALL TESTS (Input Filtering)
✅ PASS: Direct mention blocked (200 OK with BLOCKED message)
✅ PASS: Bypass prevented (history sanitized)
✅ PASS: Normal conversation works

POST_CALL TESTS (Output Filtering)
✅ PASS: LLM output blocked (post_call hook working)
✅ PASS: LLM output blocked in streaming mode (stream=false forcing)
✅ PASS: Indirect bypass blocked (post_call caught "duck" in response)

Model 'llama3-2-3b' Results: 6/6 tests passed
🎉 All tests passed! (12/12)
```

This example implementation demonstrates enterprise-grade content filtering patterns that can be adapted for:
- PII detection and redaction
- Prompt injection prevention
- Company policy enforcement
- Compliance requirements (GDPR, HIPAA, etc.)
- Output safety and content moderation

### Known Issues and Patches

The project includes patches for known LiteLLM bugs that are applied automatically during Docker build:

#### LiteLLM Streaming Bug (v1.80.11)

**Issue:** LiteLLM crashes with 500 Internal Server Error when a guardrail blocks content in streaming mode (`stream=true`) with `on_flagged_action: "passthrough"`.

**Error:** `AttributeError: 'NoneType' object has no attribute 'model_call_details'`

**Root cause:** The `litellm_logging_obj` is `None` when `ModifyResponseException` is raised in the pre-call hook, causing `CustomStreamWrapper` to crash.

**Our fix:** `patches/apply_litellm_fix.py` initializes the missing `litellm_logging_obj` before creating the streaming wrapper.

**Applied:** Automatically during `docker build` in `Dockerfile`

**Documentation:** See `BUG-LITELLM-STREAMING.md` for complete details on the bug, reproduction steps, and when to remove the patch.

**Current status:** Unresolved upstream as of January 2026. LiteLLM image is pinned to specific SHA256 hash until fixed.

#### Response Format Differences

**Issue:** LiteLLM returns different response formats depending on streaming mode - JSON dict for `stream=false`, SSE chunks for `stream=true`.

**Impact:** Content filtering hooks (`async_post_call_success_hook`) only execute for non-streaming responses, making output filtering impossible in streaming mode.

**Solution:** Force `stream=false` globally via guardrail pre-call hook to ensure content filtering works reliably.

**Documentation:** See `BUG-FORMAT-MISMATCH.md` for detailed explanation of JSON vs SSE response formats.

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
- ALB SSL termination with TLS 1.3
- Automatic certificate renewal

### Rate Limiting & Input Validation
- **ENABLE_RATE_LIMIT=true**: Built-in request throttling per user
- **LITELLM_DROP_PARAMS=true**: Parameter sanitization and validation
- Maximum token limits enforced
- Protection against API abuse and cost overruns

## Cost Breakdown

Estimated monthly costs (us-east-1, default configuration with 1 node):
- EKS Control Plane: ~$73
- EC2 SPOT Instances (1x t3.medium): ~$8-15
- NAT Gateway: ~$32
- EBS Volumes: ~$8
- Application Load Balancer: ~$16-22
- Data Transfer: Variable

**Total: ~$137-150/month**

Cost optimizations implemented:
- Single NAT gateway vs multi-AZ (~$32/month savings)
- SPOT instances vs on-demand (~$15-30/month savings per node)
- ECR vs Docker Hub (avoids rate limits)
- Default 1 node (can scale to 2+ for high availability)

## Usage

### Access the UI
Navigate to: https://openwebui.bhenning.com

### Arena Mode (Blind Random Model Selection)

**Current Status**: Arena Mode is **currently disabled** (`ENABLE_EVALUATION_ARENA_MODELS=false`).

OpenWebUI's Arena Mode provides **blind testing** by randomly selecting ONE model per request without revealing which model is responding. This is NOT a simultaneous multi-model comparison - instead, it's designed for unbiased evaluation across multiple conversations.

**How it works:**
1. Select "Arena Model" from the model dropdown in OpenWebUI
2. Send your message - Arena Mode randomly picks one of the three configured models
3. The model identity remains hidden during the conversation
4. Use "Regenerate" to try different models (each regeneration randomly selects again)
5. Models are hidden to prevent bias in your evaluation

**Configured models** (if enabled):
- `nova-lite` - AWS Bedrock Nova Lite (fastest, most cost-effective)
- `nova-pro` - AWS Bedrock Nova Pro (balanced performance)
- `llama3-2-3b` - Meta Llama 3.2 3B (open-source model)

**Configuration:**

Arena Mode is configured via environment variables in `Dockerfile.openwebui` and `docker-compose.yml`:

```bash
# Enable/Disable Arena Mode
ENABLE_EVALUATION_ARENA_MODELS=false  # Currently disabled

# Configure which models to use (if enabled)
EVALUATION_ARENA_MODELS='["nova-lite","nova-pro","llama3-2-3b"]'

# Allow OpenWebUI admin settings to persist across restarts
ENABLE_PERSISTENT_CONFIG=true  # Admin UI changes are saved to database
```

**Important Streaming Behavior:**

OpenWebUI **always forces `stream=true`** for ANY model used in the Arena Mode configuration, regardless of the model's streaming settings in LiteLLM. This means:
- Arena models will always use streaming responses
- LiteLLM's `stream` configuration for these models is ignored
- This is OpenWebUI's default behavior and cannot be overridden
- Non-arena models respect LiteLLM's streaming configuration

**Note**: With `ENABLE_PERSISTENT_CONFIG=true`, changes made in the OpenWebUI admin panel are saved to the database and persist across restarts. Environment variables set initial defaults but can be overridden through the UI.

### Available Models
- **AWS Bedrock Nova**: nova-micro, nova-lite, nova-pro
- **AWS Bedrock Llama**: llama3-2-1b, llama3-2-3b
- **Perplexity**: perplexity-sonar, perplexity-sonar-pro

### API Access

**Important**: LiteLLM is not exposed to the internet for security reasons. To access the API, you must first set up port-forwarding:

```bash
# Terminal 1: Start port-forwarding
make eks-port-forward
# or for local development:
make local-port-forward

# Terminal 2: Access LiteLLM via OpenAI-compatible API
curl http://localhost:4000/v1/chat/completions \
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

The test suite validates (6 tests per model, 12 total):

**PRE_CALL TESTS (Input Filtering):**
1. **Direct blocking**: User input with prohibited content is blocked
2. **Bypass prevention**: Conversation history sanitization prevents circumvention
3. **Normal operation**: Regular conversations work without interference

**POST_CALL TESTS (Output Filtering):**
4. **Output filtering (non-streaming)**: LLM responses with prohibited content are blocked
5. **Output filtering (streaming)**: Validates streaming bug fix and stream=false forcing
6. **Indirect bypass prevention**: Catches responses to indirect queries ("what is bird that quacks?")

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
✅ PASS: LLM output blocked in streaming mode (stream=false forcing)
✅ PASS: Indirect bypass blocked (post_call caught "duck" in response)

Model 'llama3-2-3b' Results: 6/6 tests passed
🎉 All tests passed! (12/12)
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
- ✅ Creates CNAME → ALB hostname
- ✅ Sets TTL to auto (1 = automatic)
- ✅ Preserves current proxy mode setting (DNS setup only, does not change proxy status)
- ✅ Validates with both local DNS and CloudFlare DNS (1.1.1.1)

**Note:** This command manages DNS records only. CloudFlare proxy mode (`proxied: true/false`) is configured separately. Currently, proxy mode is **enabled** for production use. See CloudFlare Proxy Mode section above for current configuration.

**Requirements:**
- `CF_API_KEY` and `CF_EMAIL` in `.secrets` file
- See Step 6 in deployment guide for credential setup

#### Manual DNS Check

For manual verification without CloudFlare API:

```bash
# Check ALB hostname
kubectl get ingress openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Verify DNS resolves
dig +short openwebui.bhenning.com

# Test HTTPS
curl -I https://openwebui.bhenning.com
```

### IP Allowlisting (On-Demand Access Control)

The project includes on-demand IP allowlisting for temporary access to the application with support for **both ISP and CloudFlare security groups**. This is useful for:
- Granting access to specific users or offices
- Allowing access from dynamic IPs (home networks, mobile devices)
- Temporary access for contractors or partners
- Testing from different networks

**Choose the right security group:**
- **ISP** (`SG=isp`): Use when CloudFlare proxy is DISABLED (direct ALB access)
- **CloudFlare** (`SG=cloudflare`): Use when CloudFlare proxy is ENABLED (currently active)

**List all security group rules:**
```bash
make eks-list-ips
# Shows both ISP and CloudFlare security groups with current rules
```

**Add an IP/CIDR to the allowlist:**
```bash
# Add to ISP security group (for direct ALB access)
make eks-allow-ip IP=1.2.3.4 SG=isp DESC="John's home office"

# Add to CloudFlare security group (for CloudFlare proxy mode)
make eks-allow-ip IP=1.2.3.4 SG=cloudflare DESC="Testing from home"

# Add a CIDR range
make eks-allow-ip IP=192.168.1.0/24 SG=isp DESC="Office network"

# IP without /32 will be automatically converted to /32
make eks-allow-ip IP=1.2.3.4 SG=isp DESC="Alice laptop"  # Becomes 1.2.3.4/32

# SG parameter defaults to 'isp' if not specified
make eks-allow-ip IP=1.2.3.4 DESC="Defaults to ISP"
```

**Remove an IP/CIDR from the allowlist:**
```bash
# Remove from ISP security group
make eks-revoke-ip IP=1.2.3.4/32 SG=isp

# Remove from CloudFlare security group
make eks-revoke-ip IP=1.2.3.4/32 SG=cloudflare

# Revoke a CIDR range
make eks-revoke-ip IP=192.168.1.0/24 SG=isp

# SG parameter defaults to 'isp' if not specified
make eks-revoke-ip IP=1.2.3.4/32
```

**List all allowed IPs:**
```bash
make eks-list-ips
```

This displays both security groups showing:
- **ISP Security Group**: Used when CloudFlare proxy is disabled (direct ALB access)
  - Shows all CIDR blocks allowed for HTTPS (443) access
  - Includes T-Mobile ISP base range plus any custom IPs
- **CloudFlare Security Group**: Used when CloudFlare proxy is enabled (currently active)
  - Shows all CloudFlare IP ranges (15 IPv4 + 7 IPv6 = 22 total ranges)
  - CloudFlare IPs are auto-managed by Terraform
  - Any custom IPs you've added for testing

**How it works:**
1. The commands retrieve both ISP and CloudFlare security group IDs from Terraform state
2. You specify which security group to modify with `SG=isp` or `SG=cloudflare`
3. Adds/removes ingress rules for HTTPS (port 443) with the specified CIDR and description
4. Changes take effect immediately (no deployment required)
5. Rules are managed via AWS EC2 Security Group API

**Important Notes:**
- Use **ISP security group** when CloudFlare proxy is disabled (DNS-only mode)
- Use **CloudFlare security group** when CloudFlare proxy is enabled (proxy mode)
- Currently using CloudFlare security group (proxy mode active)
- Base ISP and CloudFlare IP ranges are managed through Terraform
- On-demand IPs are added via Makefile for flexibility

### ALB Configuration

The ALB is configured with:
- **HTTPS listener on port 443** with ACM certificate
- **TLS 1.3 security policy** (ELBSecurityPolicy-TLS13-1-2-2021-06)
- **Target type: IP** - Routes directly to pod IPs
- **Health checks** - Validates pod availability before routing traffic
- **Security groups** - Restricts access to authorized IP ranges (ISP-based + on-demand allowlist)

To view ALB configuration:

```bash
# Get ALB ARN
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-llmgatew-openwebu`)].LoadBalancerArn' \
  --output text)

# View listeners
aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN

# View target group health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --query 'TargetGroups[?contains(TargetGroupName, `k8s-llmgatew-openweb`)].TargetGroupArn' \
    --output text)
```

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

You can access the site directly using the ALB hostname:

```bash
# Get ALB hostname
ALB=$(kubectl get ingress openwebui -n llm-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Access directly (note: certificate will show hostname mismatch warning)
curl -k https://$ALB
# Or in browser: https://k8s-llmgatew-openwebu-5d1360aa5a-1101013781.us-east-1.elb.amazonaws.com
```

**Note:** Direct ALB access will show a certificate warning because the ACM certificate is for your domain (openwebui.bhenning.com), not the ALB hostname.

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

# Check Ingress
kubectl describe ingress openwebui -n llm-gateway

# Check ALB listener certificate
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-llmgatew-openwebu`)].LoadBalancerArn' \
  --output text)
aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN
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

# Verify images match (recommended)
make ecr-verify

# Update deployments
make eks-apply
```

### Verify ECR Images

After building and pushing images to ECR, you can verify that your remote images match your local builds by comparing image digests:

```bash
# Verify ECR images match local builds
make ecr-verify
```

This command:
1. Compares local Docker image digests with ECR remote digests
2. Verifies both LiteLLM and OpenWebUI images
3. Returns exit code 0 if all match, exit code 1 if any mismatch
4. Useful for CI/CD pipelines and deployment verification

**Example output:**
```
========================================
  ECR Image Verification
========================================
Local LiteLLM digest:
  sha256:8d2fd01af90747a15b4adc2e90dcd231faf483f3ac7aff1329e0ad16f9b1d321

ECR LiteLLM digest:
  sha256:8d2fd01af90747a15b4adc2e90dcd231faf483f3ac7aff1329e0ad16f9b1d321

✓ LiteLLM images MATCH

Local OpenWebUI digest:
  sha256:f6c36a559ba2c2e0c9b37458c0820821b59677a1bfdc72297c7f492b406d92ec

ECR OpenWebUI digest:
  sha256:f6c36a559ba2c2e0c9b37458c0820821b59677a1bfdc72297c7f492b406d92ec

✓ OpenWebUI images MATCH

========================================
  ✓ All images verified successfully!
========================================
```

### Rotate Secrets
```bash
# Generate new keys
NEW_LITELLM_KEY=$(openssl rand -hex 32)
NEW_WEBUI_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")

# Update secrets in AWS Secrets Manager (all keys stored in one secret)
aws secretsmanager put-secret-value \
  --secret-id llm-gateway/api-keys \
  --secret-string "{
    \"PERPLEXITY_API_KEY\": \"your-new-perplexity-key\",
    \"LITELLM_MASTER_KEY\": \"${NEW_LITELLM_KEY}\",
    \"WEBUI_SECRET_KEY\": \"${NEW_WEBUI_KEY}\"
  }"

# Restart pods to pick up new secrets
kubectl rollout restart deployment litellm -n llm-gateway
kubectl rollout restart deployment openwebui -n llm-gateway
```

**Note:** `WEBUI_SECRET_KEY` must be a valid Fernet key (base64-encoded 32-byte key). Generate with:
```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
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

## Additional Tools and Scripts

The `tools/` directory contains helper scripts for operations, reporting, and automation:

### Operational Scripts

- **`validate-setup.sh`**: Validates that all required tools are installed (terraform, aws-cli, kubectl, docker, etc.)
  ```bash
  make validate-setup
  # Or run directly: ./tools/validate-setup.sh
  ```

- **`build-and-push-ecr.sh`**: Builds Docker images and pushes to ECR with specified tag
  ```bash
  make ecr-build-push  # Uses 'latest' tag
  # Or: ./tools/build-and-push-ecr.sh v1.2.3
  ```

- **`setup-cloudflare-dns.sh`**: Automated DNS setup via CloudFlare API
  ```bash
  make eks-verify-cloudflare-dns
  # Or: ./tools/setup-cloudflare-dns.sh openwebui.example.com
  ```

### Reporting Scripts

- **`report-aws-costs.py`**: Python cost reporting with rich formatting and colors
  ```bash
  make aws-costs-py
  # Or: AWS_REGION=us-east-1 python3 tools/report-aws-costs.py
  ```

- **`report-aws-costs.sh`**: Shell script version of cost reporting (no dependencies)
  ```bash
  make aws-costs
  # Or: AWS_REGION=us-east-1 ./tools/report-aws-costs.sh
  ```

- **`report-iam-roles.sh`**: Displays IAM roles, IRSA configuration, and security architecture
  ```bash
  make iam-report
  # Or: CLUSTER_NAME=llm-gateway-eks AWS_REGION=us-east-1 ./tools/report-iam-roles.sh
  ```

### Security Verification Scripts

- **`verify-cloudflare-ips.sh`**: Verifies that ALB security group contains current CloudFlare IP ranges
  ```bash
  ./tools/verify-cloudflare-ips.sh
  ```

- **`test-cloudflare-restriction.sh`**: Tests ALB accessibility from different IP ranges
  ```bash
  ./tools/test-cloudflare-restriction.sh
  ```

**Note:** All `make` targets source `.secrets` automatically if the file exists, making it easy to use CloudFlare API credentials or other environment-specific settings.

## Future Enhancements

- [x] **Custom guardrails/content filtering** (example implementation included)
- [x] **Automated CloudFlare DNS management** (via API)
- [x] **On-demand IP allowlisting** (via Makefile targets)
- [x] **Comprehensive testing suite** (health, models, guardrails)
- [x] **Cost and IAM reporting tools** (Python and shell versions)
- [x] **LiteLLM bug patches** (streaming and response format issues)
- [ ] Prometheus + Grafana observability stack
- [ ] Custom function calling tools
- [ ] RAG with vector database (Pinecone/Weaviate)
- [ ] Cost analytics dashboard with time-series graphs
- [ ] Automated API key rotation
- [ ] Advanced content moderation (PII detection, prompt injection prevention)
- [ ] Multi-region deployment with global load balancing
- [ ] OAuth/SSO authentication (Keycloak, Auth0, AWS Cognito)

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
