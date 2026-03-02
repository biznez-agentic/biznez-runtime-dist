variable "env_id" {
  description = "Environment identifier (customer-xxxx)"
  type        = string
}

variable "customer_name" {
  description = "Customer name for resource labeling"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "network_id" {
  description = "VPC network ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID"
  type        = string
}

variable "pod_range_name" {
  description = "Name of the secondary IP range for pods"
  type        = string
}

variable "service_range_name" {
  description = "Name of the secondary IP range for services"
  type        = string
}
