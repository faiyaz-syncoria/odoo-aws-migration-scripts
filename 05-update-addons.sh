#!/usr/bin/env bash
# =============================================================================
# 05-update-addons.sh  -  CHECKPOINT 5: Non-destructive code deploy
# -----------------------------------------------------------------------------
# For each environment, pulls the latest custom addons from the matching
# odoo.sh project branch, installs any new Python deps, and reconciles schema
# against the EXISTING database. Never drops/recreates the database, loads a
# dump, or touches the filestore - unlike 03-migrate-from-odoosh.sh, this is
# safe to run on every merge (manually or from CI) without losing data.
#
# Usage:  ./05-update-addons.sh [production|staging]   (default: both)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
require_no_placeholder ODOOSH_REPO_URL

TARGET_ENVS=("$@"); [[ ${#TARGET_ENVS[@]} -eq 0 ]] && TARGET_ENVS=("${ENVIRONMENTS[@]}")
REMOTE_UPDATE="${REPO_ROOT}/remote/odoo-update-code.sh"
[[ -f "${REMOTE_UPDATE}" ]] || die "Missing ${REMOTE_UPDATE}"

update_one() {
  local e="$1" up
  up="$(echo "${e}" | tr '[:lower:]' '[:upper:]')"
  [[ "${e}" == "production" ]] && up="PROD"
  state_load "${e}"
  [[ -n "${PUBLIC_IP:-}" ]] || die "No PUBLIC_IP for ${e}; run 01 first."

  local branch target_db
  branch="$(eval echo "\${ODOOSH_${up}_BRANCH}")"
  target_db="$(eval echo "\${TARGET_${up}_DBNAME}")"
  require_no_placeholder "ODOOSH_${up}_BRANCH" "TARGET_${up}_DBNAME"

  checkpoint "5 - Update code: odoo.sh(${branch}) -> ${target_db} @ ${PUBLIC_IP}"

  local db_pass; db_pass="$(resolve_secret PG_ODOO_DB_PASSWORD "${e}-db-password")"

  local tmpenv; tmpenv="$(mktemp)"
  cat > "${tmpenv}" <<EOF
ODOO_ENV="${e}"
ODOOSH_REPO_URL="${ODOOSH_REPO_URL}"
ODOOSH_BRANCH="${branch}"
TARGET_DBNAME="${target_db}"
RECONCILE_MODULES="${RECONCILE_MODULES:-all}"
GITHUB_USER="${GITHUB_USER}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
ODOO_USER="${ODOO_USER}"
ODOO_HOME="${ODOO_HOME}"
ODOO_CONF="${ODOO_CONF}"
ODOO_CUSTOM_ADDONS="${ODOO_CUSTOM_ADDONS}"
PG_ODOO_DB_USER="${PG_ODOO_DB_USER}"
PG_ODOO_DB_PASSWORD="${db_pass}"
EOF

  info "Uploading update assets to ${e}"
  remote_copy "${tmpenv}"       "${PUBLIC_IP}:/tmp/update.env"
  remote_copy "${REMOTE_UPDATE}" "${PUBLIC_IP}:/tmp/odoo-update-code.sh"
  rm -f "${tmpenv}"

  info "Running code update on ${e} (pull + Python deps + schema reconcile)"
  if ! remote_ssh "${PUBLIC_IP}" \
    "bash -c 'set -o pipefail; \
       sudo install -m600 /tmp/update.env /etc/odoo-update.env && \
       sudo chmod +x /tmp/odoo-update-code.sh && \
       sudo /tmp/odoo-update-code.sh 2>&1 | tee /tmp/update.log; \
       rc=\${PIPESTATUS[0]}; rm -f /tmp/update.env; exit \$rc'"; then
    die "${e}: code update FAILED - inspect /tmp/update.log on ${PUBLIC_IP}."
  fi

  ok "${e}: code updated and schema reconciled"
}

for e in "${TARGET_ENVS[@]}"; do update_one "${e}"; done

checkpoint "CHECKPOINT 5 COMPLETE - code deployed, no data touched"
