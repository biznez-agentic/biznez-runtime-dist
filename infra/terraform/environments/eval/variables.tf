variable "customer_name" {
  description = "Customer name (alphanumeric + hyphens, 3-20 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.customer_name))
    error_message = "customer_name must start with a lowercase letter, contain only lowercase letters, digits, and hyphens, and be 3-20 characters."
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
