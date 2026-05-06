apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CLUSTER_ISSUER_NAME}
spec:
  ca:
    secretName: ${CLUSTER_ISSUER_NAME}
