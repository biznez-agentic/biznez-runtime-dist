locals {
  name_prefix = "biznez-eval-${var.env_id}"

  labels = {
    managed-by  = "biznez-provisioner"
    env-id      = var.env_id
    customer    = var.customer_name
    environment = "eval"
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "google_compute_network" "eval_vpc" {
  name                    = "${local.name_prefix}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  description             = "VPC for Biznez eval environment ${var.env_id}"
}

# -----------------------------------------------------------------------------
# Subnet with secondary ranges for GKE pods and services
# -----------------------------------------------------------------------------
resource "google_compute_subnetwork" "eval_subnet" {
  name                     = "${local.name_prefix}-subnet"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.eval_vpc.id
  ip_cidr_range            = "10.0.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${local.name_prefix}-pods"
    ip_cidr_range = "10.4.0.0/16"
  }

  secondary_ip_range {
    range_name    = "${local.name_prefix}-services"
    ip_cidr_range = "10.8.0.0/20"
  }
}

# -----------------------------------------------------------------------------
# Cloud Router + NAT for outbound internet access
# -----------------------------------------------------------------------------
resource "google_compute_router" "nat_router" {
  name    = "${local.name_prefix}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.eval_vpc.id
}

resource "google_compute_router_nat" "nat_config" {
  name                               = "${local.name_prefix}-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.nat_router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}
