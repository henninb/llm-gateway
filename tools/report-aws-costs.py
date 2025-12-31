#!/usr/bin/env python3
"""
AWS Cost Report - Lists all resources currently costing money
Python version with enhanced formatting and error handling
"""

import sys
import os
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple
import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich import box

console = Console()

# Configuration
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")


class AWSCostReporter:
    def __init__(self, region: str = AWS_REGION):
        self.region = region
        self.total_resources = 0
        self.console = console

    def verify_credentials(self) -> Tuple[bool, str]:
        """Verify AWS credentials are valid."""
        try:
            sts = boto3.client('sts')
            identity = sts.get_caller_identity()
            return True, identity['Account']
        except NoCredentialsError:
            self.console.print("[red]✗ No AWS credentials found[/red]")
            self.console.print("\nConfigure credentials:")
            self.console.print("  1. Set environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")
            self.console.print("  2. Or configure: aws configure")
            return False, ""
        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_msg = e.response['Error']['Message']

            self.console.print(f"[red]✗ AUTHENTICATION FAILED[/red]\n")
            self.console.print(f"Error: {error_msg}\n")

            if error_code in ['InvalidSignatureException', 'SignatureDoesNotMatch']:
                self.console.print("[yellow]Issue: AWS credential signature problem[/yellow]\n")
                self.console.print("Common causes:")
                self.console.print("  1. System clock out of sync (check: date)")
                self.console.print("  2. Mismatched AWS credentials (env vars vs ~/.aws/credentials)")
                self.console.print("  3. Secret access key contains typos\n")
            elif error_code == 'InvalidClientTokenId':
                self.console.print("[yellow]Issue: Access key ID not found or invalid[/yellow]")
            elif error_code == 'ExpiredToken':
                self.console.print("[yellow]Issue: Temporary credentials expired[/yellow]")

            return False, ""

    def print_header(self, title: str):
        """Print a section header."""
        self.console.print(f"\n[cyan]{'='*60}[/cyan]")
        self.console.print(f"[cyan bold]{title}[/cyan bold]")
        self.console.print(f"[cyan]{'='*60}[/cyan]")

    def print_count(self, resource_type: str, count: int):
        """Print resource count with color coding."""
        if count > 0:
            self.console.print(f"[yellow]Found: {count} {resource_type}[/yellow]")
            self.total_resources += 1
        else:
            self.console.print(f"[green]No {resource_type} found[/green]")

    def estimate_cost(self, resource_type: str, count: int, cost_per_unit: float):
        """Print estimated monthly cost."""
        if count > 0:
            total = count * cost_per_unit
            self.console.print(f"[red]  Estimated cost: ~${total:.2f}/month[/red]")

    def check_eks_clusters(self):
        """Check EKS clusters."""
        self.print_header("EKS CLUSTERS (~$73/month each)")

        try:
            eks = boto3.client('eks', region_name=self.region)
            clusters = eks.list_clusters()['clusters']

            self.print_count("EKS cluster(s)", len(clusters))

            if clusters:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Cluster Name", style="cyan")
                table.add_column("Status", style="green")

                for cluster_name in clusters:
                    cluster_info = eks.describe_cluster(name=cluster_name)['cluster']
                    table.add_row(cluster_name, cluster_info['status'])

                    # List node groups
                    nodegroups = eks.list_nodegroups(clusterName=cluster_name)['nodegroups']
                    if nodegroups:
                        ng_table = Table(show_header=True, box=box.SIMPLE)
                        ng_table.add_column("Node Group", style="cyan")
                        ng_table.add_column("Instance Type")
                        ng_table.add_column("Desired Size")

                        for ng_name in nodegroups:
                            ng_info = eks.describe_nodegroup(
                                clusterName=cluster_name,
                                nodegroupName=ng_name
                            )['nodegroup']

                            ng_table.add_row(
                                ng_name,
                                ng_info.get('instanceTypes', ['N/A'])[0],
                                str(ng_info['scalingConfig']['desiredSize'])
                            )

                        self.console.print(ng_table)

                self.console.print(table)
                self.estimate_cost("EKS cluster(s)", len(clusters), 73)

        except ClientError as e:
            self.console.print(f"[red]Error checking EKS: {e}[/red]")

    def check_ec2_instances(self):
        """Check EC2 instances."""
        self.print_header("EC2 INSTANCES")

        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            response = ec2.describe_instances(
                Filters=[{'Name': 'instance-state-name', 'Values': ['running']}]
            )

            instances = []
            for reservation in response['Reservations']:
                instances.extend(reservation['Instances'])

            self.print_count("running EC2 instance(s)", len(instances))

            if instances:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Instance ID", style="cyan")
                table.add_column("Type")
                table.add_column("State", style="green")
                table.add_column("Name")

                for instance in instances:
                    name = ""
                    if 'Tags' in instance:
                        name_tag = next((tag['Value'] for tag in instance['Tags'] if tag['Key'] == 'Name'), "")
                        name = name_tag

                    table.add_row(
                        instance['InstanceId'],
                        instance['InstanceType'],
                        instance['State']['Name'],
                        name
                    )

                self.console.print(table)
                self.console.print("[yellow]  Note: Cost varies by type (t3.small ~$15/mo, t3.medium ~$30/mo)[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking EC2: {e}[/red]")

    def check_rds_databases(self):
        """Check RDS databases."""
        self.print_header("RDS DATABASES")

        try:
            rds = boto3.client('rds', region_name=self.region)
            response = rds.describe_db_instances()
            instances = response['DBInstances']

            self.print_count("RDS instance(s)", len(instances))

            if instances:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("DB Instance", style="cyan")
                table.add_column("Class")
                table.add_column("Engine")
                table.add_column("Status", style="green")
                table.add_column("Storage (GB)")

                for db in instances:
                    table.add_row(
                        db['DBInstanceIdentifier'],
                        db['DBInstanceClass'],
                        db['Engine'],
                        db['DBInstanceStatus'],
                        str(db['AllocatedStorage'])
                    )

                self.console.print(table)
                self.console.print("[yellow]  Note: db.t3.micro ~$15/mo, db.t3.small ~$30/mo (plus storage)[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking RDS: {e}[/red]")

    def check_bedrock(self):
        """Check AWS Bedrock provisioned throughput and custom models."""
        self.print_header("AWS BEDROCK")

        try:
            bedrock = boto3.client('bedrock', region_name=self.region)

            # Check provisioned throughput
            try:
                response = bedrock.list_provisioned_model_throughputs()
                provisioned = [pt for pt in response.get('provisionedModelSummaries', [])
                              if pt.get('status') == 'InService']

                self.print_count("Bedrock provisioned throughput(s)", len(provisioned))

                if provisioned:
                    table = Table(show_header=True, box=box.SIMPLE)
                    table.add_column("Name", style="cyan")
                    table.add_column("Model ARN")
                    table.add_column("Status", style="green")
                    table.add_column("Units")

                    for pt in provisioned:
                        table.add_row(
                            pt.get('provisionedModelName', 'N/A'),
                            pt.get('modelArn', 'N/A'),
                            pt.get('status', 'N/A'),
                            str(pt.get('desiredModelUnits', 0))
                        )

                    self.console.print(table)
                    self.console.print("[red bold]  Note: Provisioned throughput is EXPENSIVE - typically $100s-$1000s/month per unit[/red bold]")

            except ClientError:
                pass  # Service may not be available

            # Check custom models
            try:
                custom_models = bedrock.list_custom_models().get('modelSummaries', [])

                if custom_models:
                    self.print_count("Bedrock custom model(s)", len(custom_models))
                    self.console.print("[yellow]  Note: Custom model training and storage incur costs[/yellow]")
                else:
                    self.console.print("[green]No provisioned throughput or custom models found[/green]")
                    self.console.print("  Note: Bedrock on-demand usage is pay-per-token (variable cost)")

            except ClientError:
                self.console.print("[green]Bedrock not available or not accessible in this region[/green]")

        except Exception as e:
            self.console.print(f"[red]Error checking Bedrock: {e}[/red]")

    def check_s3_buckets(self):
        """Check S3 buckets."""
        self.print_header("S3 BUCKETS")

        try:
            s3 = boto3.client('s3')
            response = s3.list_buckets()
            buckets = response['Buckets']

            self.print_count("S3 bucket(s)", len(buckets))

            if buckets:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Bucket Name", style="cyan")
                table.add_column("Region")
                table.add_column("Created")

                for bucket in buckets:
                    try:
                        location = s3.get_bucket_location(Bucket=bucket['Name'])
                        region = location['LocationConstraint'] or 'us-east-1'
                    except:
                        region = 'Unknown'

                    table.add_row(
                        bucket['Name'],
                        region,
                        bucket['CreationDate'].strftime('%Y-%m-%d')
                    )

                self.console.print(table)
                self.console.print("[yellow]  Note: S3 costs ~$0.023/GB/month (Standard storage)[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking S3: {e}[/red]")

    def check_ecr_repositories(self):
        """Check ECR repositories."""
        self.print_header("ECR REPOSITORIES")

        try:
            ecr = boto3.client('ecr', region_name=self.region)
            response = ecr.describe_repositories()
            repositories = response['repositories']

            self.print_count("ECR repository/repositories", len(repositories))

            if repositories:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Repository Name", style="cyan")
                table.add_column("URI")
                table.add_column("Images")

                for repo in repositories:
                    repo_name = repo['repositoryName']
                    images = ecr.list_images(repositoryName=repo_name)
                    image_count = len(images['imageIds'])

                    table.add_row(
                        repo_name,
                        repo['repositoryUri'],
                        str(image_count)
                    )

                self.console.print(table)
                self.console.print("[yellow]  Note: ECR costs $0.10/GB/month for storage[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking ECR: {e}[/red]")

    def check_ecs_clusters(self):
        """Check ECS clusters and services."""
        self.print_header("ECS CLUSTERS & FARGATE TASKS")

        try:
            ecs = boto3.client('ecs', region_name=self.region)
            cluster_arns = ecs.list_clusters()['clusterArns']

            self.print_count("ECS cluster(s)", len(cluster_arns))

            if cluster_arns:
                for cluster_arn in cluster_arns:
                    cluster_name = cluster_arn.split('/')[-1]
                    self.console.print(f"\n  Cluster: [cyan]{cluster_name}[/cyan]")

                    # List services
                    services = ecs.list_services(cluster=cluster_name)['serviceArns']
                    self.console.print(f"    Services: {len(services)}")

                    # List running tasks
                    tasks = ecs.list_tasks(cluster=cluster_name, desiredStatus='RUNNING')['taskArns']
                    self.console.print(f"    Running tasks: {len(tasks)}")

                self.console.print("[yellow]  Note: Fargate costs ~$15-30/month per task (0.5 vCPU, 1GB RAM)[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking ECS: {e}[/red]")

    def check_load_balancers(self):
        """Check Application and Network Load Balancers."""
        self.print_header("LOAD BALANCERS")

        try:
            elbv2 = boto3.client('elbv2', region_name=self.region)
            lbs = elbv2.describe_load_balancers()['LoadBalancers']

            albs = [lb for lb in lbs if lb['Type'] == 'application']
            nlbs = [lb for lb in lbs if lb['Type'] == 'network']

            self.print_count("Application Load Balancer(s)", len(albs))
            self.print_count("Network Load Balancer(s)", len(nlbs))

            if lbs:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Name", style="cyan")
                table.add_column("Type")
                table.add_column("Scheme")
                table.add_column("State", style="green")

                for lb in lbs:
                    table.add_row(
                        lb['LoadBalancerName'],
                        lb['Type'],
                        lb['Scheme'],
                        lb['State']['Code']
                    )

                self.console.print(table)
                self.estimate_cost("Load Balancer(s)", len(lbs), 16)

        except ClientError as e:
            self.console.print(f"[red]Error checking Load Balancers: {e}[/red]")

    def check_cloudfront(self):
        """Check CloudFront distributions."""
        self.print_header("CLOUDFRONT DISTRIBUTIONS")

        try:
            cloudfront = boto3.client('cloudfront')
            response = cloudfront.list_distributions()

            distributions = response.get('DistributionList', {}).get('Items', [])

            self.print_count("CloudFront distribution(s)", len(distributions))

            if distributions:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("ID", style="cyan")
                table.add_column("Domain Name")
                table.add_column("Enabled", style="green")
                table.add_column("Status")

                for dist in distributions:
                    table.add_row(
                        dist['Id'],
                        dist['DomainName'],
                        str(dist['Enabled']),
                        dist['Status']
                    )

                self.console.print(table)
                self.console.print("[yellow]  Note: CloudFront costs are pay-per-use (~$0.085/GB, $0.0075/10k requests)[/yellow]")
                self.console.print("[yellow]  Estimated: $5-15/month for moderate traffic (100GB/month)[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking CloudFront: {e}[/red]")

    def check_route53(self):
        """Check Route53 hosted zones."""
        self.print_header("ROUTE53 HOSTED ZONES")

        try:
            route53 = boto3.client('route53')
            zones = route53.list_hosted_zones()['HostedZones']

            self.print_count("Route53 hosted zone(s)", len(zones))

            if zones:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Name", style="cyan")
                table.add_column("ID")
                table.add_column("Private")

                for zone in zones:
                    table.add_row(
                        zone['Name'],
                        zone['Id'].split('/')[-1],
                        str(zone.get('Config', {}).get('PrivateZone', False))
                    )

                self.console.print(table)
                self.estimate_cost("Route53 hosted zone(s)", len(zones), 0.50)
                self.console.print("[yellow]  Note: Plus $0.40 per million queries (DNS lookups)[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking Route53: {e}[/red]")

    def check_nat_gateways(self):
        """Check NAT Gateways."""
        self.print_header("NAT GATEWAYS")

        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            nat_gateways = ec2.describe_nat_gateways(
                Filters=[{'Name': 'state', 'Values': ['available']}]
            )['NatGateways']

            self.print_count("NAT Gateway(s)", len(nat_gateways))

            if nat_gateways:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("NAT Gateway ID", style="cyan")
                table.add_column("State", style="green")
                table.add_column("VPC ID")
                table.add_column("Subnet ID")

                for nat in nat_gateways:
                    table.add_row(
                        nat['NatGatewayId'],
                        nat['State'],
                        nat['VpcId'],
                        nat['SubnetId']
                    )

                self.console.print(table)
                self.estimate_cost("NAT Gateway(s)", len(nat_gateways), 32)

        except ClientError as e:
            self.console.print(f"[red]Error checking NAT Gateways: {e}[/red]")

    def check_ebs_volumes(self):
        """Check EBS volumes."""
        self.print_header("EBS VOLUMES")

        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            volumes = ec2.describe_volumes()['Volumes']

            self.print_count("EBS volume(s)", len(volumes))

            if volumes:
                total_size = sum(vol['Size'] for vol in volumes)
                self.console.print(f"  Total storage: [yellow]{total_size} GB[/yellow]")

                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Volume ID", style="cyan")
                table.add_column("Size (GB)")
                table.add_column("Type")
                table.add_column("State", style="green")

                for vol in volumes:
                    table.add_row(
                        vol['VolumeId'],
                        str(vol['Size']),
                        vol['VolumeType'],
                        vol['State']
                    )

                self.console.print(table)
                storage_cost = total_size * 0.08
                self.console.print(f"[red]  Estimated cost: ~${storage_cost:.2f}/month (gp3 @ $0.08/GB)[/red]")

        except ClientError as e:
            self.console.print(f"[red]Error checking EBS: {e}[/red]")

    def check_elastic_ips(self):
        """Check unattached Elastic IPs."""
        self.print_header("ELASTIC IPs (Unattached)")

        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            addresses = ec2.describe_addresses()['Addresses']

            unattached = [addr for addr in addresses if 'AssociationId' not in addr]

            self.print_count("unattached Elastic IP(s)", len(unattached))

            if unattached:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Public IP", style="cyan")
                table.add_column("Allocation ID")

                for addr in unattached:
                    table.add_row(
                        addr.get('PublicIp', 'N/A'),
                        addr.get('AllocationId', 'N/A')
                    )

                self.console.print(table)
                self.estimate_cost("unattached EIP(s)", len(unattached), 3.6)

        except ClientError as e:
            self.console.print(f"[red]Error checking Elastic IPs: {e}[/red]")

    def check_vpcs(self):
        """Check VPCs."""
        self.print_header("VPCs")

        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            vpcs = ec2.describe_vpcs(
                Filters=[{'Name': 'isDefault', 'Values': ['false']}]
            )['Vpcs']

            self.print_count("custom VPC(s)", len(vpcs))

            if vpcs:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("VPC ID", style="cyan")
                table.add_column("CIDR Block")
                table.add_column("Name")

                for vpc in vpcs:
                    name = ""
                    if 'Tags' in vpc:
                        name_tag = next((tag['Value'] for tag in vpc['Tags'] if tag['Key'] == 'Name'), "")
                        name = name_tag

                    table.add_row(
                        vpc['VpcId'],
                        vpc['CidrBlock'],
                        name
                    )

                self.console.print(table)
                self.console.print("[green]  Note: VPCs themselves are free, but associated resources cost money[/green]")

        except ClientError as e:
            self.console.print(f"[red]Error checking VPCs: {e}[/red]")

    def check_secrets_manager(self):
        """Check Secrets Manager secrets."""
        self.print_header("SECRETS MANAGER")

        try:
            sm = boto3.client('secretsmanager', region_name=self.region)
            secrets = sm.list_secrets()['SecretList']

            self.print_count("secret(s)", len(secrets))

            if secrets:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Name", style="cyan")
                table.add_column("Last Accessed")

                for secret in secrets:
                    last_access = secret.get('LastAccessedDate')
                    last_access_str = last_access.strftime('%Y-%m-%d') if last_access else 'Never'

                    table.add_row(
                        secret['Name'],
                        last_access_str
                    )

                self.console.print(table)
                self.estimate_cost("secret(s)", len(secrets), 0.40)

        except ClientError as e:
            self.console.print(f"[red]Error checking Secrets Manager: {e}[/red]")

    def check_cloudwatch_logs(self):
        """Check CloudWatch Log Groups."""
        self.print_header("CLOUDWATCH LOG GROUPS")

        try:
            logs = boto3.client('logs', region_name=self.region)
            log_groups = logs.describe_log_groups()['logGroups']

            self.print_count("log group(s)", len(log_groups))

            if log_groups:
                total_bytes = sum(lg.get('storedBytes', 0) for lg in log_groups)
                total_gb = total_bytes / (1024 ** 3)
                self.console.print(f"  Total log storage: [yellow]{total_gb:.2f} GB[/yellow]")

                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Log Group", style="cyan")
                table.add_column("Retention (days)")

                for lg in log_groups[:20]:  # Limit to 20 for display
                    table.add_row(
                        lg['logGroupName'],
                        str(lg.get('retentionInDays', 'Never expire'))
                    )

                self.console.print(table)
                if len(log_groups) > 20:
                    self.console.print(f"[dim]  ... and {len(log_groups) - 20} more[/dim]")

                self.console.print("[yellow]  Note: CloudWatch Logs cost ~$0.50/GB/month[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking CloudWatch Logs: {e}[/red]")

    def check_lambda_functions(self):
        """Check Lambda functions."""
        self.print_header("LAMBDA FUNCTIONS")

        try:
            lambda_client = boto3.client('lambda', region_name=self.region)
            response = lambda_client.list_functions()
            functions = response['Functions']

            self.print_count("Lambda function(s)", len(functions))

            if functions:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Function Name", style="cyan")
                table.add_column("Runtime")
                table.add_column("Memory (MB)")
                table.add_column("Last Modified")

                for func in functions:
                    table.add_row(
                        func['FunctionName'],
                        func['Runtime'],
                        str(func['MemorySize']),
                        func['LastModified'][:10]
                    )

                self.console.print(table)
                self.console.print("[green]  Note: Lambda is pay-per-invocation (usually very low cost unless heavily used)[/green]")

        except ClientError as e:
            self.console.print(f"[red]Error checking Lambda: {e}[/red]")

    def check_elasticache(self):
        """Check ElastiCache clusters."""
        self.print_header("ELASTICACHE CLUSTERS")

        try:
            elasticache = boto3.client('elasticache', region_name=self.region)
            clusters = elasticache.describe_cache_clusters()['CacheClusters']

            self.print_count("ElastiCache cluster(s)", len(clusters))

            if clusters:
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Cluster ID", style="cyan")
                table.add_column("Node Type")
                table.add_column("Engine")
                table.add_column("Status", style="green")

                for cluster in clusters:
                    table.add_row(
                        cluster['CacheClusterId'],
                        cluster['CacheNodeType'],
                        cluster['Engine'],
                        cluster['CacheClusterStatus']
                    )

                self.console.print(table)
                self.console.print("[yellow]  Note: cache.t3.micro ~$12/mo, cache.t3.small ~$25/mo[/yellow]")

        except ClientError as e:
            self.console.print(f"[red]Error checking ElastiCache: {e}[/red]")

    def check_acm_certificates(self):
        """Check ACM Certificates."""
        self.print_header("ACM CERTIFICATES")

        try:
            # Check us-east-1 (for CloudFront)
            acm_global = boto3.client('acm', region_name='us-east-1')
            certs_global = acm_global.list_certificates()['CertificateSummaryList']

            # Check current region if different
            certs_regional = []
            if self.region != 'us-east-1':
                acm_regional = boto3.client('acm', region_name=self.region)
                certs_regional = acm_regional.list_certificates()['CertificateSummaryList']

            total_certs = len(certs_global) + len(certs_regional)
            self.print_count("ACM certificate(s)", total_certs)

            if certs_global:
                self.console.print("\n  Certificates in us-east-1 (for CloudFront):")
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Domain", style="cyan")
                table.add_column("Status", style="green")

                for cert in certs_global:
                    table.add_row(cert['DomainName'], cert.get('Status', 'N/A'))

                self.console.print(table)

            if certs_regional:
                self.console.print(f"\n  Certificates in {self.region}:")
                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Domain", style="cyan")
                table.add_column("Status", style="green")

                for cert in certs_regional:
                    table.add_row(cert['DomainName'], cert.get('Status', 'N/A'))

                self.console.print(table)

            if total_certs > 0:
                self.console.print("[green]  Note: ACM public certificates are FREE (no monthly charge)[/green]")

        except ClientError as e:
            self.console.print(f"[red]Error checking ACM: {e}[/red]")

    def check_budgets(self):
        """Check AWS Budgets."""
        self.print_header("AWS BUDGETS")

        try:
            sts = boto3.client('sts')
            account_id = sts.get_caller_identity()['Account']

            budgets = boto3.client('budgets', region_name='us-east-1')  # Budgets is global, us-east-1
            response = budgets.describe_budgets(AccountId=account_id)

            budget_list = response.get('Budgets', [])

            if budget_list:
                self.console.print(f"[green]{len(budget_list)} budget(s) configured:[/green]")

                table = Table(show_header=True, box=box.SIMPLE)
                table.add_column("Budget Name", style="cyan")
                table.add_column("Limit (USD)", justify="right")
                table.add_column("Type")

                for budget in budget_list[:3]:  # Show first 3
                    table.add_row(
                        budget['BudgetName'],
                        f"${budget['BudgetLimit']['Amount']}",
                        budget['BudgetType']
                    )

                self.console.print(table)
            else:
                self.console.print("[yellow]No budgets configured[/yellow]")
                self.console.print("  Recommendation: Set up a budget to track spending")
                self.console.print("  AWS Console > Billing > Budgets > Create budget")

        except ClientError as e:
            self.console.print(f"[yellow]Cannot check budgets: {e.response['Error']['Message']}[/yellow]")

    def get_month_to_date_costs(self):
        """Get month-to-date costs and forecast."""
        self.print_header("MONTH-TO-DATE COSTS")

        try:
            ce = boto3.client('ce', region_name='us-east-1')  # Cost Explorer is always us-east-1

            # Get current month dates
            today = datetime.now()
            month_start = today.replace(day=1).strftime('%Y-%m-%d')
            month_end = today.strftime('%Y-%m-%d')

            self.console.print(f"Querying Cost Explorer for: {month_start} to {month_end}\n")

            # Get month-to-date costs
            response = ce.get_cost_and_usage(
                TimePeriod={
                    'Start': month_start,
                    'End': month_end
                },
                Granularity='MONTHLY',
                Metrics=['UnblendedCost']
            )

            mtd_cost = float(response['ResultsByTime'][0]['Total']['UnblendedCost']['Amount'])

            self.console.print(f"[green bold]Month-to-date cost: ${mtd_cost:.2f} USD[/green bold]")

            # Get top 5 services
            response_by_service = ce.get_cost_and_usage(
                TimePeriod={
                    'Start': month_start,
                    'End': month_end
                },
                Granularity='MONTHLY',
                Metrics=['UnblendedCost'],
                GroupBy=[{'Type': 'DIMENSION', 'Key': 'SERVICE'}]
            )

            services = response_by_service['ResultsByTime'][0]['Groups']
            services.sort(key=lambda x: float(x['Metrics']['UnblendedCost']['Amount']), reverse=True)

            self.console.print("\n[cyan bold]Top 5 services this month:[/cyan bold]")
            table = Table(show_header=True, box=box.SIMPLE)
            table.add_column("Service", style="cyan")
            table.add_column("Cost (USD)", justify="right", style="yellow")

            for service in services[:5]:
                service_name = service['Keys'][0]
                cost = float(service['Metrics']['UnblendedCost']['Amount'])
                if cost > 0:
                    table.add_row(service_name, f"${cost:.4f}")

            self.console.print(table)

            # Spending warning
            if mtd_cost > 100:
                self.console.print("\n[red bold]WARNING: Month-to-date cost exceeds $100[/red bold]")
            elif mtd_cost > 50:
                self.console.print("\n[yellow]⚠️  Moderate spending detected[/yellow]")
            else:
                self.console.print("\n[green]✓ Spending is within normal range[/green]")

        except ClientError as e:
            error_code = e.response['Error']['Code']
            error_msg = e.response['Error']['Message']

            self.console.print(f"[red]Could not retrieve cost data[/red]\n")
            self.console.print(f"Error: {error_msg}\n")

            if error_code == 'SubscriptionRequiredException':
                self.console.print("[yellow]Issue: Cost Explorer is not enabled[/yellow]")
                self.console.print("Solution: Enable at AWS Console > Billing > Cost Explorer")
            elif 'AccessDenied' in error_code:
                self.console.print("[yellow]Issue: IAM permissions missing[/yellow]")
                self.console.print("Solution: Add 'ce:GetCostAndUsage' permission to your IAM user/role")
            else:
                self.console.print("Possible causes:")
                self.console.print("  1. Cost Explorer not enabled")
                self.console.print("  2. IAM permissions missing (need ce:GetCostAndUsage)")

    def run_report(self):
        """Run the complete cost report."""
        # Print banner
        panel = Panel.fit(
            f"[bold green]AWS COST REPORT[/bold green]\n"
            f"Region: {self.region}\n"
            f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            border_style="green"
        )
        self.console.print(panel)

        # Verify credentials
        self.console.print("\n[cyan]Verifying AWS credentials...[/cyan]")
        valid, account = self.verify_credentials()

        if not valid:
            self.console.print("\n[red bold]ABORTING: Cannot proceed without valid credentials[/red bold]")
            sys.exit(1)

        self.console.print(f"[green]✓ Authenticated as account: {account}[/green]\n")

        # Run checks
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=self.console,
        ) as progress:

            tasks = [
                ("Checking EKS clusters...", self.check_eks_clusters),
                ("Checking EC2 instances...", self.check_ec2_instances),
                ("Checking ECS clusters...", self.check_ecs_clusters),
                ("Checking RDS databases...", self.check_rds_databases),
                ("Checking AWS Bedrock...", self.check_bedrock),
                ("Checking Load Balancers...", self.check_load_balancers),
                ("Checking CloudFront...", self.check_cloudfront),
                ("Checking Route53...", self.check_route53),
                ("Checking NAT Gateways...", self.check_nat_gateways),
                ("Checking EBS volumes...", self.check_ebs_volumes),
                ("Checking Elastic IPs...", self.check_elastic_ips),
                ("Checking VPCs...", self.check_vpcs),
                ("Checking S3 buckets...", self.check_s3_buckets),
                ("Checking ECR repositories...", self.check_ecr_repositories),
                ("Checking Secrets Manager...", self.check_secrets_manager),
                ("Checking CloudWatch Logs...", self.check_cloudwatch_logs),
                ("Checking Lambda functions...", self.check_lambda_functions),
                ("Checking ElastiCache...", self.check_elasticache),
                ("Checking ACM certificates...", self.check_acm_certificates),
            ]

            for desc, func in tasks:
                task = progress.add_task(desc, total=None)
                func()
                progress.remove_task(task)

        # Get costs
        self.get_month_to_date_costs()

        # Check budgets
        self.check_budgets()

        # Summary
        self.print_header("SUMMARY")
        self.console.print(f"[yellow]Total resource types with active resources: {self.total_resources}[/yellow]\n")

        self.console.print("[cyan bold]Major cost drivers to watch:[/cyan bold]")
        self.console.print("  1. EKS Clusters: $73/month per cluster (control plane only)")
        self.console.print("  2. EC2/EKS Nodes: $15-30+/month per instance")
        self.console.print("  3. NAT Gateways: $32/month each")
        self.console.print("  4. Load Balancers: $16/month each (ALB/NLB)")
        self.console.print("  5. RDS Databases: $15-100+/month depending on size")

        self.console.print("\n[green bold]Report complete![/green bold]")


def main():
    """Main entry point."""
    reporter = AWSCostReporter(region=AWS_REGION)
    reporter.run_report()


if __name__ == "__main__":
    main()
