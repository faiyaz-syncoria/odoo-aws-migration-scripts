#!/usr/bin/env bash
# =============================================================================
# remote/odoo-update-code.sh  -  runs ON the AWS box (as root), driven by
# /etc/odoo-update.env uploaded by 05-update-addons.sh (or persisted at
# /etc/odoo-ci-deploy.env for the CI forced-command path — see
# 06-setup-ci-deploy.sh).
#
# NON-DESTRUCTIVE code deploy: pulls the latest custom addons from the given
# branch, installs any new Python deps, and reconciles schema against the
# EXISTING database. Unlike remote/odoo-restore.sh, this never drops/recreates
# the database, loads a dump, or touches the filestore — safe to trigger on
# every merge (e.g. from CI) without losing data.
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

ENV_FILE="${1:-/etc/odoo-update.env}"
[[ -f "${ENV_FILE}" ]] || { echo "missing ${ENV_FILE}"; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"

log(){ echo "[update-code] $*"; }
WORK="$(mktemp -d /tmp/odoo-update.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

export PGPASSWORD="${PG_ODOO_DB_PASSWORD:-}"
PSQL="psql -h 127.0.0.1 -U ${PG_ODOO_DB_USER:-odoo}"

# -----------------------------------------------------------------------------
# 1. Pull latest custom addons from the odoo.sh project repo (branch-matched)
# -----------------------------------------------------------------------------
[[ -n "${ODOOSH_REPO_URL:-}" && "${ODOOSH_REPO_URL}" != *CHANGE_ME* ]] || { echo "ODOOSH_REPO_URL not set"; exit 1; }

log "Cloning custom addons (${ODOOSH_BRANCH})"
REPO_URL="${ODOOSH_REPO_URL}"
if [[ "${REPO_URL}" == https://* && -n "${GITHUB_TOKEN:-}" ]]; then
  REPO_URL="https://${GITHUB_USER}:${GITHUB_TOKEN}@${REPO_URL#https://}"
fi
GIT_AUTH=(-c "url.https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/.insteadOf=https://github.com/"
          -c "url.https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/.insteadOf=git@github.com:")
git "${GIT_AUTH[@]}" clone --recurse-submodules --shallow-submodules \
    --depth 1 --branch "${ODOOSH_BRANCH}" "${REPO_URL}" "${WORK}/repo"
git "${GIT_AUTH[@]}" -C "${WORK}/repo" submodule update --init --recursive || true

mkdir -p "${ODOO_CUSTOM_ADDONS}"
found=0
while IFS= read -r man; do
  moddir="$(dirname "${man}")"
  rm -rf "${ODOO_CUSTOM_ADDONS:?}/$(basename "${moddir}")"
  cp -a "${moddir}" "${ODOO_CUSTOM_ADDONS}/"
  found=$((found+1))
done < <(find "${WORK}/repo" -maxdepth 6 -name '__manifest__.py' -not -path '*/.git/*')
log "Synced ${found} custom module(s) into ${ODOO_CUSTOM_ADDONS}"
chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_CUSTOM_ADDONS}"

# -----------------------------------------------------------------------------
# 2. Install Python dependencies declared by the custom addons
# -----------------------------------------------------------------------------
VENV_PIP="${ODOO_HOME}/venv/bin/pip"
log "Installing custom-addon Python dependencies"
while IFS= read -r req; do
  log "  pip -r ${req}"
  "${VENV_PIP}" install -q -r "${req}" 2>/dev/null || log "  WARN: some deps in ${req} failed"
done < <(find "${ODOO_CUSTOM_ADDONS}" -maxdepth 3 -name requirements.txt 2>/dev/null)
pydeps="$( { grep -rhoE "'python'[[:space:]]*:[[:space:]]*\[[^]]*\]" "${ODOO_CUSTOM_ADDONS}" 2>/dev/null \
  | grep -oE "'[A-Za-z0-9_.\-]+'" | tr -d "'" | grep -viE '^python$' | sort -u; } || true)"
if [[ -n "${pydeps}" ]]; then
  log "  manifest python deps: $(echo "${pydeps}" | tr '\n' ' ')"
  for p in ${pydeps}; do
    "${VENV_PIP}" install -q "${p}" 2>/dev/null || log "  WARN: could not pip install '${p}'"
  done
fi
"${VENV_PIP}" install -q \
  pandas openpyxl xlsxwriter xlrd xmltodict phonenumbers python-stdnum qrcode 2>/dev/null \
  || log "  WARN: some curated deps failed to install"
"${VENV_PIP}" install -q -U "urllib3>=2" "requests>=2.32" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 3. Reconcile schema against the EXISTING database (no drop/recreate)
# -----------------------------------------------------------------------------
log "Stopping Odoo for schema reconcile"
systemctl stop odoo || true

RECONCILE_MODULES="${RECONCILE_MODULES:-all}"
run_u() {  # module-spec  logfile
  # shellcheck disable=SC2024
  sudo -u "${ODOO_USER}" "${ODOO_HOME}/venv/bin/python3" "${ODOO_HOME}/odoo/odoo-bin" \
    -c "${ODOO_CONF}" -d "${TARGET_DBNAME}" -u "$1" --stop-after-init > "$2" 2>&1
}
reconcile_per_custom_module() {
  local d m
  for d in "${ODOO_CUSTOM_ADDONS}"/*/; do
    [[ -d "${d}" ]] || continue
    m="$(basename "${d}")"
    sudo -u postgres psql -d "${TARGET_DBNAME}" -tAc \
      "SELECT 1 FROM ir_module_module WHERE name='${m}' AND state='installed'" 2>/dev/null | grep -q 1 || continue
    if run_u "${m}" "/tmp/update-reconcile-${m}.log"; then log "  reconciled ${m}"; else log "  WARN: -u ${m} failed (see /tmp/update-reconcile-${m}.log)"; fi
  done
}
if [[ "${RECONCILE_MODULES}" == "off" || "${RECONCILE_MODULES}" == "none" ]]; then
  log "Schema reconcile skipped (RECONCILE_MODULES=${RECONCILE_MODULES})"
elif [[ "${RECONCILE_MODULES}" == "all" ]]; then
  log "Reconciling schema: -u all -> /tmp/update-reconcile.log"
  if run_u all /tmp/update-reconcile.log; then
    log "Schema reconcile (-u all) complete"
  else
    log "WARN: -u all rolled back - falling back to per-custom-module updates"
    reconcile_per_custom_module
  fi
else
  log "Reconciling schema: -u ${RECONCILE_MODULES} -> /tmp/update-reconcile.log"
  run_u "${RECONCILE_MODULES}" /tmp/update-reconcile.log || log "WARN: -u ${RECONCILE_MODULES} returned non-zero - inspect /tmp/update-reconcile.log"
fi

# -----------------------------------------------------------------------------
# 4. Restart + verify
# -----------------------------------------------------------------------------
log "Starting Odoo"
systemctl start odoo
sleep 8
if curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8069/web/login" 2>/dev/null | grep -qE '200|303'; then
  log "Odoo is responding"
else
  echo "[update-code] FATAL: Odoo not responding after code update - inspect /var/log/odoo/odoo.log"
  exit 1
fi
log "Code update complete for ${ODOO_ENV:-unknown} -> ${TARGET_DBNAME}"
