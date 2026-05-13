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
  kubelet:
    # Bind /var/local-path-provisioner from the host into the kubelet
    # container at the same path so rancher/local-path-provisioner helper
    # pods (hostPath-backed) see real host filesystem state. rshared
    # propagation is the standard "this is a real host mount" idiom; it
    # lets any sub-mounts the provisioner might create later propagate
    # in both directions between host and kubelet container.
    extraMounts:
      - destination: /var/local-path-provisioner
        type: bind
        source: /var/local-path-provisioner
        options:
          - bind
          - rshared
          - rw
  install:
    disk: /dev/sda
