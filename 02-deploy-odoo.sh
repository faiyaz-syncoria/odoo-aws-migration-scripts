#!/usr/bin/env bash
# =============================================================================
# 02-deploy-odoo.sh  -  CHECKPOINT 2: Deploy default Odoo 18 Enterprise
# -----------------------------------------------------------------------------
# For each environment box (production, staging) this:
#   - waits for SSH
#   - resolves/persists per-box secrets (db password, master password)
#   - uploads the remote bootstrap + a generated remote.env
#   - runs remote bootstrap with sudo, which:
#       * mounts the 1000GB data volume at /var/lib/odoo (persistent filestore)
#       * installs PostgreSQL 16 (local) + creates the odoo role
#       * installs OS deps + wkhtmltopdf (Qt patched build for clean PDFs)
#       * installs Odoo 18 community core (apt) and clones Enterprise addons
#       * writes /etc/odoo/odoo.conf and a systemd unit
#       * starts Odoo with an EMPTY default DB (real data comes in step 3)
#   - verifies the HTTP health endpoint responds
#
# Idempotent: re-running re-applies config and restarts cleanly.
#
# Usage:  ./02-deploy-odoo.sh [production|staging]   (default: both)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
require_no_placeholder GITHUB_USER GITHUB_TOKEN

TARGET_ENVS=("$@"); [[ ${#TARGET_ENVS[@]} -eq 0 ]] && TARGET_ENVS=("${ENVIRONMENTS[@]}")
REMOTE_SCRIPT="${REPO_ROOT}/remote/odoo-bootstrap.sh"
[[ -f "${REMOTE_SCRIPT}" ]] || die "Missing ${REMOTE_SCRIPT}"

deploy_one() {
  local e="$1"
  resolve_env_spec "${e}"
  state_load "${e}"
  [[ -n "${PUBLIC_IP:-}" ]] || die "No PUBLIC_IP in state for ${e}. Run 01-provision-aws.sh first."
  checkpoint "2 - Deploy Odoo ${ODOO_VERSION} Enterprise : ${e} @ ${PUBLIC_IP}"

  wait_for_ssh "${PUBLIC_IP}"

  # resolve per-box secrets (persisted under ./secrets so they survive re-runs)
  local db_pass master_pass
  db_pass="$(resolve_secret PG_ODOO_DB_PASSWORD "${e}-db-password")"
  master_pass="$(resolve_secret ODOO_ADMIN_PASSWD "${e}-master-password")"

  # build a remote env file (uploaded to the box, root-only)
  local tmpenv; tmpenv="$(mktemp)"
  cat > "${tmpenv}" <<EOF
ODOO_ENV="${e}"
ODOO_VERSION="${ODOO_VERSION}"
ODOO_USER="${ODOO_USER}"
ODOO_HOME="${ODOO_HOME}"
ODOO_CONF="${ODOO_CONF}"
ODOO_ENTERPRISE_ADDONS="${ODOO_ENTERPRISE_ADDONS}"
ODOO_CUSTOM_ADDONS="${ODOO_CUSTOM_ADDONS}"
ODOO_FILESTORE="${ODOO_FILESTORE}"
ODOO_ENTERPRISE_GIT="${ODOO_ENTERPRISE_GIT}"
GITHUB_USER="${GITHUB_USER}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
PG_VERSION="${PG_VERSION}"
PG_ODOO_DB_USER="${PG_ODOO_DB_USER}"
PG_ODOO_DB_PASSWORD="${db_pass}"
ODOO_ADMIN_PASSWD="${master_pass}"
INSTANCE_TYPE="${ENV_INSTANCE_TYPE}"
EOF

  info "Uploading bootstrap + env to ${e}"
  remote_copy "${tmpenv}"       "${PUBLIC_IP}:/tmp/remote.env"
  remote_copy "${REMOTE_SCRIPT}" "${PUBLIC_IP}:/tmp/odoo-bootstrap.sh"
  rm -f "${tmpenv}"

  info "Running remote bootstrap (this installs PostgreSQL + Odoo, ~3-6 min)"
  # pipefail via bash -c so the bootstrap's real exit status is NOT masked by tee
  if ! remote_ssh "${PUBLIC_IP}" \
    "bash -c 'set -o pipefail; \
       sudo install -m600 /tmp/remote.env /etc/odoo-migration.env && \
       sudo chmod +x /tmp/odoo-bootstrap.sh && \
       sudo /tmp/odoo-bootstrap.sh 2>&1 | tee /tmp/bootstrap.log; \
       rc=\${PIPESTATUS[0]}; rm -f /tmp/remote.env; exit \$rc'"; then
    die "${e}: remote bootstrap FAILED - inspect /tmp/bootstrap.log on ${PUBLIC_IP} (common cause: no access to odoo/enterprise). Not marking deployed."
  fi

  # health check - must actually be listening for the deploy to count as done
  info "Verifying Odoo HTTP health on ${e}"
  if remote_ssh "${PUBLIC_IP}" "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8069/web/database/selector" | grep -qE '200|303'; then
    ok "Odoo is responding on ${e}"
  else
    die "${e}: Odoo not responding on 8069 after bootstrap - inspect /tmp/bootstrap.log and 'systemctl status odoo' on ${PUBLIC_IP}. Not marking deployed."
  fi

  state_set "${e}" ODOO_DEPLOYED "yes"
  ok "${e}: default Odoo ${ODOO_VERSION} Enterprise deployed"
}

for e in "${TARGET_ENVS[@]}"; do deploy_one "${e}"; done

checkpoint "CHECKPOINT 2 COMPLETE - default Odoo deployed on all boxes"
echo "Next: ./03-migrate-from-odoosh.sh"
