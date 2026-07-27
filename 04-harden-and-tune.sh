#!/usr/bin/env bash
# =============================================================================
# 04-harden-and-tune.sh  -  CHECKPOINT 4: Security hardening + fine tuning
# -----------------------------------------------------------------------------
# For each environment box:
#   - Nginx reverse proxy in front of Odoo (+ websocket route for live chat)
#   - Let's Encrypt TLS (certbot), HTTP->HTTPS redirect, HSTS + security headers
#   - Odoo worker/limit tuning sized to the instance (t3.large vs t3.medium)
#   - PostgreSQL memory tuning sized to the box RAM
#   - dbfilter + list_db=False so only the intended DB is served
#   - UFW firewall, fail2ban, unattended-upgrades, SSH hardening
#   - CloudWatch agent on boxes with detailed monitoring enabled (production)
#   - Nightly encrypted-at-rest backups (DB + filestore) with retention (+opt S3)
#
# Usage:  ./04-harden-and-tune.sh [production|staging]   (default: both)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
require_no_placeholder LETSENCRYPT_EMAIL

TARGET_ENVS=("$@"); [[ ${#TARGET_ENVS[@]} -eq 0 ]] && TARGET_ENVS=("${ENVIRONMENTS[@]}")
REMOTE_HARDEN="${REPO_ROOT}/remote/odoo-harden.sh"
[[ -f "${REMOTE_HARDEN}" ]] || die "Missing ${REMOTE_HARDEN}"

harden_one() {
  local e="$1" up
  up="$(echo "${e}" | tr '[:lower:]' '[:upper:]')"
  resolve_env_spec "${e}"
  state_load "${e}"
  [[ -n "${PUBLIC_IP:-}" ]] || die "No PUBLIC_IP for ${e}; run 01 first."
  require_no_placeholder "${up}_DOMAIN"

  # target DB var uses the PROD/STAGING abbreviation (domain vars use full word)
  local dbpfx="${up}"; [[ "${e}" == "production" ]] && dbpfx="PROD"
  local target_db; target_db="$(eval echo "\${TARGET_${dbpfx}_DBNAME}")"

  checkpoint "4 - Harden + tune : ${e} (${ENV_DOMAIN}) @ ${PUBLIC_IP} [TLS=${TLS_MODE:-letsencrypt}]"

  local tls_mode="${TLS_MODE:-letsencrypt}"

  if [[ "${tls_mode}" == "letsencrypt" ]]; then
    # sanity: does DNS for the domain point directly at this box? (needed for LE)
    local resolved
    resolved="$(getent hosts "${ENV_DOMAIN}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    if [[ "${resolved}" != "${PUBLIC_IP}" ]]; then
      warn "${ENV_DOMAIN} resolves to '${resolved:-nothing}', not ${PUBLIC_IP}."
      warn "Let's Encrypt HTTP-01 will fail until DNS points here (Cloudflare must be DNS-only)."
      confirm "Continue and let certbot retry (falls back to self-signed if it fails)?" || { warn "Skipping ${e}"; return; }
    fi
  else
    # cloudflare_origin: domain resolves to Cloudflare (proxied) - that's expected.
    require_no_placeholder TLS_ORIGIN_CERT_FILE TLS_ORIGIN_KEY_FILE
    [[ -f "${TLS_ORIGIN_CERT_FILE}" ]] || die "TLS_ORIGIN_CERT_FILE not found: ${TLS_ORIGIN_CERT_FILE} (create it in Cloudflare > SSL/TLS > Origin Server)"
    [[ -f "${TLS_ORIGIN_KEY_FILE}"  ]] || die "TLS_ORIGIN_KEY_FILE not found: ${TLS_ORIGIN_KEY_FILE}"
    info "Uploading Cloudflare Origin certificate to ${e}"
    remote_copy "${TLS_ORIGIN_CERT_FILE}" "${PUBLIC_IP}:/tmp/cf-origin.pem"
    remote_copy "${TLS_ORIGIN_KEY_FILE}"  "${PUBLIC_IP}:/tmp/cf-origin.key"
  fi

  local tmpenv; tmpenv="$(mktemp)"
  cat > "${tmpenv}" <<EOF
ODOO_ENV="${e}"
DOMAIN="${ENV_DOMAIN}"
TLS_MODE="${tls_mode}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
INSTANCE_TYPE="${ENV_INSTANCE_TYPE}"
MONITORING="${ENV_MONITORING}"
TARGET_DBNAME="${target_db}"
ODOO_USER="${ODOO_USER}"
ODOO_HOME="${ODOO_HOME}"
ODOO_CONF="${ODOO_CONF}"
ODOO_FILESTORE="${ODOO_FILESTORE}"
PG_VERSION="${PG_VERSION}"
PG_ODOO_DB_USER="${PG_ODOO_DB_USER}"
ENABLE_UFW="${ENABLE_UFW}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES}"
SSH_DISABLE_PASSWORD_AUTH="${SSH_DISABLE_PASSWORD_AUTH}"
SSH_DISABLE_ROOT_LOGIN="${SSH_DISABLE_ROOT_LOGIN}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET}"
AWS_REGION="${AWS_REGION}"
EOF

  info "Uploading hardening assets to ${e}"
  remote_copy "${tmpenv}"        "${PUBLIC_IP}:/tmp/harden.env"
  remote_copy "${REMOTE_HARDEN}" "${PUBLIC_IP}:/tmp/odoo-harden.sh"
  rm -f "${tmpenv}"

  info "Running remote hardening on ${e}"
  if ! remote_ssh "${PUBLIC_IP}" \
    "bash -c 'set -o pipefail; \
       sudo install -m600 /tmp/harden.env /etc/odoo-harden.env && \
       sudo chmod +x /tmp/odoo-harden.sh && \
       sudo /tmp/odoo-harden.sh 2>&1 | tee /tmp/harden.log; \
       rc=\${PIPESTATUS[0]}; \
       sudo rm -f /tmp/harden.env /tmp/cf-origin.pem /tmp/cf-origin.key; exit \$rc'"; then
    die "${e}: remote hardening FAILED - inspect /tmp/harden.log on ${PUBLIC_IP}"
  fi

  # external check via HTTPS
  info "Verifying HTTPS on https://${ENV_DOMAIN}"
  if curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 20 "https://${ENV_DOMAIN}/web/login" 2>/dev/null | grep -qE '200|303'; then
    ok "${e}: HTTPS is live at https://${ENV_DOMAIN}"
  else
    warn "${e}: HTTPS check inconclusive (DNS/cert may still be propagating) - see /tmp/harden.log"
  fi

  state_set "${e}" HARDENED "yes"
  ok "${e}: hardening + tuning complete"
}

for e in "${TARGET_ENVS[@]}"; do harden_one "${e}"; done

checkpoint "CHECKPOINT 4 COMPLETE - hardened + tuned"
cat <<DONE
Migration finished. Recommended final checks:
  - Log in to each environment and confirm data + filestore (attachments/images)
  - Confirm staging shows the neutralization banner and sends no mail
  - Confirm nightly backup timer:   systemctl list-timers | grep odoo-backup
  - Review SSL grade:               https://www.ssllabs.com/ssltest/
DONE
