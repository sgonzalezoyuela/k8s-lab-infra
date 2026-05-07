apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${INGRESS_DEFAULT_TLS_SECRET}
  namespace: ingress-nginx
spec:
  secretName: ${INGRESS_DEFAULT_TLS_SECRET}
  duration: 720h    # 30d — short enough to exercise renewal regularly in the lab
  renewBefore: 240h # 10d
  issuerRef:
    name: ${CLUSTER_ISSUER_NAME}
    kind: ClusterIssuer
  commonName: "*.${CLUSTER_DOMAIN}"
  dnsNames:
    - "*.${CLUSTER_DOMAIN}"
    - "${CLUSTER_DOMAIN}"
