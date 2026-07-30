# CLAUDE.md — project context for Claude Code

This repo is a **checkpoint-based toolkit to migrate an Odoo instance from
odoo.sh to AWS** (single VM per environment: Odoo app + PostgreSQL together),
for a **Production** and a **Staging** environment under one AWS project.

Read `README.md` (full reference + "lessons baked in") and `CUTOVER.md` (go-live
runbook) before acting. Ready-to-run task prompts live in `PROMPTS.md`.

## How the toolkit works

- `config.env` is the single source of truth (created by `./configure.sh` from
  `config.env.example`). `secrets/` holds the EC2 key, DB passwords, tokens, and
  TLS/origin keys. `.state/<env>.env` holds discovered AWS IDs. All three are
  gitignored — **never commit them, never print private keys**.
- Flow: `configure.sh` → `00-preflight.sh` → `01-provision-aws.sh` →
  `02-deploy-odoo.sh` → `03-migrate-from-odoosh.sh` → `04-harden-and-tune.sh`.
  `run-all.sh` chains them; `99-teardown.sh` destroys everything.
- `05-update-addons.sh` is a **non-destructive** ongoing-deploy path: pulls
  latest custom addon code + Python deps and reconciles schema against the
  *existing* database — no drop/recreate, unlike `03-migrate-from-odoosh.sh`.
  Safe to trigger on every code merge. `setup-ci-deploy.sh` wires this up to
  CI (see `ci-templates/deploy.yml` for the GitHub Actions side) via a
  restricted, forced-command-only SSH key — never the main admin key.
  `setup-ci-aws-access.sh` sets up the other half CI needs: an AWS OIDC role
  (no static AWS credential ever stored) scoped to only open/close a
  temporary SSH rule on the project security group, since it's intentionally
  locked to the operator's own IP and GitHub-hosted runners can't reach it
  otherwise. Needs an AWS identity with IAM write access to run — a separate,
  more privileged grant than day-to-day EC2 admin.
- Every script is **idempotent** (AWS matched by Name tag; remote steps re-apply
  cleanly) and **fails loudly** (no silent success). Re-running a failed step is
  the normal recovery.
- `ODOO_VERSION` is the version control parameter and must be **≥ the odoo.sh
  source version** (step 3 has a downgrade guard).

## Operating rules (follow these)

1. **Confirm before anything destructive or irreversible** — always show the plan
   and get an explicit yes before `99-teardown.sh`, `terminate-instances`,
   `delete-*`, `revoke-security-group-*`, or dropping a database. Teardown erases
   the AWS databases/filestores.
2. **AWS session** — run `aws sts get-caller-identity` before AWS-touching steps
   (checkpoint 1, teardown, `update-my-ip.sh`, `restrict-web-to-cloudflare.sh`).
   SSO/temporary sessions expire (often hourly); refresh with `aws sso login` or
   fresh credentials. Checkpoints 2–4 use SSH and are unaffected by AWS expiry.
3. **Secrets** — do not echo private keys, tokens, or DB passwords to the
   terminal, or include them in any chat message, email, or other message sent
   on the operator's behalf. When splitting/placing certs or keys, write to
   files and verify with fingerprints/counts, not by printing contents. Default
   to a file-path reference or a locally-run command the operator executes
   themselves; only include an actual secret value directly if the operator
   explicitly asks for that specific exception after you've flagged the risk.
4. **SSH key** — reference it explicitly as `secrets/${PROJECT_NAME}-key.pem`,
   not `secrets/*.pem` (secrets/ may also hold a TLS cert `.pem`).
5. **Pause after each checkpoint** so the operator can verify before continuing.
6. **Don't invent facts** about odoo.sh state, versions, or credentials — ask the
   operator or read the actual output.

## Known gotchas (already handled; watch for them)

- **New Elastic IPs** on every fresh provision → Cloudflare A records must be
  re-pointed to the new IPs before step 4. Check first with
  `dig +short <domain>` — DNS may already be correct and not need touching.
- **Carrier/guest-NAT networks** rotate the public IP → a `/32` SSH rule fails;
  use `./update-my-ip.sh`, and for a NAT pool add a broader `/24` by hand (the
  helper won't clobber it). Outbound port 22 may be blocked on some networks.
  If the IP is different on every single check (sample `checkip.amazonaws.com`
  a few times in a row), that's a rotating NAT pool, not a fluke — a `/32` will
  never keep up.
- **odoo.sh production SSH is often admin-only** → default pull method is
  `local_file` (download the backup zip in a browser).
- **`-u all` schema reconcile** can be rolled back by one module's RST/description
  error → the restore auto-falls back to per-custom-module updates.
- **Cloudflare Full (strict)** needs a real origin cert → `TLS_MODE=cloudflare_origin`
  installs a Cloudflare Origin Certificate; origin 80/443 lock to Cloudflare via
  `restrict-web-to-cloudflare.sh`.
- **Odoo 19+'s `ai` module needs `pgvector`** (`ai_embedding.embedding_vector` is
  a `vector(1536)` column) → bootstrap installs `postgresql-${PG_VERSION}-pgvector`
  and restore creates the extension automatically. A box provisioned before this
  fix will show `type "vector" does not exist` or `Model ai.embedding has no
  table` on `-u ai`; install the package and `CREATE EXTENSION vector` manually,
  then retry.
- **`ai_agent_ai_topic_rel` can carry orphaned rows** referencing `ai_topic` ids
  that don't exist — a pre-existing inconsistency in the source odoo.sh dump,
  not something the restore introduces. Restore now deletes these automatically;
  if `-u ai` still fails on this table's foreign key, that's why.
- **`res.users` group field renamed** in Odoo 19: `groups_id` → `group_ids`. Any
  ad hoc user/group scripting (e.g. creating an admin user via `odoo-bin shell`)
  must use the field name for the deployed version.
- **Never filter/rewrite `authorized_keys`** — always append-only, check-then-
  append. A prior version of `setup-ci-deploy.sh` tried to dedupe an entry with
  `grep -v "${KEYBODY}"` inside a heredoc where `KEYBODY` silently evaluated
  empty (nested local/remote variable expansion bug); `grep -v ""` matches
  every line, so it wiped the admin key entirely and locked out SSH. Recovery
  required stopping the instance and doing EBS root-volume surgery (attach the
  root volume to another running box, fix the file, reattach). Any script that
  touches `authorized_keys` must never use a remove/filter step — only ever
  check whether a line is already present and append if not.
- **GitHub only fires a push-triggered workflow if the workflow file already
  exists on the branch being pushed to** — adding `ci-templates/deploy.yml` to
  `main` doesn't cover `Staging` (or vice versa). Needs a companion PR/commit
  on each branch. After a re-provision, re-run `setup-ci-deploy.sh` (new boxes
  have empty `authorized_keys`) and update the addon repo's `PRODUCTION_HOST`/
  `STAGING_HOST` variables — the CI keypair itself doesn't need regenerating.
- **IAM `Authorize`/`RevokeSecurityGroupIngress` needs a `security-group-rule`
  resource grant, not just `security-group`** — the new/removed rule has no ID
  yet, so AWS evaluates that half as a wildcard even though the request is
  bound to one `--group-id`. A policy scoped to only the `security-group` ARN
  fails with `UnauthorizedOperation` on the rule resource. Also: tagging that
  rule needs a separate `ec2:CreateTags` grant on the same wildcard — not
  worth it for a cosmetic label, so `ci-templates/deploy.yml` doesn't tag it.
- **A long-silent SSH command over an unreliable path can get disconnected
  mid-run** — the CI deploy redirects all its output to a remote log file, so
  the SSH session is completely silent for the several minutes a full `-u all`
  reconcile takes. An idle NAT/firewall between a GitHub-hosted runner and AWS
  killed that connection once, right before the script's final
  `systemctl start odoo`, leaving the box down until manually restarted (the
  reconcile itself had already finished server-side by then). Fixed with
  `ServerAliveInterval`/`ServerAliveCountMax` on the SSH command; any new
  long-running silent remote command should get the same treatment.
- **IAM write actions (`CreateRole`, `CreatePolicy`, `AttachRolePolicy`,
  `CreateOpenIDConnectProvider`, `UpdateAssumeRolePolicy`) may be denied even
  under an apparently-broad role like `SystemAdministrator`** — orgs commonly
  wall these off separately since they define new trust relationships, not
  just resources. `Get*`/read access on IAM can still work fine. If
  `setup-ci-aws-access.sh` fails with `AccessDenied` on any of these, that's
  the operator needing to grant temporary elevated access or run it
  themselves — not a bug to route around.
- **A shallow (`--depth 1`) git fetch of another repo's branch can be stale**
  and not yet reflect a very recent merge, making a locally-built PR branch
  look like it conflicts with content that's actually already there. If a PR
  shows an unexpected conflict right after a related PR merged, re-fetch
  without `--depth` (or re-fetch the specific ref explicitly) before assuming
  something upstream changed unexpectedly.

## Verifying a healthy box

```bash
IP=<eip>; KEY="secrets/${PROJECT_NAME}-key.pem"
ssh -i "$KEY" ubuntu@$IP 'curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8069/web/login; sudo tail -15 /var/log/odoo/odoo.log'
```
Healthy = `Registry loaded` in the log, no `Traceback`/`UndefinedColumn`, web 200/303.
