{{- define "watchdog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "watchdog.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "watchdog.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "watchdog.labels" -}}
app.kubernetes.io/name: {{ include "watchdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "watchdog.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}
{{- end }}

{{- define "watchdog.stateClaim" -}}
{{- if .Values.state.existingClaim }}
{{- .Values.state.existingClaim }}
{{- else }}
{{- printf "%s-state" (include "watchdog.fullname" .) }}
{{- end }}
{{- end }}

{{- define "watchdog.pod" -}}
metadata:
  labels:
    {{- include "watchdog.labels" .root | nindent 4 }}
  {{- with .root.Values.podAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: {{ .root.Values.terminationGracePeriodSeconds }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  {{- with .root.Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .root.Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .root.Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .root.Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: watchdog
      image: {{ include "watchdog.image" .root | quote }}
      imagePullPolicy: {{ .root.Values.image.pullPolicy }}
      {{- with .args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      env:
        - name: WATCHDOG_CONFIG
          value: /etc/watchdog/config.yaml
        {{- range $name, $value := .root.Values.env }}
        - name: {{ $name }}
          value: {{ $value | toString | quote }}
        {{- end }}
      {{- if .root.Values.envFromSecret }}
      envFrom:
        - secretRef:
            name: {{ .root.Values.envFromSecret }}
      {{- end }}
      resources:
        {{- toYaml .root.Values.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: config
          mountPath: /etc/watchdog/config.yaml
          subPath: config.yaml
          readOnly: true
        - name: state
          mountPath: /var/lib/watchdog
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: config
      configMap:
        name: {{ include "watchdog.fullname" .root }}-config
        defaultMode: 0444
    - name: state
      {{- if .root.Values.state.persistence }}
      persistentVolumeClaim:
        claimName: {{ include "watchdog.stateClaim" .root }}
      {{- else }}
      emptyDir: {}
      {{- end }}
    - name: tmp
      emptyDir:
        sizeLimit: {{ .root.Values.tmp.sizeLimit }}
{{- end }}
