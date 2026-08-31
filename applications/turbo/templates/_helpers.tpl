{{/* Common labels applied to every object. Deterministic — no lookup/date. */}}
{{- define "turbo.labels" -}}
app.kubernetes.io/name: turbo
app.kubernetes.io/part-of: turbo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "turbo.backend.selectorLabels" -}}
app.kubernetes.io/name: turbo
app.kubernetes.io/component: backend
{{- end -}}

{{- define "turbo.frontend.selectorLabels" -}}
app.kubernetes.io/name: turbo
app.kubernetes.io/component: frontend
{{- end -}}
