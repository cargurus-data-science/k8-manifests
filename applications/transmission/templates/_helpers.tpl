{{/*
Shared helpers. Everything is keyed off .Values.service.name (the canonical
per-service handle), NOT the Helm release name — one chart serves many services,
and the release name is set per `helm upgrade --install <service> chart/`.
*/}}

{{/*
transmission.name — the canonical resource name. Required; fail loudly if a
values file forgot to set it, rather than silently rendering empty names that
collide across services.
*/}}
{{- define "transmission.name" -}}
{{- required "service.name is required (set it in chart/values/<service>-<env>.yaml)" .Values.service.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
transmission.namespace — product-level shared namespace. Must match DS-2795's
Pod Identity association namespace.
*/}}
{{- define "transmission.namespace" -}}
{{- required "namespace is required" .Values.namespace -}}
{{- end -}}

{{/*
transmission.serviceAccountName — falls back to the service name when unset, so
a service that doesn't need a distinct SA still gets a stable one.
*/}}
{{- define "transmission.serviceAccountName" -}}
{{- default (include "transmission.name" .) .Values.serviceAccount.name -}}
{{- end -}}

{{/*
transmission.image — the full "repository:tag" image ref. `image.repository`
already fails loudly when unset (see `required` below); `image.tag` gets the
same treatment against "latest" specifically: `latest` does not exist in ECR
(ImageNotFoundException), so a values file left on the chart default renders
an unpullable image instead of failing at `helm template`/`helm upgrade`.
Every values file MUST pin a real tag.
*/}}
{{- define "transmission.image" -}}
{{- if eq .Values.image.tag "latest" -}}
{{- fail "image.tag must not be \"latest\" — pin to a real ECR tag (see chart/values/<service>-<env>.yaml)" -}}
{{- end -}}
{{- required "image.repository is required" .Values.image.repository }}:{{ .Values.image.tag -}}
{{- end -}}

{{/*
transmission.labels — full label set for resource metadata. app.kubernetes.io/*
are the recommended standard keys; chart/version aid debugging.
*/}}
{{- define "transmission.labels" -}}
app.kubernetes.io/name: {{ include "transmission.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: transmission
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
transmission.selectorLabels — the STABLE subset used for selectors. Must never
include version/tag-derived labels (selectors are immutable on Deployments).
*/}}
{{- define "transmission.selectorLabels" -}}
app.kubernetes.io/name: {{ include "transmission.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
