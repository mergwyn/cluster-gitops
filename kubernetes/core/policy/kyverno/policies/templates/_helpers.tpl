{{/* Common labels */}}
{{- define "kyverno-policies.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: kyverno
app.kubernetes.io/managed-by: Helm
{{- end }}
