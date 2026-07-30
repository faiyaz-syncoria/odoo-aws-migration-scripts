#!/usr/bin/env bash
# =============================================================================
# setup-ci-aws-access.sh  -  GitHub OIDC federation for CI's temporary SSH rule
# -----------------------------------------------------------------------------
# The security group's SSH rule is intentionally locked to the operator's own
# IP (see update-my-ip.sh) - GitHub-hosted Actions runners come from Azure's
# IP space and can never match it. Rather than opening SSH broadly (GitHub's
# runner IP list is huge and ever-changing - a poor security posture for SSH)
# or maintaining a self-hosted runner, this sets up:
#
#   - An IAM OIDC identity provider trusting token.actions.githubusercontent.com
#     (created once per AWS account; safe to re-run, reused by any repo/role
#     that needs it).
#   - An IAM role assumable ONLY by GitHub Actions runs from the configured
#     odoo.sh addon repo, on the main/Staging branches (enforced via the OIDC
#     `sub` claim) - no long-lived AWS credentials are ever stored as a GitHub
#     secret.
#   - A policy scoped to ONLY ec2:AuthorizeSecurityGroupIngress /
#     RevokeSecurityGroupIngress on this ONE security group (+ read-only
#     DescribeSecurityGroups) - nothing else.
#
# ci-templates/deploy.yml uses this role to open a /32 SSH rule for its own
# runner IP at the start of each run, and revoke it at the end - SSH stays
# closed to the internet the rest of the time.
#
# Usage:  ./setup-ci-aws-access.sh
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
load_config
check_aws_auth
require_no_placeholder ODOOSH_REPO_URL

checkpoint "CI AWS access - GitHub OIDC role for temporary SSH rules"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
GH_REPO="$(echo "${ODOOSH_REPO_URL}" | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')"
[[ "${GH_REPO}" == */* ]] || die "Could not parse GitHub org/repo from ODOOSH_REPO_URL='${ODOOSH_REPO_URL}'"
info "GitHub repo (for OIDC trust): ${GH_REPO}"

SG_ID="$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=$(tag_name sg)" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
[[ -n "${SG_ID}" ]] || die "No security group found (tag Name=$(tag_name sg)). Run 01-provision-aws.sh first."
info "Security group: ${SG_ID}"

ROLE_NAME="${PROJECT_NAME}-ci-deploy-role"
POLICY_NAME="${PROJECT_NAME}-ci-deploy-sg-policy"
OIDC_URL="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"

# -----------------------------------------------------------------------------
# 1. OIDC identity provider (one per AWS account, reused across repos/roles)
# -----------------------------------------------------------------------------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  ok "GitHub OIDC provider already exists"
else
  info "Creating GitHub OIDC provider"
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
  ok "Created GitHub OIDC provider"
fi

# -----------------------------------------------------------------------------
# 2. Trust policy - only this repo, only main/Staging, only via OIDC
# -----------------------------------------------------------------------------
TRUST_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "${OIDC_URL}:aud": "sts.amazonaws.com" },
      "StringLike": { "${OIDC_URL}:sub": [
        "repo:${GH_REPO}:ref:refs/heads/main",
        "repo:${GH_REPO}:ref:refs/heads/Staging"
      ]}
    }
  }]
}
EOF
)"

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUST_POLICY}" >/dev/null
  ok "Updated trust policy on existing role ${ROLE_NAME}"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "GitHub Actions CI - temporary SSH SG rule for ${PROJECT_NAME}" >/dev/null
  ok "Created role ${ROLE_NAME}"
fi
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

# -----------------------------------------------------------------------------
# 3. Permissions policy - scoped to ONLY this one security group
# -----------------------------------------------------------------------------
# AWS evaluates Authorize/RevokeSecurityGroupIngress against BOTH the target
# security-group resource AND a security-group-rule resource (the new/removed
# rule doesn't have an ID yet, so that half must be a wildcard). The
# security-group ARN below is what actually restricts which group's rules can
# be touched - the security-group-rule wildcard is a structural requirement,
# not a scoping weakness, since the API call is still bound to --group-id.
SG_ARN="arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:security-group/${SG_ID}"
SG_RULE_ARN="arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:security-group-rule/*"
PERM_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"],
      "Resource": ["${SG_ARN}", "${SG_RULE_ARN}"]
    },
    {
      "Effect": "Allow",
      "Action": "ec2:DescribeSecurityGroups",
      "Resource": "*"
    }
  ]
}
EOF
)"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  # IAM policies keep up to 5 versions; prune old non-default ones before
  # adding the new one so re-running this never hits that limit.
  for v in $(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
              --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${v}" >/dev/null 2>&1 || true
  done
  aws iam create-policy-version --policy-arn "${POLICY_ARN}" --policy-document "${PERM_POLICY}" --set-as-default >/dev/null
  ok "Updated policy ${POLICY_NAME} to its current definition"
else
  aws iam create-policy --policy-name "${POLICY_NAME}" --policy-document "${PERM_POLICY}" \
    --description "Scoped to ${SG_ID} only - authorize/revoke SSH ingress for CI" >/dev/null
  ok "Created policy ${POLICY_NAME}"
fi
aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${POLICY_ARN}" >/dev/null 2>&1 || true
ok "Policy attached to role"

checkpoint "CI AWS ACCESS SETUP COMPLETE"
cat <<NOTE
Set these on the addon repo (${GH_REPO}) as repo VARIABLES (not secrets - none
of this is sensitive, it's just IDs the workflow needs):

  gh variable set AWS_ROLE_ARN      --repo ${GH_REPO} --body "${ROLE_ARN}"
  gh variable set SECURITY_GROUP_ID --repo ${GH_REPO} --body "${SG_ID}"
  gh variable set AWS_REGION        --repo ${GH_REPO} --body "${AWS_REGION}"

No AWS access key is stored anywhere - the workflow exchanges its OIDC token
for temporary credentials scoped to exactly: authorize/revoke SSH ingress on
${SG_ID}, nothing else. Re-run this script any time the security group or
repo changes (e.g. after a full re-provision).
NOTE
