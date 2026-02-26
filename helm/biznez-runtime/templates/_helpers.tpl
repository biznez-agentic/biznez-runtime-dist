{{/*
Biznez Agentic Runtime -- Helm template helpers
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "biznez.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated to 63 chars because some K8s name fields are limited to that.
*/}}
{{- define "biznez.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "biznez.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "biznez.labels" -}}
helm.sh/chart: {{ include "biznez.chart" . }}
{{ include "biznez.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: biznez-runtime
{{- end }}

{{/*
Selector labels for matching pods to deployments/services.
Usage: {{ include "biznez.selectorLabels" . }}
*/}}
{{- define "biznez.selectorLabels" -}}
app.kubernetes.io/name: {{ include "biznez.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component-specific labels. Call with a dict containing "root" (top-level context)
and "component" (string name).
Usage: {{ include "biznez.componentLabels" (dict "root" . "component" "backend") }}
*/}}
{{- define "biznez.componentLabels" -}}
{{ include "biznez.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Component-specific selector labels.
Usage: {{ include "biznez.componentSelectorLabels" (dict "root" . "component" "backend") }}
*/}}
{{- define "biznez.componentSelectorLabels" -}}
{{ include "biznez.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Construct a fully qualified image reference.
Params: dict with "root" (top-level context), "image" (image dict with repository, tag, digest, pullPolicy)
Logic: if digest is set, use @sha256:...; else use :tag (defaulting to appVersion).
       If global.imageRegistry is set, prepend it.
Usage: {{ include "biznez.imageRef" (dict "root" . "image" .Values.backend.image) }}
*/}}
{{- define "biznez.imageRef" -}}
{{- $registry := .root.Values.global.imageRegistry -}}
{{- $repository := .image.repository -}}
{{- $tag := .image.tag | default .root.Chart.AppVersion -}}
{{- $digest := .image.digest -}}
{{- if $registry -}}
  {{- if $digest -}}
    {{- printf "%s/%s@%s" $registry $repository $digest -}}
  {{- else -}}
    {{- printf "%s/%s:%s" $registry $repository $tag -}}
  {{- end -}}
{{- else -}}
  {{- if $digest -}}
    {{- printf "%s@%s" $repository $digest -}}
  {{- else -}}
    {{- printf "%s:%s" $repository $tag -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Resolve the image pull policy for a component.
Falls back to global.imagePullPolicy if the component doesn't set one.
Usage: {{ include "biznez.imagePullPolicy" (dict "root" . "image" .Values.backend.image) }}
*/}}
{{- define "biznez.imagePullPolicy" -}}
{{- .image.pullPolicy | default .root.Values.global.imagePullPolicy -}}
{{- end }}

{{/*
Resolve the backend Secret name.
If backend.existingSecret is set, use it; otherwise use the generated name.
Usage: {{ include "biznez.backendSecretName" . }}
*/}}
{{- define "biznez.backendSecretName" -}}
{{- if .Values.backend.existingSecret -}}
  {{- .Values.backend.existingSecret -}}
{{- else -}}
  {{- printf "%s-backend" (include "biznez.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolve the PostgreSQL Secret name (embedded).
Usage: {{ include "biznez.postgresSecretName" . }}
*/}}
{{- define "biznez.postgresSecretName" -}}
{{- if .Values.postgres.existingSecret -}}
  {{- .Values.postgres.existingSecret -}}
{{- else -}}
  {{- printf "%s-postgres" (include "biznez.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolve the PostgreSQL Secret name for external database.
Usage: {{ include "biznez.postgresExternalSecretName" . }}
*/}}
{{- define "biznez.postgresExternalSecretName" -}}
{{- if .Values.postgres.external.existingSecret -}}
  {{- .Values.postgres.external.existingSecret -}}
{{- else -}}
  {{- include "biznez.postgresSecretName" . -}}
{{- end -}}
{{- end }}

{{/*
Resolve the LLM Secret name.
Usage: {{ include "biznez.llmSecretName" . }}
*/}}
{{- define "biznez.llmSecretName" -}}
{{- if .Values.llm.existingSecret -}}
  {{- .Values.llm.existingSecret -}}
{{- else -}}
  {{- printf "%s-llm" (include "biznez.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolve the Langfuse Secret name.
Usage: {{ include "biznez.langfuseSecretName" . }}
*/}}
{{- define "biznez.langfuseSecretName" -}}
{{- if .Values.langfuse.existingSecret -}}
  {{- .Values.langfuse.existingSecret -}}
{{- else -}}
  {{- printf "%s-langfuse" (include "biznez.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolve the Gateway Secret name.
Usage: {{ include "biznez.gatewaySecretName" . }}
*/}}
{{- define "biznez.gatewaySecretName" -}}
{{- if .Values.gateway.existingSecret -}}
  {{- .Values.gateway.existingSecret -}}
{{- else -}}
  {{- printf "%s-gateway" (include "biznez.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolve the Auth Secret name.
Usage: {{ include "biznez.authSecretName" . }}
*/}}
{{- define "biznez.authSecretName" -}}
{{- if .Values.auth.existingSecret -}}
  {{- .Values.auth.existingSecret -}}
{{- else -}}
  {{- printf "%s-auth" (include "biznez.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Construct the DATABASE_URL.
Precedence:
  1. postgres.external.databaseUrl (full override)
  2. Constructed from postgres.external fields (when postgres.enabled=false)
  3. Constructed from embedded postgres (when postgres.enabled=true)
Usage: {{ include "biznez.databaseUrl" . }}
*/}}
{{- define "biznez.databaseUrl" -}}
{{- if .Values.postgres.external.databaseUrl -}}
  {{- .Values.postgres.external.databaseUrl -}}
{{- else if not .Values.postgres.enabled -}}
  {{- $host := required "postgres.external.host is required when embedded postgres is disabled" .Values.postgres.external.host -}}
  {{- $port := .Values.postgres.external.port | default "5432" -}}
  {{- $db := .Values.postgres.external.database | default "biznez_platform" -}}
  {{- $ssl := .Values.postgres.external.sslMode | default "require" -}}
  {{- printf "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@%s:%s/%s?sslmode=%s" $host $port $db $ssl -}}
{{- else -}}
  {{- $host := printf "%s-postgres" (include "biznez.fullname" .) -}}
  {{- $db := .Values.postgres.database | default "biznez_platform" -}}
  {{- printf "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@%s:5432/%s?sslmode=disable" $host $db -}}
{{- end -}}
{{- end }}

{{/*
Derive the public frontend URL.
Precedence: explicit > ingress-derived > eval default.
Usage: {{ include "biznez.publicUrl.frontend" . }}
*/}}
{{- define "biznez.publicUrl.frontend" -}}
{{- if .Values.backend.config.frontendUrl -}}
  {{- .Values.backend.config.frontendUrl -}}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts -}}
  {{- $scheme := ternary "https" "http" .Values.ingress.tls.enabled -}}
  {{- range .Values.ingress.hosts -}}
    {{- if eq (index .paths 0).service "frontend" -}}
      {{- printf "%s://%s" $scheme .host -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
  {{- print "http://localhost:8080" -}}
{{- end -}}
{{- end }}

{{/*
Derive the public API URL.
Precedence: explicit > ingress-derived > eval default.
Usage: {{ include "biznez.publicUrl.api" . }}
*/}}
{{- define "biznez.publicUrl.api" -}}
{{- if .Values.backend.config.apiUrl -}}
  {{- .Values.backend.config.apiUrl -}}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts -}}
  {{- $scheme := ternary "https" "http" .Values.ingress.tls.enabled -}}
  {{- range .Values.ingress.hosts -}}
    {{- if eq (index .paths 0).service "backend" -}}
      {{- printf "%s://%s" $scheme .host -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
  {{- print "http://localhost:8000" -}}
{{- end -}}
{{- end }}

{{/*
Derive CORS origins.
Precedence: explicit > frontend URL derived above.
Usage: {{ include "biznez.corsOrigins" . }}
*/}}
{{- define "biznez.corsOrigins" -}}
{{- if .Values.backend.config.corsOrigins -}}
  {{- .Values.backend.config.corsOrigins -}}
{{- else -}}
  {{- include "biznez.publicUrl.frontend" . -}}
{{- end -}}
{{- end }}

{{/*
Pod security context for a component.
Merges component-level overrides on top of global defaults.
Usage: {{ include "biznez.podSecurityContext" (dict "root" . "component" .Values.backend) | nindent 8 }}
*/}}
{{- define "biznez.podSecurityContext" -}}
{{- $global := .root.Values.global.podSecurityContext -}}
{{- $override := .component.securityContext | default dict -}}
{{- $merged := mustMergeOverwrite (deepCopy $global) $override -}}
{{- toYaml $merged -}}
{{- end }}

{{/*
Container security context for a component.
Merges component-level overrides on top of global defaults.
Usage: {{ include "biznez.containerSecurityContext" (dict "root" . "component" .Values.backend) | nindent 12 }}
*/}}
{{- define "biznez.containerSecurityContext" -}}
{{- $global := .root.Values.global.containerSecurityContext -}}
{{- $override := .component.securityContext | default dict -}}
{{- $merged := mustMergeOverwrite (deepCopy $global) $override -}}
{{- toYaml $merged -}}
{{- end }}

{{/*
Standard /tmp emptyDir volume definition.
Usage: {{ include "biznez.tmpVolume" . | nindent 8 }}
*/}}
{{- define "biznez.tmpVolume" -}}
- name: tmp
  emptyDir: {}
{{- end }}

{{/*
Standard /tmp emptyDir volume mount.
Usage: {{ include "biznez.tmpVolumeMount" . | nindent 12 }}
*/}}
{{- define "biznez.tmpVolumeMount" -}}
- name: tmp
  mountPath: /tmp
{{- end }}

{{/*
Backend envFrom block -- shared between backend Deployment and migration Job.
Injects the ConfigMap as environment source.
Usage: {{ include "biznez.backend.envFrom" . | nindent 12 }}
*/}}
{{- define "biznez.backend.envFrom" -}}
- configMapRef:
    name: {{ include "biznez.fullname" . }}-backend
{{- end }}

{{/*
Backend env vars -- shared between backend Deployment and migration Job.
Injects secrets as individual env entries (not envFrom) for visibility and validation.
Usage: {{ include "biznez.backend.envVars" . | nindent 12 }}
*/}}
{{- define "biznez.backend.envVars" -}}
- name: DATABASE_URL
  value: {{ include "biznez.databaseUrl" . | quote }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      {{- if .Values.postgres.enabled }}
      name: {{ include "biznez.postgresSecretName" . }}
      {{- else }}
      name: {{ include "biznez.postgresExternalSecretName" . }}
      {{- end }}
      key: POSTGRES_USER
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      {{- if .Values.postgres.enabled }}
      name: {{ include "biznez.postgresSecretName" . }}
      {{- else }}
      name: {{ include "biznez.postgresExternalSecretName" . }}
      {{- end }}
      key: POSTGRES_PASSWORD
- name: ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "biznez.backendSecretName" . }}
      key: ENCRYPTION_KEY
- name: JWT_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "biznez.backendSecretName" . }}
      key: JWT_SECRET_KEY
{{- if ne .Values.llm.provider "none" }}
- name: LLM_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "biznez.llmSecretName" . }}
      key: LLM_API_KEY
      optional: true
{{- end }}
{{- if .Values.langfuse.enabled }}
- name: LANGFUSE_PUBLIC_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "biznez.langfuseSecretName" . }}
      key: LANGFUSE_PUBLIC_KEY
      optional: true
- name: LANGFUSE_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "biznez.langfuseSecretName" . }}
      key: LANGFUSE_SECRET_KEY
      optional: true
{{- end }}
{{- if .Values.gateway.enabled }}
- name: AGENT_GATEWAY_URL
  value: {{ .Values.gateway.baseUrl | quote }}
{{- end }}
- name: FRONTEND_URL
  value: {{ include "biznez.publicUrl.frontend" . | quote }}
- name: API_BASE_URL
  value: {{ include "biznez.publicUrl.api" . | quote }}
- name: CORS_ORIGINS
  value: {{ include "biznez.corsOrigins" . | quote }}
{{- end }}

{{/*
ServiceAccount name.
Usage: {{ include "biznez.serviceAccountName" . }}
*/}}
{{- define "biznez.serviceAccountName" -}}
{{- if .Values.rbac.serviceAccountName -}}
  {{- .Values.rbac.serviceAccountName -}}
{{- else -}}
  {{- include "biznez.fullname" . -}}
{{- end -}}
{{- end }}
