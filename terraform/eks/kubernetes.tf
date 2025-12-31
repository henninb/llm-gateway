# Kubernetes Namespace
resource "kubernetes_namespace" "llm_gateway" {
  metadata {
    name = var.namespace

    labels = {
      name        = var.namespace
      project     = "llm-gateway"
      managed_by  = "terraform"
      environment = var.environment
    }
  }
}

# ConfigMap for LiteLLM configuration
resource "kubernetes_config_map" "litellm_config" {
  metadata {
    name      = "litellm-config"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
  }

  data = {
    "config.yaml" = file("${path.module}/../../config/litellm_config.yaml")
  }
}

# LiteLLM Deployment
resource "kubernetes_deployment" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name

    labels = {
      app = "litellm"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "litellm"
      }
    }

    template {
      metadata {
        labels = {
          app = "litellm"
        }
      }

      spec {
        # Use the service account with IAM role for Bedrock access
        service_account_name = kubernetes_service_account.litellm.metadata[0].name

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
          name  = "litellm"
          image = var.use_ecr_images ? "${data.aws_ecr_repository.litellm.repository_url}:${var.ecr_image_tag}" : "ghcr.io/berriai/litellm:main-latest"

          # Start LiteLLM with the config file
          command = ["litellm"]
          args    = ["--config", "/app/config.yaml", "--port", "4000", "--host", "0.0.0.0"]

          port {
            container_port = 4000
            protocol       = "TCP"
          }

          # Non-root container security context (only when using ECR images)
          dynamic "security_context" {
            for_each = var.use_ecr_images ? [1] : []
            content {
              run_as_non_root            = true
              read_only_root_filesystem  = false # LiteLLM needs to write to /tmp
              allow_privilege_escalation = false
              capabilities {
                drop = ["ALL"]
              }
            }
          }

          env {
            name = "PERPLEXITY_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.api_keys.metadata[0].name
                key  = "perplexity_api_key"
              }
            }
          }

          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.api_keys.metadata[0].name
                key  = "litellm_master_key"
              }
            }
          }

          env {
            name  = "AWS_REGION_NAME"
            value = var.aws_region
          }

          # Security: Drop unsupported parameters instead of failing
          env {
            name  = "LITELLM_DROP_PARAMS"
            value = "true"
          }

          # Security: Enable rate limiting
          env {
            name  = "ENABLE_RATE_LIMIT"
            value = "true"
          }

          resources {
            requests = {
              cpu    = var.litellm_cpu_request
              memory = var.litellm_memory_request
            }
            limits = {
              cpu    = var.litellm_cpu_limit
              memory = var.litellm_memory_limit
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/app/config.yaml"
            sub_path   = "config.yaml"
            read_only  = true
          }

          liveness_probe {
            tcp_socket {
              port = 4000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          readiness_probe {
            tcp_socket {
              port = 4000
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.litellm_config.metadata[0].name
          }
        }
      }
    }
  }
}

# LiteLLM Service (ClusterIP - internal only)
resource "kubernetes_service" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name

    labels = {
      app = "litellm"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "litellm"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 4000
      protocol    = "TCP"
    }
  }
}

# Kubernetes Secret for API Keys (will be populated from AWS Secrets Manager)
resource "kubernetes_secret" "api_keys" {
  metadata {
    name      = "api-keys"
    namespace = kubernetes_namespace.llm_gateway.metadata[0].name
  }

  data = {
    perplexity_api_key = data.aws_secretsmanager_secret_version.api_keys.secret_string != null ? jsondecode(data.aws_secretsmanager_secret_version.api_keys.secret_string)["PERPLEXITY_API_KEY"] : ""
    litellm_master_key = data.aws_secretsmanager_secret_version.api_keys.secret_string != null ? jsondecode(data.aws_secretsmanager_secret_version.api_keys.secret_string)["LITELLM_MASTER_KEY"] : ""
    webui_secret_key   = data.aws_secretsmanager_secret_version.api_keys.secret_string != null ? jsondecode(data.aws_secretsmanager_secret_version.api_keys.secret_string)["WEBUI_SECRET_KEY"] : ""
  }

  type = "Opaque"
}
