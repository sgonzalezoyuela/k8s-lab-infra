machine:
  network:
    hostname: ${CP_HOSTNAME}
    nameservers:
      - ${NETWORK_DNS}
    interfaces:
      - deviceSelector:
          physical: true
        addresses:
          - ${CP_IP}/${NETWORK_CIDR}
        routes:
          - network: 0.0.0.0/0
            gateway: ${NETWORK_GATEWAY}
  install:
    disk: /dev/sda
