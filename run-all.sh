#!/usr/bin/env bash
# =============================================================================
# run-all.sh  -  orchestrate the full migration through all four checkpoints.
# -----------------------------------------------------------------------------
# Runs, in order, with a pause between checkpoints for validation:
#   00 preflight -> 01 provision -> 02 deploy -> 03 migrate -> 04 harden
#
# Usage:
#   ./run-all.sh                 # both environments, interactive gates
#   ./run-all.sh staging         # single environment
#   ASSUME_YES=1 ./run-all.sh    # non-interactive (CI)
#
# RECOMMENDED FLOW: run staging end-to-end first, validate, then production.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
HERE="$(dirname "$0")"

TARGET_ENVS=("$@")
gate(){ # message
  echo
  confirm "$1" || die "Stopped by operator."
}

bash "${HERE}/00-preflight.sh"
gate "Preflight passed. Proceed to CHECKPOINT 1 (AWS provisioning)?"

bash "${HERE}/01-provision-aws.sh" "${TARGET_ENVS[@]}"
gate "AWS provisioned. Point DNS at the Elastic IPs now. Proceed to CHECKPOINT 2 (deploy Odoo)?"

bash "${HERE}/02-deploy-odoo.sh" "${TARGET_ENVS[@]}"
gate "Default Odoo deployed. Proceed to CHECKPOINT 3 (migrate from odoo.sh)?"

bash "${HERE}/03-migrate-from-odoosh.sh" "${TARGET_ENVS[@]}"
gate "Data migrated. Validate the apps. Proceed to CHECKPOINT 4 (harden + tune)?"

bash "${HERE}/04-harden-and-tune.sh" "${TARGET_ENVS[@]}"

checkpoint "ALL CHECKPOINTS COMPLETE"
ok "Migration finished."
