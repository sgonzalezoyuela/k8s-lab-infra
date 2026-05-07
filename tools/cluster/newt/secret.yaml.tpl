apiVersion: v1
kind: Secret
metadata:
  name: newt-credentials
  namespace: newt
  labels:
    app.kubernetes.io/name: newt
type: Opaque
stringData:
  PANGOLIN_ENDPOINT: ${PANGOLIN_ENDPOINT}
  NEWT_ID: ${NEWT_ID}
  NEWT_SECRET: ${NEWT_SECRET}
