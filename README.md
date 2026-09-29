# kubecommerce-gitops

GitOps repository for KubeCommerce. Argo CD reconciles the cluster from this
repository: the Helm chart renders the application, `environments/` holds the
per-environment values, and `platform/` + `argocd/` hold the platform add-ons
and their Argo CD Applications.

## Layout

```text
charts/kubecommerce/   Helm chart for the application services
environments/          Per-environment values (dev, staging, prod)
platform/              Platform manifests and Helm values (gateway, infra,
                       namespaces, monitoring, observability, exporters,
                       cloud-apps, external-secrets, cert-manager, ...)
argocd/                App-of-apps, ApplicationSet and platform Applications
bootstrap/             Argo CD bootstrap/install assets
```

## Cloud (AWS) wiring

The AWS delivery path is additive and **inert on kind**: local development
keeps using `make k8s-secrets` (out-of-band Kubernetes Secrets) and plain HTTP
through the NodePort Gateway.

| Component | Manifests | What it does |
| --- | --- | --- |
| External Secrets Operator | `platform/cloud-apps/external-secrets*.yaml`, `platform/external-secrets/` | Installs ESO (Helm, pinned) and syncs AWS Secrets Manager into the five `<service>-secrets` Secrets the chart consumes, per environment. Auth is EKS Pod Identity (no `auth` block; IRSA is a documented alternative) — no static AWS keys. |
| AWS Load Balancer Controller | `platform/cloud-apps/aws-load-balancer-controller.yaml` | Installs the controller (Helm, pinned) so LoadBalancer Services are reconciled. Envoy Gateway's data-plane Service becomes an AWS **NLB**, giving the shared Gateway a public address for HTTPS/ACME. |
| cert-manager + TLS | `platform/cloud-apps/cert-manager*.yaml`, `platform/cert-manager/` | Installs cert-manager (Helm, pinned, Gateway API enabled), creates Let's Encrypt ClusterIssuers, and issues the `kubecommerce-tls` certificate for the Gateway's HTTPS listener. |
| Gateway HTTPS | `platform/gateway/gateway.yaml` | Adds a 443/HTTPS listener (TLS Terminate) alongside the existing HTTP listener; `platform/gateway/httproute.yaml` carries commented cloud hostnames. |

These are driven by the `kubecommerce-platform-cloud` child Application
(`argocd/platform-apps/platform-cloud.yaml`). Its child Applications have **no
automated sync**, so they do nothing until an operator supplies the Terraform
outputs and syncs manually:

* **region**, **EKS cluster name** and the **secret prefix** →
  `platform/external-secrets/` / `platform/cloud-apps/aws-load-balancer-controller.yaml`;
* **ESO / LBC IAM roles** (Pod Identity associations; IRSA is documented as an
  alternative for ESO);
* **Gateway DNS / domain** → `platform/cert-manager/` email + the Gateway HTTPS
  hostname and `cert-manager.io/cluster-issuer` annotation.

Bootstrap prerequisites (owned by `argocd/project.yaml`): source repos
`charts.external-secrets.io`, `charts.jetstack.io` and
`aws.github.io/eks-charts`, plus destination namespaces `external-secrets`,
`cert-manager` and `platform-system`. See
`platform/external-secrets/README.md` and `platform/cert-manager/README.md` for
the full runbooks.

## CI

`.github/workflows/validate.yml` runs on `pull_request`, on `push` to `main`,
and via `workflow_dispatch`. It uses `permissions: contents: read` and a
`concurrency` group with `cancel-in-progress: true`, so superseded runs on the
same ref are cancelled.

| Job | What it checks |
| --- | --- |
| `helm-validate` | `helm lint --strict` and `helm template ... | kubeconform -strict -summary -ignore-missing-schemas` for `dev`, `staging`, and `prod` |
| `manifest-validate` | kubeconform over the `argocd/` and `platform/` manifest directories (values files are excluded by listing only manifest directories) plus a `python3` YAML parse |
| `yaml-hygiene` | `python3` YAML parse of the manifests (known Helm values files skipped explicitly) and a trailing-whitespace check |
| `policy-validate` | pinned Kyverno CLI against (a) the namespace-stamped Helm-rendered dev chart (no violations), (b) `platform/policies/tests/insecure-deployment.yaml` (exactly 10 violations, every policy fires, non-zero exit), (c) `platform/policies/tests/compliant-workload.yaml` (passes), and (d) the hardened OTel collector render (hardened security context, outside policy scope) |
| `actionlint` | self-check of this workflow with a pinned `actionlint` binary |

No cluster, cloud credentials, or secrets are required. Third-party actions are
pinned to full commit SHAs:

| Action | Pin |
| --- | --- |
| `actions/checkout` | `3d3c42e5aac5ba805825da76410c181273ba90b1` (`v7.0.1`) |
| `azure/setup-helm` | `9bc31f4ebc9c6b171d7bfbaa5d006ae7abdb4310` (`v5.0.1`) |

Tool versions are pinned in the workflow `env`: Helm `v3.22.0`,
kubeconform `v0.8.0` (verified against a pinned SHA-256),
Kyverno CLI `v1.19.1` (verified against a pinned SHA-256), and
actionlint `v1.7.12` (verified against a pinned SHA-256).

### Branch protection on `main`

Require the following status checks before merging:

- `helm-validate`
- `manifest-validate`
- `yaml-hygiene`
- `policy-validate`
- `actionlint`
