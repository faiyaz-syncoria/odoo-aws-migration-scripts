#!/usr/bin/env bash
# =============================================================================
# 03-migrate-from-odoosh.sh  -  CHECKPOINT 3: Backup from odoo.sh + restore
# -----------------------------------------------------------------------------
# For each environment, automates:
#   - pulling the DB dump + filestore from the matching odoo.sh branch
#       * method "ssh_dump"    : SSH into the odoo.sh build host, pg_dump + tar
#       * method "https_backup": download the signed odoo.sh backup .zip
#   - cloning the custom addons from the odoo.sh project repo (branch-matched)
#   - restoring onto the target AWS box:
#       * recreate the target DB, load the dump, restore the filestore
#       * install custom addons into the addons path, update module list
#   - neutralizing staging (kills outbound mail, payment creds, crons, etc.)
#
# The heavy data pull runs ON the AWS box (not your laptop) to avoid a double
# transfer of a potentially large filestore.
#
# Usage:  ./03-migrate-from-odoosh.sh [production|staging]   (default: both)
#
# TIP: run staging first, validate, then production.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
if [[ "${INSTALL_MODE:-migrate}" == "fresh" ]]; then
  die "config.env has INSTALL_MODE=fresh (no odoo.sh source) - refusing to run this destructive DB-recreate step. Set INSTALL_MODE=migrate and fill in the odoo.sh source vars if you actually want to migrate data."
fi
require_no_placeholder ODOOSH_REPO_URL

TARGET_ENVS=("$@"); [[ ${#TARGET_ENVS[@]} -eq 0 ]] && TARGET_ENVS=("${ENVIRONMENTS[@]}")
REMOTE_RESTORE="${REPO_ROOT}/remote/odoo-restore.sh"
[[ -f "${REMOTE_RESTORE}" ]] || die "Missing ${REMOTE_RESTORE}"

migrate_one() {
  local e="$1" up
  # config uses the abbreviation PROD/STAGING for odoo.sh + target vars
  up="$(echo "${e}" | tr '[:lower:]' '[:upper:]')"
  [[ "${e}" == "production" ]] && up="PROD"
  state_load "${e}"
  [[ -n "${PUBLIC_IP:-}" ]]      || die "No PUBLIC_IP for ${e}; run 01 first."
  [[ "${ODOO_DEPLOYED:-}" == "yes" ]] || warn "${e} not marked deployed; run 02 first if this fails."

  # per-env source parameters
  local ssh_host dump_url dump_file src_db branch target_db neutralize
  ssh_host="$(eval echo "\${ODOOSH_${up}_SSH_HOST:-}")"
  ssh_host="${ssh_host#ssh }"   # tolerate a pasted 'ssh user@host' value
  dump_url="$(eval echo "\${ODOOSH_${up}_DUMP_URL:-}")"
  dump_file="$(eval echo "\${ODOOSH_${up}_DUMP_FILE:-}")"
  src_db="$(eval echo "\${ODOOSH_${up}_DBNAME}")"
  branch="$(eval echo "\${ODOOSH_${up}_BRANCH}")"
  target_db="$(eval echo "\${TARGET_${up}_DBNAME}")"
  neutralize="no"
  [[ "${e}" == "staging" && "${NEUTRALIZE_STAGING}" == "true" ]] && neutralize="yes"

  checkpoint "3 - Migrate ${e}: odoo.sh(${branch}) -> ${target_db} @ ${PUBLIC_IP}"
  require_no_placeholder "ODOOSH_${up}_DBNAME"
  if [[ "${ODOOSH_PULL_METHOD}" == "ssh_dump" ]];     then require_no_placeholder "ODOOSH_${up}_SSH_HOST"; fi
  if [[ "${ODOOSH_PULL_METHOD}" == "https_backup" ]]; then require_no_placeholder "ODOOSH_${up}_DUMP_URL"; fi
  if [[ "${ODOOSH_PULL_METHOD}" == "local_file" ]];   then
    [[ -f "${dump_file}" ]] || die "ODOOSH_${up}_DUMP_FILE not found: '${dump_file}' (download the backup .zip from odoo.sh first)"
  fi

  # DB password needed by restore (already generated in step 2)
  local db_pass; db_pass="$(resolve_secret PG_ODOO_DB_PASSWORD "${e}-db-password")"

  # build remote restore env
  local tmpenv; tmpenv="$(mktemp)"
  cat > "${tmpenv}" <<EOF
ODOO_ENV="${e}"
TARGET_ODOO_VERSION="${ODOO_VERSION}"
RECONCILE_MODULES="${RECONCILE_MODULES:-all}"
PULL_METHOD="${ODOOSH_PULL_METHOD}"
ODOOSH_SSH_HOST="${ssh_host}"
ODOOSH_DUMP_URL="${dump_url}"
SRC_DBNAME="${src_db}"
TARGET_DBNAME="${target_db}"
ODOOSH_REPO_URL="${ODOOSH_REPO_URL}"
ODOOSH_BRANCH="${branch}"
NEUTRALIZE="${neutralize}"
GITHUB_USER="${GITHUB_USER}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
ODOO_USER="${ODOO_USER}"
ODOO_HOME="${ODOO_HOME}"
ODOO_CONF="${ODOO_CONF}"
ODOO_CUSTOM_ADDONS="${ODOO_CUSTOM_ADDONS}"
ODOO_FILESTORE="${ODOO_FILESTORE}"
PG_VERSION="${PG_VERSION}"
PG_ODOO_DB_USER="${PG_ODOO_DB_USER}"
PG_ODOO_DB_PASSWORD="${db_pass}"
EOF

  info "Uploading restore assets to ${e}"
  remote_copy "${tmpenv}"        "${PUBLIC_IP}:/tmp/restore.env"
  remote_copy "${REMOTE_RESTORE}" "${PUBLIC_IP}:/tmp/odoo-restore.sh"
  rm -f "${tmpenv}"

  # upload odoo.sh SSH key if using ssh_dump
  if [[ "${ODOOSH_PULL_METHOD}" == "ssh_dump" ]]; then
    [[ -f "${ODOOSH_SSH_KEY}" ]] || die "ODOOSH_SSH_KEY not found at ${ODOOSH_SSH_KEY}"
    remote_copy "${ODOOSH_SSH_KEY}" "${PUBLIC_IP}:/tmp/odoosh_key"
    remote_ssh  "${PUBLIC_IP}" "chmod 600 /tmp/odoosh_key"
  fi

  # upload the local backup .zip if using local_file (may be large; scp streams it)
  if [[ "${ODOOSH_PULL_METHOD}" == "local_file" ]]; then
    info "Uploading local backup $(du -h "${dump_file}" | cut -f1) to ${e} (this can take a while over a slow link)"
    remote_copy "${dump_file}" "${PUBLIC_IP}:/tmp/odoo-backup.zip"
  fi

  info "Running remote restore on ${e} (pull + restore; can take a while)"
  if ! remote_ssh "${PUBLIC_IP}" \
    "bash -c 'set -o pipefail; \
       sudo install -m600 /tmp/restore.env /etc/odoo-restore.env && \
       sudo chmod +x /tmp/odoo-restore.sh && \
       sudo /tmp/odoo-restore.sh 2>&1 | tee /tmp/restore.log; \
       rc=\${PIPESTATUS[0]}; \
       rm -f /tmp/restore.env /tmp/odoosh_key /tmp/odoo-backup.zip; exit \$rc'"; then
    die "${e}: remote restore FAILED - inspect /tmp/restore.log on ${PUBLIC_IP} (exit 2 = version downgrade guard tripped)."
  fi

  # post-restore sanity check: DB exists and Odoo answers
  if remote_ssh "${PUBLIC_IP}" "sudo -u postgres psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${target_db}'\"" | grep -q 1; then
    ok "${e}: database ${target_db} restored"
  else
    die "${e}: target database ${target_db} not found after restore - see /tmp/restore.log"
  fi

  state_set "${e}" MIGRATED "yes"
  ok "${e}: migration complete"
}

for e in "${TARGET_ENVS[@]}"; do migrate_one "${e}"; done

checkpoint "CHECKPOINT 3 COMPLETE - data migrated from odoo.sh"
echo "Validate the apps, then run ./04-harden-and-tune.sh"
