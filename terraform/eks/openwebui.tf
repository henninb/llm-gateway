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
  # Don't wait for rollout - the api-keys secret must be created first via External Secrets
  wait_for_rollout = false

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
                name = "api-keys"
                key  = "litellm_master_key"
              }
            }
          }

          env {
            name = "WEBUI_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "api-keys"
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
            value = jsonencode(["nova-lite", "nova-pro", "llama3-2-3b"])
          }

          env {
            name  = "ENABLE_EVALUATION_ARENA_MODELS"
            value = "false"
          }

          env {
            name  = "BYPASS_MODEL_ACCESS_CONTROL"
            value = "true"
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

# OpenWebUI Service (ClusterIP - internal only, accessed via Ingress)
resource "kubernetes_service" "openwebui" {
  metadata {
    name      = "openwebui"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name

    labels = {
      app = "openwebui"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "openwebui"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

# OpenWebUI Ingress (creates ALB)
resource "kubernetes_ingress_v1" "openwebui" {
  count = var.acm_certificate_arn != "" ? 1 : 0

  metadata {
    name      = "openwebui"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name

    labels = {
      app = "openwebui"
    }

    annotations = {
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ "HTTP" = 80 }, { "HTTPS" = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/ssl-policy"      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      "alb.ingress.kubernetes.io/security-groups" = aws_security_group.alb_unified.id
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service.openwebui.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# Output OpenWebUI ALB hostname
output "openwebui_loadbalancer_hostname" {
  description = "ALB hostname for OpenWebUI"
  value       = var.acm_certificate_arn != "" && length(kubernetes_ingress_v1.openwebui) > 0 && length(kubernetes_ingress_v1.openwebui[0].status) > 0 && length(kubernetes_ingress_v1.openwebui[0].status[0].load_balancer) > 0 && length(kubernetes_ingress_v1.openwebui[0].status[0].load_balancer[0].ingress) > 0 ? kubernetes_ingress_v1.openwebui[0].status[0].load_balancer[0].ingress[0].hostname : "Provisioning ALB..."
}

output "openwebui_url" {
  description = "Full URL to access OpenWebUI"
  value       = var.acm_certificate_arn != "" && length(kubernetes_ingress_v1.openwebui) > 0 && length(kubernetes_ingress_v1.openwebui[0].status) > 0 && length(kubernetes_ingress_v1.openwebui[0].status[0].load_balancer) > 0 && length(kubernetes_ingress_v1.openwebui[0].status[0].load_balancer[0].ingress) > 0 ? "https://${kubernetes_ingress_v1.openwebui[0].status[0].load_balancer[0].ingress[0].hostname}" : "Provisioning ALB..."
}
