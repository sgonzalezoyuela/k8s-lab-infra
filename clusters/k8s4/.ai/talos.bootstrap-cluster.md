# Companion: talos.bootstrap-cluster

## Sequence (each step idempotent where possible)

1. **Wait for Talos maintenance mode** on both VMs.
   After `infra-up`, Talos boots from ISO into maintenance mode and listens on
   port 50000 (insecure). Poll
   `talosctl -n <ip> --insecure version`
   until it responds (timeout: 5 min per node).

2. **Apply config** (insecure, since maintenance mode has no PKI yet):
   ```
   talosctl apply-config --insecure -n ${CP_IP}  -f _out/cp.yaml
   talosctl apply-config --insecure -n ${WK0_IP} -f _out/wk0.yaml
   ```
   After this, Talos installs to disk, reboots, and comes up in secure mode
   using PKI from `_out/secrets.yaml`. From here on, talosctl uses
   `_out/talosconfig` (no `--insecure`).

3. **Wait for secure API**:
   `talosctl -n ${CP_IP} --talosconfig _out/talosconfig version` succeeds.

4. **Bootstrap etcd** (CP only, exactly once):
   ```
   talosctl bootstrap -n ${CP_IP} --talosconfig _out/talosconfig
   ```
   Re-running after a successful bootstrap returns "AlreadyExists" — script must
   treat that as success.

5. **Fetch kubeconfig**:
   ```
   talosctl kubeconfig --talosconfig _out/talosconfig \
     -n ${CP_IP} ${KUBECONFIG} --force
   ```

6. **Wait for nodes Ready**:
   Loop
   `kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'`
   until both are `True` (timeout: 5 min).

## Justfile additions

```just
talos-apply: talos-config
    ./talos/scripts/wait-maintenance.sh
    talosctl apply-config --insecure -n $CP_IP  -f _out/cp.yaml
    talosctl apply-config --insecure -n $WK0_IP -f _out/wk0.yaml

talos-bootstrap: talos-apply
    ./talos/scripts/wait-secure.sh
    ./talos/scripts/bootstrap-once.sh

kubeconfig: talos-bootstrap
    talosctl kubeconfig --talosconfig _out/talosconfig -n $CP_IP $KUBECONFIG --force

cluster-up: talos-image infra-up talos-config talos-apply talos-bootstrap kubeconfig
    ./talos/scripts/wait-nodes-ready.sh

cluster-down: infra-down
    rm -f $KUBECONFIG _out/cp.yaml _out/wk0.yaml _out/patches/*.yaml
```

## Helper scripts (to add under `talos/scripts/`)

- `wait-maintenance.sh` — polls both `${CP_IP}` and `${WK0_IP}` for `talosctl --insecure version`.
- `wait-secure.sh` — polls `${CP_IP}` for `talosctl --talosconfig _out/talosconfig version`.
- `bootstrap-once.sh` — runs `talosctl bootstrap` and treats `AlreadyExists` as success:
  ```bash
  set +e
  out=$(talosctl bootstrap -n "$CP_IP" --talosconfig _out/talosconfig 2>&1)
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then exit 0; fi
  if echo "$out" | grep -qiE 'already.?exists|already.?bootstrap'; then
    echo "etcd already bootstrapped, skipping"
    exit 0
  fi
  echo "$out" >&2
  exit $rc
  ```
- `wait-nodes-ready.sh` — loop on `kubectl get nodes` until both are Ready.

## CNI note
Talos default config ships flannel as CNI. For a lab this is fine. We don't
swap it in Phase 1; switching CNI is a Phase 2+ concern if needed.

## Failure modes
- VM never enters maintenance mode → ISO didn't boot → check `infra-up`
  succeeded and that VM has the ISO mounted (manual `qm config` check).
- `apply-config` succeeds but VM never comes up in secure mode → install disk
  wrong (check `machine.install.disk` matches the actual VM scsi0 device,
  usually `/dev/sda`).
- `bootstrap` returns `AlreadyExists` → treat as success (handled in
  `bootstrap-once.sh`).
- Kubeconfig fetch fails with TLS error → kube-apiserver not yet up; retry
  with backoff up to 3 min.
- Nodes stuck NotReady → almost always CNI; check `kubectl -n kube-flannel`
  pods and `kubectl describe node` for taints.
