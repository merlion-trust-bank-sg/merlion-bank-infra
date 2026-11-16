{{/* Common labels on every object */}}
{{- define "boa.labels" -}}
app.kubernetes.io/part-of: bank-of-anthos
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.env | quote }}
{{- end -}}

{{/* image reference by digest: <registry>/<name>@<digest> */}}
{{- define "boa.image" -}}
{{- $img := .img -}}
{{- if not $img.digest }}{{ fail (printf "image digest for %s is not set" $img.name) }}{{ end -}}
{{ .root.Values.image.registry }}/{{ $img.name }}@{{ $img.digest }}
{{- end -}}

{{/* The fewest replicas a service runs: the HPA's minimum when it has one, otherwise replicas */}}
{{- define "boa.minReplicas" -}}
{{- if and .hpa .hpa.enabled }}{{ .hpa.minReplicas }}{{ else }}{{ .replicas }}{{ end -}}
{{- end -}}

{{/* Pod and container hardening shared by every workload */}}
{{- define "boa.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "boa.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  privileged: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end -}}
