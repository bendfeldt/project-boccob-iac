# Runbook: certificate rotation

| Certificate | Lifetime / renewal | Procedure |
|---|---|---|
| Workload and ingress certificates (ClusterIssuer `openbao-pki`) | 90 days, renewed at 60 days by cert-manager, private key rotated (`rotationPolicy: Always`) | automatic; alert `CertificateExpiringSoon` (< `cert_expiry_warning_days`) and `CertificateNotReady` indicate failures. Force: `kubectl -n <ns> delete secret <tls-secret>` (cert-manager reissues) or `cmctl renew`. **[verified: issuance via make verify]** |
| Issuing CA (`pki_int`, 5 years) | rotate at least a year before expiry | create a new intermediate in OpenBao (`pki_int` new issuer), sign by root, set as default issuer; re-issue leaves (delete TLS Secrets namespace by namespace); update the `platform-ca` bundle (stack 11/12) so both old and new chains are trusted during the overlap **[static]** |
| Root CA (`pki`, 10 years) | plan years ahead | new root, cross-sign, distribute to every `platform-ca` ConfigMap and to clients outside the cluster (workstations, registry), then re-issue the intermediate **[static]** |
| Bootstrap CA (OpenBao listener only) | cert-manager CA issuer in `platform-system` | renew the OpenBao listener certificate by deleting `secrets/openbao-server-tls`; OpenBao reloads on restart (OnDelete: restart pods one by one, unseal) **[static]** |
| Registry CA / Zot certificate | `~/.boccob/<env>/pki/registry-ca.*` | regenerate with registry-up, distribute the CA to nodes (`registries.yaml`) and Kyverno (`stacks/31-policy` reads the CA file; redeploy) **[static]** |
| Kyverno webhook certificates | managed by Kyverno | automatic |

After rotation: `make verify ENV=<env>` (PKI chain check, TLS checks of
PostgreSQL, S3, Keycloak).
