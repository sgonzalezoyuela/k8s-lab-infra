# Companion: cluster.ingress-nginx

## Why

After Phase-2's first three opt-in services (MetalLB, cert-manager,
newt), the cluster has a pool of routable LoadBalancer IPs and a working
internal CA — but no L7 entrypoint. Any user-facing workload still has to
either burn a whole LB IP (one IP per service is wasteful and forces
operators to mint A records per port) or rely on `kubectl port-forward`
(developer-only). **ingress-nginx** is the L7 router that closes that gap:
one stable LoadBalancer IP, `Host`-header-based routing to N backends, and
TLS termination wired straight into cert-manager.

This feature installs ingress-nginx in the most boring shape that still
satisfies the lab's three non-negotiables:

1. **Restricted PSA.** The controller pod runs in a namespace labelled
   `pod-security.kubernetes.io/enforce: restricted`. Possible because
   nginx only needs `NET_BIND_SERVICE` (to bind 80/443 as uid 101), which
   is the one capability restricted PSA still permits. Everything else is
   dropped, the root filesystem is read-only, seccomp is `RuntimeDefault`.
2. **Pinned LB IP.** The controller's `Service` requests `INGRESS_LB_IP`
   (`10.4.200.10`) explicitly via `loadBalancerIP`. Without this, MetalLB
   picks any free IP in the pool and your wildcard DNS goes stale on every
   reinstall. We also fail-fast in `install.sh` if `INGRESS_LB_IP` isn't
   inside `METALLB_RANGE`, before talking to the cluster.
3. **Wildcard default-SSL certificate.** A single `Certificate` named
   `${INGRESS_DEFAULT_TLS_SECRET}` (`ingress-default-tls`) covering
   `*.${CLUSTER_DOMAIN}` and the apex `${CLUSTER_DOMAIN}` is issued by the
   `atricore-ca` ClusterIssuer and wired into the controller via
   `controller.extraArgs.default-ssl-certificate`. Unmatched-SNI clients
   get a real handshake instead of the dummy "Kubernetes Ingress
   Controller Fake Certificate" that ships with the chart.

Phase 1 (`just cluster-up`) stays untouched: ingress is opt-in, sequenced
after metallb + cert-manager are healthy.

## Source-of-truth decisions (locked-in)

| Decision | Value | Rationale |
|---|---|---|
| Controller | `ingress-nginx` (Helm chart `ingress-nginx/ingress-nginx`) | Most ubiquitous Ingress implementation; cert-manager's ingress-shim integrates natively; nothing in the lab needs the things Contour/Traefik do better. |
| Chart version pin | per-cluster via `INGRESS_NGINX_CHART_VERSION` in `.env`, default in `tools/.env.example` and bundled `chart-version.txt` | Same model as cert-manager + metallb. |
| Default chart version | `4.15.1` (app `v1.15.1`) | Current upstream stable when this feature shipped; tracks the post-CVE-2025-1974 hardened defaults. |
| `v` prefix on the chart version | **No** (`4.15.1`, not `v4.15.1`) | The ingress-nginx chart numbers itself without the prefix (matches metallb; cert-manager is the odd one). The structural test guards this so we don't accidentally re-use cert-manager's `v` style. |
| LB IP allocation | Pinned via `controller.service.loadBalancerIP=$INGRESS_LB_IP` (`10.4.200.10`) | Stable target for wildcard DNS. Failing closed (next free IP) breaks DNS silently; pin + smoke-assert catches it. |
| LB IP pre-validation | parse `INGRESS_LB_IP` as IPv4, assert it falls inside `METALLB_RANGE` | Catches the typo where the operator picks an IP outside the pool — MetalLB would refuse to allocate and the install wedges on `--wait`. |
| Default SSL cert source | `cert-manager` `Certificate` referencing `${CLUSTER_ISSUER_NAME}` ClusterIssuer | One CA. No new trust anchor. Renewal is automatic. |
| Default SSL cert wiring | `--set controller.extraArgs.default-ssl-certificate=ingress-nginx/$INGRESS_DEFAULT_TLS_SECRET` | Documented chart hook. nginx-controller hot-reloads the cert when the Secret rotates. |
| Default SSL cert dnsNames | `*.${CLUSTER_DOMAIN}`, `${CLUSTER_DOMAIN}` | Wildcard covers every app host; apex covers `https://k8s4.lab.atricore.io` itself. |
| Default SSL cert duration | 720h / renew 240h | Short-ish (30d) to exercise renewal regularly in the lab; long enough that we don't hammer the in-cluster CA. |
| Snippet annotations | **Disabled** (`controller.allowSnippetAnnotations: false`) | Several CVEs in 2023–2024 (most notably CVE-2025-1974) abused arbitrary-config-injection via `nginx.ingress.kubernetes.io/configuration-snippet`. The chart default is now `false`; we pin it explicitly so a future bump can't silently re-enable it. The lab has zero use cases that need snippets. |
| Pod Security Admission | `enforce: restricted` on namespace `ingress-nginx` | Most restrictive PSA mode that still works for nginx. Drops the temptation to ratchet down to `baseline` later. |
| Container security context | `runAsNonRoot: true`, `runAsUser: 101`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, capabilities `drop: [ALL]` + `add: [NET_BIND_SERVICE]`, seccomp `RuntimeDefault` | Exactly the set restricted PSA permits. uid 101 is the upstream nginx user. |
| Default backend | Disabled (`defaultBackend.enabled: false`) | The wildcard cert handles the SNI fallback; an unmatched-host HTTP request gets a 404 directly from nginx, which is preferable to a fake "default" page. |
| Service externalTrafficPolicy | `Cluster` | We don't need source-IP preservation today; `Cluster` keeps the routing simple and avoids the MetalLB-L2 "only-the-elected-speaker-node-answers" gotcha that `Local` introduces. Workloads that want client IPs can opt in per-Ingress later. |
| Smoke test scope | `helm status` + `rollout status deployment/ingress-nginx-controller` + assert `Service.status.loadBalancer.ingress[0].ip == $INGRESS_LB_IP` | Three crisp signals. The third one is the actual contract — it catches the silent fall-back-to-next-free-IP failure where the controller comes up but on the wrong address. We deliberately do NOT curl through the LB IP: that requires the host route, which is operator-side, and a real backend, which doesn't exist yet. |
| Phase | Opt-in (`just ingress-install`); NOT part of `cluster-up` | Same shape as the other Phase-2 services. Hard-depends on cert-manager + metallb. |
| Apply mode | `kubectl apply --server-side --field-manager=ingress-install` | Crisp idempotence: rerunning the recipe reports "unchanged" instead of churning ownership labels. |

## Files added

```
tools/cluster/ingress-nginx/
  install.sh                    # idempotent install: PSA-namespace, helm + wildcard Cert wiring
  uninstall.sh                  # safe-to-rerun teardown
  smoke.sh                      # helm status + controller rollout + pinned LB IP assertion
  helm-values.yaml              # restricted-PSA-compliant security context, snippets off, no defaultBackend
  default-ssl-cert.yaml.tpl     # cert-manager Certificate for *.${CLUSTER_DOMAIN} (envsubst template)
  chart-version.txt             # bundled-default chart version (4.15.1, no v prefix)
```

Edits:

```
tools/.env.example                        + INGRESS_NGINX_CHART_VERSION (next to other Phase-2 keys)
                                          + INGRESS_LB_IP (must be inside METALLB_RANGE)
                                          + INGRESS_DEFAULT_TLS_SECRET
tools/Justfile                            + 3 [no-cd] recipes
                                            (ingress-install/-smoke/-uninstall)
tools/Makefile                            + bootstrap.config-scheme required-vars list
                                            extended with the 3 new keys
                                          + new test-cluster.ingress-nginx target wired into top-level test:
tools/docs/INIT-CLUSTER.md                + new "Phase 2: ingress-nginx" subsection placed AFTER cert-manager
                                            (depends on it for the wildcard cert)
                                          + 3 new rows in the configuration table
README.md                                 + Phase 2 step in per-cluster workflow (4th, after newt)
                                            with prerequisites, DNS guidance, host-route reminder
clusters/k8s4/.env                        + INGRESS_NGINX_CHART_VERSION=4.15.1
                                          + INGRESS_LB_IP=10.4.200.10
                                          + INGRESS_DEFAULT_TLS_SECRET=ingress-default-tls
clusters/k8s4/.ai/cluster.ingress-nginx.md  REWRITTEN (this file) from the auto-generated template
                                            into a real design doc mirroring metallb-l2 and cert-manager.
```

## Pre-install validation rationale

Two classes of operator mistake account for ~all expected install-time
failures, both caught with pure-bash bitmask arithmetic before we touch
the cluster:

1. **`INGRESS_LB_IP` outside `METALLB_RANGE`.** Easy typo; MetalLB would
   refuse to allocate and the controller Service stays in `<pending>`,
   wedging the `helm --wait`. We fail with a clear message before the
   helm call.
2. **Bad shape (not IPv4 / octet > 255).** Caught with the same regex +
   range check used in `tools/cluster/metallb/install.sh`.

The arithmetic (`ip_to_int` + bitmask) is the same shape as the metallb
installer's overlap check, intentionally, so an operator who learned one
recognises the other. We deliberately do **not** check whether
`INGRESS_LB_IP` is already in use by another Service — that's a transient
state best caught at smoke time (the smoke compares the actual allocated
IP against `INGRESS_LB_IP`).

The wildcard Certificate's prerequisites (cert-manager Ready, atricore-ca
ClusterIssuer Ready) are not pre-validated explicitly: the
`kubectl wait --for=condition=Ready certificate/...` call at the end of
`install.sh` surfaces those failures with a clear message ("ClusterIssuer
not found" / "no matching CA Secret") and short timeout (60s).

## Smoke approach

Three crisp signals, each catching a distinct failure mode:

| Step | Failure mode it catches |
|---|---|
| `helm -n ingress-nginx status ingress-nginx` | Helm release missing entirely (someone ran `ingress-uninstall` and forgot, or the install never completed). |
| `kubectl rollout status deployment/ingress-nginx-controller --timeout=60s` | Controller Deployment exists but pods are crashing / pending (PSA mismatch, image pull, OOM). |
| `kubectl get svc ingress-nginx-controller -o jsonpath='...ip'` == `$INGRESS_LB_IP` | The silent failure: MetalLB couldn't allocate the pinned IP (because something else in the pool is squatting it), fell back to the next free IP, and the controller came up on the wrong address. Wildcard DNS still points at `INGRESS_LB_IP`, nothing works, and `kubectl get svc` looks healthy. |

We deliberately do **not** include an end-to-end request flow:

- It would require the operator-side host route (`sudo ip route add
  ${METALLB_RANGE} via ${CP_IP}`), which is documented but out of band
  for the recipe.
- It would require a real backend Service to route to, which doesn't
  exist as part of this feature.
- It would conflate "ingress-nginx works" with "MetalLB ARP propagation
  works", which is metallb-smoke's job.

The minimal smoke is enough to flush out 100% of the problems we've
actually seen. Adding curl-through-LB later is a separate feature
(`ops.smoke-test`).

## Idempotence claims

| Action | Idempotence proof |
|---|---|
| `ingress-nginx` namespace | `kubectl apply --server-side --field-manager=ingress-install` — emits "unchanged" when the PSA labels match. |
| Helm release | `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $X -f helm-values.yaml --set ... --wait` — same chart version, same values, same `--set`s → no rollout. |
| Wildcard Certificate | `envsubst < tpl \| kubectl apply --server-side` — emits "unchanged" when the spec is bit-identical. cert-manager won't reissue an unchanged Certificate. |
| Cert Ready wait | `kubectl wait --for=condition=Ready certificate ... --timeout=60s` returns immediately when the condition is already true. |

Re-running `just ingress-install` after a clean install produces no
spurious diffs, no rollout churn, and no Certificate reissue.

## Uninstall behavior

Order: `Certificate` → `Secret` → Helm release → namespace. Each step
uses `--ignore-not-found` (or `helm uninstall ... 2>/dev/null || true`)
so the recipe can be re-run on an empty cluster without errors. The
Certificate is deleted before its backing Secret because cert-manager
will recreate the Secret on Certificate deletion otherwise (its
re-reconcile loop is fast). The Helm release deletion cascades the
controller Deployment, the Service (which releases the LB IP back to
MetalLB), the IngressClass, and the admission webhooks.

The namespace deletion is the long-pole; it cascades any remaining
ingress-nginx objects.

## How to use (sample app Ingress)

The wildcard default-ssl Certificate handles unmatched-SNI clients, but
production-quality apps should declare their own `Ingress` with an
auto-issued per-host certificate. Annotate with
`cert-manager.io/cluster-issuer: atricore-ca` and cert-manager's
ingress-shim watches the resource, creates the matching `Certificate`,
and lands the cert in the named `Secret`. ingress-nginx loads it for SNI
matching the listed hosts.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    cert-manager.io/cluster-issuer: atricore-ca
spec:
  ingressClassName: nginx
  tls:
    - hosts: [my-app.k8s4.lab.atricore.io]
      secretName: my-app-tls
  rules:
    - host: my-app.k8s4.lab.atricore.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

If you skip the per-host `tls:` block, ingress-nginx falls back to the
wildcard default-ssl Certificate. The handshake is still valid, but the
served `commonName` is `*.${CLUSTER_DOMAIN}` rather than the per-host
SAN. Fine for internal/throwaway services; prefer the per-Ingress flow
for anything user-facing.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Operator picks `INGRESS_LB_IP` outside `METALLB_RANGE` | `install.sh` fails fast with a clear error. |
| `INGRESS_LB_IP` is squatted by another Service in the pool | Smoke asserts the actual allocated IP equals `INGRESS_LB_IP` and prints `kubectl get svc -A | grep <ip>` as the next debugging step. |
| Wildcard cert is a single-key blast radius | Accepted. Lab scale, single cluster, internal CA. Per-Ingress certs (the documented annotation flow) are still the recommended path for anything user-facing; the wildcard exists only to give unmatched-SNI clients a real handshake. Rotation is `kubectl -n ingress-nginx delete certificate $INGRESS_DEFAULT_TLS_SECRET` followed by `just ingress-install`. |
| Snippet annotations re-enabled by accident (CVE foothold) | `helm-values.yaml` pins `controller.allowSnippetAnnotations: false`; the structural test asserts the literal string. A future chart bump that flips the default cannot silently re-enable it. |
| Restricted PSA breaks on a future chart bump that adds a new init container | Caught at install time: `helm --wait` blocks on the rollout, and PSA denies admission with a precise error. The fix is a values override, not a PSA downgrade. |
| MetalLB and ingress-nginx fight over the same IP after a chart upgrade churn | `--wait` ensures the Service is fully reconciled before we declare victory; the smoke's IP equality check catches the bad case the next time the operator runs it. |
| Cert-manager not Ready when ingress-install runs | `kubectl wait --for=condition=Ready certificate ... --timeout=60s` surfaces this as a clear failure. The README + INIT-CLUSTER.md prerequisites list cert-manager-install + metallb-install explicitly. |
| Wildcard DNS missing | Out of band; the operator must add `*.${CLUSTER_DOMAIN}` (or per-host A records) pointing at `INGRESS_LB_IP`. README + INIT-CLUSTER.md document this. |

## Out of scope

- **TCP/UDP load balancing.** ingress-nginx supports it via `ConfigMap`s
  (`tcp-services`, `udp-services`); the lab doesn't need it today. If we
  ever do, it's an additive helm-values change, not a rearchitecture.
- **Multiple ingress classes.** Single class `nginx`, marked default.
  Adding a second controller (e.g. an internal-only one for east-west
  traffic) would be a sibling `tools/cluster/ingress-nginx-internal/` —
  not part of this feature.
- **Per-Ingress mTLS / client-cert auth.** Available via annotations; we
  don't ship cluster-wide config for it.
- **Observability.** No `ServiceMonitor`, no Grafana dashboard import,
  no metrics scraping wired here. Belongs to a future
  `ops.observability` feature.
- **HTTP→HTTPS redirect cluster default.** Off; per-Ingress
  `nginx.ingress.kubernetes.io/ssl-redirect: "true"` is the right knob
  and the chart default already does the right thing for Ingresses with a
  `tls:` block.
- **WAF / ModSecurity.** Out; if the lab ever needs it, it's a values
  override, not a separate component.
- **HorizontalPodAutoscaler / multiple replicas.** Single replica today;
  the lab has one worker and the controller is overkill at lab scale.
  Bumping replicas is a values change.
- **Ingress for the controller itself.** Not exposed; the LB IP + DNS
  pair is the operator-facing surface.
