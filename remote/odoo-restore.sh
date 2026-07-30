#!/usr/bin/env bash
# =============================================================================
# remote/odoo-restore.sh  -  runs ON the AWS box (as root), driven by
# /etc/odoo-restore.env uploaded by 03-migrate-from-odoosh.sh.
#
# Pulls DB dump + filestore from odoo.sh, clones custom addons, and restores
# into the local PostgreSQL + filestore. Neutralizes staging when asked.
# Safe to re-run (target DB is recreated each time).
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

[[ -f /etc/odoo-restore.env ]] || { echo "missing /etc/odoo-restore.env"; exit 1; }
# shellcheck disable=SC1091
source /etc/odoo-restore.env

log(){ echo "[restore] $*"; }
WORK="$(mktemp -d /tmp/odoo-migrate.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

export PGPASSWORD="${PG_ODOO_DB_PASSWORD}"
PSQL="psql -h 127.0.0.1 -U ${PG_ODOO_DB_USER}"
ADMIN_PSQL="sudo -u postgres psql"

DUMP="${WORK}/dump.sql"
FSTAR="${WORK}/filestore.tar.gz"

# -----------------------------------------------------------------------------
# 1. Pull dump + filestore from odoo.sh
# -----------------------------------------------------------------------------
pull_ssh_dump() {
  log "Pulling DB dump over SSH from ${ODOOSH_SSH_HOST}"
  local SSH="ssh -i /tmp/odoosh_key -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"
  # Plain-SQL dump, no owner/privileges so it restores cleanly under the odoo role.
  ${SSH} "${ODOOSH_SSH_HOST}" \
    "pg_dump --no-owner --no-privileges --format=plain ${SRC_DBNAME}" | gzip > "${DUMP}.gz"
  gunzip -f "${DUMP}.gz"

  log "Locating + pulling filestore from odoo.sh"
  # odoo.sh commonly stores the filestore under one of these paths.
  local remote_fs=""
  for cand in \
      "\$HOME/data/filestore/${SRC_DBNAME}" \
      "\$HOME/.local/share/Odoo/filestore/${SRC_DBNAME}" \
      "/home/odoo/data/filestore/${SRC_DBNAME}"; do
    if ${SSH} "${ODOOSH_SSH_HOST}" "test -d ${cand}"; then remote_fs="${cand}"; break; fi
  done
  if [[ -n "${remote_fs}" ]]; then
    ${SSH} "${ODOOSH_SSH_HOST}" "tar czf - -C \$(dirname ${remote_fs}) \$(basename ${remote_fs})" > "${FSTAR}"
  else
    log "WARN: could not auto-locate filestore on odoo.sh - continuing without it (adjust paths if needed)"
    : > "${FSTAR}"
  fi
}

# extract a standard odoo backup zip (dump.sql + filestore/ + manifest.json)
extract_backup_zip() { # path-to-zip
  command -v unzip >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=300 update -qq && apt-get -o DPkg::Lock::Timeout=300 install -y -qq unzip; }
  ( cd "${WORK}" && unzip -o -qq "$1" )
  # zip extracts dump.sql into WORK, which is already where DUMP points - only
  # move if they are genuinely different paths (avoids "same file" error).
  if [[ -f "${WORK}/dump.sql" && "${WORK}/dump.sql" != "${DUMP}" ]]; then
    mv -f "${WORK}/dump.sql" "${DUMP}"
  fi
  if [[ -d "${WORK}/filestore" ]]; then
    tar czf "${FSTAR}" -C "${WORK}" filestore
  else
    : > "${FSTAR}"
  fi
}

pull_https_backup() {
  log "Downloading odoo.sh backup zip"
  curl -fsSL "${ODOOSH_DUMP_URL}" -o "${WORK}/backup.zip"
  extract_backup_zip "${WORK}/backup.zip"
}

pull_local_file() {
  log "Using uploaded local backup zip (/tmp/odoo-backup.zip)"
  [[ -s /tmp/odoo-backup.zip ]] || { echo "expected /tmp/odoo-backup.zip - not found"; exit 1; }
  extract_backup_zip /tmp/odoo-backup.zip
}

case "${PULL_METHOD}" in
  ssh_dump)     pull_ssh_dump ;;
  https_backup) pull_https_backup ;;
  local_file)   pull_local_file ;;
  *) echo "unknown PULL_METHOD=${PULL_METHOD}"; exit 1 ;;
esac
[[ -s "${DUMP}" ]] || { echo "dump is empty - aborting"; exit 1; }
log "Dump size: $(du -h "${DUMP}" | cut -f1)"

# -----------------------------------------------------------------------------
# 2. Clone custom addons from the odoo.sh project repo (branch-matched)
# -----------------------------------------------------------------------------
if [[ -n "${ODOOSH_REPO_URL}" && "${ODOOSH_REPO_URL}" != *CHANGE_ME* ]]; then
  log "Cloning custom addons (${ODOOSH_BRANCH})"
  REPO_URL="${ODOOSH_REPO_URL}"
  # inject token for https repos
  if [[ "${REPO_URL}" == https://* && -n "${GITHUB_TOKEN}" ]]; then
    REPO_URL="https://${GITHUB_USER}:${GITHUB_TOKEN}@${REPO_URL#https://}"
  fi
  # This repo uses git submodules. Make every github.com https URL (the parent
  # AND any private submodule, e.g. enterprise pos) authenticate with the token,
  # and recurse submodules so no addon folder comes across empty.
  GIT_AUTH=(-c "url.https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/.insteadOf=https://github.com/"
            -c "url.https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/.insteadOf=git@github.com:")
  git "${GIT_AUTH[@]}" clone --recurse-submodules --shallow-submodules \
      --depth 1 --branch "${ODOOSH_BRANCH}" "${REPO_URL}" "${WORK}/repo" || \
  git "${GIT_AUTH[@]}" clone --recurse-submodules "${REPO_URL}" "${WORK}/repo"
  # ensure submodules are fully materialized (in case the initial recurse was partial)
  git "${GIT_AUTH[@]}" -C "${WORK}/repo" submodule update --init --recursive || true
  # copy every module (dir containing __manifest__.py) into the custom addons path
  mkdir -p "${ODOO_CUSTOM_ADDONS}"
  found=0
  while IFS= read -r man; do
    moddir="$(dirname "${man}")"
    # skip anything inside a .git dir; copy the module (overwrite if re-run)
    rm -rf "${ODOO_CUSTOM_ADDONS:?}/$(basename "${moddir}")"
    cp -a "${moddir}" "${ODOO_CUSTOM_ADDONS}/"
    found=$((found+1))
  done < <(find "${WORK}/repo" -maxdepth 6 -name '__manifest__.py' -not -path '*/.git/*')
  log "Installed ${found} custom module(s) into ${ODOO_CUSTOM_ADDONS}"
  chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_CUSTOM_ADDONS}"

  # -- install Python dependencies declared by the custom addons ---------------
  VENV_PIP="${ODOO_HOME}/venv/bin/pip"
  log "Installing custom-addon Python dependencies"
  # 1) any requirements.txt shipped inside the modules
  while IFS= read -r req; do
    log "  pip -r ${req}"
    "${VENV_PIP}" install -q -r "${req}" 2>/dev/null || log "  WARN: some deps in ${req} failed"
  done < <(find "${ODOO_CUSTOM_ADDONS}" -maxdepth 3 -name requirements.txt 2>/dev/null)
  # 2) python names declared in manifests' external_dependencies
  # NOTE: wrapped in "|| true" - under set -e+pipefail an empty grep result
  # (no manifest declares python deps) would otherwise abort the whole restore.
  pydeps="$( { grep -rhoE "'python'[[:space:]]*:[[:space:]]*\[[^]]*\]" "${ODOO_CUSTOM_ADDONS}" 2>/dev/null \
    | grep -oE "'[A-Za-z0-9_.\-]+'" | tr -d "'" | grep -viE '^python$' | sort -u; } || true)"
  if [[ -n "${pydeps}" ]]; then
    log "  manifest python deps: $(echo "${pydeps}" | tr '\n' ' ')"
    for p in ${pydeps}; do
      "${VENV_PIP}" install -q "${p}" 2>/dev/null || log "  WARN: could not pip install '${p}' (import name may differ from pip name)"
    done
  fi
  # 3) curated deps that custom addons commonly need but often don't declare
  #    (payroll/Excel/phone/QR/EFT). Harmless if unused.
  "${VENV_PIP}" install -q \
    pandas openpyxl xlsxwriter xlrd xmltodict phonenumbers python-stdnum qrcode 2>/dev/null \
    || log "  WARN: some curated deps failed to install"
  # 4) reassert a consistent HTTP stack - custom requirements.txt sometimes pin
  #    old urllib3/requests/six that break Odoo's core (urllib3.packages.six).
  "${VENV_PIP}" install -q -U "urllib3>=2" "requests>=2.32" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 3. Restore database
# -----------------------------------------------------------------------------
log "Stopping Odoo before restore"
systemctl stop odoo || true

log "Recreating target database ${TARGET_DBNAME}"
# terminate connections, drop, recreate owned by odoo role
${ADMIN_PSQL} -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TARGET_DBNAME}';" >/dev/null 2>&1 || true
${ADMIN_PSQL} -c "DROP DATABASE IF EXISTS \"${TARGET_DBNAME}\";"
${ADMIN_PSQL} -c "CREATE DATABASE \"${TARGET_DBNAME}\" OWNER \"${PG_ODOO_DB_USER}\";"
# ensure unaccent/pg_trgm exist if the dump expects them
${ADMIN_PSQL} -d "${TARGET_DBNAME}" -c "CREATE EXTENSION IF NOT EXISTS unaccent;" >/dev/null 2>&1 || true
${ADMIN_PSQL} -d "${TARGET_DBNAME}" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"  >/dev/null 2>&1 || true
# pgvector: Odoo 19+'s 'ai' module needs the `vector` type for ai_embedding.embedding_vector.
# odoo-bootstrap.sh installs this at deploy time, but re-assert here (idempotent, fast if
# already present) so a restore onto a box deployed before this fix still gets it.
if [[ -n "${PG_VERSION:-}" ]] && ! dpkg -s "postgresql-${PG_VERSION}-pgvector" >/dev/null 2>&1; then
  log "Installing pgvector for PostgreSQL ${PG_VERSION} (not present from bootstrap)"
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq "postgresql-${PG_VERSION}-pgvector" >/dev/null 2>&1 || \
    log "WARN: could not install postgresql-${PG_VERSION}-pgvector - 'ai' module reconcile will fail"
fi
${ADMIN_PSQL} -d "${TARGET_DBNAME}" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || true

log "Loading dump into ${TARGET_DBNAME}"
${PSQL} -d "${TARGET_DBNAME}" -v ON_ERROR_STOP=0 -q -f "${DUMP}"

# Known odoo.sh data quirk: some source databases carry orphaned ai_agent_ai_topic_rel
# rows referencing ai_topic ids that don't exist in ai_topic itself (ai_topic dumps
# empty even though the relation table doesn't). This isn't caused by this restore -
# the raw dump already contains the inconsistency - but it blocks `-u ai` later with
# a foreign key violation, so clean it up here if present.
if ${PSQL} -d "${TARGET_DBNAME}" -tAc "SELECT to_regclass('public.ai_agent_ai_topic_rel')" 2>/dev/null | grep -q ai_agent_ai_topic_rel; then
  orphans="$(${PSQL} -d "${TARGET_DBNAME}" -tAc \
    "SELECT count(*) FROM ai_agent_ai_topic_rel WHERE ai_topic_id NOT IN (SELECT id FROM ai_topic)" 2>/dev/null || echo 0)"
  if [[ "${orphans:-0}" -gt 0 ]]; then
    log "Cleaning ${orphans} orphaned ai_agent_ai_topic_rel row(s) (ai_topic data missing from source dump)"
    ${PSQL} -d "${TARGET_DBNAME}" -c \
      "DELETE FROM ai_agent_ai_topic_rel WHERE ai_topic_id NOT IN (SELECT id FROM ai_topic);" >/dev/null 2>&1 || true
  fi
fi

# Downgrade guard: a DB from a newer Odoo cannot run on an older codebase.
if [[ -n "${TARGET_ODOO_VERSION:-}" ]]; then
  src_base="$(${PSQL} -d "${TARGET_DBNAME}" -tAc \
    "SELECT latest_version FROM ir_module_module WHERE name='base'" 2>/dev/null | tr -d '[:space:]' | head -c 16)"
  src_major="${src_base%%.*}"; tgt_major="${TARGET_ODOO_VERSION%%.*}"
  if [[ -n "${src_major}" && -n "${tgt_major}" && "${src_major}" =~ ^[0-9]+$ && "${src_major}" -gt "${tgt_major}" ]]; then
    echo "[restore] FATAL: source DB is Odoo ${src_base} but this box runs codebase ${TARGET_ODOO_VERSION}."
    echo "[restore] Cannot restore a newer database onto an older Odoo. Redeploy with"
    echo "[restore]   ODOO_VERSION=${src_major}.0 ./02-deploy-odoo.sh ${ODOO_ENV}"
    echo "[restore] then re-run the migration. Aborting before touching the running service."
    exit 2
  fi
  log "Version check OK: source base=${src_base:-unknown}, target codebase=${TARGET_ODOO_VERSION}"
fi

# -----------------------------------------------------------------------------
# 4. Restore filestore
# -----------------------------------------------------------------------------
if [[ -s "${FSTAR}" ]]; then
  log "Restoring filestore -> ${ODOO_FILESTORE}/${TARGET_DBNAME}"
  mkdir -p "${ODOO_FILESTORE}"
  tar xzf "${FSTAR}" -C "${WORK}"
  # source dir is either the src db name or 'filestore'
  SRC_FS_DIR="$(find "${WORK}" -maxdepth 2 -type d \( -name "${SRC_DBNAME}" -o -name filestore \) 2>/dev/null | head -1 || true)"
  rm -rf "${ODOO_FILESTORE:?}/${TARGET_DBNAME}"
  mkdir -p "${ODOO_FILESTORE}/${TARGET_DBNAME}"
  if [[ -n "${SRC_FS_DIR}" ]]; then
    cp -a "${SRC_FS_DIR}/." "${ODOO_FILESTORE}/${TARGET_DBNAME}/"
  fi
  chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_FILESTORE}"
else
  log "No filestore payload to restore"
fi

# -----------------------------------------------------------------------------
# 4b. Reconcile module schema with the deployed code.
#     The backup may be from a slightly older code state than the addons we
#     just cloned (e.g. new fields -> missing columns). Updating the modules
#     creates those columns. Configurable via RECONCILE_MODULES (default all).
# -----------------------------------------------------------------------------
RECONCILE_MODULES="${RECONCILE_MODULES:-all}"
run_u() {  # module-spec  logfile
  # shellcheck disable=SC2024  # script runs as root; root owns the redirect
  sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/python3" "${ODOO_HOME}/odoo/odoo-bin" \
    -c "${ODOO_CONF}" -d "${TARGET_DBNAME}" -u "$1" --stop-after-init > "$2" 2>&1
}
reconcile_per_custom_module() {
  # Update each INSTALLED custom module in its own transaction so one module's
  # error can't roll back the rest (this is what makes -u <all> flaky).
  local d m
  for d in "${ODOO_CUSTOM_ADDONS}"/*/; do
    [[ -d "${d}" ]] || continue
    m="$(basename "${d}")"
    sudo -u postgres psql -d "${TARGET_DBNAME}" -tAc \
      "SELECT 1 FROM ir_module_module WHERE name='${m}' AND state='installed'" 2>/dev/null | grep -q 1 || continue
    if run_u "${m}" "/tmp/reconcile-${m}.log"; then log "  reconciled ${m}"; else log "  WARN: -u ${m} failed (see /tmp/reconcile-${m}.log)"; fi
  done
}
if [[ "${RECONCILE_MODULES}" == "off" || "${RECONCILE_MODULES}" == "none" ]]; then
  log "Schema reconcile skipped (RECONCILE_MODULES=${RECONCILE_MODULES})"
elif [[ "${RECONCILE_MODULES}" == "all" ]]; then
  log "Reconciling schema: -u all (several minutes) -> /tmp/reconcile.log"
  if run_u all /tmp/reconcile.log; then
    log "Schema reconcile (-u all) complete"
  else
    log "WARN: -u all rolled back (often one module's RST/desc error) - falling back to per-custom-module updates"
    reconcile_per_custom_module
  fi
else
  log "Reconciling schema: -u ${RECONCILE_MODULES} -> /tmp/reconcile.log"
  run_u "${RECONCILE_MODULES}" /tmp/reconcile.log || log "WARN: -u ${RECONCILE_MODULES} returned non-zero - inspect /tmp/reconcile.log"
fi

# -----------------------------------------------------------------------------
# 5. Neutralize staging (never touch real customers/mail/payments)
# -----------------------------------------------------------------------------
if [[ "${NEUTRALIZE}" == "yes" ]]; then
  log "Neutralizing ${TARGET_DBNAME} (staging)"
  # Prefer Odoo's built-in neutralize (runs every module's neutralize SQL).
  if sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/python3" "${ODOO_HOME}/odoo/odoo-bin" \
        neutralize -c "${ODOO_CONF}" -d "${TARGET_DBNAME}" --stop-after-init >/dev/null 2>&1; then
    log "Built-in neutralize applied"
  else
    log "Built-in neutralize unavailable - applying SQL fallback"
    ${PSQL} -d "${TARGET_DBNAME}" -v ON_ERROR_STOP=0 <<'SQL'
-- disable outbound mail
UPDATE ir_mail_server SET active = false;
UPDATE fetchmail_server SET active = false;
-- pause scheduled actions
UPDATE ir_cron SET active = false;
-- disable payment providers (put into test/disabled)
UPDATE payment_provider SET state = 'disabled' WHERE state IS DISTINCT FROM 'disabled';
-- flag the base url / mark as neutralized
INSERT INTO ir_config_parameter (key, value)
  VALUES ('database.is_neutralized', 'True')
  ON CONFLICT (key) DO UPDATE SET value = 'True';
SQL
  fi
fi

# -----------------------------------------------------------------------------
# 5b. Optional hold: disable cron/mail/payments BEFORE Odoo ever starts, so the
#     cron poller can't fire a live job (e.g. a recurring payment) on first boot.
#     Applies regardless of NEUTRALIZE - this only pauses outbound automation,
#     it does not run Odoo's broader neutralize (no data scrubbing, reversible
#     by flipping these back to true/enabled deliberately).
# -----------------------------------------------------------------------------
if [[ "${HOLD_BEFORE_START:-no}" == "yes" ]]; then
  log "HOLD_BEFORE_START set - disabling cron/mail/payments before first start"
  ${PSQL} -d "${TARGET_DBNAME}" -v ON_ERROR_STOP=0 <<'SQL'
UPDATE ir_cron SET active = false;
UPDATE ir_mail_server SET active = false;
UPDATE fetchmail_server SET active = false;
UPDATE payment_provider SET state = 'disabled' WHERE state IS DISTINCT FROM 'disabled';
SQL
fi

# -----------------------------------------------------------------------------
# 6. Ownership + restart + module list refresh
# -----------------------------------------------------------------------------
chown -R "${ODOO_USER}:${ODOO_USER}" /var/lib/odoo
log "Starting Odoo"
systemctl start odoo
sleep 8
systemctl --no-pager --full status odoo | head -n 8 || true
log "Restore complete for ${ODOO_ENV} -> ${TARGET_DBNAME}"
