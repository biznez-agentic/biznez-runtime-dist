terraform {
  backend "gcs" {
    bucket = "biznez-terraform-state"
    # prefix is set dynamically via -backend-config="prefix=eval/<env_id>"
    # This ensures each environment has isolated state under eval/<env_id>
  }
}
