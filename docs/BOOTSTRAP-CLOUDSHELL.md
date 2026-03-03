# Bootstrap GCP Prerequisites — Cloud Shell Tutorial

<walkthrough-author name="Biznez" repositoryUrl="https://github.com/biznez-agentic/biznez-runtime-dist"></walkthrough-author>

## Overview

This tutorial sets up all GCP prerequisites needed to run the **Provision Eval Environment** workflow.

**What gets created:**
- 6 GCP APIs enabled
- GCS bucket for Terraform state (hardened)
- Workload Identity Federation pool + OIDC provider
- Service account with eval-scoped IAM roles
- WIF → SA binding (GitHub repo authorization)
- GitHub variable and secrets (if `gh` CLI is available)

**Time:** ~5 minutes

<walkthrough-tutorial-duration duration="5"></walkthrough-tutorial-duration>

Click **Start** to begin.

## Set your project

First, set the GCP project you want to use for eval environments.

<walkthrough-project-setup billing="true"></walkthrough-project-setup>

```bash
gcloud config set project {{project-id}}
```

**Important:** Use a **dedicated eval project**, not a production or shared org project. The bootstrap grants broad admin roles to the provisioner service account.

## Run the bootstrap

Run the bootstrap script with your project ID:

```bash
bash infra/scripts/bootstrap-gcp.sh --project {{project-id}}
```

The script will:
1. Validate your permissions with early-hint probes
2. Show a summary and ask for confirmation
3. Create all resources (idempotent — safe to re-run)
4. Verify everything was created correctly
5. Print a summary with all resource names

### Options

Add `--dry-run` to preview without creating anything:
```bash
bash infra/scripts/bootstrap-gcp.sh --project {{project-id}} --dry-run
```

If the `gh` CLI is not available in Cloud Shell, the script auto-falls back to printing the GitHub commands for you to run manually.

## Set GitHub secrets (if needed)

If the script printed manual GitHub commands (because `gh` was unavailable), run them from a machine with `gh` CLI:

```
gh variable set GCP_PROJECT_ID --body '<project-id>' --repo '<owner/repo>'
gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body '<provider-resource>' --repo '<owner/repo>'
gh secret set GCP_SERVICE_ACCOUNT --body '<sa-email>' --repo '<owner/repo>'
```

The exact values are in the script output and in `infra/.bootstrap.env`.

Alternatively, set them manually in **GitHub repo → Settings → Secrets and variables → Actions**.

## Verify

Check that all prerequisites are in place:

```bash
bash infra/scripts/bootstrap-gcp.sh status --project {{project-id}}
```

All GCP resources should show **EXISTS** or a count matching the required total.

## Next steps

You're ready to provision an eval environment:

1. Go to **GitHub → Actions → Provision Eval Environment**
2. Click **Run workflow**
3. Enter: customer name, region, and (optionally) the GCP project ID
4. The workflow will create a GKE cluster, copy images, and deploy the runtime

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

**Bootstrap complete.** Your GCP project is ready for eval provisioning.
