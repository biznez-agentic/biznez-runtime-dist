terraform {
  backend "gcs" {
    # Both bucket and prefix set via -backend-config at init time:
    #   -backend-config="bucket=biznez-terraform-state-<project-id>"
    #   -backend-config="prefix=eval/<env_id>"
    # See infra/scripts/bootstrap-gcp.sh for bucket naming convention.
  }
}
