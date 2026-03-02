locals {
  name_prefix  = "biznez-eval-${var.env_id}"
  cluster_name = local.name_prefix

  labels = {
    managed-by  = "biznez-provisioner"
    env-id      = var.env_id
    customer    = var.customer_name
    environment = "eval"
  }
}

# -----------------------------------------------------------------------------
# GKE Autopilot Cluster
# -----------------------------------------------------------------------------
resource "google_container_cluster" "eval_cluster" {
  name     = local.cluster_name
  project  = var.project_id
  location = var.region

  enable_autopilot    = true
  deletion_protection = false

  network    = var.network_id
  subnetwork = var.subnet_id

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pod_range_name
    services_secondary_range_name = var.service_range_name
  }

  release_channel {
    channel = "REGULAR"
  }

  # Public endpoint -- GHA runners need direct API access.
  # Control plane is protected by GCP IAM auth (only WIF SA has access).
  # Private cluster endpoint deferred to 10.3 when bastion/VPN plumbing is justified.

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = local.labels
}
