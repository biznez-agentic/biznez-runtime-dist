output "env_id" {
  description = "Environment identifier (customer-xxxx)"
  value       = var.env_id
}

output "cluster_name" {
  description = "GKE cluster name"
  value       = module.gke_cluster.cluster_name
}

output "cluster_endpoint" {
  description = "GKE cluster endpoint"
  value       = module.gke_cluster.cluster_endpoint
  sensitive   = true
}

output "ar_url" {
  description = "Artifact Registry URL for image pushes"
  value       = module.artifact_registry.ar_url
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}
