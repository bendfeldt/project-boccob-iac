# Input: `tofu show -json <plan>`. Output: one line per planned delete/replace
# of an irreplaceable resource (scripts/deploy.sh refuses the plan unless
# ALLOW_DESTROY=<env>). Test: scripts/tests/destroy-guard.test.sh.
#   vault_*        OpenBao mounts, auth, policies, roles, PKI, transit keys
#   namespaces     deleting one deletes everything in it (PVCs, CNPG clusters, OpenBao)
#   CNPG clusters, the RustFS release, PersistentVolumeClaims
.resource_changes[]? | select(.change.actions | index("delete"))
| select((.type | startswith("vault_"))
         or (.type | startswith("kubernetes_namespace"))
         or (.type == "kubernetes_manifest" and ((.change.before.manifest.kind // "") == "Cluster")
             and ((.change.before.manifest.apiVersion // "") | startswith("postgresql.cnpg.io")))
         or (.type == "helm_release" and (.address | test("module\\.rustfs\\.")))
         or (.type | startswith("kubernetes_persistent_volume_claim")))
| "\(.address) (\(.change.actions | join("+")))"
