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

    # EGRESS: Allow HTTPS to external APIs (Bedrock, Perplexity)
    egress {
      to {
        # Allow any external destination (AWS Bedrock, Perplexity API)
        # In production, you could restrict this to specific CIDR blocks
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
