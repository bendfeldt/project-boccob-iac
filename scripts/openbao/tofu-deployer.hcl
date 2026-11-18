# OpenBao policy "tofu-deployer": what OpenTofu needs to configure OpenBao
# (stacks with STACK_NEEDS_OPENBAO=1) and nothing else. Written and used by
# scripts/lib/openbao.sh (openbao_tofu_token); see docs/compliance/runbooks/
# key-rotation.md for test/prod.
#
# Not granted: any secret value (kv data/metadata), transit encrypt/sign, raft
# snapshots, seal/unseal, audit devices, token creation for others, sys/raw.
# Inherent limit: whoever manages ACL policies and auth roles can grant access
# indirectly (e.g. a role bound to a ServiceAccount they control), so this
# policy limits accidents and the blast radius of a leaked deploy token, not a
# malicious operator. Its own policy is read-only to it.

# --- secrets engines managed as code: kv (v2), pki, pki_int, transit ----------
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/kv" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/mounts/kv/tune" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/pki" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/mounts/pki/tune" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/pki_int" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/mounts/pki_int/tune" {
  capabilities = ["create", "read", "update"]
}
path "sys/mounts/transit" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/mounts/transit/tune" {
  capabilities = ["create", "read", "update"]
}

# --- kubernetes auth method and its roles --------------------------------------
path "sys/auth" {
  capabilities = ["read"]
}
path "sys/auth/kubernetes" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
path "sys/auth/kubernetes/tune" {
  capabilities = ["create", "read", "update", "sudo"]
}
# the provider reads auth methods through the mount table as well
path "sys/mounts/auth/kubernetes" {
  capabilities = ["create", "read", "update", "delete"]
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

# --- transit: key lifecycle only (no encrypt/decrypt/sign) ---------------------
path "transit/keys" {
  capabilities = ["list"]
}
path "transit/keys/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# --- explicitly never: secret values -------------------------------------------
path "kv/*" {
  capabilities = ["deny"]
}
