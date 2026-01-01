# LLM Gateway

A production-ready, secure, and cost-optimized LLM gateway deployed on AWS EKS with comprehensive security controls and multi-provider AI model support.

## Overview

LLM Gateway is a unified interface for accessing multiple AI model providers (AWS Bedrock, Perplexity) through a single endpoint. Built with security, cost optimization, and production best practices in mind, it demonstrates enterprise-grade cloud architecture and DevOps practices.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         AWS EKS Cluster                          │
│                                                                   │
│  ┌────────────────────┐          ┌─────────────────────┐        │
│  │   OpenWebUI Pod    │          │   LiteLLM Pod       │        │
│  │  (Web Interface)   │──────────│   (LLM Proxy)       │        │
│  │                    │          │                     │        │
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
    │                │
    └───────┬────────┘
            │
            │
    ┌───────▼────────┐
    │   CloudFlare   │
    │   DNS (Proxy)  │
    └───────┬────────┘
            │
            ▼
    openwebui.bhenning.com
```

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
- **Persistent Storage**: User data and conversations stored in EBS volumes
- **Auto-Scaling**: EKS node group scales based on demand
- **Health Checks**: Kubernetes liveness/readiness probes

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

2. Create `.env` file:
```bash
cat > .env <<EOF
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_REGION=us-east-1
LITELLM_MASTER_KEY=$(openssl rand -hex 32)
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
PERPLEXITY_API_KEY=your-perplexity-key
EOF
```

3. Start the services:
```bash
docker-compose up -d
```

4. Access OpenWebUI at http://localhost:3000

## AWS EKS Deployment

### Step 1: Setup Infrastructure

```bash
# 1. Create ECR repositories
cd terraform/ecr
terraform init
terraform apply

# 2. Build and push Docker images
cd ../..
./tools/build-and-push-ecr.sh

# 3. Create EKS cluster
cd terraform/eks-cluster
terraform init
terraform apply
```

### Step 2: Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name llm-gateway-eks
```

### Step 3: Create Secrets in AWS Secrets Manager

```bash
cd ../eks
make eks-secrets-populate
```

You'll be prompted to enter:
- LITELLM_MASTER_KEY
- WEBUI_SECRET_KEY
- PERPLEXITY_API_KEY

### Step 4: Deploy Applications

```bash
# Update terraform.tfvars with your ACM certificate ARN
vim terraform.tfvars

# Apply EKS application deployment
terraform init
terraform apply
```

### Step 5: Configure DNS

Get the LoadBalancer DNS:
```bash
kubectl get svc openwebui -n llm-gateway
```

Create a CNAME record in CloudFlare:
- Type: CNAME
- Name: openwebui
- Target: [LoadBalancer DNS from above]
- Proxy status: DNS only

## Configuration

### LiteLLM Configuration

Edit `config/litellm_config.yaml` to:
- Add/remove AI models
- Configure rate limits
- Set budget limits
- Customize CORS policies

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
- **AWS Bedrock**: nova-pro, llama3-2-3b, claude-3-5-sonnet, titan-text-express
- **Perplexity**: perplexity-sonar-pro

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

### Automated Test Suite

The project includes comprehensive test scripts to validate LiteLLM deployment and model access:

#### Test Local Deployment

```bash
# Test all models with shell script
./tests/test-models.sh

# Test all models with Python script
python tests/test-litellm-api.py

# Test with custom endpoint
LITELLM_ENDPOINT=http://192.168.1.10:4000 python tests/test-litellm-api.py
```

#### Test Production Deployment

```bash
# Test production endpoint
export LITELLM_MASTER_KEY=your-production-key
./tests/test-production.sh
```

This validates:
- ✅ IRSA authentication (no static AWS keys)
- ✅ Multi-provider access (AWS Bedrock + Perplexity)
- ✅ Zero-trust network policies
- ✅ HTTPS/TLS encryption
- ✅ All 7 configured models

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

## Troubleshooting

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
kubectl get sa litellm-sa -n llm-gateway -o yaml

# Check pod environment
kubectl exec -n llm-gateway -it $(kubectl get pod -n llm-gateway -l app=litellm -o jsonpath='{.items[0].metadata.name}') -- env | grep AWS
```

## Maintenance

### Update Images
```bash
# Build and push new images
./tools/build-and-push-ecr.sh

# Update deployments
cd terraform/eks
terraform apply -var="ecr_image_tag=latest"
```

### Rotate Secrets
```bash
# Update secrets in AWS Secrets Manager
aws secretsmanager update-secret --secret-id llm-gateway/litellm-master-key --secret-string "new-key"

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

- [ ] Prometheus + Grafana observability stack
- [ ] Custom function calling tools
- [ ] RAG with vector database (Pinecone/Weaviate)
- [ ] Cost analytics dashboard
- [ ] Automated API key rotation
- [ ] Content moderation/PII detection
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
