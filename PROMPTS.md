# Prompt Library — driving the migration with Claude Code

Copy-paste these prompts into **Claude Code** (run `claude` from this repo
directory). Each assumes Claude Code will read `CLAUDE.md`, `README.md`, and
`CUTOVER.md` for context and follow the operating rules there (confirm before
destructive actions, pause after each checkpoint, never print secrets).

Replace `<...>` placeholders before sending. Prompts are ordered from
setup → fresh migration → re-migration → per-step ops → CI/CD → cutover →
maintenance.
This library is refined from real migration sessions — see the Tips at the
bottom for gotchas that keep coming up in practice.

---

## 0. Start any session

> Read `CLAUDE.md`, `README.md`, and `CUTOVER.md` in this repo so you have full
> context on this Odoo.sh→AWS migration toolkit. Summarize back to me the current
> state (does `config.env` exist? what does `.state/` show is provisioned? what's
> in `secrets/`?) and wait for my instruction. Do not run anything destructive
> without confirming.

---

## 1. Set up / update `config.env`

**Interactive (recommended for a new project):**

> Run `./configure.sh` and walk me through it. I want to choose instance specs
> for both environments, region, Odoo version, backup source, and TLS mode.
> After it writes `config.env`, run `./00-preflight.sh` and help me fix anything
> it flags before we go further — including any branch-not-found warnings under
> "GitHub access" (don't skip past those, they mean the module code Claude will
> deploy won't match what you expect). Don't print my GitHub token or any secrets.

**Guided edit (config.env already exists, tweak a few values):**

> Show me the current non-secret values in `config.env` (mask tokens/passwords).
> I want to change: <e.g. PRODUCTION_INSTANCE_TYPE to m5.large, ODOO_VERSION to
> 18.0>. Update those keys in `config.env`, keep everything else, then run
> `./00-preflight.sh` and report the result.

**Low-spec demo/test profile (cheap, throwaway environment):**

> This is a demo/test instance, not a real production workload. Set both
> `PRODUCTION_INSTANCE_TYPE` and `STAGING_INSTANCE_TYPE` to `t3.small` and both
> EBS sizes to `<e.g. 10-20>` GB, keep everything else in `config.env` unchanged,
> then run `./00-preflight.sh`. Flag if `t3.small`'s 2GB RAM looks too tight for
> what I'm actually planning to do with it (real data volume, several concurrent
> users, etc.) before we provision.

---

## 2. Fresh migration (brand-new project)

> We're doing a fresh Odoo.sh→AWS migration on a new project. Prerequisites I've
> prepared: <GitHub PAT with enterprise+repo access / odoo.sh backup zip at
> \<path\> / Cloudflare origin cert at secrets/cf-origin.pem+key>. Do this,
> pausing for my confirmation between each checkpoint:
> 1. `aws sts get-caller-identity` (tell me if I need to re-auth).
> 2. `./configure.sh` (or confirm config.env is complete) then `./00-preflight.sh`
>    — resolve any warnings (especially branch-not-found) before continuing.
> 3. `./01-provision-aws.sh` — then check whether the domains already resolve
>    somewhere (`dig +short <domain>`) before assuming DNS needs pointing fresh;
>    either way, STOP and give me the new Elastic IPs so I can confirm/create the
>    Cloudflare A records (proxied) before continuing.
> 4. `./02-deploy-odoo.sh`.
> 5. `./03-migrate-from-odoosh.sh production` then `... staging`, verifying each
>    DB loads cleanly (registry loaded, web 200, no UndefinedColumn/Traceback in
>    the log). If a custom module fails its schema reconcile, diagnose whether
>    it's an infra issue (missing extension/package) or a genuine bug in that
>    module's code before treating it as blocking.
> 6. `./04-harden-and-tune.sh` then `./restrict-web-to-cloudflare.sh`.
> 7. If auto-deploy on merge is wanted, run `./setup-ci-deploy.sh` (see prompt
>    #6) — do this last, since it needs `02-deploy-odoo.sh` already done.
> Report a short status after each step. Never print secrets.

---

## 3. Re-migration (tear down existing, then run fresh)

> We're re-testing this migration from scratch. FIRST show me the plan and the
> exact resources `./99-teardown.sh` will delete (instances, EIPs, data volumes,
> SG, subnet, IGW, VPC, key pair) and wait for my explicit "yes" — this is
> irreversible and erases the AWS databases (odoo.sh is untouched).
> After I confirm:
> 1. `aws sts get-caller-identity` (re-auth if needed), then `./99-teardown.sh`.
> 2. Verify nothing lingers (describe-instances / describe-vpcs by Project tag).
> 3. `rm -f secrets/<PROJECT_NAME>-key.pem` (AWS key is gone; drop the stale local one).
> 4. If this re-run should use different specs (e.g. downsizing to a demo
>    profile), update `config.env` first — see prompt #1's "low-spec demo/test
>    profile" — and confirm whether `secrets/*-db-password`,
>    `*-master-password`, and any TLS cert/key should be kept as-is (same
>    subdomains) or regenerated.
> 5. Then run the fresh migration exactly as in prompt #2, pausing between
>    checkpoints, and remind me to re-point Cloudflare DNS to the NEW Elastic IPs
>    after provisioning (check with `dig` first — it may already be correct).

---

## 4. Per-step operations

**Provision only:**
> `aws sts get-caller-identity`, then `./01-provision-aws.sh`. Report the Elastic
> IPs and instance IDs, and remind me to point DNS at them (check with `dig`
> first in case it's already correct).

**Deploy Odoo only (one or both envs):**
> Run `./02-deploy-odoo.sh <production|staging>` (no args = both) and confirm
> each box ends with "Odoo is responding". If it fails, read the box's
> `/tmp/bootstrap.log` and tell me the cause before retrying.

**Migrate one environment:**
> Run `./03-migrate-from-odoosh.sh <env>`. After it finishes, verify the DB loads
> cleanly (ssh to the box, check web 200 and `/var/log/odoo/odoo.log` for
> `Registry loaded` and no `Traceback`/`UndefinedColumn`). If a module's schema
> reconcile failed, use the "Diagnose a failed module reconcile" prompt below
> rather than assuming it's safe to ignore.

**Seed staging from the production backup (no separate staging backup):**
> Set `ODOOSH_STAGING_DUMP_FILE` to the production backup zip and
> `ODOOSH_STAGING_BRANCH` to the correct branch name (verify it actually exists
> in the repo first — branch names on odoo.sh don't always match what's in
> `config.env`) in `config.env`, then run `./03-migrate-from-odoosh.sh staging`.
> Confirm it neutralizes staging (mail/crons/payments off).

**Deploy latest code without touching data (one or both envs):**
> Run `./05-update-addons.sh <env>` (no args = both). This is NOT the same as
> `./03-migrate-from-odoosh.sh` — it pulls the latest custom addon code and
> reconciles schema against the *existing* database, no drop/recreate. Confirm
> the admin user and a couple of real record counts (e.g. `res_partner`,
> `sale_order`) are unchanged before and after, to prove no data was touched.

**Harden / TLS only:**
> Run `./04-harden-and-tune.sh <env>`. Confirm nginx config test passes and HTTPS
> is live. Then run `./restrict-web-to-cloudflare.sh`. If certbot/origin cert
> errors, read `/tmp/harden.log` and diagnose.

**Create or reset an Odoo admin user:**
> On <env>, create (or reset the password for) an Odoo backend user with login
> `<email>` and full admin rights. Generate a strong random password with no
> special characters (to avoid copy/paste issues), do this via `odoo-bin shell`
> against the target database rather than raw SQL (note: the groups field on
> `res.users` may be named `group_ids` rather than `groups_id` depending on
> Odoo version — check first). Store the password in
> `secrets/<env>-admin-user-password` (chmod 600), verify the login actually
> works end-to-end via the `/web/session/authenticate` endpoint, and tell me
> only the file path — don't print the password itself, and don't include it in
> any chat message, email, or other message you send on my behalf unless I
> explicitly ask for that specific exception.

**Diagnose a failed module reconcile (schema issues after migration):**
> `-u <module>` failed on <env> during migration/reconcile. SSH in and check
> `/var/log/odoo/odoo.log` for the actual traceback (not just the one-line WARN
> in the restore log). Distinguish between: (a) an infra/dependency issue (e.g.
> a missing PostgreSQL extension or package — fixable at the toolkit level, flag
> it as a follow-up task so future migrations don't hit it), (b) leftover
> inconsistent data from the source odoo.sh dump (e.g. orphaned rows violating a
> foreign key that didn't exist before) — check whether cleaning it up is safe
> and scoped, and confirm with me before deleting any rows, (c) a genuine bug in
> that module's own code (e.g. a broken external ID / view reference) — don't
> try to "fix" this at the infra level; report it clearly as a code issue for
> the module's developer. Restart Odoo and confirm the app itself is still
> healthy regardless of which category it turns out to be.

---

## 5. TLS / network helpers

**Refresh SSH access after changing networks:**
> Run `./update-my-ip.sh`, then verify SSH works: `nc -vz -w5 <prod-eip> 22`. If
> it still times out, sample `curl -fsS https://checkip.amazonaws.com` a few
> times in a row — if the IP is different every time, this is a carrier/NAT pool
> rotating faster than a single `/32` rule can track, not a fluke. In that case,
> tell me the pool's `/24` before adding it as a security-group rule (don't
> remove the Cloudflare web rules), since it's a broader access grant than a
> single IP and I want to confirm it first.

**Lock / unlock origin to Cloudflare:**
> Lock: `./restrict-web-to-cloudflare.sh`. Unlock (for direct testing):
> `./restrict-web-to-cloudflare.sh --open`. Confirm which is in effect afterward.

---

## 6. Continuous deployment (auto-deploy on merge)

**Set up CI/CD for the first time:**
> Run `./setup-ci-deploy.sh` for both environments — this generates a
> restricted SSH key (`secrets/ci-deploy-key`) and installs it on each box with
> a forced `command=` restriction so it can only ever run the non-destructive
> `05-update-addons.sh` deploy. Verify this by trying an unrelated command over
> SSH with that key (e.g. `whoami`) and confirming only the deploy runs,
> nothing else. Then run `./setup-ci-aws-access.sh` — this needs an AWS
> identity with IAM write access (`iam:CreateRole`, `CreatePolicy`,
> `AttachRolePolicy`, `CreateOpenIDConnectProvider`); if it's denied under my
> current session, tell me exactly which action failed and ask me to either
> grant it or run the script myself, don't try to route around it. It sets up
> an OIDC role so CI can open/close a temporary SSH rule for its own runner IP
> (no static AWS key ever stored) — the SG only allows the operator's own IP,
> and GitHub-hosted runners can't reach it otherwise. Then draft/apply
> `ci-templates/deploy.yml` to the odoo.sh addon repo (ask me first how to
> deliver it — direct push, a PR, or hand it to me — since that's a different
> repo than this one, and check both `main` and `Staging` need the file
> separately), and tell me the exact `gh secret set`/`gh variable set` commands
> for `CI_DEPLOY_SSH_KEY`, `PRODUCTION_HOST`, `STAGING_HOST`, `AWS_ROLE_ARN`,
> `SECURITY_GROUP_ID`, and `AWS_REGION` (the last three are printed by
> `setup-ci-aws-access.sh`). Never print the SSH key's contents.

**After a re-provision (Elastic IPs or security group changed):**
> The AWS environment was just re-provisioned. Re-run `./setup-ci-deploy.sh`
> (after `02-deploy-odoo.sh` has completed on the new boxes) to reinstall the
> forced-command entry, and `./setup-ci-aws-access.sh` if the security group
> was recreated too — neither the SSH keypair nor the AWS role needs
> regenerating, only their server-side/AWS-side installation. Then update the
> addon repo's `PRODUCTION_HOST`/`STAGING_HOST` (and `SECURITY_GROUP_ID` if it
> changed) repo variables — the secrets/role ARN don't change. Re-running
> `setup-ci-deploy.sh` also refreshes the persisted repo/branch/token config on
> each box, so do the same after changing `ODOOSH_REPO_URL`, a branch name, or
> rotating `GITHUB_TOKEN`, even without a re-provision.

**Diagnose a failed CI deploy:**
> The GitHub Actions deploy failed for `<env>`. Pull the actual run log
> (`gh run view <id> --repo <addon-repo> --log`) rather than trusting the
> pass/fail label alone. Check for, in order: (a) an AWS/IAM error assuming the
> OIDC role or touching the security group — read the exact denied action and
> fix the IAM policy, don't just widen it blindly; (b) the SSH step itself
> failing or disconnecting mid-run (e.g. "Broken pipe") — if so, SSH in with
> the *admin* key (not the CI key) and check whether Odoo is actually still
> running and the reconcile actually completed server-side before assuming
> data is at risk; (c) the same categories as a migration reconcile failure
> (infra/dependency, source data inconsistency, or a genuine module bug) once
> the deploy script itself got far enough to run one. Confirm the app is
> healthy and no SG rule was left behind before re-triggering, don't just
> re-run and hope.

**A note on git staleness when working across the addon repo:**
> If a PR I open against the addon repo shows an unexpected merge conflict
> right after a related PR merged, don't assume something changed upstream —
> re-fetch that branch without `--depth 1` (a shallow fetch can be stale and
> not yet reflect a just-merged commit) before rebuilding the PR from a
> possibly-wrong base.

---

## 7. Cutover to production (go-live)

> We're going live per `CUTOVER.md`. Walk me through it, confirming each step:
> freeze odoo.sh; I'll download a fresh production backup; then
> `ODOOSH_PROD_DUMP_FILE=<new zip> ./03-migrate-from-odoosh.sh production` to load
> the delta; verify a clean registry load; re-enable prod side effects
> (`ir_cron`, `ir_mail_server`) and remind me to re-verify payment providers in
> the Odoo UI deliberately; then I cut DNS. Do NOT enable payments in bulk.
> Once live, confirm whether the admin user(s) created during testing should
> stay, be disabled, or have their passwords rotated before go-live traffic
> starts.

---

## 8. Maintenance / frequent tasks

**Health check both environments:**
> For production and staging, ssh in and report: Odoo service status, web
> response code, last 10 `/var/log/odoo/odoo.log` lines, disk usage of
> `/var/lib/odoo`, and whether the `odoo-backup.timer` is active. Flag anything
> unhealthy. Don't change anything.

**Add a Python dependency a new/updated custom module needs:**
> Odoo on <env> is erroring with `ModuleNotFoundError: <pkg>`. Install `<pkg>`
> into the venv (`/opt/odoo/venv/bin/pip`), restart odoo, and confirm the log is
> clean. Then add `<pkg>` to the curated list in `remote/odoo-restore.sh` so
> future restores include it, and note it for me to commit.

**Trigger / verify a backup:**
> On <env>, run `/usr/local/bin/odoo-backup.sh` manually, then list
> `/opt/odoo/backups` and confirm a fresh dump + filestore archive exist.

**Safely retrieve or share a credential:**
> I need <the production DB password / master password / admin login> for
> <reason>. Don't print the raw value in chat, and don't email or message it
> anywhere on my behalf by default — either tell me the exact file path in
> `secrets/` to check myself, or give me a one-line command I can run locally
> that prints it in my own terminal. Only include the actual value directly in
> your response if I explicitly say so after you've flagged the risk.

**Diagnose a failed step (generic):**
> The last run of `<script>` failed. Read the relevant log on the box
> (`/tmp/{bootstrap,restore,reconcile,harden}.log` or `/var/log/odoo/odoo.log`),
> identify the root cause, propose a fix, and wait for my go-ahead before
> applying it. If it's a script bug, patch the script and re-run.

---

## 9. Teardown only (decommission)

> Show me exactly what `./99-teardown.sh` will delete for project
> `<PROJECT_NAME>` and wait for my explicit confirmation. This is irreversible.
> After I confirm, run it, then verify no instances/VPC remain under the Project
> tag. Leave odoo.sh alone.

---

## 10. Commit & push toolkit changes

> Show me `git status` and `git diff` for the changes made this session. Draft a
> commit message that explains *why* the change was made (not just what
> changed), commit only the relevant files (not a blanket `git add -A`), and
> confirm with me before pushing to `origin/main` if there are any commits ahead
> of origin that predate this session — I want to know what's being pushed
> together, not just what I asked for this session.

---

### Tips

- Claude Code prompts before running commands — approve destructive ones
  deliberately. You can pre-approve safe read-only commands in its settings.
- Keep your AWS session fresh; if a step says "not authenticated", run
  `aws sso login` (or paste fresh credentials) and retry — sessions can expire
  mid-session even if a check passed a few minutes earlier.
- If SSH suddenly stops working partway through a session, don't assume the box
  is unhealthy — check your own public IP first (`curl checkip.amazonaws.com`).
  Carrier/guest-NAT networks can rotate it even faster than `update-my-ip.sh`
  can keep up with a single `/32` rule.
- Never ask Claude Code to paste raw secrets (passwords, tokens, private keys)
  into a chat message, email, or any other message sent on your behalf — it
  will (and should) push back and offer a local-only alternative instead. This
  is by design, not a bug to work around.
- After changing any script, re-copy to this repo isn't needed if you're already
  editing here — just commit. If editing elsewhere, keep this repo the source of
  truth.
- Odoo's `res.users` group field has been renamed across versions (`groups_id`
  → `group_ids` as of Odoo 19) — if a scripted user/group change fails with
  "Invalid field", check the field name for the version actually deployed
  rather than assuming the script is wrong.
- Any change to `~/.ssh/authorized_keys` must be append-only (check if a line
  is already present, append if not) — never filter/rewrite the file. A remove
  step is one bad match away from wiping every key and locking out SSH
  entirely, which then requires EBS root-volume surgery to recover.
