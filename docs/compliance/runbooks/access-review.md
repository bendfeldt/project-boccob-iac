# Runbook: access review

Cadence and approvers are set by the access control policy **[manual]**
(typical: quarterly for privileged access, half-yearly for the rest). Export
the lists below, have the owners confirm or revoke, store the signed result.

| What | How to list | Owner |
|---|---|---|
| Keycloak group members (`platform-admin`, `data-engineer`, `analyst`, `pii-reader`, `auditor`) | `kcadm.sh get groups/<id>/members -r lakehouse` inside the Keycloak pod (admin credentials `kv/identity/keycloak-admin`), or the admin console | data owner / security officer |
| Keycloak clients and service accounts | `kcadm.sh get clients -r lakehouse --fields clientId,serviceAccountsEnabled` | platform owner |
| OpenBao policies and roles | `bao policy list`, `bao list auth/kubernetes/role`, `bao read auth/kubernetes/role/<r>` | security officer |
| OpenBao tokens with root/admin policy | `bao list auth/token/accessors` + `bao token lookup -accessor` | security officer |
| Kubernetes RBAC (cluster-admin bindings, kubeconfigs issued) | `kubectl get clusterrolebindings -o wide`, `kubectl get rolebindings -A -o wide` | platform owner |
| S3 users and policies | `rc admin user list`, `rc admin policy list` (RustFS root, break-glass) | platform owner |
| Break-glass accounts (Keycloak `bootstrap-admin`, RustFS root, OpenBao root) | records of use; rotate after use (`key-rotation.md`) | security officer |
| OPA role → table/column rules | solution repo policy bundle (`make opa-test` output) | data owner |
| PolicyExceptions (Kyverno) | `kubectl -n kyverno get policyexceptions.policies.kyverno.io -o yaml` (each has `boccob.io/justification`) | security officer |
| Dagster UI access (`dagster_ui_groups`, stack 22; test/prod: `platform-admin` only) | members of those Keycloak groups | security officer — **privileged**: a UI user can launch every job with run config and tags, i.e. act as `svc-dagster` (`pii-reader`, `lakehouse-service`) and, through the purge jobs, with the purge credential. The launcher's tag allowlist and admission policies stop arbitrary code, not misuse of the jobs themselves |
| Grafana audit instance access | members of the `auditor` group (Keycloak) | DPO |

Evidence: the Kubernetes API, OpenBao and Keycloak event logs in the audit
tenant show who used which access during the period
(`incident-response.md` §4 queries).
