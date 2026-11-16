# openbao

OpenBao server on integrated raft storage (1 member in dev, 3 in HA), TLS on
the listener (certificate from the *bootstrap* CA so OpenBao does not depend
on its own PKI), declarative audit devices (stdout + file on a dedicated
volume), restricted Pod Security.

The release is created **sealed and uninitialised**. Initialisation, unseal
and raft join are done by `scripts/openbao/init.sh` (key custody is described
in `docs/runbook-bootstrap.md`). Mounts, auth methods, PKI and policies are
configured by `modules/openbao-config` in `stacks/11-foundation-pki`.

Update strategy is `OnDelete`: upgrade standbys first, then step down and
replace the active member (each restarted pod must be unsealed).
