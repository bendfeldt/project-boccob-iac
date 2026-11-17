# shellcheck shell=bash
# Non-secret settings for the scripts (sourced by scripts/lib/common.sh).
# test = k3s installed on hosts from the air-gap bundle (scripts/cluster/host-install.sh).
export CLUSTER_NAME="boccob-test"
export CLUSTER_MODE="hosts"
export BASE_DOMAIN="test.lakehouse.internal"
# Zot must be reachable under this name from every node and from the operator
# workstation, with a certificate trusted via REGISTRY_CA_FILE.
export REGISTRY_HOST="registry.test.lakehouse.internal:5000"

# hosts-mode only: where the fixed registration address (VIP / LB / DNS RR) of
# the k3s servers lives, and the node inventory used by scripts/cluster/hosts-up.sh
export K3S_API_ENDPOINT="k3s.test.lakehouse.internal"
export K3S_SERVERS="${K3S_SERVERS:-k3s-server-1.test.lakehouse.internal k3s-server-2.test.lakehouse.internal k3s-server-3.test.lakehouse.internal}"
export K3S_AGENTS="${K3S_AGENTS:-k3s-agent-1.test.lakehouse.internal k3s-agent-2.test.lakehouse.internal k3s-agent-3.test.lakehouse.internal}"
export K3S_SSH_USER="${K3S_SSH_USER:-root}"

# OpenBao init: Shamir 5/3, shares PGP-encrypted to the key custodians
# (see docs/runbook-bootstrap.md "OpenBao key custody"). Comma separated list of
# public key files, one per share, plus one for the initial root token.
export OPENBAO_KEY_SHARES=5
export OPENBAO_KEY_THRESHOLD=3
export OPENBAO_REPLICAS=3
export OPENBAO_PGP_KEYS="${OPENBAO_PGP_KEYS:-}"
export OPENBAO_ROOT_TOKEN_PGP_KEY="${OPENBAO_ROOT_TOKEN_PGP_KEY:-}"
# state encryption: pbkdf2 passphrase supplied by the operator through
# TOFU_STATE_PASSPHRASE (from the password vault / HSM-backed secret store);
# never written to disk by the scripts in this mode.
export STATE_ENCRYPTION="pbkdf2-env"

# deploy.sh refuses to deploy while admission policies are in Audit mode
export REQUIRE_POLICY_ENFORCE=1
