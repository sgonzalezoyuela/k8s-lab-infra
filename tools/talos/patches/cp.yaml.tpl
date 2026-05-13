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
          # On-link route to the gateway. Required when ${NETWORK_GATEWAY}
          # is NOT in the same subnet as ${CP_IP}/${NETWORK_CIDR} (e.g. node
          # 10.4.0.1/24 with gateway 10.0.0.1). Without this, the kernel
          # cannot ARP the gateway and the default route below fails to
          # install ("Network is unreachable"). Talos treats a route with no
          # `gateway` as scope=link, i.e. directly via this interface.
          # When the gateway IS already on-link given the prefix, this entry
          # is redundant but harmless.
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
