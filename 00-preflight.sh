#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh  -  validate EVERY prerequisite before the migration runs.
# -----------------------------------------------------------------------------
# Changes nothing. Catches the things that otherwise fail mid-run:
#   - local tooling, AWS auth + region + EC2 permissions (AMI/instance-types)
#   - gh (GitHub CLI) presence/auth - optional, only for setup-ci-deploy.sh
#   - instance types valid in the region
#   - GitHub token access to odoo/enterprise AND your project repo
#   - the target Odoo version branch actually exists
#   - pull-method inputs present (backup file / ssh host+key / signed URL)
#   - TLS inputs present + cert/key pair matches (cloudflare_origin)
#   - branch names exist in the repo; domains/CIDR sane
#   - outbound SSH (:22) reachable from this machine (NAT/firewall check)
#
# Run after ./configure.sh and re-run until it prints "Preflight passed".
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
# Preflight only PROBES - individual checks are allowed to fail without aborting
# the whole run. The FAILS counter + final gate decide pass/fail, so relax the
# strict mode inherited from common.sh.
set +e +u +o pipefail
trap - ERR

FAILS=0; WARNS=0
pass(){ echo "   ${C_GRN}ok  ${C_RESET} $*"; }
warn2(){ echo "   ${C_YEL}warn${C_RESET} $*"; WARNS=$((WARNS+1)); }
fail2(){ echo "   ${C_RED}FAIL${C_RESET} $*"; FAILS=$((FAILS+1)); }
have(){ command -v "$1" >/dev/null 2>&1; }
placeholder(){ local v="${1:-}"; [[ -z "${v}" || "${v}" == *CHANGE_ME* ]]; }

checkpoint "0 - Preflight checks"
INSTALL_MODE="${INSTALL_MODE:-migrate}"
if [[ "${INSTALL_MODE}" == "fresh" ]]; then
  info "INSTALL_MODE=fresh - odoo.sh source checks are skipped; checkpoint 3 will not run"
else
  info "INSTALL_MODE=migrate - full odoo.sh source validation applies"
fi

# ---- 1. local tooling -------------------------------------------------------
info "Local tooling"
# aws gets its own check: must be v2 specifically (README requires it; v1 has
# different flag/output behavior that can fail confusingly deep into a run
# rather than clearly upfront).
if have aws; then
  aws_major="$(aws --version 2>&1 | sed -n 's#^aws-cli/\([0-9][0-9]*\)\..*#\1#p')"
  if [[ "${aws_major}" == "2" ]]; then
    pass "command: aws (v2)"
  else
    fail2 "aws CLI must be v2 (found: $(aws --version 2>&1 | head -1 | cut -d' ' -f1 || echo unknown)) - install AWS CLI v2"
  fi
else
  fail2 "missing command: aws"
fi
for c in jq ssh scp git curl openssl; do
  if have "$c"; then pass "command: $c"; else fail2 "missing command: $c"; fi
done

# gh (GitHub CLI) is only needed for the OPTIONAL CI/CD auto-deploy setup
# (setup-ci-deploy.sh's PR/secret/variable steps) - not the core migration, so
# this warns rather than fails preflight.
if have gh; then
  if gh auth status >/dev/null 2>&1; then
    pass "command: gh (authenticated)"
  else
    warn2 "gh installed but not authenticated - run 'gh auth login' before using setup-ci-deploy.sh"
  fi
else
  warn2 "gh (GitHub CLI) not found - only needed for setup-ci-deploy.sh's CI/CD auto-deploy setup, not the core migration"
fi

# ---- 2. AWS auth + region + permissions ------------------------------------
info "AWS"
if aws sts get-caller-identity >/dev/null 2>&1; then
  pass "authenticated as $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
  live_acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  if placeholder "${AWS_ACCOUNT_ID:-}"; then
    warn2 "AWS_ACCOUNT_ID not set in config.env - authenticated account is ${live_acct}; set it to guard future runs against the wrong account"
  elif [[ "${live_acct}" == "${AWS_ACCOUNT_ID}" ]]; then
    pass "authenticated account matches config.env AWS_ACCOUNT_ID (${AWS_ACCOUNT_ID})"
  else
    fail2 "authenticated account ${live_acct} does NOT match config.env AWS_ACCOUNT_ID (${AWS_ACCOUNT_ID}) - wrong profile/account"
  fi
  if aws ec2 describe-availability-zones --region "${AWS_REGION}" >/dev/null 2>&1; then
    pass "region ${AWS_REGION} reachable"
  else fail2 "region ${AWS_REGION} not reachable / EC2 denied"; fi
  # AMI resolution needs ssm:GetParameters OR ec2:DescribeImages
  if aws ec2 describe-images --owners 099720109477 --filters 'Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-amd64-server-*' --query 'Images[0].ImageId' --output text >/dev/null 2>&1; then
    pass "ec2:DescribeImages works (AMI auto-resolve)"
  else warn2 "ec2:DescribeImages denied - AMI auto-resolve may fail (set EC2_AMI_ID manually)"; fi
  # instance types valid in region
  for pair in "PRODUCTION_INSTANCE_TYPE:${PRODUCTION_INSTANCE_TYPE}" "STAGING_INSTANCE_TYPE:${STAGING_INSTANCE_TYPE}"; do
    it="${pair#*:}"
    if aws ec2 describe-instance-types --instance-types "${it}" --region "${AWS_REGION}" >/dev/null 2>&1; then
      pass "instance type ${it} available in ${AWS_REGION}"
    else fail2 "instance type ${it} not available in ${AWS_REGION}"; fi
  done
else
  fail2 "AWS CLI not authenticated (profile '${AWS_PROFILE:-default}'). Refresh SSO / credentials."
fi

# ---- 3. core config present -------------------------------------------------
info "Config completeness"
CORE_VARS=(PROJECT_NAME AWS_REGION AWS_AZ ADMIN_ALLOWED_CIDR \
           PRODUCTION_DOMAIN STAGING_DOMAIN \
           GITHUB_USER GITHUB_TOKEN ODOO_VERSION \
           TARGET_PROD_DBNAME TARGET_STAGING_DBNAME)
if [[ "${INSTALL_MODE}" == "migrate" ]]; then
  CORE_VARS+=(ODOOSH_REPO_URL ODOOSH_PROD_DBNAME ODOOSH_STAGING_DBNAME)
fi
for v in "${CORE_VARS[@]}"; do
  if placeholder "${!v:-}"; then fail2 "config ${v} not set"; else pass "config ${v}"; fi
done
# CIDR sanity
if [[ "${ADMIN_ALLOWED_CIDR:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then pass "ADMIN_ALLOWED_CIDR is a valid CIDR"
elif ! placeholder "${ADMIN_ALLOWED_CIDR:-}"; then warn2 "ADMIN_ALLOWED_CIDR '${ADMIN_ALLOWED_CIDR}' doesn't look like x.x.x.x/nn"; fi

# ---- 4. GitHub access -------------------------------------------------------
info "GitHub access"
gitok(){ # url  -> 0 if refs listed
  git ls-remote --heads "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${1}.git" >/dev/null 2>&1
}
if placeholder "${GITHUB_USER:-}" || placeholder "${GITHUB_TOKEN:-}"; then
  fail2 "GITHUB_USER / GITHUB_TOKEN not set - cannot check repo access"
else
  # needed regardless of INSTALL_MODE: 02-deploy-odoo.sh clones odoo/enterprise
  gitok "odoo/enterprise" && pass "can access odoo/enterprise" || fail2 "cannot access odoo/enterprise (grant this GitHub account Enterprise access)"
  # target Odoo version branch exists - relevant regardless of mode
  if git ls-remote --heads "https://github.com/odoo/odoo.git" "${ODOO_VERSION}" 2>/dev/null | grep -q "${ODOO_VERSION}"; then
    pass "odoo/odoo has branch ${ODOO_VERSION}"
  else warn2 "could not confirm odoo/odoo branch ${ODOO_VERSION} (network or version typo?)"; fi

  if [[ "${INSTALL_MODE}" == "migrate" ]]; then
    # project repo (strip protocol + trailing .git, keep org/repo)
    proj="${ODOOSH_REPO_URL#https://github.com/}"; proj="${proj%.git}"
    if [[ "${ODOOSH_REPO_URL}" == https://github.com/* ]]; then
      gitok "${proj}" && pass "can access ${proj}" || fail2 "cannot access project repo ${proj} with these credentials"
      # branch names exist in the project repo
      for br in "${ODOOSH_PROD_BRANCH}" "${ODOOSH_STAGING_BRANCH}"; do
        if git ls-remote --heads "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${proj}.git" "${br}" 2>/dev/null | grep -q "refs/heads/${br}$"; then
          pass "repo branch '${br}' exists"
        else warn2 "repo branch '${br}' not found in ${proj} (addon clone will fall back to default)"; fi
      done
    else warn2 "ODOOSH_REPO_URL is not an https github URL - skipping token access check"; fi
  else
    info "INSTALL_MODE=fresh - skipping odoo.sh project repo / branch checks"
  fi
fi

# ---- 5. pull-method inputs --------------------------------------------------
if [[ "${INSTALL_MODE}" == "fresh" ]]; then
  info "Backup source"
  info "INSTALL_MODE=fresh - no odoo.sh backup source needed, skipping"
else
info "Backup source (${ODOOSH_PULL_METHOD})"
case "${ODOOSH_PULL_METHOD}" in
  local_file)
    f="${ODOOSH_PROD_DUMP_FILE:-}"
    if [[ -z "${f}" ]]; then fail2 "ODOOSH_PROD_DUMP_FILE not set"; elif [[ -f "${f}" ]]; then pass "ODOOSH_PROD_DUMP_FILE exists ($(du -h "${f}" | cut -f1))"; else fail2 "ODOOSH_PROD_DUMP_FILE not found: ${f}"; fi
    f="${ODOOSH_STAGING_DUMP_FILE:-}"
    [[ -z "${f}" ]] && warn2 "ODOOSH_STAGING_DUMP_FILE blank (seed staging from prod backup later)" || { [[ -f "${f}" ]] && pass "ODOOSH_STAGING_DUMP_FILE exists" || fail2 "ODOOSH_STAGING_DUMP_FILE not found: ${f}"; }
    ;;
  ssh_dump)
    [[ -f "${ODOOSH_SSH_KEY}" ]] && pass "odoo.sh SSH key present (${ODOOSH_SSH_KEY})" || fail2 "ODOOSH_SSH_KEY not found: ${ODOOSH_SSH_KEY}"
    for v in ODOOSH_PROD_SSH_HOST ODOOSH_STAGING_SSH_HOST; do
      placeholder "${!v:-}" && fail2 "${v} not set" || pass "${v} set"
    done
    ;;
  https_backup)
    for v in ODOOSH_PROD_DUMP_URL ODOOSH_STAGING_DUMP_URL; do
      placeholder "${!v:-}" && fail2 "${v} not set" || pass "${v} set"
    done ;;
  *) fail2 "ODOOSH_PULL_METHOD='${ODOOSH_PULL_METHOD}' invalid (local_file|ssh_dump|https_backup)";;
esac
fi

# ---- 6. TLS inputs ----------------------------------------------------------
info "TLS (${TLS_MODE:-letsencrypt})"
case "${TLS_MODE:-letsencrypt}" in
  cloudflare_origin)
    cc="${TLS_ORIGIN_CERT_FILE:-}"; kk="${TLS_ORIGIN_KEY_FILE:-}"
    if [[ -f "${cc}" && -f "${kk}" ]]; then
      pass "origin cert + key present"
      cm="$(openssl x509 -noout -modulus -in "${cc}" 2>/dev/null | openssl md5 2>/dev/null)"
      km="$(openssl rsa -noout -modulus -in "${kk}" 2>/dev/null | openssl md5 2>/dev/null)"
      if [[ -n "${cm}" && "${cm}" == "${km}" ]]; then pass "cert/key pair matches"; else warn2 "cert/key modulus mismatch (or non-RSA key) - verify the pair"; fi
    else fail2 "TLS_ORIGIN_CERT_FILE/KEY_FILE missing (create in Cloudflare > SSL/TLS > Origin Server)"; fi
    ;;
  letsencrypt)
    placeholder "${LETSENCRYPT_EMAIL:-}" && fail2 "LETSENCRYPT_EMAIL not set" || pass "LETSENCRYPT_EMAIL set"
    warn2 "letsencrypt requires the domain to point DIRECTLY at the box (Cloudflare DNS-only)"
    ;;
  *) fail2 "TLS_MODE='${TLS_MODE}' invalid (cloudflare_origin|letsencrypt)";;
esac

# ---- 7. outbound SSH reachability (NAT/firewall) ----------------------------
info "Network"
if timeout 6 bash -c 'exec 3<>/dev/tcp/github.com/22' 2>/dev/null; then pass "outbound SSH (:22) works from this network"
else warn2 "outbound TCP :22 seems blocked here - SSH to the boxes may fail; use a network that allows port 22"; fi

# ---- spec echo --------------------------------------------------------------
info "Specs to be provisioned (confirm against the engagement)"
for e in "${ENVIRONMENTS[@]}"; do
  resolve_env_spec "${e}"
  echo "   ${e}: ${ENV_INSTANCE_TYPE}, EBS ${ENV_EBS_GB}GB, monitoring=${ENV_MONITORING}, tenancy=${ENV_TENANCY}, ${ENV_DOMAIN}"
done

echo
if [[ "${FAILS}" -eq 0 ]]; then
  if [[ "${INSTALL_MODE}" == "fresh" ]]; then
    ok "Preflight passed${WARNS:+ (${WARNS} warning(s) - review above)} - safe to run ./01-provision-aws.sh (fresh install: run-all.sh will skip checkpoint 3)"
  else
    ok "Preflight passed${WARNS:+ (${WARNS} warning(s) - review above)} - safe to run ./01-provision-aws.sh (or ./run-all.sh)"
  fi
else
  die "Preflight found ${FAILS} blocking problem(s) and ${WARNS} warning(s) - fix the FAIL items above, then re-run."
fi
