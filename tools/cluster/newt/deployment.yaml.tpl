apiVersion: apps/v1
kind: Deployment
metadata:
  name: newt
  namespace: newt
  labels:
    app.kubernetes.io/name: newt
    app.kubernetes.io/component: tunnel-client
spec:
  replicas: 1
  # Recreate (not RollingUpdate): a Pangolin site only accepts ONE concurrent
  # newt connection. RollingUpdate would briefly run two pods, the new pod
  # would race the old one for the WebSocket, and we'd see flapping during
  # rolls. Recreate gives us a clean stop-then-start.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: newt
  template:
    metadata:
      labels:
        app.kubernetes.io/name: newt
        app.kubernetes.io/component: tunnel-client
    spec:
      automountServiceAccountToken: false
      containers:
        - name: newt
          image: fosrl/newt:${NEWT_IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: newt-credentials
          env:
            - name: LOG_LEVEL
              value: INFO
          ports:
            - name: metrics
              containerPort: 2112
              protocol: TCP
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
