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
