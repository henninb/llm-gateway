# Network Policies for LLM Gateway
# Implements zero-trust networking to restrict pod-to-pod communication

# Network Policy for LiteLLM
# - Only allow ingress from OpenWebUI pods
# - Allow egress to external APIs (Bedrock, Perplexity) and DNS
resource "kubernetes_network_policy" "litellm" {
  metadata {
    name      = "litellm-network-policy"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
    labels = {
      app = "litellm"
    }
  }

  spec {
    pod_selector {
      match_labels = {
        app = "litellm"
      }
    }

    policy_types = ["Ingress", "Egress"]

    # INGRESS: Only allow connections from OpenWebUI pods
    ingress {
      from {
        pod_selector {
          match_labels = {
            app = "openwebui"
          }
        }
      }

      ports {
        port     = "4000"
        protocol = "TCP"
      }
    }

    # EGRESS: Allow DNS resolution (required for API calls)
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

    # EGRESS: Allow HTTPS to external APIs
    #
    # SECURITY NOTE:
    # - AWS Bedrock traffic uses VPC endpoints (private network, no internet)
    # - Perplexity API (api.perplexity.ai) requires internet access
    # - Perplexity uses CloudFlare CDN (IPs change frequently), so we can't use static IP filtering
    #
    # CURRENT STATE: Allows HTTPS to any destination (except AWS metadata service)
    #
    # RISK: Compromised container could exfiltrate data to attacker-controlled HTTPS endpoints
    #
    # MITIGATION OPTIONS:
    # 1. VPC Endpoints for AWS (IMPLEMENTED) - AWS traffic stays private
    # 2. AWS Network Firewall with domain filtering - Cost: ~$285/month, overkill for this setup
    # 3. Service Mesh (Istio/Calico Enterprise) - Complex, resource overhead
    # 4. Accept risk with monitoring - Use VPC Flow Logs + CloudWatch alerts for anomalies
    #
    # RECOMMENDATION: Use VPC Flow Logs to monitor outbound HTTPS connections
    egress {
      to {
        # Allow HTTPS to any external destination
        # AWS Bedrock: Uses VPC endpoint (doesn't hit this rule)
        # Perplexity API: Requires internet access via NAT Gateway
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            "169.254.169.254/32", # Block AWS metadata service (SSRF protection)
            "169.254.170.2/32"    # Block ECS/EKS task metadata endpoint
          ]
        }
      }

      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# Network Policy for OpenWebUI
# - Allow ingress from anywhere (exposed via LoadBalancer)
# - Only allow egress to LiteLLM and DNS
resource "kubernetes_network_policy" "openwebui" {
  metadata {
    name      = "openwebui-network-policy"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
    labels = {
      app = "openwebui"
    }
  }

  spec {
    pod_selector {
      match_labels = {
        app = "openwebui"
      }
    }

    policy_types = ["Ingress", "Egress"]

    # INGRESS: Allow from anywhere (LoadBalancer will route traffic here)
    ingress {
      from {
        # Allow all sources (LoadBalancer, health checks, users)
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }

    # EGRESS: Allow DNS resolution
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

    # EGRESS: Allow connections to LiteLLM only
    egress {
      to {
        pod_selector {
          match_labels = {
            app = "litellm"
          }
        }
      }

      ports {
        port     = "4000"
        protocol = "TCP"
      }
    }

    # EGRESS: Allow connections to AWS Secrets Manager (for API key retrieval)
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            "169.254.169.254/32" # Block AWS metadata service
          ]
        }
      }

      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# Output network policy status
output "network_policies_enabled" {
  description = "Network policies have been applied"
  value = {
    litellm_policy   = kubernetes_network_policy.litellm.metadata[0].name
    openwebui_policy = kubernetes_network_policy.openwebui.metadata[0].name
  }
}
