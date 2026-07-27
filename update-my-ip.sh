#!/usr/bin/env bash
# =============================================================================
# update-my-ip.sh  -  lock SSH access to your CURRENT public IP.
# -----------------------------------------------------------------------------
# Run this whenever you change WiFi / networks. It:
#   1. detects your current public IPv4
#   2. writes it to config.env as ADMIN_ALLOWED_CIDR (so preflight passes and
#      future provisioning uses it)
#   3. if the security group already exists, rewrites its port-22 rule to allow
#      ONLY your current IP (revoking any previous admin SSH rule)
#
# Safe to run any number of times, before or after provisioning.
# Usage:  ./update-my-ip.sh
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config

# ---- 1. detect current public IP -------------------------------------------
MYIP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null \
        || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
MYIP="$(echo "${MYIP}" | tr -d '[:space:]')"
[[ "${MYIP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Could not detect a valid public IPv4 (got: '${MYIP}')"
NEWCIDR="${MYIP}/32"
info "Current public IP: ${NEWCIDR}"

# ---- 2. update config.env ---------------------------------------------------
CFG="${REPO_ROOT}/config.env"
[[ -f "${CFG}" ]] || die "config.env not found"
if grep -qE '^[[:space:]]*ADMIN_ALLOWED_CIDR[[:space:]]*=' "${CFG}"; then
  sed -i "s|^[[:space:]]*ADMIN_ALLOWED_CIDR[[:space:]]*=.*|ADMIN_ALLOWED_CIDR=\"${NEWCIDR}\"|" "${CFG}"
else
  echo "ADMIN_ALLOWED_CIDR=\"${NEWCIDR}\"" >> "${CFG}"
fi
ok "config.env: ADMIN_ALLOWED_CIDR -> ${NEWCIDR}"

# ---- 3. update the live security group if it exists -------------------------
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  warn "AWS not authenticated - skipped live security-group update."
  warn "Config is set; run this again after 'aws sso login' if the SG already exists."
  exit 0
fi

VPC_ID="$(aws_vpc_id)"
if [[ -z "${VPC_ID}" ]]; then
  info "No project VPC yet - the SSH rule will use ${NEWCIDR} when you run ./01-provision-aws.sh"
  exit 0
fi

SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=$(tag_name sg)" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -z "${SG_ID}" ]]; then
  info "Security group not created yet - nothing live to update (will apply at provisioning)."
  exit 0
fi

# NAT-safe rule management:
# This helper only manages port-22 rules it created itself, identified by the
# description tag below. It NEVER touches rules you added manually (e.g. a broad
# /24 for a carrier-NAT network), so re-running it can't lock you out.
MGMT_DESC="auto-my-ip"

# revoke only PREVIOUS auto-managed /32 rules (not the current one, not manual ones)
old_managed="$(aws ec2 describe-security-groups --group-ids "${SG_ID}" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[?Description=='${MGMT_DESC}'].CidrIp" \
  --output text 2>/dev/null || true)"
for c in ${old_managed}; do
  [[ "${c}" == "${NEWCIDR}" ]] && continue
  aws ec2 revoke-security-group-ingress --group-id "${SG_ID}" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${c}}]" >/dev/null 2>&1 || true
  info "Revoked previous auto rule: ${c}"
done

# add the current /32 (tagged), harmless if it already exists
aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${NEWCIDR},Description=${MGMT_DESC}}]" \
  >/dev/null 2>&1 || true

# report what SSH currently allows (managed + any manual rules like a /24)
all22="$(aws ec2 describe-security-groups --group-ids "${SG_ID}" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[].CidrIp" --output text 2>/dev/null || true)"
ok "Security group ${SG_ID}: SSH (22) now allows -> ${all22:-none}"
info "Manual rules (e.g. a /24 for a NAT'd network) are preserved and never revoked by this script."
