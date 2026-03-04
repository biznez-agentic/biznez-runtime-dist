variable "env_id" {
  description = "Environment identifier (customer_name-suffix, e.g., customer1-ab12)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}-[a-z0-9]{4}$", var.env_id))
    error_message = "env_id must match ^[a-z][a-z0-9-]{2,19}-[a-z0-9]{4}$ (e.g., customer1-ab12)."
  }
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west2"
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}
