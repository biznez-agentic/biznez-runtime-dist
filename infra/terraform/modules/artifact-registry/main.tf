locals {
  name_prefix = "biznez-eval-${var.env_id}"
  repo_name   = "${local.name_prefix}-runtime"

  labels = {
    managed-by  = "biznez-provisioner"
    env-id      = var.env_id
    customer    = var.customer_name
    environment = "eval"
  }
}

# -----------------------------------------------------------------------------
# Artifact Registry Docker Repository
# -----------------------------------------------------------------------------
resource "google_artifact_registry_repository" "eval_runtime" {
  repository_id = local.repo_name
  project       = var.project_id
  location      = var.region
  format        = "DOCKER"
  description   = "Biznez eval images for ${var.env_id}"
  labels        = local.labels

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"

    most_recent_versions {
      keep_count = 5
    }
  }
}
