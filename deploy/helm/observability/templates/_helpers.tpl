{{/* Common labels on every object */}}
{{- define "obs.labels" -}}
app.kubernetes.io/part-of: observability
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.env | quote }}
{{- end -}}

{{/* Secrets Manager name of the alerting secret */}}
{{- define "obs.alertSecret" -}}
{{- if .Values.alertSecret }}{{ .Values.alertSecret }}{{ else }}
{{- if not .Values.clusterName }}{{ fail "clusterName is not set" }}{{ end -}}
{{ .Values.clusterName }}/monitoring/alerting{{ end }}
{{- end -}}
