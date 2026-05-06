machine:
  network:
    hostname: ${WK0_HOSTNAME}
    nameservers:
      - ${NETWORK_DNS}
    interfaces:
      - deviceSelector:
          physical: true
        addresses:
          - ${WK0_IP}/${NETWORK_CIDR}
        routes:
          # On-link route to the gateway. See cp.yaml.tpl for full rationale:
          # required when the gateway is not in the node's subnet; harmless
          # when it is. Talos treats a route with no `gateway` as scope=link.
          - network: ${NETWORK_GATEWAY}/32
          - network: 0.0.0.0/0
            gateway: ${NETWORK_GATEWAY}
  install:
    disk: /dev/sda
