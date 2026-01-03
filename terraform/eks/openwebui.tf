# OpenWebUI Persistent Volume Claim
resource "kubernetes_persistent_volume_claim" "openwebui_data" {
  metadata {
    name      = "openwebui-data"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    storage_class_name = "ebs-gp3"

    resources {
      requests = {
        storage = var.openwebui_storage_size
      }
    }
  }

  # Don't wait for the PVC to bind - it will bind when the pod is created (WaitForFirstConsumer)
  wait_until_bound = false
}

# OpenWebUI Deployment
resource "kubernetes_deployment" "openwebui" {
  metadata {
    name      = "openwebui"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name

    labels = {
      app = "openwebui"
    }
  }

  spec {
    replicas = 1 # Single replica due to ReadWriteOnce volume

    selector {
      match_labels = {
        app = "openwebui"
      }
    }

    template {
      metadata {
        labels = {
          app = "openwebui"
        }
      }

      spec {
        # Non-root security context (only when using ECR images)
        dynamic "security_context" {
          for_each = var.use_ecr_images ? [1] : []
          content {
            run_as_non_root = true
            run_as_user     = 1000
            run_as_group    = 1000
            fs_group        = 1000
          }
        }

        container {
          name  = "openwebui"
          image = var.use_ecr_images ? "${data.aws_ecr_repository.openwebui.repository_url}:${var.ecr_image_tag}" : "ghcr.io/open-webui/open-webui:v0.6.43"

          port {
            container_port = 8080
            protocol       = "TCP"
          }

          # Non-root container security context (only when using ECR images)
          dynamic "security_context" {
            for_each = var.use_ecr_images ? [1] : []
            content {
              run_as_non_root            = true
              read_only_root_filesystem  = false
              allow_privilege_escalation = false
              capabilities {
                drop = ["ALL"]
              }
            }
          }

          env {
            name  = "OPENAI_API_BASE_URL"
            value = "http://litellm/v1"
          }

          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.api_keys.metadata[0].name
                key  = "litellm_master_key"
              }
            }
          }

          env {
            name = "WEBUI_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.api_keys.metadata[0].name
                key  = "webui_secret_key"
              }
            }
          }

          env {
            name  = "DATA_DIR"
            value = "/app/backend/data"
          }

          env {
            name  = "ENABLE_OLLAMA_API"
            value = "false"
          }

          env {
            name  = "USER_AGENT"
            value = "OpenWebUI"
          }

          env {
            name  = "EVALUATION_ARENA_MODELS"
            value = jsonencode(["perplexity-sonar-pro", "nova-pro", "llama3-2-3b"])
          }

          resources {
            requests = {
              cpu    = var.openwebui_cpu_request
              memory = var.openwebui_memory_request
            }
            limits = {
              cpu    = var.openwebui_cpu_limit
              memory = var.openwebui_memory_limit
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/backend/data"
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 180 # Allow time for embedding model downloads
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.openwebui_data.metadata[0].name
          }
        }
      }
    }
  }
}

# OpenWebUI Service (LoadBalancer - internet-facing)
resource "kubernetes_service" "openwebui" {
  metadata {
    name      = "openwebui"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name

    labels = {
      app = "openwebui"
    }

    annotations = merge(
      {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "nlb"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-security-groups" = aws_security_group.cloudflare_only.id
      },
      var.acm_certificate_arn != "" ? {
        "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"               = var.acm_certificate_arn
        "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"              = "443"
        "service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy" = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      } : {}
    )
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "openwebui"
    }

    # HTTPS port (only if ACM certificate is provided)
    dynamic "port" {
      for_each = var.acm_certificate_arn != "" ? [1] : []
      content {
        name        = "https"
        port        = 443
        target_port = 8080
        protocol    = "TCP"
      }
    }
  }
}

# Output OpenWebUI LoadBalancer hostname
output "openwebui_loadbalancer_hostname" {
  description = "LoadBalancer hostname for OpenWebUI"
  value       = kubernetes_service.openwebui.status[0].load_balancer[0].ingress[0].hostname
}

output "openwebui_url" {
  description = "Full URL to access OpenWebUI"
  value       = var.acm_certificate_arn != "" ? "https://${kubernetes_service.openwebui.status[0].load_balancer[0].ingress[0].hostname}" : "http://${kubernetes_service.openwebui.status[0].load_balancer[0].ingress[0].hostname}"
}
