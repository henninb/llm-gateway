#!/bin/sh

# IAM Roles Report for LLM Gateway
# Displays IAM roles created for the project with explanations

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-llm-gateway-eks}"

# Helper function to print section headers
print_header() {
    printf "\n"
    printf "%b========================================%b\n" "$CYAN" "$NC"
    printf "%b%s%b\n" "$CYAN" "$1" "$NC"
    printf "%b========================================%b\n" "$CYAN" "$NC"
}

# Helper function to print role details
print_role() {
    role_name="$1"
    purpose="$2"
    security_note="$3"

    printf "%b🔐 Role: %s%b\n" "$GREEN" "$role_name" "$NC"
    printf "%b   Purpose: %s%b\n" "$BLUE" "$purpose" "$NC"

    if [ -n "$security_note" ]; then
        printf "%b   Security: %s%b\n" "$YELLOW" "$security_note" "$NC"
    fi
    printf "\n"
}

# Start report
printf "%b========================================%b\n" "$MAGENTA" "$NC"
printf "%b   IAM ROLES REPORT%b\n" "$MAGENTA" "$NC"
printf "%b   LLM Gateway Project%b\n" "$MAGENTA" "$NC"
printf "%b   Cluster: %s%b\n" "$MAGENTA" "$CLUSTER_NAME" "$NC"
printf "%b   Region: %s%b\n" "$MAGENTA" "$AWS_REGION" "$NC"
printf "%b========================================%b\n" "$MAGENTA" "$NC"

# Verify AWS credentials
printf "\n%bVerifying AWS credentials...%b\n" "$CYAN" "$NC"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    printf "%b✗ Authentication failed%b\n" "$RED" "$NC"
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
printf "%b✓ Authenticated as account: %s%b\n" "$GREEN" "$ACCOUNT_ID" "$NC"

# =============================================================================
# SECTION 1: EKS CLUSTER MANAGEMENT ROLES
# =============================================================================
print_header "1. EKS CLUSTER MANAGEMENT ROLES"

printf "%bThese roles allow AWS EKS to manage the Kubernetes control plane and worker nodes.%b\n\n" "$YELLOW" "$NC"

# EKS Cluster Role
CLUSTER_ROLE="${CLUSTER_NAME}-cluster-role"
if aws iam get-role --role-name "$CLUSTER_ROLE" >/dev/null 2>&1; then
    print_role "$CLUSTER_ROLE" \
        "Allows EKS service to manage cluster resources (networking, load balancers, etc.)" \
        "Trusted by eks.amazonaws.com service principal"

    printf "   Attached Policies:\n"
    aws iam list-attached-role-policies --role-name "$CLUSTER_ROLE" --query 'AttachedPolicies[*].PolicyName' --output text | tr '\t' '\n' | while IFS= read -r policy; do
        if [ -n "$policy" ]; then
            printf "     • %s\n" "$policy"
        fi
    done
    printf "\n"
else
    printf "%b⚠ Role not found: %s%b\n" "$YELLOW" "$CLUSTER_ROLE" "$NC"
    printf "   This role will be created when you run: make eks-cluster-apply\n\n"
fi

# EKS Node Role
NODE_ROLE="${CLUSTER_NAME}-node-role"
if aws iam get-role --role-name "$NODE_ROLE" >/dev/null 2>&1; then
    print_role "$NODE_ROLE" \
        "Allows EC2 instances to join the EKS cluster as worker nodes" \
        "Trusted by ec2.amazonaws.com service principal"

    printf "   Attached Policies:\n"
    aws iam list-attached-role-policies --role-name "$NODE_ROLE" --query 'AttachedPolicies[*].PolicyName' --output text | tr '\t' '\n' | while IFS= read -r policy; do
        if [ -n "$policy" ]; then
            printf "     • %s\n" "$policy"
        fi
    done
    printf "\n"
else
    printf "%b⚠ Role not found: %s%b\n" "$YELLOW" "$NODE_ROLE" "$NC"
    printf "   This role will be created when you run: make eks-cluster-apply\n\n"
fi

# =============================================================================
# SECTION 2: IRSA (IAM ROLES FOR SERVICE ACCOUNTS)
# =============================================================================
print_header "2. IRSA - IAM ROLES FOR SERVICE ACCOUNTS"

printf "%bIRSA allows Kubernetes pods to assume IAM roles without static credentials.%b\n" "$YELLOW" "$NC"
printf "%bThis is the recommended security best practice for AWS EKS.%b\n\n" "$YELLOW" "$NC"

# Check OIDC Provider
printf "%b📋 OIDC Provider%b\n" "$BLUE" "$NC"
OIDC_PROVIDERS=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, '${CLUSTER_NAME}') || contains(Arn, 'eks')].Arn" --output text)

if [ -n "$OIDC_PROVIDERS" ]; then
    echo "$OIDC_PROVIDERS" | tr '\t' '\n' | while IFS= read -r provider_arn; do
        if [ -n "$provider_arn" ]; then
            printf "   ✓ %s\n" "$provider_arn"
        fi
    done
    printf "\n%b   Why: Enables IRSA by establishing trust between EKS and IAM%b\n" "$YELLOW" "$NC"
    printf "%b   Security: Only pods with matching service accounts can assume roles%b\n\n" "$YELLOW" "$NC"
else
    printf "%b   ⚠ OIDC provider not found%b\n" "$YELLOW" "$NC"
    printf "   This will be created when you run: make eks-cluster-apply\n\n"
fi

# EBS CSI Driver Role
EBS_CSI_ROLE="${CLUSTER_NAME}-ebs-csi-driver"
if aws iam get-role --role-name "$EBS_CSI_ROLE" >/dev/null 2>&1; then
    print_role "$EBS_CSI_ROLE" \
        "Allows the EBS CSI driver to create, attach, detach, and delete EBS volumes" \
        "IRSA - Only accessible by kube-system:ebs-csi-controller-sa service account"

    printf "   Attached Policies:\n"
    aws iam list-attached-role-policies --role-name "$EBS_CSI_ROLE" --query 'AttachedPolicies[*].PolicyName' --output text | tr '\t' '\n' | while IFS= read -r policy; do
        if [ -n "$policy" ]; then
            printf "     • %s\n" "$policy"
        fi
    done

    printf "\n%b   Why needed: OpenWebUI requires persistent storage for user data%b\n" "$YELLOW" "$NC"
    printf "%b   What it does: Dynamically provisions EBS volumes when PVCs are created%b\n\n" "$YELLOW" "$NC"
else
    printf "%b⚠ Role not found: %s%b\n" "$YELLOW" "$EBS_CSI_ROLE" "$NC"
    printf "   This role will be created when you run: make eks-cluster-apply\n\n"
fi

# LiteLLM Role
LITELLM_ROLE="${CLUSTER_NAME}-litellm-sa"
if aws iam get-role --role-name "$LITELLM_ROLE" >/dev/null 2>&1; then
    print_role "$LITELLM_ROLE" \
        "Allows LiteLLM pods to invoke AWS Bedrock models (Nova, Llama, etc.)" \
        "IRSA - Only accessible by llm-gateway:litellm service account"

    printf "   Attached Policies:\n"
    aws iam list-attached-role-policies --role-name "$LITELLM_ROLE" --query 'AttachedPolicies[*].PolicyName' --output text | tr '\t' '\n' | while IFS= read -r policy; do
        if [ -n "$policy" ]; then
            printf "     • %s\n" "$policy"
        fi
    done

    printf "\n%b   Why needed: Zero-trust security - no static AWS credentials in pods%b\n" "$YELLOW" "$NC"
    printf "%b   What it does: Allows bedrock:InvokeModel and bedrock:InvokeModelWithResponseStream%b\n" "$YELLOW" "$NC"
    printf "%b   Security benefit: Temporary credentials auto-rotated by AWS STS%b\n\n" "$YELLOW" "$NC"
else
    printf "%b⚠ Role not found: %s%b\n" "$YELLOW" "$LITELLM_ROLE" "$NC"
    printf "   This role will be created when you run: make eks-apply\n\n"
fi

# =============================================================================
# SECTION 3: SECURITY ARCHITECTURE SUMMARY
# =============================================================================
print_header "3. SECURITY ARCHITECTURE SUMMARY"

printf "%b✓ Zero Static Credentials:%b\n" "$GREEN" "$NC"
printf "  • No AWS access keys stored in container images\n"
printf "  • No AWS secrets in Kubernetes manifests\n"
printf "  • All credentials are temporary and auto-rotated by AWS STS\n\n"

printf "%b✓ Principle of Least Privilege:%b\n" "$GREEN" "$NC"
printf "  • Each role has minimal permissions for its specific task\n"
printf "  • LiteLLM can ONLY invoke Bedrock models (cannot access S3, EC2, etc.)\n"
printf "  • EBS CSI driver can ONLY manage EBS volumes\n\n"

printf "%b✓ Identity Federation (IRSA):%b\n" "$GREEN" "$NC"
printf "  • OIDC provider establishes trust between EKS and IAM\n"
printf "  • Pods authenticate using Kubernetes service account tokens\n"
printf "  • AWS STS exchanges tokens for temporary IAM credentials (15 min - 12 hour TTL)\n\n"

printf "%b✓ Audit & Compliance:%b\n" "$GREEN" "$NC"
printf "  • All IAM role assumptions are logged in CloudTrail\n"
printf "  • Can track which pod assumed which role and when\n"
printf "  • Easy to revoke access by deleting/modifying IAM roles\n\n"

# =============================================================================
# SECTION 4: IRSA FLOW DIAGRAM
# =============================================================================
print_header "4. HOW IRSA WORKS (Technical Flow)"

cat << 'EOF'

┌─────────────────────────────────────────────────────────────────┐
│                   IRSA Authentication Flow                      │
└─────────────────────────────────────────────────────────────────┘

1. Pod starts with Kubernetes Service Account
   ├─ Service account has annotation: eks.amazonaws.com/role-arn
   └─ Kubernetes injects OIDC token into pod filesystem

2. Application makes AWS API call (e.g., bedrock:InvokeModel)
   ├─ AWS SDK reads OIDC token from /var/run/secrets/eks.amazonaws.com/
   └─ SDK calls AWS STS AssumeRoleWithWebIdentity

3. AWS STS validates the OIDC token
   ├─ Checks: Token signed by EKS OIDC provider
   ├─ Checks: Service account matches role's trust policy
   └─ Checks: Token not expired

4. AWS STS returns temporary credentials
   ├─ Access Key ID (temporary)
   ├─ Secret Access Key (temporary)
   ├─ Session Token
   └─ Expiration (default: 1 hour, max: 12 hours)

5. Application uses temporary credentials
   ├─ Credentials automatically refreshed by AWS SDK
   └─ All API calls logged in CloudTrail with assumed role identity

┌─────────────────────────────────────────────────────────────────┐
│  Security Benefits vs. Static Credentials                       │
├─────────────────────────────────────────────────────────────────┤
│  ✓ No credentials stored in code/configs                        │
│  ✓ No credential rotation needed (auto-rotated by AWS)          │
│  ✓ Limited blast radius if pod compromised (temporary creds)    │
│  ✓ Fine-grained permissions per service account                 │
│  ✓ Full CloudTrail audit trail                                  │
└─────────────────────────────────────────────────────────────────┘

EOF

# =============================================================================
# SECTION 5: COST IMPLICATIONS
# =============================================================================
print_header "5. COST IMPLICATIONS"

printf "%b💰 IAM Roles: FREE%b\n" "$GREEN" "$NC"
printf "  • No charge for IAM roles, policies, or OIDC providers\n"
printf "  • No charge for STS AssumeRoleWithWebIdentity API calls\n"
printf "  • Only pay for actual AWS service usage (Bedrock, EBS, etc.)\n\n"

# =============================================================================
# END OF REPORT
# =============================================================================
print_header "END OF REPORT"

printf "%bFor more details, run:%b\n" "$CYAN" "$NC"
printf "  • View a specific role: aws iam get-role --role-name <role-name>\n"
printf "  • List all roles: aws iam list-roles --query 'Roles[?contains(RoleName, \`%s\`)].RoleName'\n" "$CLUSTER_NAME"
printf "  • CloudTrail logs: aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=<role-name>\n"
printf "\n%b✓ Report complete!%b\n" "$GREEN" "$NC"
