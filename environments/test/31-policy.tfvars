# Admission control is a gate here, not a report: every policy and the
# signature check of the solution images (<registry>/boccob/*) reject.
# scripts/deploy.sh refuses this environment unless both modes are Enforce.
policy_mode           = "Enforce"
signature_mode        = "Enforce"
policy_failure_policy = "Fail"
