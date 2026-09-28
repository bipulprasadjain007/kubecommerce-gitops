{{/*
Shared template helpers for the kubecommerce chart.

Most helpers take a dict of the form:
  (dict "root" $ "name" $serviceName "svc" $serviceValues)
so one set of templates can render every entry in `.Values.services`.
Core template functions ($, .Values, .Release) are only available through
`.root`; helper-local arguments are passed explicitly.
*/}}

{{/* ------------------------------------------------------------------------- */}}
{{/* Naming / labels                                                           */}}
{{/* ------------------------------------------------------------------------- */}}

{{/* Stable selector labels. `name` is the canonical service slug. */}}
{{- define "kubecommerce.selectorLabels" -}}
app.kubernetes.io/name: {{ .name | quote }}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
{{- end -}}

{{/* Full label set for a service's resources. */}}
{{- define "kubecommerce.labels" -}}
{{ include "kubecommerce.selectorLabels" . }}
app.kubernetes.io/part-of: {{ .root.Values.global.partOf | default "kubecommerce" | quote }}
app.kubernetes.io/component: {{ .svc.component | default "api" | quote }}
app.kubernetes.io/version: {{ (.svc.image.tag | default .root.Chart.AppVersion) | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name (.root.Chart.Version | replace "+" "_") | quote }}
environment: {{ .root.Values.global.environment | quote }}
{{- with .root.Values.global.labels }}
{{ toYaml . }}
{{- end }}
{{- with .svc.labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ServiceAccount name: explicit per-service name, else the service slug. */}}
{{- define "kubecommerce.serviceAccountName" -}}
{{- .svc.serviceAccount.name | default .name -}}
{{- end -}}

{{/*
Image reference. Uses an immutable digest when set, otherwise the tag, and
falls back to the chart appVersion. Repository defaults to
`<global.imageRegistry>/kubecommerce-<slug>`.
*/}}
{{- define "kubecommerce.image" -}}
{{- $repo := .svc.image.repository -}}
{{- if not $repo -}}
  {{- $repo = printf "%s/kubecommerce-%s" (.root.Values.global.imageRegistry | trimSuffix "/") .name -}}
{{- end -}}
{{- if .svc.image.digest -}}
{{- printf "%s@%s" $repo .svc.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (.svc.image.tag | default .root.Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/* ------------------------------------------------------------------------- */}}
{{/* Security context                                                          */}}
{{/* ------------------------------------------------------------------------- */}}

{{/* Pod security context: global defaults merged with per-service overrides. */}}
{{- define "kubecommerce.podSecurityContext" -}}
{{- $global := .root.Values.global.podSecurityContext | default dict -}}
{{- $svc := .svc.podSecurityContext | default dict -}}
{{- toYaml (merge (deepCopy $svc) $global) -}}
{{- end -}}

{{/* Container security context: global defaults + per-service overrides. */}}
{{- define "kubecommerce.securityContext" -}}
{{- $global := .root.Values.global.securityContext | default dict -}}
{{- $svc := .svc.securityContext | default dict -}}
{{- toYaml (merge (deepCopy $svc) $global) -}}
{{- end -}}

{{/* ------------------------------------------------------------------------- */}}
{{/* Config / env                                                              */}}
{{/* ------------------------------------------------------------------------- */}}

{{/*
Resolved non-secret env map for a service: global env defaults, then
per-service env, with ENVIRONMENT/SERVICE_NAME/SERVICE_VERSION always forced by
the chart. Values must be strings (enforced by values.schema.json).
*/}}
{{- define "kubecommerce.env" -}}
{{- $root := .root -}}
{{- $env := merge (deepCopy (.svc.env | default dict)) ($root.Values.global.env | default dict) -}}
{{- $_ := set $env "ENVIRONMENT" ($root.Values.global.environment | toString) -}}
{{- $_ := set $env "SERVICE_NAME" .name -}}
{{- $_ := set $env "SERVICE_VERSION" (($.svc.image.tag | default $root.Chart.AppVersion) | toString) -}}
{{- toYaml $env -}}
{{- end -}}

{{/*
Same resolved env map, rendered as a Kubernetes `env:` list of literal
name/value pairs. Used by the pre-install migration Job so it does not depend on
the Sync-phase ConfigMap. `fromYaml` is only ever applied to the map above.
*/}}
{{- define "kubecommerce.envList" -}}
{{- $env := include "kubecommerce.env" (dict "root" .root "name" .name "svc" .svc) | fromYaml -}}
{{- $out := list -}}
{{- range $k, $v := $env -}}
  {{- $out = append $out (dict "name" $k "value" ($v | toString)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/* ------------------------------------------------------------------------- */}}
{{/* Probes                                                                    */}}
{{/* ------------------------------------------------------------------------- */}}

{{/* Renders an httpGet probe block. Args: probe dict + defaultPath. */}}
{{- define "kubecommerce.probe" -}}
{{- $probe := .probe -}}
httpGet:
  path: {{ $probe.path | default .defaultPath | quote }}
  port: {{ $probe.port | default "http" | quote }}
initialDelaySeconds: {{ $probe.initialDelaySeconds | default 5 }}
periodSeconds: {{ $probe.periodSeconds | default 10 }}
timeoutSeconds: {{ $probe.timeoutSeconds | default 3 }}
failureThreshold: {{ $probe.failureThreshold | default 3 }}
successThreshold: {{ $probe.successThreshold | default 1 }}
{{- end -}}

{{/* ------------------------------------------------------------------------- */}}
{{/* Scheduling                                                                */}}
{{/* ------------------------------------------------------------------------- */}}

{{/* Renders a single topologySpreadConstraint list for a service. */}}
{{- define "kubecommerce.topologySpreadConstraints" -}}
{{- $ts := .svc.topologySpread -}}
- maxSkew: {{ $ts.maxSkew | default 1 }}
  topologyKey: {{ $ts.topologyKey | default "kubernetes.io/hostname" | quote }}
  whenUnsatisfiable: {{ $ts.whenUnsatisfiable | default "ScheduleAnyway" | quote }}
  labelSelector:
    matchLabels:
      {{- include "kubecommerce.selectorLabels" . | nindent 6 }}
{{- with $ts.extra }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ------------------------------------------------------------------------- */}}
{{/* NetworkPolicy rule composition                                            */}}
{{/* ------------------------------------------------------------------------- */}}

{{/*
Full egress rule list for a service: infra needs + explicit service-to-service
rules from values. Returns a YAML list.
*/}}
{{- define "kubecommerce.egressRules" -}}
{{- $root := .root -}}
{{- $np := $root.Values.global.networkPolicy -}}
{{- $needs := .svc.networkPolicy.infraEgress | default (list) -}}
{{- $rules := list -}}
{{- if has "dns" $needs -}}
  {{- $dns := $np.dns -}}
  {{- $rules = append $rules (dict
        "to" (list (dict
          "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" $dns.namespace))
          "podSelector" (dict "matchLabels" $dns.podLabels)))
        "ports" (list
          (dict "port" ($dns.port | default 53) "protocol" "UDP")
          (dict "port" ($dns.port | default 53) "protocol" "TCP"))) -}}
{{- end -}}
{{- range $key := (list "postgres" "redis" "rabbitmq" "otel") -}}
  {{- if has $key $needs -}}
    {{- $infra := index $np $key -}}
    {{- $rules = append $rules (dict
          "to" (list (dict
            "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" $infra.namespace))
            "podSelector" (dict "matchLabels" $infra.podLabels)))
          "ports" (list (dict "port" $infra.port "protocol" ($infra.protocol | default "TCP")))) -}}
  {{- end -}}
{{- end -}}
{{- toYaml (concat $rules (.svc.networkPolicy.egress | default (list))) -}}
{{- end -}}

{{/*
Full ingress rule list for a service: explicit ingress rules from values plus
an optional monitoring-scrape allow. Returns a YAML list.
*/}}
{{- define "kubecommerce.ingressRules" -}}
{{- $root := .root -}}
{{- $svc := .svc -}}
{{- $rules := concat (list) ($svc.networkPolicy.ingress | default (list)) -}}
{{- if $svc.networkPolicy.monitoringIngress | default true -}}
  {{- $mon := $root.Values.global.networkPolicy.monitoring -}}
  {{- $rules = append $rules (dict
        "from" (list (dict
          "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" $mon.namespace))))
        "ports" (list (dict "port" ($svc.port | default 8000) "protocol" "TCP"))) -}}
{{- end -}}
{{- toYaml $rules -}}
{{- end -}}
