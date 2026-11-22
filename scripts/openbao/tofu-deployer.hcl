# OpenBao policy "tofu-deployer": what OpenTofu needs to configure OpenBao
# (stacks with STACK_NEEDS_OPENBAO=1) and nothing else. Written and used by
# scripts/lib/openbao.sh (openbao_tofu_token); see docs/compliance/runbooks/
# key-rotation.md for test/prod.
#
# Not granted: any secret value (kv data/metadata), transit encrypt/sign, raft
# snapshots, seal/unseal, audit devices, token creation for others, sys/raw.
# PRIVILEGED: this token can write any ACL policy except its own
# and any kubernetes-auth role, so together with Kubernetes access to some
# ServiceAccount it can grant itself everything, kv/* included. "No secret
# values" is therefore a guard against accidents and against a leaked token used
# without cluster access, not a security boundary against the operator. Controls
# that remain: short TTL, non-renewable, revoked after the run; no delete of
# mounts, CA keys/issuers/root or transit keys; every request is in the OpenBao
# audit device (tenant audit); OpenBao changes are code-reviewed (four eyes) and
# their plan is reviewed before `make deploy` (docs/runbook-bootstrap.md).

# --- secrets engines managed as code: kv (v2), pki, pki_int, transit ----------
# no "delete": disabling a mount destroys everything in it (all KV secrets incl.
# the pepper, the CA keys, the cosign key); the resources also carry
# prevent_destroy and deploy.sh refuses such plans
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/kv" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/kv/tune" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/pki" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/pki/tune" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/pki_int" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/pki_int/tune" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/transit" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/transit/tune" {
  capabilities = ["create", "read", "update"]
}

# --- kubernetes auth method and its roles --------------------------------------
path "sys/auth" {
  capabilities = ["read"]
}
path "sys/auth/kubernetes" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "sys/auth/kubernetes/tune" {
  capabilities = ["create", "read", "update", "sudo"]
}
# the provider reads auth methods through the mount table as well
path "sys/mounts/auth/kubernetes" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/auth/kubernetes/tune" {
  capabilities = ["create", "read", "update"]
}
path "auth/kubernetes/config" {
  capabilities = ["create", "read", "update"]
}
path "auth/kubernetes/role" {
  capabilities = ["list"]
}
path "auth/kubernetes/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# --- ACL policies (except this one) ---------------------------------------------
path "sys/policies/acl" {
  capabilities = ["list"]
}
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policy/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policies/acl/tofu-deployer" {
  capabilities = ["read"]
}
path "sys/policy/tofu-deployer" {
  capabilities = ["read"]
}

# --- PKI: root + issuing CA, roles, URLs ---------------------------------------
path "pki/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "pki_int/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
# never delete CA keys, issuers or the root
path "pki/root" {
  capabilities = ["deny"]
}
path "pki/key/*" {
  capabilities = ["read", "list", "update"]
}
path "pki/issuer/*" {
  capabilities = ["read", "list", "update"]
}
path "pki_int/root" {
  capabilities = ["deny"]
}
path "pki_int/key/*" {
  capabilities = ["read", "list", "update"]
}
path "pki_int/issuer/*" {
  capabilities = ["read", "list", "update"]
}

# --- transit: key lifecycle only (no encrypt/decrypt/sign) ---------------------
path "transit/keys" {
  capabilities = ["list"]
}
path "transit/keys/*" {
  capabilities = ["create", "read", "update", "list"]
}

# --- explicitly never: secret values -------------------------------------------
path "kv/*" {
  capabilities = ["deny"]
}
