#!/usr/bin/env bash
# =============================================================================
# setup-ci-deploy.sh  -  install a RESTRICTED SSH deploy key for CI/CD
# -----------------------------------------------------------------------------
# One-time (re-runnable) setup so a CI pipeline (e.g. GitHub Actions on the
# odoo.sh project repo) can trigger 05-update-addons.sh's non-destructive
# code-only deploy WITHOUT getting general admin SSH access to the box:
#
#   - Generates secrets/ci-deploy-key(.pub) if it doesn't already exist.
#   - Persists a per-env config at /etc/odoo-ci-deploy.env on the box (repo,
#     branch, target db, DB creds) so the deploy needs zero uploaded state.
#   - Installs remote/odoo-update-code.sh at /usr/local/bin/odoo-ci-deploy.sh.
#   - Adds the CI public key to the ubuntu user's authorized_keys with a
#     forced `command=` restricted to ONLY run that one script against that
#     one env file - no shell, no port/X11/agent forwarding, no pty. Even a
#     leaked private key can only trigger a non-destructive code deploy on
#     whichever box it's authorized on, nothing else.
#
# Usage:  ./setup-ci-deploy.sh [production|staging]   (default: both)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
require_no_placeholder ODOOSH_REPO_URL

TARGET_ENVS=("$@"); [[ ${#TARGET_ENVS[@]} -eq 0 ]] && TARGET_ENVS=("${ENVIRONMENTS[@]}")
REMOTE_UPDATE="${REPO_ROOT}/remote/odoo-update-code.sh"
[[ -f "${REMOTE_UPDATE}" ]] || die "Missing ${REMOTE_UPDATE}"

CI_KEY="${SECRETS_DIR}/ci-deploy-key"
CI_PUB="${CI_KEY}.pub"
if [[ ! -f "${CI_KEY}" ]]; then
  checkpoint "Generating CI deploy keypair"
  ssh-keygen -t ed25519 -f "${CI_KEY}" -N "" -C "ci-deploy@${PROJECT_NAME}" -q
  chmod 600 "${CI_KEY}"; chmod 644 "${CI_PUB}"
  ok "Generated ${CI_KEY} (+ .pub)"
else
  ok "Reusing existing ${CI_KEY}"
fi
PUBKEY_LINE="$(cat "${CI_PUB}")"

setup_one() {
  local e="$1" up
  up="$(echo "${e}" | tr '[:lower:]' '[:upper:]')"
  [[ "${e}" == "production" ]] && up="PROD"
  state_load "${e}"
  [[ -n "${PUBLIC_IP:-}" ]] || die "No PUBLIC_IP for ${e}; run 01 first."

  local branch target_db
  branch="$(eval echo "\${ODOOSH_${up}_BRANCH}")"
  target_db="$(eval echo "\${TARGET_${up}_DBNAME}")"
  require_no_placeholder "ODOOSH_${up}_BRANCH" "TARGET_${up}_DBNAME"

  checkpoint "Installing CI deploy access : ${e} @ ${PUBLIC_IP}"

  local db_pass; db_pass="$(resolve_secret PG_ODOO_DB_PASSWORD "${e}-db-password")"

  # persisted env file for the forced-command wrapper (root-only)
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

  info "Uploading persisted config + deploy script to ${e}"
  remote_copy "${tmpenv}"        "${PUBLIC_IP}:/tmp/odoo-ci-deploy.env"
  remote_copy "${REMOTE_UPDATE}" "${PUBLIC_IP}:/tmp/odoo-ci-deploy.sh"
  rm -f "${tmpenv}"

  remote_ssh "${PUBLIC_IP}" \
    "sudo install -m600 /tmp/odoo-ci-deploy.env /etc/odoo-ci-deploy.env && rm -f /tmp/odoo-ci-deploy.env && \
     sudo install -m755 /tmp/odoo-ci-deploy.sh /usr/local/bin/odoo-ci-deploy.sh && rm -f /tmp/odoo-ci-deploy.sh"
  ok "Persisted config + wrapper installed"

  # install the forced-command authorized_keys entry. APPEND-ONLY - never
  # filter/rewrite the file, so a bug here can never wipe an unrelated key
  # (this is exactly how a prior version of this script broke SSH access).
  local keybody; keybody="$(echo "${PUBKEY_LINE}" | awk '{print $2}')"
  local forced="command=\"sudo /usr/local/bin/odoo-ci-deploy.sh /etc/odoo-ci-deploy.env\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${PUBKEY_LINE}"
  if remote_ssh "${PUBLIC_IP}" "grep -qF '${keybody}' ~/.ssh/authorized_keys 2>/dev/null"; then
    ok "CI deploy key already present on ${e}, leaving authorized_keys untouched"
  else
    remote_ssh "${PUBLIC_IP}" "echo '${forced}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    ok "CI deploy key appended on ${e} (forced-command restricted)"
  fi
}

for e in "${TARGET_ENVS[@]}"; do setup_one "${e}"; done

checkpoint "CI DEPLOY SETUP COMPLETE"
cat <<NOTE
Add secrets/ci-deploy-key as a GitHub Actions secret in the ADDON repo
(syncoria/syncoria-Demo-Master), e.g. named CI_DEPLOY_SSH_KEY. Never commit or
print its contents - reference the file path when setting the secret:
  gh secret set CI_DEPLOY_SSH_KEY --repo syncoria/syncoria-Demo-Master < secrets/ci-deploy-key
The key is restricted server-side: it can only run the non-destructive
code-deploy wrapper on the box(es) it was just installed on, nothing else.
NOTE
