# no-gcp-in-dist.rego -- Catch accidental GCP-specific references in rendered YAML
#
# This policy ensures the distribution chart contains no GCP-specific strings
# that would tie it to a specific cloud provider.

package main

import rego.v1

# GCP API domains
deny contains msg if {
    input.kind
    some key, val in object.union(
        object.get(input, "metadata", {}),
        object.get(input, "spec", {})
    )
    contains_gcp_ref(val)
    msg := sprintf("GCP reference found in %s/%s (key: %s): distribution chart must be cloud-agnostic", [input.kind, object.get(input.metadata, "name", "unknown"), key])
}

# Check string values for GCP patterns
contains_gcp_ref(val) if {
    is_string(val)
    gcp_pattern := [
        "googleapis.com",
        "gke.io",
        "cloud.google.com",
        "pkg.dev",
        "gcr.io",
        "gke-managed",
        "container.googleapis.com"
    ]
    some pattern in gcp_pattern
    contains(val, pattern)
}

# Check for GCP project ID pattern (e.g., biznez-platform-prod, biznez-dev-12345)
deny contains msg if {
    input.kind
    some container in object.get(object.get(input, "spec", {}), "containers", [])
    some env_var in object.get(container, "env", [])
    val := object.get(env_var, "value", "")
    is_string(val)
    regex.match(`biznez-[a-z]+-[a-z0-9]+\.pkg\.dev`, val)
    msg := sprintf("GCP Artifact Registry URL found in %s/%s env var %s", [input.kind, object.get(input.metadata, "name", "unknown"), env_var.name])
}
