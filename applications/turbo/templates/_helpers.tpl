{{/* Common labels applied to every object. Deterministic — no lookup/date.
     app.kubernetes.io/name is intentionally omitted here: every object also
     includes a component selectorLabels helper (which carries name), and
     defining it in both produces a duplicate YAML key. */}}
{{- define "turbo.labels" -}}
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
