#!/usr/bin/env bash
# Create (idempotently) the test users of environments/<env>/test-users.conf in the
# Keycloak realm `lakehouse`, with generated passwords kept outside git in
# ~/.boccob/<env>/test-users/<user>. dev only.
#
#   scripts/dev/test-users.sh dev
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${1:-${ENV:-}}"
require_cmd kubectl
[[ "$ENV" == "dev" || "${ALLOW_TEST_USERS:-0}" == "1" ]] || die "test users are for dev only (ALLOW_TEST_USERS=1 to override)"
conf="${REPO_ROOT}/environments/${ENV}/test-users.conf"
[[ -f "$conf" ]] || die "missing ${conf}"
# shellcheck source=/dev/null
source "$conf"

pwdir="${STATE_DIR}/test-users"
admin_user="$(kubectl -n identity get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)"
admin_pw="$(kubectl -n identity get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)"

input=""
for entry in "${TEST_USERS[@]}"; do
  user="${entry%%=*}"; groups="${entry#*=}"
  [[ -f "${pwdir}/${user}" ]] || random_secret 24 | write_secret_file "${pwdir}/${user}"
  input+="${user} ${groups} $(cat "${pwdir}/${user}")"$'\n'
done

# secrets go over stdin to kcadm inside the Keycloak pod (never on a host command line)
step "Keycloak test users (${#TEST_USERS[@]})"
{ printf '%s\n%s\n' "$admin_user" "$admin_pw"; printf '%s' "$input"; } | kubectl -n identity exec -i deploy/keycloak -- bash -c '
set -euo pipefail
export HOME=/tmp
k() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/test-users.kcadm; }
read -r AU; read -r AP
keytool -importcert -noprompt -alias platform -file /etc/platform-ca/ca.crt -keystore /tmp/test-users.p12 -storepass changeit >/dev/null 2>&1 || true
k config truststore --trustpass changeit /tmp/test-users.p12 >/dev/null
k config credentials --server https://keycloak.identity.svc:8443 --realm master --user "$AU" --password "$AP" >/dev/null
while read -r U G P; do
  [[ -n "$U" ]] || continue
  id="$(k get users -r lakehouse -q "username=$U" -q exact=true --fields id --format csv --noquotes)"
  if [[ -z "$id" ]]; then
    k create users -r lakehouse -s "username=$U" -s enabled=true -s emailVerified=true \
      -s "email=$U@example.invalid" -s "firstName=$U" -s lastName=Test >/dev/null 2>&1
    id="$(k get users -r lakehouse -q "username=$U" -q exact=true --fields id --format csv --noquotes)"
    # the realm password policy keeps a history: set the password on creation only
    k set-password -r lakehouse --username "$U" --new-password "$P" >/dev/null
    state=created
  else
    state=exists
  fi
  for g in ${G//,/ }; do
    gid=""
    while IFS=, read -r i n; do [[ "$n" == "$g" ]] && gid="$i"; done < <(k get groups -r lakehouse -q "search=$g" --fields id,name --format csv --noquotes)
    [[ -n "$gid" ]] || { echo "group $g not found"; exit 1; }
    k update "users/$id/groups/$gid" -r lakehouse -s realm=lakehouse -s "userId=$id" -s "groupId=$gid" -n >/dev/null
  done
  echo "$U: $state, groups $G"
done
rm -f /tmp/test-users.kcadm /tmp/test-users.p12'
log "passwords in ${pwdir}/<user>"
