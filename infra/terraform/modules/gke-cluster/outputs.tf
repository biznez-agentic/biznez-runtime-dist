output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.eval_cluster.name
}

output "cluster_endpoint" {
  description = "GKE cluster endpoint"
  value       = google_container_cluster.eval_cluster.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "GKE cluster CA certificate (base64-encoded)"
  value       = google_container_cluster.eval_cluster.master_auth[0].cluster_ca_certificate
  sensitive   = true
}
