#!/bin/sh

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
TOTAL_RESOURCES=0

# Helper function to print section headers
print_header() {
    printf "\n"
    printf "%b========================================%b\n" "$CYAN" "$NC"
    printf "%b%s%b\n" "$CYAN" "$1" "$NC"
    printf "%b========================================%b\n" "$CYAN" "$NC"
}

# Helper function to print resource count
print_count() {
    resource_type="$1"
    count="$2"
    if [ "$count" -gt 0 ]; then
        printf "%bFound: %d %s%b\n" "$YELLOW" "$count" "$resource_type" "$NC"
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + count))
    else
        printf "%bNo %s found%b\n" "$GREEN" "$resource_type" "$NC"
    fi
}

# Helper function to estimate monthly cost
estimate_cost() {
    resource_type="$1"
    count="$2"
    cost_per_unit="$3"

    if [ "$count" -gt 0 ]; then
        total=$(awk "BEGIN {printf \"%.2f\", $count * $cost_per_unit}")
        printf "%b  Estimated cost: ~\$%s/month%b\n" "$RED" "$total" "$NC"
    fi
}

# Helper function to pause for user to read
press_to_continue() {
    printf "\n%bPress any key to continue...%b" "$BLUE" "$NC"
    # Read a single character without requiring Enter
    if command -v stty >/dev/null 2>&1; then
        # Save terminal settings
        old_stty=$(stty -g)
        # Disable canonical mode and echo
        stty -icanon -echo
        # Read one character
        dd bs=1 count=1 >/dev/null 2>&1
        # Restore terminal settings
        stty "$old_stty"
    else
        # Fallback: require Enter
        read -r dummy
    fi
    printf "\n"
}

# Start report
printf "%b========================================%b\n" "$GREEN" "$NC"
printf "%b   AWS COST REPORT%b\n" "$GREEN" "$NC"
printf "%b   Region: %s%b\n" "$GREEN" "$AWS_REGION" "$NC"
printf "%b   Date: %s%b\n" "$GREEN" "$(date)" "$NC"
printf "%b========================================%b\n" "$GREEN" "$NC"

# Verify AWS credentials before proceeding
printf "\n%bVerifying AWS credentials...%b\n" "$CYAN" "$NC"
AUTH_ERROR=$(mktemp)
CALLER_IDENTITY=$(aws sts get-caller-identity --query 'Account' --output text 2>"$AUTH_ERROR")
AUTH_STATUS=$?
AUTH_ERROR_MSG=$(cat "$AUTH_ERROR")
rm -f "$AUTH_ERROR"

if [ $AUTH_STATUS -ne 0 ]; then
    printf "%b✗ AUTHENTICATION FAILED%b\n" "$RED" "$NC"
    echo ""
    echo "Error details:"
    echo "$AUTH_ERROR_MSG" | sed 's/^/  /'
    echo ""

    # Provide specific guidance
    if echo "$AUTH_ERROR_MSG" | grep -q "InvalidSignatureException\|SignatureDoesNotMatch"; then
        echo "Issue: AWS credential signature problem"
        echo ""
        echo "Common causes:"
        echo "  1. System clock out of sync (check: date)"
        echo "  2. Mismatched AWS credentials (environment variables vs ~/.aws/credentials)"
        echo "  3. Secret access key contains typos or wrong value"
        echo ""
        echo "Debug steps:"
        echo "  1. Check system time: date"
        echo "  2. Check which credentials are active: env | grep AWS"
        echo "  3. Try: unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"
        echo "  4. Verify ~/.aws/credentials or ~/.config/aws/credentials"
    elif echo "$AUTH_ERROR_MSG" | grep -q "InvalidClientTokenId"; then
        echo "Issue: AWS Access Key ID not found or invalid"
        echo "  The access key may have been deleted or rotated in AWS"
    elif echo "$AUTH_ERROR_MSG" | grep -q "ExpiredToken"; then
        echo "Issue: Temporary credentials have expired"
        echo "  Refresh your AWS session credentials"
    elif echo "$AUTH_ERROR_MSG" | grep -q "AccessDenied"; then
        echo "Issue: Credentials lack sts:GetCallerIdentity permission"
        echo "  This is unusual - contact your AWS administrator"
    else
        echo "Unable to authenticate to AWS"
        echo "  Check your AWS credentials configuration"
    fi

    echo ""
    printf "%bABORTING: Cannot proceed without valid credentials%b\n" "$RED" "$NC"
    exit 1
fi

printf "%b✓ Authenticated as account: %s%b\n" "$GREEN" "$CALLER_IDENTITY" "$NC"
echo ""

# Warning about Cost Explorer API charges
printf "%bℹ️  Note: AWS Cost Explorer API charges \$0.01 per request%b\n" "$YELLOW" "$NC"
printf "%b   This script makes ~5-10 API calls (~\$0.05-0.10 per run)%b\n" "$YELLOW" "$NC"
printf "   Frequent runs can add up to \$1-2/month in API charges\n"
echo ""

# 1. EKS Clusters (most expensive)
print_header "EKS CLUSTERS (~\$73/month each for control plane)"
EKS_CLUSTERS=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text 2>/dev/null | wc -w)
print_count "EKS cluster(s)" "$EKS_CLUSTERS"
if [ "$EKS_CLUSTERS" -gt 0 ]; then
    aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output table 2>/dev/null
    estimate_cost "EKS cluster(s)" "$EKS_CLUSTERS" 73

    # Check for node groups
    for cluster in $(aws eks list-clusters --region "$AWS_REGION" --query 'clusters[]' --output text 2>/dev/null); do
        echo ""
        echo "  Cluster: $cluster"
        echo "  Node groups:"
        aws eks list-nodegroups --cluster-name "$cluster" --region "$AWS_REGION" --output table 2>/dev/null

        # Get node group details
        for ng in $(aws eks list-nodegroups --cluster-name "$cluster" --region "$AWS_REGION" --query 'nodegroups[]' --output text 2>/dev/null); do
            echo "    Node group: $ng"
            aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" --region "$AWS_REGION" \
                --query 'nodegroup.{InstanceType:instanceTypes[0],DesiredSize:scalingConfig.desiredSize,MinSize:scalingConfig.minSize,MaxSize:scalingConfig.maxSize}' \
                --output table 2>/dev/null
        done
    done
    press_to_continue
fi

# 2. EC2 Instances
print_header "EC2 INSTANCES"
EC2_RUNNING=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null | wc -l)
print_count "running EC2 instance(s)" "$EC2_RUNNING"
if [ "$EC2_RUNNING" -gt 0 ]; then
    echo ""
    aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0],LaunchTime]' \
        --output table 2>/dev/null
    printf "%b  Note: Cost varies by instance type (t3.small ~\$15/mo, t3.medium ~\$30/mo)%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 3. ECS Clusters and Services
print_header "ECS CLUSTERS & FARGATE TASKS"
ECS_CLUSTERS=$(aws ecs list-clusters --region "$AWS_REGION" --query 'clusterArns' --output text 2>/dev/null | wc -w)
print_count "ECS cluster(s)" "$ECS_CLUSTERS"
if [ "$ECS_CLUSTERS" -gt 0 ]; then
    echo ""
    for cluster_arn in $(aws ecs list-clusters --region "$AWS_REGION" --query 'clusterArns[]' --output text 2>/dev/null); do
        cluster_name=$(echo "$cluster_arn" | awk -F'/' '{print $2}')
        echo "  Cluster: $cluster_name"

        # List services
        services=$(aws ecs list-services --cluster "$cluster_name" --region "$AWS_REGION" --query 'serviceArns' --output text 2>/dev/null | wc -w)
        echo "    Services: $services"

        if [ "$services" -gt 0 ]; then
            aws ecs list-services --cluster "$cluster_name" --region "$AWS_REGION" --output table 2>/dev/null
        fi

        # List running tasks
        tasks=$(aws ecs list-tasks --cluster "$cluster_name" --region "$AWS_REGION" --desired-status RUNNING --query 'taskArns' --output text 2>/dev/null | wc -w)
        echo "    Running tasks: $tasks"
        echo ""
    done
    printf "%b  Note: Fargate costs ~\$15-30/month per task (0.5 vCPU, 1GB RAM)%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 4. RDS Databases
print_header "RDS DATABASES"
RDS_INSTANCES=$(aws rds describe-db-instances --region "$AWS_REGION" --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceClass,Engine,DBInstanceStatus]' --output text 2>/dev/null | wc -l)
print_count "RDS instance(s)" "$RDS_INSTANCES"
if [ "$RDS_INSTANCES" -gt 0 ]; then
    echo ""
    aws rds describe-db-instances --region "$AWS_REGION" \
        --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceClass,Engine,DBInstanceStatus,AllocatedStorage]' \
        --output table 2>/dev/null
    printf "%b  Note: db.t3.micro ~\$15/mo, db.t3.small ~\$30/mo (plus storage)%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 5. AWS Bedrock (Provisioned Throughput & Custom Models)
print_header "AWS BEDROCK"

# Check for Provisioned Throughput
PROVISIONED_THROUGHPUT=$(aws bedrock list-provisioned-model-throughputs --region "$AWS_REGION" \
    --query 'provisionedModelSummaries[?status==`InService`]' \
    --output text 2>/dev/null | wc -l)
print_count "Bedrock provisioned throughput(s)" "$PROVISIONED_THROUGHPUT"
if [ "$PROVISIONED_THROUGHPUT" -gt 0 ]; then
    echo ""
    echo "  Provisioned Throughput:"
    aws bedrock list-provisioned-model-throughputs --region "$AWS_REGION" \
        --query 'provisionedModelSummaries[?status==`InService`].[provisionedModelName,modelArn,status,desiredModelUnits]' \
        --output table 2>/dev/null
    printf "%b  Note: Provisioned throughput is EXPENSIVE - typically \$100s-\$1000s/month per unit%b\n" "$RED" "$NC"
    press_to_continue
fi

# Check for Custom Models
CUSTOM_MODELS=$(aws bedrock list-custom-models --region "$AWS_REGION" \
    --query 'modelSummaries[*].modelName' \
    --output text 2>/dev/null | wc -w)
if [ "$CUSTOM_MODELS" -gt 0 ]; then
    echo ""
    print_count "Bedrock custom model(s)" "$CUSTOM_MODELS"
    aws bedrock list-custom-models --region "$AWS_REGION" \
        --query 'modelSummaries[*].[modelName,modelArn,creationTime]' \
        --output table 2>/dev/null
    printf "%b  Note: Custom model training and storage incur costs%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# If neither provisioned throughput nor custom models, show info about on-demand
if [ "$PROVISIONED_THROUGHPUT" -eq 0 ] && [ "$CUSTOM_MODELS" -eq 0 ]; then
    # Check if Bedrock is accessible (if we can list foundation models)
    FOUNDATION_MODELS=$(aws bedrock list-foundation-models --region "$AWS_REGION" \
        --query 'modelSummaries[0].modelId' \
        --output text 2>/dev/null)
    if [ -n "$FOUNDATION_MODELS" ] && [ "$FOUNDATION_MODELS" != "None" ]; then
        printf "%bNo provisioned throughput or custom models found%b\n" "$GREEN" "$NC"
        printf "  Note: Bedrock on-demand usage is pay-per-token (variable cost)\n"
        printf "  Costs only accrue when API calls are made\n"
    else
        printf "%bBedrock not available or not accessible in this region%b\n" "$GREEN" "$NC"
    fi
fi

# 6. Load Balancers (ALB/NLB)
print_header "LOAD BALANCERS"
ALB_COUNT=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query 'LoadBalancers[?Type==`application`].[LoadBalancerName,Type,State.Code]' \
    --output text 2>/dev/null | wc -l)
NLB_COUNT=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query 'LoadBalancers[?Type==`network`].[LoadBalancerName,Type,State.Code]' \
    --output text 2>/dev/null | wc -l)
TOTAL_LB=$((ALB_COUNT + NLB_COUNT))

print_count "Application Load Balancer(s)" "$ALB_COUNT"
print_count "Network Load Balancer(s)" "$NLB_COUNT"

if [ "$TOTAL_LB" -gt 0 ]; then
    echo ""
    aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query 'LoadBalancers[*].[LoadBalancerName,Type,Scheme,State.Code,VpcId]' \
        --output table 2>/dev/null
    estimate_cost "Load Balancer(s)" "$TOTAL_LB" 16
    press_to_continue
fi

# 7. CloudFront Distributions
print_header "CLOUDFRONT DISTRIBUTIONS"
CF_DISTROS_RAW=$(aws cloudfront list-distributions \
    --query 'DistributionList.Items[*].Id' \
    --output text 2>/dev/null)
if [ "$CF_DISTROS_RAW" = "None" ] || [ -z "$CF_DISTROS_RAW" ]; then
    CF_DISTROS=0
else
    CF_DISTROS=$(echo "$CF_DISTROS_RAW" | wc -w)
fi
print_count "CloudFront distribution(s)" "$CF_DISTROS"
if [ "$CF_DISTROS" -gt 0 ]; then
    echo ""
    aws cloudfront list-distributions \
        --query 'DistributionList.Items[*].[Id,DomainName,Enabled,Status,Comment]' \
        --output table 2>/dev/null

    # Get distribution details
    for dist_id in $(aws cloudfront list-distributions \
        --query 'DistributionList.Items[*].Id' \
        --output text 2>/dev/null); do
        echo ""
        echo "  Distribution: $dist_id"

        # Get aliases (custom domains)
        aliases=$(aws cloudfront get-distribution --id "$dist_id" \
            --query 'Distribution.DistributionConfig.Aliases.Items' \
            --output text 2>/dev/null)
        if [ -n "$aliases" ] && [ "$aliases" != "None" ]; then
            echo "    Aliases: $aliases"
        fi

        # Get price class
        price_class=$(aws cloudfront get-distribution --id "$dist_id" \
            --query 'Distribution.DistributionConfig.PriceClass' \
            --output text 2>/dev/null)
        echo "    Price Class: $price_class"
    done

    printf "%b  Note: CloudFront costs are pay-per-use (~\$0.085/GB data transfer, \$0.0075/10k requests)%b\n" "$YELLOW" "$NC"
    printf "%b  Estimated: \$5-15/month for moderate traffic (100GB/month)%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 8. Route53 Hosted Zones
print_header "ROUTE53 HOSTED ZONES"
HOSTED_ZONES_RAW=$(aws route53 list-hosted-zones \
    --query 'HostedZones[*].Id' \
    --output text 2>/dev/null)
if [ "$HOSTED_ZONES_RAW" = "None" ] || [ -z "$HOSTED_ZONES_RAW" ]; then
    HOSTED_ZONES=0
else
    HOSTED_ZONES=$(echo "$HOSTED_ZONES_RAW" | wc -w)
fi
print_count "Route53 hosted zone(s)" "$HOSTED_ZONES"
if [ "$HOSTED_ZONES" -gt 0 ]; then
    echo ""
    aws route53 list-hosted-zones \
        --query 'HostedZones[*].[Name,Id,ResourceRecordSetCount,Config.PrivateZone]' \
        --output table 2>/dev/null

    # Show record sets for each zone
    for zone_id in $(aws route53 list-hosted-zones \
        --query 'HostedZones[*].Id' \
        --output text 2>/dev/null); do
        zone_name=$(aws route53 get-hosted-zone --id "$zone_id" \
            --query 'HostedZone.Name' \
            --output text 2>/dev/null)
        record_count=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
            --query 'ResourceRecordSets[*]' \
            --output text 2>/dev/null | wc -l)
        echo ""
        echo "  Zone: $zone_name"
        echo "    Records: $record_count"
    done

    estimate_cost "Route53 hosted zone(s)" "$HOSTED_ZONES" 0.50
    printf "%b  Note: Plus \$0.40 per million queries (DNS lookups)%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 9. NAT Gateways
print_header "NAT GATEWAYS"
NAT_GW=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=state,Values=available" \
    --query 'NatGateways[*].[NatGatewayId,State,SubnetId]' \
    --output text 2>/dev/null | wc -l)
print_count "NAT Gateway(s)" "$NAT_GW"
if [ "$NAT_GW" -gt 0 ]; then
    echo ""
    aws ec2 describe-nat-gateways --region "$AWS_REGION" \
        --filter "Name=state,Values=available" \
        --query 'NatGateways[*].[NatGatewayId,State,SubnetId,VpcId]' \
        --output table 2>/dev/null
    estimate_cost "NAT Gateway(s)" "$NAT_GW" 32
    press_to_continue
fi

# 10. EBS Volumes
print_header "EBS VOLUMES"
EBS_VOLUMES=$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --query 'Volumes[*].[VolumeId,Size,VolumeType,State]' \
    --output text 2>/dev/null | wc -l)
print_count "EBS volume(s)" "$EBS_VOLUMES"
if [ "$EBS_VOLUMES" -gt 0 ]; then
    echo ""
    TOTAL_SIZE=$(aws ec2 describe-volumes --region "$AWS_REGION" \
        --query 'Volumes[*].Size' --output text 2>/dev/null | awk '{s+=$1} END {print s}')
    printf "  Total storage: %b%s GB%b\n" "$YELLOW" "$TOTAL_SIZE" "$NC"
    aws ec2 describe-volumes --region "$AWS_REGION" \
        --query 'Volumes[*].[VolumeId,Size,VolumeType,State,Tags[?Key==`Name`].Value|[0]]' \
        --output table 2>/dev/null

    # Estimate cost (gp3 is $0.08/GB/month)
    STORAGE_COST=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE * 0.08}")
    printf "%b  Estimated cost: ~\$%s/month (gp3 @ \$0.08/GB)%b\n" "$RED" "$STORAGE_COST" "$NC"
    press_to_continue
fi

# 11. Elastic IPs (unattached cost money)
print_header "ELASTIC IPs (Unattached)"
UNATTACHED_EIP=$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' \
    --output text 2>/dev/null | wc -l)
print_count "unattached Elastic IP(s)" "$UNATTACHED_EIP"
if [ "$UNATTACHED_EIP" -gt 0 ]; then
    echo ""
    aws ec2 describe-addresses --region "$AWS_REGION" \
        --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId,Tags[?Key==`Name`].Value|[0]]' \
        --output table 2>/dev/null
    estimate_cost "unattached EIP(s)" "$UNATTACHED_EIP" 3.6
    press_to_continue
fi

# 12. VPCs (mostly free, but list for completeness)
print_header "VPCs"
VPC_COUNT=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --query 'Vpcs[?IsDefault==`false`]' --output text 2>/dev/null | wc -l)
print_count "custom VPC(s)" "$VPC_COUNT"
if [ "$VPC_COUNT" -gt 0 ]; then
    echo ""
    aws ec2 describe-vpcs --region "$AWS_REGION" \
        --query 'Vpcs[?IsDefault==`false`].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
        --output table 2>/dev/null
    printf "%b  Note: VPCs themselves are free, but associated resources cost money%b\n" "$GREEN" "$NC"
    press_to_continue
fi

# 13. S3 Buckets (check for buckets - storage costs apply)
print_header "S3 BUCKETS"
S3_BUCKETS=$(aws s3api list-buckets --query 'Buckets[*].Name' --output text 2>/dev/null | wc -w)
print_count "S3 bucket(s)" "$S3_BUCKETS"
if [ "$S3_BUCKETS" -gt 0 ]; then
    echo ""
    echo "  Buckets:"
    for bucket in $(aws s3api list-buckets --query 'Buckets[*].Name' --output text 2>/dev/null); do
        region=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text 2>/dev/null)
        [ "$region" = "None" ] && region="us-east-1"
        size=$(aws s3 ls "s3://$bucket" --recursive --summarize 2>/dev/null | grep "Total Size" | awk '{print $3}')
        size_gb=$(awk "BEGIN {printf \"%.2f\", $size / 1024 / 1024 / 1024}")
        echo "    - $bucket (Region: $region, Size: ~${size_gb} GB)"
    done
    printf "%b  Note: S3 costs ~\$0.023/GB/month (Standard storage)%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 14. ECR Repositories
print_header "ECR REPOSITORIES"
ECR_REPOS=$(aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[*].repositoryName' --output text 2>/dev/null | wc -w)
print_count "ECR repository/repositories" "$ECR_REPOS"
if [ "$ECR_REPOS" -gt 0 ]; then
    echo ""
    echo "  Repositories:"
    TOTAL_ECR_SIZE=0
    for repo in $(aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[*].repositoryName' --output text 2>/dev/null); do
        # Get images in the repository
        image_count=$(aws ecr list-images --repository-name "$repo" --region "$AWS_REGION" --query 'imageIds' --output text 2>/dev/null | wc -l)

        # Get repository URI
        repo_uri=$(aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo" --query 'repositories[0].repositoryUri' --output text 2>/dev/null)

        echo "    - $repo"
        echo "      URI: $repo_uri"
        echo "      Images: $image_count"

        # Try to get image sizes (this requires describing each image)
        repo_size=0
        for digest in $(aws ecr list-images --repository-name "$repo" --region "$AWS_REGION" --query 'imageIds[*].imageDigest' --output text 2>/dev/null); do
            size=$(aws ecr describe-images --repository-name "$repo" --region "$AWS_REGION" --image-ids imageDigest="$digest" --query 'imageDetails[0].imageSizeInBytes' --output text 2>/dev/null)
            if [ -n "$size" ] && [ "$size" != "None" ]; then
                repo_size=$((repo_size + size))
            fi
        done

        if [ "$repo_size" -gt 0 ]; then
            size_gb=$(awk "BEGIN {printf \"%.2f\", $repo_size / 1024 / 1024 / 1024}")
            echo "      Size: ~${size_gb} GB"
            TOTAL_ECR_SIZE=$(awk "BEGIN {printf \"%.2f\", $TOTAL_ECR_SIZE + $size_gb}")
        fi
        echo ""
    done

    if [ "$(echo "$TOTAL_ECR_SIZE > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        printf "  Total ECR storage: %b%s GB%b\n" "$YELLOW" "$TOTAL_ECR_SIZE" "$NC"
        ECR_COST=$(awk "BEGIN {printf \"%.2f\", $TOTAL_ECR_SIZE * 0.10}")
        printf "%b  Estimated cost: ~\$%s/month (@ \$0.10/GB)%b\n" "$RED" "$ECR_COST" "$NC"
    else
        printf "%b  Note: ECR costs \$0.10/GB/month for storage%b\n" "$YELLOW" "$NC"
    fi
    press_to_continue
fi

# 15. Secrets Manager Secrets
print_header "SECRETS MANAGER"
SECRETS=$(aws secretsmanager list-secrets --region "$AWS_REGION" \
    --query 'SecretList[*].[Name,LastAccessedDate]' \
    --output text 2>/dev/null | wc -l)
print_count "secret(s)" "$SECRETS"
if [ "$SECRETS" -gt 0 ]; then
    echo ""
    aws secretsmanager list-secrets --region "$AWS_REGION" \
        --query 'SecretList[*].[Name,LastAccessedDate]' \
        --output table 2>/dev/null
    estimate_cost "secret(s)" "$SECRETS" 0.40
    press_to_continue
fi

# 16. CloudWatch Log Groups (with data retention)
print_header "CLOUDWATCH LOG GROUPS"
LOG_GROUPS=$(aws logs describe-log-groups --region "$AWS_REGION" \
    --query 'logGroups[*].[logGroupName,storedBytes]' \
    --output text 2>/dev/null | wc -l)
print_count "log group(s)" "$LOG_GROUPS"
if [ "$LOG_GROUPS" -gt 0 ]; then
    echo ""
    TOTAL_LOG_GB=$(aws logs describe-log-groups --region "$AWS_REGION" \
        --query 'logGroups[*].storedBytes' --output text 2>/dev/null | \
        awk '{s+=$1} END {printf "%.2f", s/1024/1024/1024}')
    printf "  Total log storage: %b%s GB%b\n" "$YELLOW" "$TOTAL_LOG_GB" "$NC"
    echo ""
    aws logs describe-log-groups --region "$AWS_REGION" \
        --query 'logGroups[*].[logGroupName,retentionInDays]' \
        --output table 2>/dev/null | head -20
    printf "%b  Note: CloudWatch Logs cost ~\$0.50/GB/month%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 17. Lambda Functions (with provisioned concurrency)
print_header "LAMBDA FUNCTIONS"
LAMBDA_COUNT=$(aws lambda list-functions --region "$AWS_REGION" \
    --query 'Functions[*].FunctionName' --output text 2>/dev/null | wc -w)
print_count "Lambda function(s)" "$LAMBDA_COUNT"
if [ "$LAMBDA_COUNT" -gt 0 ]; then
    echo ""
    aws lambda list-functions --region "$AWS_REGION" \
        --query 'Functions[*].[FunctionName,Runtime,MemorySize,LastModified]' \
        --output table 2>/dev/null
    printf "%b  Note: Lambda is pay-per-invocation (usually very low cost unless heavily used)%b\n" "$GREEN" "$NC"
    press_to_continue
fi

# 18. ElastiCache Clusters
print_header "ELASTICACHE CLUSTERS"
ELASTICACHE=$(aws elasticache describe-cache-clusters --region "$AWS_REGION" \
    --query 'CacheClusters[*].[CacheClusterId,CacheNodeType,Engine,CacheClusterStatus]' \
    --output text 2>/dev/null | wc -l)
print_count "ElastiCache cluster(s)" "$ELASTICACHE"
if [ "$ELASTICACHE" -gt 0 ]; then
    echo ""
    aws elasticache describe-cache-clusters --region "$AWS_REGION" \
        --query 'CacheClusters[*].[CacheClusterId,CacheNodeType,Engine,CacheClusterStatus]' \
        --output table 2>/dev/null
    printf "%b  Note: cache.t3.micro ~\$12/mo, cache.t3.small ~\$25/mo%b\n" "$YELLOW" "$NC"
    press_to_continue
fi

# 19. ACM Certificates
print_header "ACM CERTIFICATES"
# Check both us-east-1 (for CloudFront) and current region
ACM_CERTS_GLOBAL_RAW=$(aws acm list-certificates --region us-east-1 \
    --query 'CertificateSummaryList[*].DomainName' \
    --output text 2>/dev/null)
if [ "$ACM_CERTS_GLOBAL_RAW" = "None" ] || [ -z "$ACM_CERTS_GLOBAL_RAW" ]; then
    ACM_CERTS_GLOBAL=0
else
    ACM_CERTS_GLOBAL=$(echo "$ACM_CERTS_GLOBAL_RAW" | wc -w)
fi

ACM_CERTS_REGIONAL=0
if [ "$AWS_REGION" != "us-east-1" ]; then
    ACM_CERTS_REGIONAL_RAW=$(aws acm list-certificates --region "$AWS_REGION" \
        --query 'CertificateSummaryList[*].DomainName' \
        --output text 2>/dev/null)
    if [ "$ACM_CERTS_REGIONAL_RAW" != "None" ] && [ -n "$ACM_CERTS_REGIONAL_RAW" ]; then
        ACM_CERTS_REGIONAL=$(echo "$ACM_CERTS_REGIONAL_RAW" | wc -w)
    fi
fi
TOTAL_ACM=$((ACM_CERTS_GLOBAL + ACM_CERTS_REGIONAL))

print_count "ACM certificate(s)" "$TOTAL_ACM"
if [ "$TOTAL_ACM" -gt 0 ]; then
    echo ""
    if [ "$ACM_CERTS_GLOBAL" -gt 0 ]; then
        echo "  Certificates in us-east-1 (for CloudFront):"
        aws acm list-certificates --region us-east-1 \
            --query 'CertificateSummaryList[*].[DomainName,Status,CertificateArn]' \
            --output table 2>/dev/null
    fi

    if [ "$ACM_CERTS_REGIONAL" -gt 0 ]; then
        echo ""
        echo "  Certificates in $AWS_REGION:"
        aws acm list-certificates --region "$AWS_REGION" \
            --query 'CertificateSummaryList[*].[DomainName,Status,CertificateArn]' \
            --output table 2>/dev/null
    fi

    printf "%b  Note: ACM public certificates are FREE (no monthly charge)%b\n" "$GREEN" "$NC"
    press_to_continue
fi

# Summary
printf "\n"
print_header "SUMMARY"
printf "%bTotal resource types with active resources: %d%b\n" "$YELLOW" "$TOTAL_RESOURCES" "$NC"
printf "\n"
printf "%bMajor cost drivers to watch:%b\n" "$CYAN" "$NC"
echo "  1. EKS Clusters: \$73/month per cluster (control plane only)"
echo "  2. EC2/EKS Nodes: \$15-30+/month per instance"
echo "  3. NAT Gateways: \$32/month each"
echo "  4. Load Balancers: \$16/month each (ALB/NLB)"
echo "  5. CloudFront: \$5-15/month (pay-per-use, depends on traffic)"
echo "  6. RDS Databases: \$15-100+/month depending on size"
echo "  7. EBS Volumes: \$0.08-0.10/GB/month"
echo "  8. Route53 Hosted Zones: \$0.50/month per zone"
printf "\n"

# Month-to-date costs and forecast
print_header "MONTH-TO-DATE COSTS"

# Get current month dates
# AWS Cost Explorer API uses exclusive end dates, so we need tomorrow's date
MONTH_START=$(date -d "$(date +%Y-%m-01)" +%Y-%m-%d 2>/dev/null || date -v1d +%Y-%m-%d 2>/dev/null || date +%Y-%m-01)
MONTH_END=$(date -d "tomorrow" +%Y-%m-%d 2>/dev/null || date -v+1d +%Y-%m-%d 2>/dev/null)

printf "Querying Cost Explorer for: %s to %s\n" "$MONTH_START" "$MONTH_END"
echo ""

# Get month-to-date costs
MTD_ERROR=$(mktemp)
MTD_COST=$(aws ce get-cost-and-usage \
    --time-period Start="$MONTH_START",End="$MONTH_END" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --query 'ResultsByTime[0].Total.UnblendedCost.Amount' \
    --output text 2>"$MTD_ERROR" || echo "error")
MTD_ERROR_MSG=$(cat "$MTD_ERROR")
rm -f "$MTD_ERROR"

if [ "$MTD_COST" != "error" ] && [ -n "$MTD_COST" ]; then
    MTD_COST_ROUNDED=$(printf "%.2f" "$MTD_COST" 2>/dev/null || echo "$MTD_COST")
    printf "%bMonth-to-date cost: \$%s USD%b\n" "$GREEN" "$MTD_COST_ROUNDED" "$NC"

    # Get forecasted monthly cost
    LAST_DAY=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%Y-%m-%d 2>/dev/null || \
               date -v1d -v+1m -v-1d +%Y-%m-%d 2>/dev/null || \
               echo "$MONTH_END")

    FORECAST=$(aws ce get-cost-forecast \
        --time-period Start="$MONTH_END",End="$LAST_DAY" \
        --metric UNBLENDED_COST \
        --granularity MONTHLY \
        --query 'Total.Amount' \
        --output text 2>/dev/null || echo "")

    if [ -n "$FORECAST" ] && [ "$FORECAST" != "None" ]; then
        FORECAST_ROUNDED=$(printf "%.2f" "$FORECAST" 2>/dev/null || echo "$FORECAST")
        TOTAL_FORECAST=$(awk "BEGIN {printf \"%.2f\", $MTD_COST + $FORECAST}")
        printf "Forecasted month-end: \$%s USD\n" "$TOTAL_FORECAST"
    fi

    # Get top 5 services by cost
    printf "\n%bTop 5 services this month:%b\n" "$CYAN" "$NC"
    aws ce get-cost-and-usage \
        --time-period Start="$MONTH_START",End="$MONTH_END" \
        --granularity MONTHLY \
        --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE \
        --query 'ResultsByTime[0].Groups[:5].[Keys[0],Metrics.UnblendedCost.Amount]' \
        --output text 2>/dev/null | while IFS= read -r service cost; do
            if [ -n "$cost" ] && [ "$cost" != "0" ]; then
                cost_rounded=$(printf "%.4f" "$cost" 2>/dev/null || echo "$cost")
                printf "  - %s: \$%s\n" "$service" "$cost_rounded"
            fi
        done

    # Warn if costs are high
    MTD_INT=$(echo "$MTD_COST" | cut -d. -f1)
    printf "\n"
    if [ "$MTD_INT" -gt 100 ]; then
        printf "%bWARNING: Month-to-date cost exceeds \$100%b\n" "$RED" "$NC"
        echo "  Consider reviewing your usage and setting up billing alarms"
    elif [ "$MTD_INT" -gt 50 ]; then
        printf "%b⚠️  Moderate spending detected%b\n" "$YELLOW" "$NC"
    else
        printf "%b✓ Spending is within normal range%b\n" "$GREEN" "$NC"
    fi
    printf "\n"
    press_to_continue

else
    printf "%bCould not retrieve cost data%b\n" "$RED" "$NC"
    if [ -n "$MTD_ERROR_MSG" ]; then
        echo "  Error details:"
        echo "$MTD_ERROR_MSG" | sed 's/^/    /'
        echo ""
    fi

    # Check for common issues
    if echo "$MTD_ERROR_MSG" | grep -q "InvalidSignatureException"; then
        echo "  Issue: AWS credential/signature problem"
        echo ""
        echo "  Common causes:"
        echo "    1. System clock is out of sync (most common)"
        echo "       Check: date (should match actual time)"
        echo "       Fix: sudo ntpdate -s time.nist.gov  OR  sudo timedatectl set-ntp true"
        echo ""
        echo "    2. AWS Secret Access Key contains special characters not properly set"
        echo "       Fix: Re-export credentials or check ~/.aws/credentials format"
        echo ""
        echo "    3. Temporary credentials have expired"
        echo "       Fix: Refresh your AWS credentials"
        echo ""
        echo "    4. Mixing credentials from different AWS accounts"
        echo "       Check: aws sts get-caller-identity"
    elif echo "$MTD_ERROR_MSG" | grep -q "SubscriptionRequiredException"; then
        echo "  Issue: Cost Explorer is not enabled"
        echo "  Solution: Enable at AWS Console > Billing > Cost Explorer"
    elif echo "$MTD_ERROR_MSG" | grep -q "AccessDenied"; then
        echo "  Issue: IAM permissions missing"
        echo "  Solution: Add 'ce:GetCostAndUsage' permission to your IAM user/role"
    elif echo "$MTD_ERROR_MSG" | grep -q "ValidationException"; then
        echo "  Issue: Invalid date range or parameters"
        echo "  Debug: MONTH_START=$MONTH_START, MONTH_END=$MONTH_END"
    else
        echo "  Possible causes:"
        echo "    1. Cost Explorer not enabled (AWS Console > Billing > Cost Explorer)"
        echo "    2. IAM permissions missing (need ce:GetCostAndUsage)"
        echo "    3. Cost Explorer not available in your region"
    fi
    printf "\n"
fi

# Check for budgets
print_header "AWS BUDGETS"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

if [ -n "$ACCOUNT_ID" ]; then
    BUDGETS=$(aws budgets describe-budgets \
        --account-id "$ACCOUNT_ID" \
        --query 'Budgets[*].[BudgetName,BudgetLimit.Amount]' \
        --output text 2>/dev/null || echo "")

    if [ -n "$BUDGETS" ]; then
        BUDGET_COUNT=$(echo "$BUDGETS" | wc -l)
        printf "%b%d budget(s) configured:%b\n" "$GREEN" "$BUDGET_COUNT" "$NC"
        echo "$BUDGETS" | while read -r budget_name budget_limit; do
            printf "  - %s: \$%s\n" "$budget_name" "$budget_limit"
        done | head -3
        printf "\n"
        # press_to_continue
    else
        printf "%bNo budgets configured%b\n" "$YELLOW" "$NC"
        echo "  Recommendation: Set up a budget to track spending"
        echo "  AWS Console > Billing > Budgets > Create budget"
        printf "\n"
    fi
else
    printf "%bCannot check budgets - account ID not available%b\n" "$RED" "$NC"
    printf "\n"
fi

printf "%bReport complete!%b\n" "$GREEN" "$NC"
