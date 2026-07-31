#!/usr/bin/env bash
# =============================================================================
# configure.sh  -  interactive setup for a NEW project / Odoo instance.
# -----------------------------------------------------------------------------
# Walks you through every choice (AWS region, per-environment instance specs,
# Odoo version, backup source, TLS mode, domains, credentials) and writes a
# complete config.env. Re-runnable: existing values become the defaults.
#
# This is the intended entry point for a new engagement:
#     ./configure.sh      # choose everything, incl. instance specs per env
#     ./00-preflight.sh   # validate all prerequisites
#     ./run-all.sh        # execute the migration
#
# Nothing here touches AWS or the boxes; it only produces config.env. Instance
# types are validated against AWS only if you're already authenticated.
# =============================================================================
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${HERE}/config.env"
EXAMPLE="${HERE}/config.env.example"
[[ -f "${EXAMPLE}" ]] || { echo "config.env.example not found next to this script"; exit 1; }

# colours
if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[0m'; else B=""; G=""; Y=""; C=""; R=""; fi
say(){ echo "${C}$*${R}"; }
hdr(){ echo; echo "${B}${G}== $* ==${R}"; }

[[ -t 0 ]] || { echo "configure.sh needs an interactive terminal. Edit config.env by hand instead."; exit 1; }

# start config.env from the template on first run (keeps comments/structure)
if [[ ! -f "${CFG}" ]]; then cp "${EXAMPLE}" "${CFG}"; chmod 600 "${CFG}"; say "Created config.env from template."; fi

# read current value of a key from config.env (strips surrounding quotes)
cur() { local v; v="$(grep -E "^[[:space:]]*$1[[:space:]]*=" "${CFG}" | tail -1 | cut -d= -f2- || true)"; v="${v%\"}"; v="${v#\"}"; echo "${v}"; }
# write KEY="value" into config.env (replace or append)
setk() {
  local k="$1" val="$2"
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "${CFG}"; then
    # escape for sed replacement
    local esc; esc="$(printf '%s' "${val}" | sed -e 's/[&|\\]/\\&/g')"
    sed -i "s|^[[:space:]]*${k}[[:space:]]*=.*|${k}=\"${esc}\"|" "${CFG}"
  else
    printf '%s="%s"\n' "${k}" "${val}" >> "${CFG}"
  fi
}

# ask KEY "Prompt"  -> default = current value
ask() {
  local k="$1" prompt="$2" def ans; def="$(cur "${k}")"
  read -r -p "${prompt} [${def}]: " ans || true
  setk "${k}" "${ans:-${def}}"
}
ask_secret() {
  local k="$1" prompt="$2" def ans; def="$(cur "${k}")"
  local shown="(unchanged)"
  if [[ -z "${def}" || "${def}" == *CHANGE_ME* ]]; then shown="(none set)"; fi
  read -r -s -p "${prompt} ${shown}: " ans || true; echo
  if [[ -n "${ans}" ]]; then setk "${k}" "${ans}"; fi
}
# ask_menu KEY "Prompt" opt1 opt2 ...  (default = current value if it matches)
ask_menu() {
  local k="$1" prompt="$2"; shift 2
  local def; def="$(cur "${k}")"
  echo "${prompt} (current: ${def:-none})"
  local i=1 opt
  for opt in "$@"; do echo "   ${i}) ${opt}"; i=$((i+1)); done
  echo "   c) custom value"
  local choice; read -r -p "   choose [1]: " choice || true; choice="${choice:-1}"
  if [[ "${choice}" == "c" ]]; then local v; read -r -p "   enter value: " v || true; setk "${k}" "${v}"; return; fi
  if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=$# )); then
    setk "${k}" "${!choice}"
  else setk "${k}" "${@:1:1}"; fi
}

echo "${B}Odoo.sh -> AWS migration : interactive configuration${R}"
echo "Press Enter to keep the value shown in [brackets]. Ctrl-C to abort."

# -----------------------------------------------------------------------------
hdr "Install mode"
say "migrate = full odoo.sh -> AWS data migration.  fresh = brand-new, empty Odoo Enterprise instance, no odoo.sh source."
ask_menu INSTALL_MODE "Install mode" "migrate" "fresh"
FRESH_INSTALL=0
if [[ "$(cur INSTALL_MODE)" == "fresh" ]]; then FRESH_INSTALL=1; fi

# -----------------------------------------------------------------------------
hdr "Project & AWS"
ask PROJECT_NAME     "Project name (prefix for all AWS resources)"
ask_menu AWS_REGION  "AWS region" "us-east-2" "us-east-1" "us-west-2" "ca-central-1" "eu-west-1"
# default the AZ to <region>a if not already set
if [[ -z "$(cur AWS_AZ)" || "$(cur AWS_AZ)" == *CHANGE_ME* ]]; then setk AWS_AZ "$(cur AWS_REGION)a"; fi
ask AWS_AZ           "Availability zone"
ask AWS_PROFILE      "AWS CLI profile (blank = default chain)"

hdr "AWS account guard"
say "Every AWS-touching script checks the authenticated caller against this before doing anything - protects against running with the wrong profile/account."
profile_flag=(); [[ -n "$(cur AWS_PROFILE)" ]] && profile_flag=(--profile "$(cur AWS_PROFILE)")
detected_acct=""
if command -v aws >/dev/null 2>&1; then
  detected_acct="$(aws "${profile_flag[@]}" sts get-caller-identity --query Account --output text 2>/dev/null || true)"
fi
if [[ -n "${detected_acct}" ]]; then
  read -r -p "Authenticated as account ${detected_acct} - use this? [Y/n]: " yn || true
  if [[ "${yn:-Y}" =~ ^[Yy] ]]; then setk AWS_ACCOUNT_ID "${detected_acct}"; else ask AWS_ACCOUNT_ID "AWS account ID (12 digits)"; fi
else
  say "(not authenticated yet - enter the target account ID manually; 00-preflight.sh will verify it later)"
  ask AWS_ACCOUNT_ID "AWS account ID (12 digits)"
fi

hdr "Admin SSH access"
detected=""
detected="$(curl -fsS --max-time 6 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -n "${detected}" ]]; then
  read -r -p "Lock SSH to your current IP ${detected}/32? [Y/n]: " yn || true
  [[ "${yn:-Y}" =~ ^[Yy] ]] && setk ADMIN_ALLOWED_CIDR "${detected}/32" || ask ADMIN_ALLOWED_CIDR "Admin CIDR for SSH (x.x.x.x/32)"
else
  ask ADMIN_ALLOWED_CIDR "Admin CIDR for SSH (x.x.x.x/32)"
fi

# -----------------------------------------------------------------------------
hdr "Instance specifications - PRODUCTION"
ask_menu PRODUCTION_INSTANCE_TYPE "Production instance type" \
  "t3.large" "t3.xlarge" "t3.2xlarge" "m5.large" "m5.xlarge" "m6i.large" "m6i.xlarge" "c6i.large"
ask      PRODUCTION_EBS_GB        "Production data volume size (GB)"
ask_menu PRODUCTION_MONITORING    "Production detailed CloudWatch monitoring" "enabled" "disabled"
ask_menu PRODUCTION_TENANCY       "Production tenancy" "default" "dedicated"
ask      PRODUCTION_DOMAIN        "Production domain (FQDN)"

hdr "Instance specifications - STAGING"
ask_menu STAGING_INSTANCE_TYPE    "Staging instance type" \
  "t3.medium" "t3.large" "t3.xlarge" "m5.large" "m6i.large"
ask      STAGING_EBS_GB           "Staging data volume size (GB)"
ask_menu STAGING_MONITORING       "Staging detailed CloudWatch monitoring" "disabled" "enabled"
ask_menu STAGING_TENANCY          "Staging tenancy" "default" "dedicated"
ask      STAGING_DOMAIN           "Staging domain (FQDN)"
ask_menu EBS_VOLUME_TYPE          "EBS volume type" "gp3" "gp2" "io2"

# -----------------------------------------------------------------------------
hdr "Odoo"
ask_menu ODOO_VERSION "Target Odoo version (must be >= source)" "19.0" "18.0" "17.0" "16.0"
ask GITHUB_USER  "GitHub username with odoo/enterprise access"
ask_secret GITHUB_TOKEN "GitHub Personal Access Token (repo scope)"

# -----------------------------------------------------------------------------
hdr "Target database names"
ask TARGET_PROD_DBNAME   "Target PRODUCTION db name (created on AWS)"
ask TARGET_STAGING_DBNAME "Target STAGING db name (created on AWS)"
say "Note: for a fresh install, create the DB with this exact name via Odoo's own database manager after checkpoint 2 - checkpoint 4 pins dbfilter to it."

if [[ "${FRESH_INSTALL}" -eq 1 ]]; then
  hdr "odoo.sh source"
  say "Fresh install selected - skipping odoo.sh source questions (no data migration)."
else
  hdr "odoo.sh source"
  ask ODOOSH_REPO_URL      "odoo.sh project git repo (https://github.com/org/repo.git)"
  ask ODOOSH_PROD_BRANCH   "Production branch name in that repo"
  ask ODOOSH_STAGING_BRANCH "Staging branch name in that repo"
  ask ODOOSH_PROD_DBNAME   "Source PRODUCTION database name (on odoo.sh)"
  ask ODOOSH_STAGING_DBNAME "Source STAGING database name (on odoo.sh)"

  ask_menu ODOOSH_PULL_METHOD "How to fetch the DB+filestore from odoo.sh" "local_file" "ssh_dump" "https_backup"
  method="$(cur ODOOSH_PULL_METHOD)"
  case "${method}" in
    local_file)
      say "You'll download the backup .zip from odoo.sh (Branch > Backups > Download)."
      ask ODOOSH_PROD_DUMP_FILE    "Local path to PRODUCTION backup .zip"
      ask ODOOSH_STAGING_DUMP_FILE "Local path to STAGING backup .zip (blank to seed staging from prod later)"
      ;;
    ssh_dump)
      ask ODOOSH_PROD_SSH_HOST     "odoo.sh PRODUCTION SSH host (build_id@host)"
      ask ODOOSH_STAGING_SSH_HOST  "odoo.sh STAGING SSH host (build_id@host)"
      ask ODOOSH_SSH_KEY           "Path to odoo.sh-registered SSH private key"
      ;;
    https_backup)
      ask ODOOSH_PROD_DUMP_URL     "Signed PRODUCTION backup URL"
      ask ODOOSH_STAGING_DUMP_URL  "Signed STAGING backup URL"
      ;;
  esac
  ask_menu NEUTRALIZE_STAGING "Neutralize staging (disable mail/crons/payments)" "true" "false"
  ask_menu RECONCILE_MODULES  "Post-restore schema reconcile" "all" "off"
fi

# -----------------------------------------------------------------------------
hdr "TLS / edge"
ask_menu TLS_MODE "Origin TLS mode" "cloudflare_origin" "letsencrypt"
tls="$(cur TLS_MODE)"
if [[ "${tls}" == "cloudflare_origin" ]]; then
  ask TLS_ORIGIN_CERT_FILE "Path to Cloudflare Origin certificate (PEM)"
  ask TLS_ORIGIN_KEY_FILE   "Path to Cloudflare Origin private key"
  ask_menu RESTRICT_WEB_TO_CLOUDFLARE "Lock origin 80/443 to Cloudflare IPs" "true" "false"
fi
ask LETSENCRYPT_EMAIL "Contact email (Let's Encrypt / cert notices)"

# -----------------------------------------------------------------------------
hdr "Optional hardening"
ask_menu ENABLE_UFW "Enable UFW firewall on the boxes" "true" "false"
ask BACKUP_RETENTION_DAYS "Nightly backup retention (days)"
ask BACKUP_S3_BUCKET      "S3 bucket for off-box backups (blank = disabled)"

# -----------------------------------------------------------------------------
# validate instance types against AWS if we can
hdr "Validation"
if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
  for it in "$(cur PRODUCTION_INSTANCE_TYPE)" "$(cur STAGING_INSTANCE_TYPE)"; do
    if aws ec2 describe-instance-types --instance-types "${it}" --region "$(cur AWS_REGION)" >/dev/null 2>&1; then
      echo "   ${G}ok${R}  ${it} available in $(cur AWS_REGION)"
    else
      echo "   ${Y}warn${R} ${it} not found in $(cur AWS_REGION) - double-check the type/region"
    fi
  done
else
  echo "   (AWS not authenticated - skipping instance-type validation; 00-preflight.sh will re-check)"
fi

chmod 600 "${CFG}"
hdr "Summary"
cat <<SUM
  Mode        : $(cur INSTALL_MODE)
  Project     : $(cur PROJECT_NAME)   Region: $(cur AWS_REGION) / $(cur AWS_AZ)
  Production  : $(cur PRODUCTION_INSTANCE_TYPE), $(cur PRODUCTION_EBS_GB)GB $(cur EBS_VOLUME_TYPE), monitoring=$(cur PRODUCTION_MONITORING), $(cur PRODUCTION_DOMAIN)
  Staging     : $(cur STAGING_INSTANCE_TYPE), $(cur STAGING_EBS_GB)GB $(cur EBS_VOLUME_TYPE), monitoring=$(cur STAGING_MONITORING), $(cur STAGING_DOMAIN)
  Odoo        : $(cur ODOO_VERSION) enterprise
  TLS         : $(cur TLS_MODE)
  Config      : ${CFG}
SUM
if [[ "${FRESH_INSTALL}" -eq 1 ]]; then
  echo "  odoo.sh     : (skipped - fresh install, checkpoint 3 will not run)"
else
  echo "  Source repo : $(cur ODOOSH_REPO_URL)"
  echo "  Pull method : $(cur ODOOSH_PULL_METHOD) | reconcile=$(cur RECONCILE_MODULES) | neutralize staging=$(cur NEUTRALIZE_STAGING)"
fi
echo
say "Next:  ./00-preflight.sh   then   ./run-all.sh"
