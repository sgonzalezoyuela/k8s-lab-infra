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
          - network: 0.0.0.0/0
            gateway: ${NETWORK_GATEWAY}
  install:
    disk: /dev/sda
