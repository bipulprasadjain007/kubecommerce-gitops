# Policy as code (Kyverno)

Guide Phase 12.4. This directory installs the [Kyverno](https://kyverno.io)
policy engine and the cluster-scoped `ClusterPolicy` resources that encode the
Kubernetes hardening requirements from guide Phase 12.3/12.4.

```text
platform/policies/
├── apps/
│   ├── kyverno.yaml            Argo Application - Kyverno Helm chart (wave -2)
│   └── kyverno-policies.yaml   Argo Application - ClusterPolicies (wave -1)
├── policies/                    ClusterPolicy manifests (one file per policy)
├── tests/
│   ├── insecure-deployment.yaml  deliberately insecure regression fixture
│   └── compliant-workload.yaml   hardened "golden path" fixture (must pass)
└── README.md
```

The `argocd/platform-apps/platform-policies.yaml` child Application (wave `-2`)
is applied by the root app-of-apps and in turn creates the two Applications
above. The `kyverno` namespace is created by
`platform/namespaces/namespaces.yaml` (namespaces child Application, wave `-5`),
**not** by this stack: the policy Applications use `CreateNamespace=false`.

## Pins

| Component | Pin | Notes |
| --- | --- | --- |
| Kyverno Helm chart | `3.9.1` (app `v1.19.1`) | `platform/policies/apps/kyverno.yaml` |
| Kyverno CLI | `v1.19.1` | `.github/workflows/validate.yml`, SHA-256 verified |
| Helm | `v3.22.0` | workflow `env` |
| OTel collector chart | `0.173.1` | `platform/observability/otel-collector-values.yaml` |

The CLI tarball SHA-256 is
`b38228f367fc0fdc2b08f4c83ea50ac5f16c60ff8d62d76a66157c33c47b70ae`
(`kyverno-cli_v1.19.1_linux_x86_64.tar.gz`).

## What is enforced vs audited

Every policy carries a `kubecommerce.io/guide-requirement` annotation naming the
guide clause it encodes. Container-level checks cover `containers`,
`initContainers` and `ephemeralContainers` (resource requests cover `containers`
and `initContainers`; Kubernetes does not support resource reservations for
ephemeral containers).

| Policy | Action | Encodes |
| --- | --- | --- |
| `disallow-privileged-containers` | **Enforce** | 12.4 disallow privileged containers; 12.3 dropped capabilities |
| `disallow-mutable-image-tags` | **Enforce** | 12.4 disallow `latest`/empty tags; 12.2 immutable image identity |
| `require-run-as-non-root` | **Enforce** | 12.3 non-root containers; 12.4 require non-root execution |
| `require-resource-requests-limits` | Audit | 12.4 require resource requests/limits |
| `require-readiness-liveness-probes` | Audit | 12.4 require probes for Deployments |
| `restrict-image-registries` | Audit | 12.4 require approved image registries |
| `require-seccomp-runtime-default` | Audit | 12.3 seccomp `RuntimeDefault` |
| `require-readonly-root-filesystem` | Audit | 12.3 read-only root filesystem |
| `require-drop-all-capabilities` | Audit | 12.3 dropped Linux capabilities |
| `disallow-hostpath-hostnetwork` | Audit | 12.3 least-privilege host access (`hostPath`/`hostNetwork`/`hostPID`/`hostIPC`) |

The three enforced policies are safe from day one because the Helm chart already
complies: `privileged` is never set, `allowPrivilegeEscalation: false` is set
globally, images are always tagged from `ghcr.io/bipulprasadjain007`, and the
pod security context sets `runAsNonRoot: true` / `runAsUser: 999`.

The audit policies are reported (and shown in `PolicyReport` objects on the
cluster) but do not block admission. The hardened chart also satisfies all of
them, so the CI gate expects **zero** violations for the chart; the split keeps
the blast radius small if a future change needs a grace period.

Notes on implementation choices:

- `disallow-mutable-image-tags` uses `validate.deny`/JMESPath (not a `*:*`
  pattern) for the "has a tag" half, so a registry with a port but no tag
  (`registry.local:5000/repo`) is correctly rejected instead of falsely passing.
- `require-drop-all-capabilities` likewise uses `contains(drop, 'ALL')`, so
  `drop: [ALL, NET_RAW]` passes while `drop: [NET_RAW]` fails.
- `require-readiness-liveness-probes` skips pods owned by a `Job`
  (a precondition inspects `metadata.ownerReferences`), so the Alembic migration
  Job's pod is not reported as a missing-probe violation.

## Scoping (and why it is written the way it is)

Each rule matches on two alternatives under `match.any`:

1. `namespaceSelector` - the in-scope namespaces, matched dynamically via the
   Kubernetes-managed `kubernetes.io/metadata.name` label. This is the cluster
   scoping.
2. `namespaces` **plus** `selector: app.kubernetes.io/part-of: kubecommerce` -
   the explicit namespace list bounds the label selector, so a pod that carries
   the `part-of: kubecommerce` label in any other namespace (for example the OTel
   collector in `observability`) is **not** matched. The Kyverno **CLI** cannot
   evaluate namespace selectors and `helm template` omits `metadata.namespace`,
   so the `policy-validate` CI job stamps the render namespace before applying
   (see the local recipe below); the fixtures already declare their namespace.

No alternative can match a Kubernetes system namespace. `monitoring` and
`observability` are outside the host-access/registry scope because node-level
agents and upstream images legitimately differ; `platform-system` is included for
the host-access audit but is explicitly excepted from the registry policy.

Rules come in two flavours: standalone `Pod`, and workload controllers
(`Deployment`/`StatefulSet`/`DaemonSet`/`Job`) whose pod template is validated at
`/spec/template/spec/...`. `CronJob` is deliberately **not** listed: its pod
template lives at `/spec/jobTemplate/spec/template/spec`, so using the chart
template path would validate a non-existent field and fail open. The `Job` a
CronJob creates is admitted and validated at the correct path instead. This
explicit two-flavour approach does not use Kyverno autogen. CI stamps the
namespace of the rendered resources so the CLI can evaluate the namespace-scoped
rules; note the CLI cannot evaluate `namespaceSelector`, so it only exercises the
`namespaces` + label alternative while admission enforces both alternatives.

### Platform workloads carrying `app.kubernetes.io/part-of: kubecommerce`

Because the label is also a NetworkPolicy peer, each platform workload that
carries it was checked:

- **OTel collector** (`observability`) - hardened in
  `platform/observability/otel-collector-values.yaml` (non-root uid 10001,
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, dropped
  `ALL`, RuntimeDefault seccomp). The configured pipeline keeps all state in
  memory and mounts only the read-only config ConfigMap at `/conf`, so no
  writable `emptyDir` is required; if a `file_storage` extension is added, mount
  an emptyDir at its `directory` path. It is also outside the namespace-bounded
  policy scope.
- **PostgreSQL/Redis/RabbitMQ StatefulSets** (`platform-system`) and the
  **alert-sink** (`observability`) already ship a compliant `securityContext`
  (non-root, read-only rootfs, dropped `ALL`).
- **Alloy/Loki/Tempo/KPS/exporters** pods do not carry the label (only their
  Argo `Application` objects do), and their namespaces are out of scope.

> **Kyverno v1.19 note.** `kyverno.io/v1 ClusterPolicy` is still fully supported
> but emits a deprecation warning pointing at the newer CEL-based
> `policies.kyverno.io` `ValidatingPolicy`. The guide specifies ClusterPolicies,
> so they are used here; the migration is a tracked follow-up.

## Run the checks locally

```bash
export PATH="$HOME/.local/bin:$PATH"
cd kubecommerce-gitops

# 1. Static validation
python3 -c "import yaml,pathlib; [list(yaml.safe_load_all(p.read_text())) for p in pathlib.Path('platform/policies').rglob('*.yaml')]; print('yaml ok')"
kubeconform -strict -summary -ignore-missing-schemas \
  platform/policies/policies/ platform/policies/tests/ platform/policies/apps/ \
  argocd/platform-apps/platform-policies.yaml

# 2. Render the hardened dev chart and stamp metadata.namespace (the policies
#    are namespace-scoped and `helm template` omits the namespace).
helm template kubecommerce charts/kubecommerce -n kubecommerce-dev \
  -f environments/dev/values.yaml > /tmp/kc-dev.yaml
python3 - <<'PY'
import yaml
CLUSTER = {"Namespace", "ClusterRole", "ClusterRoleBinding",
           "CustomResourceDefinition", "ValidatingWebhookConfiguration",
           "MutatingWebhookConfiguration"}
docs = [d for d in yaml.safe_load_all(open("/tmp/kc-dev.yaml")) if d]
for d in docs:
    if d.get("kind") not in CLUSTER:
        d.setdefault("metadata", {})["namespace"] = "kubecommerce-dev"
yaml.safe_dump_all(docs, open("/tmp/kc-dev-ns.yaml", "w"), sort_keys=False)
PY

# 3. Install the pinned CLI (once)
curl -fsSL --retry 3 -o /tmp/kyverno-cli.tar.gz \
  "https://github.com/kyverno/kyverno/releases/download/v1.19.1/kyverno-cli_v1.19.1_linux_x86_64.tar.gz"
echo "b38228f367fc0fdc2b08f4c83ea50ac5f16c60ff8d62d76a66157c33c47b70ae  /tmp/kyverno-cli.tar.gz" | sha256sum -c -
tar -xzf /tmp/kyverno-cli.tar.gz -C /tmp kyverno
install -m 0755 /tmp/kyverno "$HOME/.local/bin/kyverno"

# 4. Hardened chart: expect fail: 0 and exit 0 (Enforce + Audit), ~85 passes
kyverno apply platform/policies/policies --resource /tmp/kc-dev-ns.yaml

# 5. Insecure fixture: expect exactly 10 violations and exit 1
kyverno apply platform/policies/policies \
  --resource platform/policies/tests/insecure-deployment.yaml; echo "exit=$?"

# 6. Compliant fixture: expect fail: 0 and exit 0
kyverno apply platform/policies/policies \
  --resource platform/policies/tests/compliant-workload.yaml
```

The `policy-validate` CI job asserts all four directions: the namespace-stamped
chart renders no violations with at least one passing rule; the insecure fixture
produces exactly **10** violations and every policy name appears (so deleting a
policy cannot pass); the compliant fixture passes; and the OTel collector render
carries the hardened security context while staying outside the policy scope.

## Promoting an Audit policy to Enforce

1. Read the current violations: `kubectl get policyreport -A` (or
   `kyverno apply` locally against a live/cluster export).
2. Remediate the workloads (chart values or the offending manifest).
3. Change `spec.validationFailureAction: Audit` to `Enforce` in
   `platform/policies/policies/<policy>.yaml`.
4. Run the local checks above - the hardened dev/staging/prod renders must still
   report `fail: 0`.
5. Open a PR. `policy-validate` re-runs the four-direction gate; merge and Argo CD
   reconciles the ClusterPolicy (Application `kubecommerce-platform-kyverno-policies`).

To temporarily exempt a specific resource while remediating, prefer a Kyverno
`PolicyException` over weakening the policy; add it to `platform/policies/` (the
project already allows the `kyverno.io/PolicyException` kind only if you also add
it to the AppProject allow-list).

## Local kind caveat

Kyverno is an **admission** controller, so it works on a default `kind` cluster
with the `kindnet` CNI: a violating Pod is rejected at admission time regardless
of the CNI. This is different from `NetworkPolicy`, which `kindnet` does not
enforce (see the kind bootstrap notes). If you need to prove enforcement on a
kind cluster, apply the insecure fixture and watch the API server reject it:

```bash
kubectl apply -f platform/policies/tests/insecure-deployment.yaml   # expect a denial
kubectl apply -f platform/policies/tests/compliant-workload.yaml      # expect success
kubectl -n kyverno get clusterpolicy
kubectl get policyreport -A
```

To use a CNI that also enforces NetworkPolicy, recreate the cluster with
`CNI=calico` (repo A `scripts/kind-up.sh`).
