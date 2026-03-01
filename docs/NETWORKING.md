# Networking Guide

This guide covers network exposure, TLS, streaming timeouts, Gateway API, network policies, proxy configuration, and the Agent Gateway.

## Overview

The chart supports three exposure patterns:

| Pattern | Use Case | Requires |
|---------|----------|----------|
| **ClusterIP + port-forward** | Evaluation, local development | Nothing (default) |
| **Ingress** | Production (most clusters) | Ingress controller (nginx, ALB, etc.) |
| **Gateway API** | Production (newer clusters) | Gateway API CRDs + controller |

Ingress and Gateway API are mutually exclusive — enabling both causes a validation error.

## Evaluation (ClusterIP + Port-Forward)

The default configuration exposes services as ClusterIP only. Access via port-forward:

```bash
kubectl port-forward svc/biznez-frontend 8080:80 -n biznez
kubectl port-forward svc/biznez-backend 8000:8000 -n biznez
```

No ingress controller, TLS certificates, or DNS configuration needed.

## Ingress Setup

Enable ingress and configure hosts:

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: api.biznez.example.com
      paths:
        - path: /
          service: backend
          port: 8000
    - host: app.biznez.example.com
      paths:
        - path: /
          service: frontend
          port: 80
```

### Rendering Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `multiHost` (default) | Single Ingress resource with all hosts | Most deployments |
| `splitByHost` | One Ingress resource per host | Different ingress classes or annotations per host |

Set via `ingress.mode: multiHost` or `ingress.mode: splitByHost`.

In `splitByHost` mode, each host entry can override `className` and `annotations`:

```yaml
ingress:
  mode: splitByHost
  hosts:
    - host: api.biznez.example.com
      className: nginx-internal
      annotations:
        nginx.ingress.kubernetes.io/ssl-redirect: "true"
      paths:
        - path: /
          service: backend
    - host: app.biznez.example.com
      className: nginx-external
      paths:
        - path: /
          service: frontend
```

### Path Validation

Each path must specify a valid `service`: `backend`, `frontend`, or `gateway`. Invalid service names cause a template error.

## TLS Configuration

Enable TLS on the ingress:

```yaml
ingress:
  tls:
    enabled: true
    mode: existingSecret    # or certManager
    secretName: biznez-tls  # required for existingSecret mode
```

### existingSecret mode

Pre-create a TLS Secret and reference it by name:

```bash
kubectl create secret tls biznez-tls \
  --cert=tls.crt --key=tls.key -n biznez
```

### certManager mode

Automated TLS via cert-manager. Set the ClusterIssuer:

```yaml
ingress:
  tls:
    enabled: true
    mode: certManager
    clusterIssuer: letsencrypt-prod
```

The chart adds the `cert-manager.io/cluster-issuer` annotation automatically.

### Validation guards

- `existingSecret` mode requires `ingress.tls.secretName`
- `certManager` mode requires `ingress.tls.clusterIssuer`

## Streaming / SSE Timeouts

The backend uses Server-Sent Events (SSE) for agent streaming responses. This requires the ingress controller to allow long-lived HTTP connections without premature timeout.

### nginx Ingress Controller (reference implementation)

Set `ingress.applyNginxStreamingAnnotations: true` to automatically add:

```yaml
nginx.ingress.kubernetes.io/proxy-read-timeout: "300"    # backend.streaming.proxyReadTimeout
nginx.ingress.kubernetes.io/proxy-send-timeout: "300"    # backend.streaming.proxySendTimeout
nginx.ingress.kubernetes.io/proxy-buffering: "off"       # backend.streaming.proxyBuffering
nginx.ingress.kubernetes.io/proxy-body-size: "10m"       # backend.streaming.maxBodySize
```

These values are sourced from `backend.streaming.*` in `values.yaml` and can be tuned.

### Other Ingress Controllers

The general principle for any ingress controller: **set the read/proxy timeout to be greater than or equal to the streaming window** (default: 300 seconds).

Consult your controller's documentation for the equivalent timeout settings. Common knobs:
- Read timeout / proxy timeout (must be >= 300s)
- Response buffering (should be disabled for SSE)
- Idle connection timeout (must be >= streaming window)

## Gateway API

Alternative to Ingress for clusters with Gateway API support.

### Prerequisites

- Gateway API CRDs installed (`gateway.networking.k8s.io/v1`)
- A Gateway resource deployed and managed by a controller

### Configuration

```yaml
gatewayApi:
  enabled: true
  gatewayRef:
    name: my-gateway
    namespace: gateway-system
  httpRoutes:
    - hostname: api.biznez.example.com
      service: backend
    - hostname: app.biznez.example.com
      service: frontend
```

### Validation guards

- `gatewayApi.gatewayRef.name` is required
- Each `httpRoutes[]` entry requires `hostname` and `service`
- Cannot be enabled simultaneously with `ingress.enabled`

## Network Policies

Enable with `networkPolicy.enabled: true`. The chart creates four NetworkPolicy resources.

### Policy summary

| Policy | Ingress From | Egress To |
|--------|-------------|-----------|
| **Backend** | Frontend, Gateway, Ingress controller NS | DNS, Postgres, Gateway, configured external targets |
| **Frontend** | Ingress controller NS | DNS, Backend |
| **PostgreSQL** (eval) | Backend (port 5432) | None |
| **Gateway** | Backend | DNS, configured external targets |

### Ingress namespace selector

When both `networkPolicy.enabled` and `ingress.enabled` are true, you must specify which namespace the ingress controller runs in:

```yaml
networkPolicy:
  ingress:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: ingress-nginx
```

Or set `networkPolicy.ingress.allowFromAnyNamespace: true` (less secure).

### Egress strategies

Choose one or combine:

**A. Allow all HTTPS** (eval default, not for production):

```yaml
networkPolicy:
  egress:
    allowAllHttps: true
```

**B. Corporate proxy:**

```yaml
networkPolicy:
  egress:
    allowAllHttps: false
    proxy:
      cidrs: ["10.0.0.0/8"]
      ports: [3128, 443]
      httpProxy: "http://proxy.internal:3128"
      httpsProxy: "http://proxy.internal:3128"
      noProxy: ".cluster.local,.svc"
```

**C. Explicit external service CIDRs:**

```yaml
networkPolicy:
  egress:
    allowAllHttps: false
    externalServices:
      cidrs: ["203.0.113.0/24"]
      ports: [443]
```

**D. In-cluster MCP targets:**

```yaml
networkPolicy:
  egress:
    mcpTargets:
      namespaceSelectors:
        - matchLabels:
            kubernetes.io/metadata.name: mcp-services
      ports: [443, 8080]
```

### DNS egress

DNS egress to kube-system (kube-dns/coredns) is always allowed when network policies are enabled. The target is configurable:

```yaml
networkPolicy:
  egress:
    dns:
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchExpressions:
          - key: k8s-app
            operator: In
            values: ["kube-dns", "coredns"]
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

## Proxy Configuration

For environments that require HTTP proxies for outbound traffic, configure proxy environment variables via the egress proxy settings or backend `extraEnv`:

```yaml
backend:
  extraEnv:
    - name: HTTP_PROXY
      value: "http://proxy.internal:3128"
    - name: HTTPS_PROXY
      value: "http://proxy.internal:3128"
    - name: NO_PROXY
      value: ".cluster.local,.svc,localhost,127.0.0.1"
```

When using network policy egress strategy B, also set the proxy CIDRs to allow traffic to the proxy server.

## Agent Gateway

The Agent Gateway is an MCP (Model Context Protocol) proxy that routes tool calls from the backend to external MCP services.

### Configuration

The gateway configuration uses a binds-based structure:

```yaml
gateway:
  enabled: true
  config:
    binds:
      - port: 8080
        listeners:
          - name: mcp-gateway
            routes:
              - name: tavily-route
                matches:
                  - path:
                      pathPrefix: "/org_dev001/tavily"
                backends:
                  - mcp:
                      targets:
                        - name: tavily-mcp
                          mcp:
                            host: "https://mcp.tavily.com/mcp"
```

### Secrets for MCP targets

API keys for MCP target services are managed via `gateway.existingSecret`:

```yaml
gateway:
  existingSecret: biznez-gateway-keys   # K8s Secret with TAVILY_API_KEY, etc.
```

In eval mode, keys can be set inline via `gateway.secrets` (forbidden in production).

### In-cluster URL

The backend reaches the gateway at `http://<release>-gateway:<port>`. This is auto-derived from the release name. Override with `gateway.baseUrl` if the gateway is external or in a different namespace.

## Troubleshooting

### SSE / Streaming Timeouts

**Symptom:** Agent responses cut off mid-stream, or 504 Gateway Timeout during agent execution.

**Fix:** Increase ingress controller timeouts. For nginx, set `ingress.applyNginxStreamingAnnotations: true`. For other controllers, ensure read timeout >= 300s.

### 502 / 504 Errors

**Symptom:** Intermittent bad gateway or gateway timeout errors.

**Possible causes:**
- Backend pod not ready — check `biznez-cli health-check`
- Ingress controller cannot reach backend — verify network policies allow ingress controller namespace
- Resource limits too low — increase `backend.resources.limits`

### Blocked Egress

**Symptom:** Backend cannot reach external LLM APIs or MCP targets.

**Fix:** Check network policy egress rules. If `networkPolicy.egress.allowAllHttps: false`, ensure the target is covered by `proxy.cidrs`, `externalServices.cidrs`, or `mcpTargets.namespaceSelectors`.

```bash
# Test egress from backend pod:
kubectl exec deploy/biznez-backend -n biznez -- \
  wget -qO- --timeout=5 https://api.example.com/health || echo "blocked"
```

### DNS Resolution Failures

**Symptom:** Backend cannot resolve external hostnames.

**Fix:** Verify DNS egress rules in network policy. The default allows UDP/TCP port 53 to kube-dns/coredns in kube-system. If your cluster uses a different DNS setup, update `networkPolicy.egress.dns.*`.
