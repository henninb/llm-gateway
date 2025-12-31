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
from rich.layout import Layout
from rich.tree import Tree
from rich import box
from rich.columns import Columns
from rich.text import Text

console = Console()

# Configuration
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")


class AWSCostReporter:
    def __init__(self, region: str = AWS_REGION):
        self.region = region
        self.total_resources = 0
        self.console = console

        # Cost tracking
        self.cost_summary = {
            'compute': {'count': 0, 'estimated_cost': 0, 'resources': []},
            'storage': {'count': 0, 'estimated_cost': 0, 'resources': []},
            'networking': {'count': 0, 'estimated_cost': 0, 'resources': []},
            'database': {'count': 0, 'estimated_cost': 0, 'resources': []},
            'serverless': {'count': 0, 'estimated_cost': 0, 'resources': []},
            'other': {'count': 0, 'estimated_cost': 0, 'resources': []}
        }
        self.total_estimated_cost = 0

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
        self.console.print(f"\n[bold cyan]{title}[/bold cyan]")

    def display_cost_dashboard(self):
        """Display aggregate cost summary dashboard."""
        self.console.print("\n")

        # Create cost summary table
        table = Table(title="💰 COST SUMMARY BY CATEGORY", box=box.ROUNDED, title_style="bold magenta")
        table.add_column("Category", style="cyan bold", width=15)
        table.add_column("Resources", justify="center", style="yellow", width=10)
        table.add_column("Est. Monthly Cost", justify="right", style="green bold", width=18)

        categories_display = {
            'compute': '🖥️  Compute',
            'database': '🗄️  Database',
            'storage': '💾 Storage',
            'networking': '🌐 Networking',
            'serverless': '⚡ Serverless',
            'other': '📦 Other'
        }

        total_resources = 0
        for cat_key, cat_display in categories_display.items():
            cat_data = self.cost_summary[cat_key]
            if cat_data['count'] > 0:
                table.add_row(
                    cat_display,
                    str(cat_data['count']),
                    f"${cat_data['estimated_cost']:.2f}"
                )
                total_resources += cat_data['count']

        # Add total row
        table.add_section()
        table.add_row(
            "[bold]TOTAL[/bold]",
            f"[bold]{total_resources}[/bold]",
            f"[bold red]${self.total_estimated_cost:.2f}[/bold red]"
        )

        self.console.print(table)

        # Show top cost drivers
        all_resources = []
        for cat_data in self.cost_summary.values():
            all_resources.extend(cat_data['resources'])

        all_resources.sort(key=lambda x: x['cost'], reverse=True)

        if all_resources:
            self.console.print("\n[bold yellow]🔥 Top 5 Cost Drivers:[/bold yellow]")
            for i, res in enumerate(all_resources[:5], 1):
                self.console.print(f"  {i}. {res['name']}: [red]${res['cost']:.2f}/mo[/red] ({res['count']} resource{'s' if res['count'] > 1 else ''})")

        self.console.print()

    def add_cost(self, category: str, resource_name: str, count: int, cost_per_unit: float):
        """Track costs by category."""
        if count > 0:
            total_cost = count * cost_per_unit
            self.cost_summary[category]['count'] += count
            self.cost_summary[category]['estimated_cost'] += total_cost
            self.cost_summary[category]['resources'].append({
                'name': resource_name,
                'count': count,
                'cost': total_cost
            })
            self.total_estimated_cost += total_cost
            self.total_resources += 1

    def print_count(self, resource_type: str, count: int):
        """Print resource count with color coding."""
        if count > 0:
            self.console.print(f"  [cyan]●[/cyan] {count} {resource_type}")
        else:
            self.console.print(f"  [dim]○ No {resource_type}[/dim]", end="")
            return False
        return True

    def estimate_cost(self, resource_type: str, count: int, cost_per_unit: float):
        """Print estimated monthly cost."""
        if count > 0:
            total = count * cost_per_unit
            self.console.print(f"    [yellow]→ ~${total:.2f}/month[/yellow]")

    def check_eks_clusters(self):
        """Check EKS clusters."""
        try:
            eks = boto3.client('eks', region_name=self.region)
            clusters = eks.list_clusters()['clusters']

            if self.print_count("EKS cluster(s)", len(clusters)):
                self.add_cost('compute', 'EKS Clusters', len(clusters), 73)

                # Compact display - just names and node count
                for cluster_name in clusters:
                    nodegroups = eks.list_nodegroups(clusterName=cluster_name)['nodegroups']
                    self.console.print(f"    [dim]├─[/dim] {cluster_name} [dim]({len(nodegroups)} node group{'s' if len(nodegroups) != 1 else ''})[/dim]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

    def check_ec2_instances(self):
        """Check EC2 instances."""
        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            response = ec2.describe_instances(
                Filters=[{'Name': 'instance-state-name', 'Values': ['running']}]
            )

            instances = []
            for reservation in response['Reservations']:
                instances.extend(reservation['Instances'])

            if self.print_count("EC2 instance(s)", len(instances)):
                # Estimate $25/month average
                self.add_cost('compute', 'EC2 Instances', len(instances), 25)

                # Compact display
                for instance in instances:
                    name = next((tag['Value'] for tag in instance.get('Tags', []) if tag['Key'] == 'Name'), instance['InstanceId'])
                    self.console.print(f"    [dim]├─[/dim] {name} [dim]({instance['InstanceType']})[/dim]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

    def check_rds_databases(self):
        """Check RDS databases."""
        try:
            rds = boto3.client('rds', region_name=self.region)
            instances = rds.describe_db_instances()['DBInstances']

            if self.print_count("RDS instance(s)", len(instances)):
                self.add_cost('database', 'RDS Databases', len(instances), 30)

                for db in instances:
                    self.console.print(f"    [dim]├─[/dim] {db['DBInstanceIdentifier']} [dim]({db['DBInstanceClass']}, {db['Engine']})[/dim]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

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
        try:
            s3 = boto3.client('s3')
            buckets = s3.list_buckets()['Buckets']

            if self.print_count("S3 bucket(s)", len(buckets)):
                self.add_cost('storage', 'S3 Buckets', len(buckets), 1)  # Minimal baseline cost

                for bucket in buckets:
                    self.console.print(f"    [dim]├─[/dim] {bucket['Name']}")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

    def check_ecr_repositories(self):
        """Check ECR repositories."""
        try:
            ecr = boto3.client('ecr', region_name=self.region)
            repositories = ecr.describe_repositories()['repositories']

            if self.print_count("ECR repository/repositories", len(repositories)):
                self.add_cost('storage', 'ECR Repositories', len(repositories), 2)  # Baseline ~2GB per repo

                for repo in repositories:
                    images = ecr.list_images(repositoryName=repo['repositoryName'])
                    self.console.print(f"    [dim]├─[/dim] {repo['repositoryName']} [dim]({len(images['imageIds'])} images)[/dim]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

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
        try:
            elbv2 = boto3.client('elbv2', region_name=self.region)
            lbs = elbv2.describe_load_balancers()['LoadBalancers']

            if self.print_count("Load Balancer(s)", len(lbs)):
                self.add_cost('networking', 'Load Balancers', len(lbs), 16)

                for lb in lbs:
                    lb_type = "ALB" if lb['Type'] == 'application' else "NLB"
                    self.console.print(f"    [dim]├─[/dim] {lb['LoadBalancerName']} [dim]({lb_type})[/dim]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

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
        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            nat_gateways = ec2.describe_nat_gateways(
                Filters=[{'Name': 'state', 'Values': ['available']}]
            )['NatGateways']

            if self.print_count("NAT Gateway(s)", len(nat_gateways)):
                self.add_cost('networking', 'NAT Gateways', len(nat_gateways), 32)

                for nat in nat_gateways:
                    self.console.print(f"    [dim]├─[/dim] {nat['NatGatewayId']} [dim](VPC: {nat['VpcId']})[/dim]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

    def check_ebs_volumes(self):
        """Check EBS volumes."""
        try:
            ec2 = boto3.client('ec2', region_name=self.region)
            volumes = ec2.describe_volumes()['Volumes']

            if self.print_count("EBS volume(s)", len(volumes)):
                total_size = sum(vol['Size'] for vol in volumes)
                self.add_cost('storage', 'EBS Volumes', total_size, 0.08)
                self.console.print(f"    [yellow]→ Total: {total_size} GB[/yellow]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

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
        try:
            lambda_client = boto3.client('lambda', region_name=self.region)
            functions = lambda_client.list_functions()['Functions']

            if self.print_count("Lambda function(s)", len(functions)):
                self.add_cost('serverless', 'Lambda Functions', len(functions), 0.5)  # Minimal baseline

                for func in functions[:5]:  # Show first 5
                    self.console.print(f"    [dim]├─[/dim] {func['FunctionName']} [dim]({func['Runtime']})[/dim]")
                if len(functions) > 5:
                    self.console.print(f"    [dim]└─ ...and {len(functions) - 5} more[/dim]")

        except ClientError as e:
            self.console.print(f"  [red]✗ Error: {e.response['Error']['Code']}[/red]")

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
        self.print_header("ACTUAL AWS COSTS")

        try:
            ce = boto3.client('ce', region_name='us-east-1')  # Cost Explorer is always us-east-1

            # Get current month dates
            today = datetime.now()
            month_start = today.replace(day=1).strftime('%Y-%m-%d')
            month_end = today.strftime('%Y-%m-%d')

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

            # Create prominent cost display
            cost_panel = Panel.fit(
                f"[bold cyan]MONTH-TO-DATE COST[/bold cyan]\n\n"
                f"[bold green]${mtd_cost:.2f} USD[/bold green]\n\n"
                f"[dim]{month_start} to {month_end}[/dim]",
                border_style="bright_blue",
                padding=(1, 2)
            )
            self.console.print("\n", cost_panel)

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

            # Spending warning with colored panel
            if mtd_cost > 100:
                warning_panel = Panel(
                    "[bold white]⚠️  WARNING: Month-to-date cost exceeds $100[/bold white]",
                    border_style="red bold",
                    padding=(0, 1)
                )
                self.console.print("\n", warning_panel)
            elif mtd_cost > 50:
                warning_panel = Panel(
                    "[bold black]⚠️  Moderate spending detected[/bold black]",
                    border_style="yellow",
                    padding=(0, 1)
                )
                self.console.print("\n", warning_panel)
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

        # Run checks grouped by category
        self.console.print("\n[bold magenta]🖥️  COMPUTE RESOURCES[/bold magenta]")
        self.check_eks_clusters()
        self.check_ec2_instances()
        self.check_ecs_clusters()

        self.console.print("\n[bold magenta]🗄️  DATABASE & STORAGE[/bold magenta]")
        self.check_rds_databases()
        self.check_elasticache()
        self.check_s3_buckets()
        self.check_ecr_repositories()
        self.check_ebs_volumes()

        self.console.print("\n[bold magenta]🌐 NETWORKING[/bold magenta]")
        self.check_load_balancers()
        self.check_nat_gateways()
        self.check_cloudfront()
        self.check_route53()
        self.check_elastic_ips()
        self.check_vpcs()

        self.console.print("\n[bold magenta]⚡ SERVERLESS & OTHER[/bold magenta]")
        self.check_lambda_functions()
        self.check_bedrock()
        self.check_secrets_manager()
        self.check_cloudwatch_logs()
        self.check_acm_certificates()

        # Display cost dashboard first
        self.display_cost_dashboard()

        # Get actual costs
        self.get_month_to_date_costs()

        # Check budgets
        self.check_budgets()

        self.console.print("\n[green bold]✓ Report complete![/green bold]")


def main():
    """Main entry point."""
    reporter = AWSCostReporter(region=AWS_REGION)
    reporter.run_report()


if __name__ == "__main__":
    main()
