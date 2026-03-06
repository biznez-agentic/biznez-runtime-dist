output "network_id" {
  description = "VPC network ID"
  value       = google_compute_network.eval_vpc.id
}

output "network_name" {
  description = "VPC network name"
  value       = google_compute_network.eval_vpc.name
}

output "subnet_id" {
  description = "Subnet ID"
  value       = google_compute_subnetwork.eval_subnet.id
}

output "subnet_name" {
  description = "Subnet name"
  value       = google_compute_subnetwork.eval_subnet.name
}

output "pod_range_name" {
  description = "Name of the secondary IP range for pods"
  value       = google_compute_subnetwork.eval_subnet.secondary_ip_range[0].range_name
}

output "service_range_name" {
  description = "Name of the secondary IP range for services"
  value       = google_compute_subnetwork.eval_subnet.secondary_ip_range[1].range_name
}

output "ingress_ip" {
  description = "Static external IP for ingress load balancer"
  value       = google_compute_address.ingress_ip.address
}
