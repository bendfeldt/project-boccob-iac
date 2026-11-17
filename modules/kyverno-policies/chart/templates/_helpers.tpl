{{/* variants: list of {suffix, action, selector} for the Audit default + label-enforced namespaces */}}
{{- define "boccob.variants" -}}
{{- $mode := .mode -}}
{{- $root := .root -}}
{{- if eq $mode "Enforce" }}
- suffix: ""
  action: Deny
  enforcedOnly: false
{{- else }}
- suffix: ""
  action: Audit
  enforcedOnly: false
- suffix: "-enforce"
  action: Deny
  enforcedOnly: true
{{- end }}
{{- end -}}

{{- define "boccob.labels" -}}
app.kubernetes.io/part-of: boccob-lakehouse
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: policy
{{- end -}}

{{/* matchConstraints for pods; arg: dict root, enforcedOnly */}}
{{- define "boccob.matchPods" -}}
matchConstraints:
  resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
  namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: {{ toJson .root.Values.excludedNamespaces }}
      {{- if .enforcedOnly }}
      - key: {{ .root.Values.enforceLabel.key }}
        operator: In
        values: [{{ .root.Values.enforceLabel.value | quote }}]
      {{- end }}
{{- end -}}
