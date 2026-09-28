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
                       namespaces, monitoring, observability, exporters, ...)
argocd/                App-of-apps, ApplicationSet and platform Applications
bootstrap/             Argo CD bootstrap/install assets
```

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
| `actionlint` | self-check of this workflow with a pinned `actionlint` binary |

No cluster, cloud credentials, or secrets are required. Third-party actions are
pinned to full commit SHAs:

| Action | Pin |
| --- | --- |
| `actions/checkout` | `3d3c42e5aac5ba805825da76410c181273ba90b1` (`v7.0.1`) |
| `azure/setup-helm` | `9bc31f4ebc9c6b171d7bfbaa5d006ae7abdb4310` (`v5.0.1`) |

Tool versions are pinned in the workflow `env`: Helm `v3.22.0`,
kubeconform `v0.8.0` (verified against a pinned SHA-256), and
actionlint `v1.7.12` (verified against a pinned SHA-256).

### Branch protection on `main`

Require the following status checks before merging:

- `helm-validate`
- `manifest-validate`
- `yaml-hygiene`
- `actionlint`
