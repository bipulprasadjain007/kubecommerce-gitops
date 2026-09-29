# cert-manager — Gateway TLS and ACME HTTP-01

This directory holds the **cloud-only** certificate automation for the
north-south Gateway (guide Phase 13, Step 13.4). cert-manager issues a
Let's Encrypt certificate and writes it to the `kubecommerce-tls` Secret that
the Gateway's HTTPS listener references
(`platform/gateway/gateway.yaml`).

```text
platform/cert-manager/
├── README.md
└── cluster-issuers/
    ├── letsencrypt-staging.yaml   # ClusterIssuer letsencrypt-staging (dev/staging)
    └── letsencrypt-prod.yaml      # ClusterIssuer letsencrypt-prod (production)
```

Argo CD wiring (see `argocd/platform-apps/platform-cloud.yaml`):

| Application | Chart / path | Wave | Sync |
|---|---|---|---|
| `cert-manager` | Helm `cert-manager` `v1.21.2` (`https://charts.jetstack.io`) | 0 | manual |
| `cert-manager-issuers` | `platform/cert-manager/cluster-issuers` | 1 | manual |

The chart is installed with `crds.enabled: true` and Gateway API support on
(`config.gatewayAPI.enabled: true`, the cert-manager ≥ 1.20
`ControllerConfiguration` field). No cluster change happens until an operator
sets the real domain/email and syncs manually, so this path is inert on kind.

## Prerequisites

1. **Gateway API CRDs** must exist before cert-manager starts (Envoy Gateway
   installs them). If cert-manager was already running when the CRDs landed:

   ```bash
   kubectl -n cert-manager rollout restart deployment cert-manager
   ```

2. **Public DNS** pointing the chosen hostname at the Gateway's externally
   exposed address. On EKS, Envoy Gateway provisions a `LoadBalancer` Service
   for the Gateway (this repo's EnvoyProxy `NodePort` override is only for
   kind) and the **AWS Load Balancer Controller** reconciles it into an NLB —
   install it from `platform/cloud-apps/aws-load-balancer-controller.yaml`
   (manually synced like the other cloud apps). Get the address and create the
   DNS record:

   ```bash
   kubectl -n platform-system get svc -l gateway.envoyproxy.io/owning-gateway-name=kubecommerce-gateway
   # A/CNAME kubecommerce.<domain> -> <EXTERNAL-IP / ELB hostname>
   ```

   Both the DNS name and TCP :80 must be reachable from the internet for
   Let's Encrypt's HTTP-01 validation.

3. **Replace placeholders** before syncing:
   * `cluster-issuers/*.yaml` → `email` (`platform-engineering@example.com`).
   * `platform/gateway/gateway.yaml` → the HTTPS listener `hostname`
     (`kubecommerce.<domain>`) and the `cert-manager.io/cluster-issuer`
     annotation (staging for dev/staging, prod for production).

4. **AppProject** (owner: Argo CD bootstrap): `argocd/project.yaml` must allow
   `sourceRepos: https://charts.jetstack.io` and destination namespace
   `cert-manager`. The `ClusterIssuer` + `Certificate` kinds are whitelisted.

## How HTTP-01 is solved through the Gateway

The Gateway carries the annotation
`cert-manager.io/cluster-issuer: letsencrypt-staging|prod`. cert-manager's
Gateway API integration watches the Gateway's TLS listeners and, for every
listener that has:

* a non-empty `hostname`,
* `tls.mode: Terminate`, and
* a `tls.certificateRefs[].name` (`kubecommerce-tls`),

**creates a `Certificate` object automatically** (no hand-written Certificate
manifest). The Certificate's `dnsNames` come from the listener hostname and it
writes to the referenced Secret in `platform-system`.

To satisfy the ACME HTTP-01 challenge, the `ClusterIssuer` solver uses
`http01.gatewayHTTPRoute.parentRefs` to point at the shared Gateway. For each
challenge cert-manager creates a temporary HTTPRoute on the Gateway's **port-80
`http` listener** serving `GET /.well-known/acme-challenge/<token>`. Let's
Encrypt fetches that URL from the public DNS name, and on success cert-manager
stores the certificate in `kubecommerce-tls`. Envoy Gateway then programs the
HTTPS listener.

Choose the issuer by environment:

| Environment | Gateway annotation | ACME endpoint |
|---|---|---|
| dev / staging | `letsencrypt-staging` | `acme-staging-v02` (untrusted, high limits) |
| production | `letsencrypt-prod` | `acme-v02` (trusted, strict rate limits) |

## Verify (once a cluster exists)

```bash
# 1. cert-manager is up and the issuers registered
kubectl -n cert-manager get pods
kubectl get clusterissuer
kubectl get clusterissuer letsencrypt-staging \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'

# 2. the Certificate auto-created for the Gateway listener
kubectl -n platform-system get certificate
kubectl -n platform-system get certificate kubecommerce-tls -o wide
kubectl -n platform-system describe certificate kubecommerce-tls   # events/conditions

# 3. the ACME order/challenge progress
kubectl -n platform-system get order,challenge
kubectl -n platform-system describe challenge

# 4. the TLS Secret exists and the Gateway https listener is Programmed
kubectl -n platform-system get secret kubecommerce-tls
kubectl -n platform-system get gateway kubecommerce-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'

# 5. end-to-end over TLS
curl -vI https://kubecommerce.<domain>/api/health/live
```

`Ready=True` on the Certificate and `Programmed=True` on the `https` listener
mean the cloud TLS path is complete.

## Enabling on AWS (checklist)

1. Sync the `cert-manager` Application (wave 0) and wait for the CRDs/webhook.
2. Edit `cluster-issuers/*.yaml` email + `gateway.yaml` hostname/annotation.
3. Sync `cert-manager-issuers` (wave 1).
4. Point public DNS at the Gateway's LoadBalancer.
5. Watch the Certificate become `Ready` (commands above).
