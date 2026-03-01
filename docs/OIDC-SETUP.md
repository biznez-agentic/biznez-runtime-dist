# OIDC Provider Setup Guide

This guide covers configuring OpenID Connect (OIDC) authentication for the Biznez Agentic Runtime. The platform is OIDC-first — local JWT authentication is provided only as a fallback for evaluation.

## Overview

| Auth Mode | Value | Use Case |
|-----------|-------|----------|
| OIDC | `auth.mode: oidc` | Production (recommended) |
| Dual | `auth.mode: dual` | Transition period — both OIDC and local JWT |
| Local | `auth.mode: local` | Evaluation only |

## Provider-Agnostic Setup

The platform works with any OIDC-compliant identity provider:

- **Okta** / Okta Workforce
- **Microsoft Entra ID** (Azure AD)
- **Auth0**
- **Keycloak**
- **Google Workspace**
- Any provider that implements OpenID Connect Discovery

### Register the Application

In your identity provider, register a new application/client with:

1. **Application type:** Web application
2. **Grant type:** Authorization Code
3. **Redirect URI:** `https://<frontend-url>/auth/callback`
4. **Logout URI:** `https://<frontend-url>/auth/logout` (if supported)

Note the **Client ID** (audience) and **Issuer URL** from your provider.

## Configuration

Minimum required values:

```yaml
auth:
  mode: oidc
  oidc:
    issuer: "https://idp.example.com"
    audience: "biznez-app"
```

Full configuration options:

```yaml
auth:
  mode: oidc
  oidc:
    issuer: "https://idp.example.com"        # OIDC issuer URL (required)
    audience: "biznez-app"                    # OAuth2 client/audience ID (required)
    jwksUrl: ""                               # Auto-derived from issuer if empty
    jwksCacheTtl: 3600                        # JWKS cache TTL in seconds
    clockSkewSeconds: 30                       # Allowed clock skew for token validation
    claims:
      subject: sub                            # Claim for user subject identifier
      email: email                            # Claim for user email
      name: name                              # Claim for user display name
      groups: groups                          # Claim for group memberships
    roleMapping:
      adminGroups: []                         # Groups granted admin role
      userGroups: []                          # Groups granted user role
    allowedEmailDomains: []                   # Restrict to specific email domains
  existingSecret: ""                          # K8s Secret with AUTH_CLIENT_SECRET
```

### Validation guards (production)

When `global.profile: production`:
- `auth.oidc.issuer` is required (guard error if empty)
- `auth.oidc.audience` is required (guard error if empty)

## Claim Mapping

The platform maps OIDC token claims to internal user attributes:

| Platform Attribute | Default Claim | Description |
|---|---|---|
| Subject (user ID) | `sub` | Unique identifier from the IdP |
| Email | `email` | User's email address |
| Display name | `name` | User's display name |
| Groups | `groups` | Group memberships for role mapping |

Override the claim names if your IdP uses different claim names:

```yaml
auth:
  oidc:
    claims:
      subject: sub
      email: preferred_email     # Custom claim name
      name: display_name         # Custom claim name
      groups: team_memberships   # Custom claim name
```

## Role Mapping

Map IdP groups to platform roles:

```yaml
auth:
  oidc:
    roleMapping:
      adminGroups:
        - "biznez-admins"
        - "platform-team"
      userGroups:
        - "biznez-users"
        - "engineering"
```

Users whose `groups` claim contains a value in `adminGroups` are granted admin privileges. Users in `userGroups` are granted standard user access.

## Redirect URIs

Configure these redirect URIs in your identity provider:

| URI | Purpose |
|-----|---------|
| `https://<frontend-url>/auth/callback` | Authorization code callback |
| `https://<frontend-url>/auth/logout` | Post-logout redirect (if supported) |

The frontend URL is derived from the ingress configuration or `backend.config.frontendUrl`.

## `biznez-cli oidc-discover`

Use this command to verify your OIDC provider configuration:

```bash
biznez-cli oidc-discover --issuer https://idp.example.com
```

This fetches the provider's `.well-known/openid-configuration` endpoint and displays:
- Issuer URL
- Authorization endpoint
- Token endpoint
- JWKS URI
- Supported scopes and claims
- Suggested `values.yaml` configuration

Use this to verify the issuer URL is correct before installing.

## Common Pitfalls

### HTTP vs HTTPS issuer

Many providers require HTTPS for the issuer URL. If your provider returns an error, ensure the issuer URL uses `https://` and matches exactly what the provider expects (including trailing slash or lack thereof).

### Audience mismatch

The `auth.oidc.audience` must match the **Client ID** (or **Audience**) configured in your IdP. Token validation will fail if these don't match. Check your IdP's application registration for the correct value.

### Clock skew

Token validation compares timestamps (`iat`, `exp`, `nbf`) against the server clock. If the backend server's clock differs from the IdP's clock, token validation may fail.

Increase the tolerance:

```yaml
auth:
  oidc:
    clockSkewSeconds: 60   # Default: 30
```

### JWKS cache TTL

The backend caches the IdP's JWKS (JSON Web Key Set) for `jwksCacheTtl` seconds (default: 3600). If the IdP rotates keys, there may be a window where tokens signed with the new key are rejected.

Decrease the TTL if your IdP rotates keys frequently:

```yaml
auth:
  oidc:
    jwksCacheTtl: 600   # Refresh every 10 minutes
```

### JWKS endpoint unreachable

If network policies are enabled and the IdP is external, ensure egress is allowed to the IdP's JWKS endpoint. See [Networking Guide](NETWORKING.md) for egress configuration.

## Dual Mode (Transition)

During migration from local JWT to OIDC:

```yaml
auth:
  mode: dual
```

In dual mode:
- Both OIDC and local JWT tokens are accepted
- Users can authenticate via either method
- The OIDC issuer and audience must still be configured

**Security implications:** Dual mode retains the weaknesses of local JWT (no MFA, no external audit). Use it only during transition and switch to `auth.mode: oidc` once all users are migrated.

## Local JWT (Evaluation Only)

```yaml
auth:
  mode: local
```

In local mode:
- The backend generates and validates its own JWTs using `JWT_SECRET_KEY`
- A bootstrap admin user is created on first start
- Check backend logs for the initial admin credentials

**Limitations:**
- No multi-factor authentication
- No external audit trail
- No SSO or federation
- No password policy enforcement
- Not suitable for production — the production profile guard requires OIDC

Check backend logs for bootstrap credentials:

```bash
kubectl logs deploy/biznez-backend -n biznez | grep -iE 'admin|password|created|bootstrap'
```
