# -----------------------------------------------------------------------------
# Biznez Eval Environment — Root Module
# Composes: networking, gke-cluster, artifact-registry, iam
# -----------------------------------------------------------------------------

locals {
  env_id        = var.env_id
  customer_name = replace(var.env_id, "/-[a-z0-9]{4}$/", "")
}

# Fetch project number for IAM bindings
data "google_project" "current" {
  project_id = var.project_id
}

# -----------------------------------------------------------------------------
# Networking — VPC, Subnet, NAT
# -----------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  env_id        = local.env_id
  customer_name = local.customer_name
  region        = var.region
  project_id    = var.project_id
}

# -----------------------------------------------------------------------------
# GKE Autopilot Cluster
# -----------------------------------------------------------------------------
module "gke_cluster" {
  source = "../../modules/gke-cluster"

  env_id             = local.env_id
  customer_name      = local.customer_name
  region             = var.region
  project_id         = var.project_id
  network_id         = module.networking.network_id
  subnet_id          = module.networking.subnet_id
  pod_range_name     = module.networking.pod_range_name
  service_range_name = module.networking.service_range_name
}

# -----------------------------------------------------------------------------
# Artifact Registry — Docker Repo
# -----------------------------------------------------------------------------
module "artifact_registry" {
  source = "../../modules/artifact-registry"

  env_id        = local.env_id
  customer_name = local.customer_name
  region        = var.region
  project_id    = var.project_id
}

# -----------------------------------------------------------------------------
# IAM — AR Reader for GKE Node SAs
# -----------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  env_id         = local.env_id
  project_id     = var.project_id
  project_number = data.google_project.current.number
}
