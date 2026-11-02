{{/*
Expand the name of the chart.
*/}}
{{- define "object-storage.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Hardcoded to ensure consistent naming regardless of release name.
This is critical because Tempo and Loki expect this exact service name.
*/}}
{{- define "object-storage.fullname" -}}
{{- "observability-object-storage" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "object-storage.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "object-storage.labels" -}}
helm.sh/chart: {{ include "object-storage.chart" . }}
{{ include "object-storage.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "object-storage.selectorLabels" -}}
app.kubernetes.io/name: {{ include "object-storage.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Get the target namespace for the object storage deployment.
Always deploys to observability-hub namespace.
*/}}
{{- define "object-storage.namespace" -}}
{{- "observability-hub" }}
{{- end }}
