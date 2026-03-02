# -----------------------------------------------------------------------------
# IAM bindings for Artifact Registry image pulls
#
# GKE Autopilot pulls images using node-level credentials (not Workload Identity).
# Which principal the kubelet uses depends on cluster config. We bind both:
#   1. Compute Engine default SA (most common)
#   2. GKE service agent (fallback, used in some configurations)
#
# Both bindings are at project level (acceptable for single-project eval).
# No imagePullSecrets needed.
# -----------------------------------------------------------------------------

resource "google_project_iam_member" "compute_sa_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${var.project_number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "gke_agent_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:service-${var.project_number}@container-engine-robot.iam.gserviceaccount.com"
}
