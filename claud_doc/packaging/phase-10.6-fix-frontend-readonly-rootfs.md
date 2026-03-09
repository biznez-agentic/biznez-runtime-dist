# Fix: Frontend CrashLoopBackOff on Eval — readOnlyRootFilesystem Blocks nginx.conf Write

## Context

After deploying the new frontend image `dev-e8f09d0` (which includes the non-root fix from runtime PR #245) to a fresh eval environment (`manimaun20-slen`, GitHub Actions run 22843184179), the frontend pod enters **CrashLoopBackOff** with:

```
/bin/sh: can't create /etc/nginx/nginx.conf: Read-only file system
```

Backend, gateway, and postgres all start successfully. Only the frontend fails.

## Root Cause

Three independent factors interact to cause the crash:

1. **Non-root container user** — Helm chart runs the frontend as UID 101 (nginx)
2. **readOnlyRootFilesystem security hardening** — Helm chart global default sets `readOnlyRootFilesystem: true`
3. **Startup script writes to `/etc/nginx/nginx.conf`** — the entrypoint runs `envsubst` to generate nginx config at runtime

The non-root fix in runtime PR #245 (`chown nginx:nginx /etc/nginx`) is irrelevant when the entire filesystem is mounted read-only — file ownership doesn't matter if the kernel blocks all writes.

### The crash sequence

1. Container starts as user 101 (nginx)
2. Entrypoint runs: `envsubst '${CSP_CONNECT_SRC}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf`
3. Write to `/etc/nginx/nginx.conf` is blocked by `readOnlyRootFilesystem: true`
4. Shell exits with error → container crashes → CrashLoopBackOff

### Why it works on dev but not eval

| | Dev cluster | Eval cluster |
|---|---|---|
| `runAsUser` | 101 (nginx) | 101 (nginx) |
| `readOnlyRootFilesystem` | **not set** (default false) | **true** (Helm global default) |
| Entrypoint `envsubst` write | Succeeds (filesystem writable) | **Fails** (filesystem read-only) |

The dev cluster's K8s manifests don't set `readOnlyRootFilesystem`. The eval cluster uses the Helm chart which applies it globally as a security hardening default.

### Why the Helm chart already has some writable mounts

The frontend deployment template (`templates/frontend/deployment.yaml`) already mounts:

| Mount | Path | Purpose |
|-------|------|---------|
| `tmp` (emptyDir) | `/tmp` | General temp files |
| `nginx-cache` (emptyDir) | `/var/cache/nginx` | nginx runtime cache |
| `nginx-run` (emptyDir) | `/var/run` | nginx PID file |

These were added during the security hardening phase (Phase 5) for paths that were known to need writes. **`/etc/nginx` was missed** because the original frontend image had a different entrypoint that didn't need to write there at startup.

---

## Pre-Implementation Checks

### 1. Existing mounts under `/etc/nginx`

Check that no ConfigMaps, Secrets, TLS certificates, or other volumes are already mounted inside `/etc/nginx`. Mounting an emptyDir at `/etc/nginx` would **shadow** any existing sub-mounts and break the deployment.

**Current state (verified):** The frontend deployment template has no mounts under `/etc/nginx`. The only content-related mount is `env-config.js` at `/usr/share/nginx/html/env-config.js` (outside `/etc/nginx`). Safe to proceed.

### 2. fsGroup and emptyDir writability

The init container runs as UID 101 and writes to the `nginx-config` emptyDir. Writability depends on the pod's `fsGroup` setting.

**Current state (verified):**
- Global `podSecurityContext.fsGroup: 1000` is set in `values.yaml` (line 36)
- Frontend `podSecurityContext: {}` — empty, so inherits the global fsGroup
- emptyDir volumes created by a pod with `fsGroup` are group-writable by that GID
- UID 101 can write to the emptyDir because Kubernetes sets the volume's group ownership to the fsGroup (GID 1000) with group-write permissions

**Conclusion:** emptyDir is writable by UID 101. No changes needed.

### 3. `/bin/sh` executable by UID 101

The init container command runs `sh -c 'cp -rp ...'`. The shell must be executable by UID 101.

**Current state (verified):** The `nginx:1.25-alpine` base image ships `/bin/sh` (busybox) with permissions `755` (`-rwxr-xr-x`). Any user can execute it. The Dockerfile's `chown` changes only affect `/etc/nginx`, `/var/cache/nginx`, `/var/run`, and `/usr/share/nginx/html` — not `/bin/sh`.

### 4. Trade-offs of mounting the entire `/etc/nginx`

Once `/etc/nginx` is replaced with an emptyDir, the container no longer sees configuration files baked into the image at that path. All files must be explicitly copied by the init container. This means:

- The init container must reliably copy the **full** configuration tree every time
- Future nginx config changes in the image must be picked up by the copy
- Runtime `/etc/nginx` diverges from image `/etc/nginx` (debugging: `docker run` shows different files than the running pod)

These trade-offs are accepted because:
- The mount target **must** be `/etc/nginx` (that's where `nginx.conf` is written)
- The init container copy is deterministic — same image, same files
- This is the standard K8s pattern for nginx with read-only root

**Note on runtime directories:** The `/etc/nginx` tree in `nginx:1.25-alpine` typically contains static config files (`mime.types`, `conf.d/default.conf`, `fastcgi_params`, etc.) and the `templates/` directory added by the Dockerfile. It does not contain runtime directories. If future image versions add runtime state under `/etc/nginx`, the copy could create subtle issues — but this is unlikely and would be caught by the verification steps.

---

## Fix Plan

### Recommended Fix: Add `/etc/nginx` emptyDir + init container

**File:** `helm/biznez-runtime/templates/frontend/deployment.yaml`

#### Init container

Add an init container that copies the full nginx configuration tree from the **read-only image layer** (not from a mounted path) into the writable emptyDir mount. The main container's existing entrypoint then works unchanged.

```yaml
initContainers:
  - name: copy-nginx-config
    image: {{ include "biznez.imageRef" (dict "root" . "image" .Values.frontend.image) }}
    command:
      - sh
      - -c
      - cp -rp /etc/nginx/. /nginx-config/
    volumeMounts:
      - name: nginx-config
        mountPath: /nginx-config
    securityContext:
      runAsUser: 101
      runAsGroup: 101
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

**Copy command:** `cp -rp /etc/nginx/. /nginx-config/`
- `-r` — recursive (copies subdirectories like `templates/`, `conf.d/`)
- `-p` — preserve permissions and ownership
- `/etc/nginx/.` — the trailing `/.` copies **contents** of the directory (not the directory itself), and includes hidden files. This is more robust than wildcard expansion (`*`) which misses dotfiles and can behave inconsistently across shells

**Init container reads from the image layer:** In the init container, `/etc/nginx` is **not** mounted as a volume — it reads directly from the container image's filesystem layer. Only the destination `/nginx-config` is a volume mount (the writable emptyDir). This is what makes the copy work: the source is the image's baked-in `/etc/nginx`, the destination is the writable emptyDir.

**Security context:** The init container uses an explicit security context rather than inheriting the frontend's via the helper template. This ensures:
- Runs as the same UID 101 (nginx) that owns the files in the image (per PR #245's `chown`)
- `readOnlyRootFilesystem: true` is maintained — the only writable path is the emptyDir mount at `/nginx-config`
- If the frontend's security context changes in the future, the init container remains stable and predictable

**Why UID 101 can read `/etc/nginx` in the init container:** The Dockerfile's `chown -R nginx:nginx /etc/nginx` (PR #245) grants ownership to UID 101. The init container runs as UID 101, so it can read all files. The destination `/nginx-config` is an emptyDir with group-write permissions set by the pod's `fsGroup: 1000`.

#### Volume

Add to volumes:

```yaml
- name: nginx-config
  emptyDir: {}
```

#### Volume mount (main container)

Add to the frontend container's volumeMounts:

```yaml
- name: nginx-config
  mountPath: /etc/nginx
```

### Execution flow after fix

1. **Init container** (`copy-nginx-config`): Reads `/etc/nginx/` from the **read-only image layer** (no volume is mounted at `/etc/nginx` in the init container), copies all contents (including `templates/nginx.conf.template`, `mime.types`, `conf.d/`, etc.) into the writable `nginx-config` emptyDir mounted at `/nginx-config`
2. **Main container** starts with `/etc/nginx` mounted as the writable emptyDir (which now contains all the original nginx config files copied by the init container)
3. Entrypoint runs `envsubst '${CSP_CONNECT_SRC}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf` — succeeds because `/etc/nginx` is the writable emptyDir
4. nginx starts normally, reads the generated `nginx.conf`

### Why this requires zero image changes

- The existing Dockerfile already places the template at `/etc/nginx/templates/nginx.conf.template`
- The existing `chown -R nginx:nginx /etc/nginx` ensures UID 101 can read the source files
- The existing entrypoint already reads from and writes to `/etc/nginx`
- The init container uses the same image, just copies the files
- Works identically on dev (no readOnlyRootFilesystem) and eval (with readOnlyRootFilesystem)

---

## Alternative considered: Disable readOnlyRootFilesystem for frontend

```yaml
# values.yaml
frontend:
  containerSecurityContext:
    runAsUser: 101
    runAsGroup: 101
    readOnlyRootFilesystem: false  # Override global default
```

**Rejected** because:
- Weakens the security posture for the frontend container
- CIS Kubernetes Benchmark recommends read-only root for all containers
- The emptyDir approach achieves the same result without compromising security

---

## Files Modified

| # | File | Change |
|---|------|--------|
| 1 | `helm/biznez-runtime/templates/frontend/deployment.yaml` | Add `copy-nginx-config` init container, add `nginx-config` emptyDir volume, add `/etc/nginx` volume mount to main container |

---

## Verification

### 1. Template rendering

```bash
helm template biznez helm/biznez-runtime/ | grep -A20 'copy-nginx-config'
```

Confirm the init container, volume, and mount render correctly.

### 2. Init container completes

```bash
kubectl get pods -n biznez -l app.kubernetes.io/component=frontend
```

Pod should show init container completed (`Init:0/1` → `Running 1/1`), not `Init:CrashLoopBackOff`.

### 3. File ownership and permissions

```bash
kubectl exec -n biznez deploy/biznez-biznez-runtime-frontend -- ls -la /etc/nginx/
kubectl exec -n biznez deploy/biznez-biznez-runtime-frontend -- ls -la /etc/nginx/templates/
```

Confirm:
- `nginx.conf` exists and is writable by nginx user
- `templates/nginx.conf.template` exists and is readable
- All files owned by nginx:nginx (UID 101:101)
- Directory permissions allow traversal

### 4. nginx is using the generated config

```bash
kubectl exec -n biznez deploy/biznez-biznez-runtime-frontend -- cat /etc/nginx/nginx.conf
```

Confirm the file contains the substituted `CSP_CONNECT_SRC` value (not the raw `${CSP_CONNECT_SRC}` template variable).

### 5. nginx process started correctly

```bash
kubectl exec -n biznez deploy/biznez-biznez-runtime-frontend -- ps aux
```

Confirm nginx master and worker processes are running. Expected output similar to:

```
PID   USER     COMMAND
  1   nginx    nginx: master process nginx -g daemon off;
  N   nginx    nginx: worker process
```

### 6. nginx logs show successful startup

```bash
kubectl logs -n biznez deploy/biznez-biznez-runtime-frontend --tail=10
```

Confirm no nginx startup errors in logs.

### 7. Frontend serves traffic via ingress

```bash
curl -s -o /dev/null -w '%{http_code}' http://<INGRESS_IP>/
curl -s -o /dev/null -w '%{http_code}' http://<INGRESS_IP>/health
```

Confirm HTTP 200 on both the root page and health endpoint.

### 8. CSP headers in response (if applicable)

```bash
curl -sI http://<INGRESS_IP>/ | grep -i content-security-policy
```

Confirm CSP `connect-src` directive reflects the substituted value.

### 9. Cross-environment compatibility

Deploy the same FE image to the dev cluster (without readOnlyRootFilesystem). Confirm:
- Init container still runs (copies files to emptyDir — harmless)
- Frontend starts and serves traffic normally
- No behavioral change from the dev cluster's perspective

### 10. Security posture

```bash
kubectl get pod -n biznez -l app.kubernetes.io/component=frontend -o jsonpath='{.items[0].spec.containers[0].securityContext}'
```

Confirm `readOnlyRootFilesystem: true` remains in the main container's security context.

---

## Compatibility

- **Same FE image works on both dev and eval** — no image changes required
- **Backward compatible** — if `readOnlyRootFilesystem` is later removed, the init container still works (just copies files to emptyDir unnecessarily)
- **Forward compatible** — if the FE image changes its nginx config structure, the init container automatically picks up the new files (same image, same copy)

## Maintainability Note

Runtime `/etc/nginx` in the pod will differ from `/etc/nginx` in the image — the pod has the emptyDir copy plus the generated `nginx.conf`, while the image has the original files without the generated config. This is unavoidable given the read-only root requirement and runtime template generation. When debugging nginx config issues, inspect the running pod's `/etc/nginx` (not the image's).
