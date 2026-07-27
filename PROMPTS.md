# Prompt Library — driving the migration with Claude Code

Copy-paste these prompts into **Claude Code** (run `claude` from this repo
directory). Each assumes Claude Code will read `CLAUDE.md`, `README.md`, and
`CUTOVER.md` for context and follow the operating rules there (confirm before
destructive actions, pause after each checkpoint, never print secrets).

Replace `<...>` placeholders before sending. Prompts are ordered from
setup → fresh migration → re-migration → per-step ops → cutover → maintenance.

---

## 0. Start any session

> Read `CLAUDE.md`, `README.md`, and `CUTOVER.md` in this repo so you have full
> context on this Odoo.sh→AWS migration toolkit. Summarize back to me the current
> state (does `config.env` exist? what does `.state/` show is provisioned?) and
> wait for my instruction. Do not run anything destructive without confirming.

---

## 1. Set up / update `config.env`

**Interactive (recommended for a new project):**

> Run `./configure.sh` and walk me through it. I want to choose instance specs
> for both environments, region, Odoo version, backup source, and TLS mode.
> After it writes `config.env`, run `./00-preflight.sh` and help me fix anything
> it flags before we go further. Don't print my GitHub token or any secrets.

**Guided edit (config.env already exists, tweak a few values):**

> Show me the current non-secret values in `config.env` (mask tokens/passwords).
> I want to change: <e.g. PRODUCTION_INSTANCE_TYPE to m5.large, ODOO_VERSION to
> 18.0>. Update those keys in `config.env`, keep everything else, then run
> `./00-preflight.sh` and report the result.

---

## 2. Fresh migration (brand-new project)

> We're doing a fresh Odoo.sh→AWS migration on a new project. Prerequisites I've
> prepared: <GitHub PAT with enterprise+repo access / odoo.sh backup zip at
> \<path\> / Cloudflare origin cert at secrets/cf-origin.pem+key>. Do this,
> pausing for my confirmation between each checkpoint:
> 1. `aws sts get-caller-identity` (tell me if I need to re-auth).
> 2. `./configure.sh` (or confirm config.env is complete) then `./00-preflight.sh`.
> 3. `./01-provision-aws.sh` — then STOP and give me the new Elastic IPs so I can
>    create/point the Cloudflare A records (proxied) before continuing.
> 4. `./02-deploy-odoo.sh`.
> 5. `./03-migrate-from-odoosh.sh production` then `... staging`, verifying each
>    DB loads cleanly (registry loaded, web 200, no UndefinedColumn).
> 6. `./04-harden-and-tune.sh` then `./restrict-web-to-cloudflare.sh`.
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
> 4. Then run the fresh migration exactly as in prompt #2, pausing between
>    checkpoints, and remind me to re-point Cloudflare DNS to the NEW Elastic IPs
>    after provisioning.

---

## 4. Per-step operations

**Provision only:**
> `aws sts get-caller-identity`, then `./01-provision-aws.sh`. Report the Elastic
> IPs and instance IDs, and remind me to point DNS at them.

**Deploy Odoo only (one or both envs):**
> Run `./02-deploy-odoo.sh <production|staging|both>` and confirm each box ends
> with "Odoo is responding". If it fails, read the box's `/tmp/bootstrap.log` and
> tell me the cause before retrying.

**Migrate one environment:**
> Run `./03-migrate-from-odoosh.sh <env>`. After it finishes, verify the DB loads
> cleanly (ssh to the box, check web 200 and `/var/log/odoo/odoo.log` for
> `Registry loaded` and no `UndefinedColumn`). If a column is missing, run the
> targeted `-u <module>` reconcile and re-check.

**Seed staging from the production backup (no separate staging backup):**
> Set `ODOOSH_STAGING_DUMP_FILE` to the production backup zip and
> `ODOOSH_STAGING_BRANCH=main` in `config.env`, then run
> `./03-migrate-from-odoosh.sh staging`. Confirm it neutralizes staging
> (mail/crons/payments off).

**Harden / TLS only:**
> Run `./04-harden-and-tune.sh <env>`. Confirm nginx config test passes and HTTPS
> is live. Then run `./restrict-web-to-cloudflare.sh`. If certbot/origin cert
> errors, read `/tmp/harden.log` and diagnose.

---

## 5. TLS / network helpers

**Refresh SSH access after changing networks:**
> Run `./update-my-ip.sh`, then verify SSH works: `nc -vz -w5 <prod-eip> 22`. If
> it times out on a NAT'd network, add a broader `/24` rule for my egress range
> (don't remove the Cloudflare web rules) and tell me what you added.

**Lock / unlock origin to Cloudflare:**
> Lock: `./restrict-web-to-cloudflare.sh`. Unlock (for direct testing):
> `./restrict-web-to-cloudflare.sh --open`. Confirm which is in effect afterward.

---

## 6. Cutover to production (go-live)

> We're going live per `CUTOVER.md`. Walk me through it, confirming each step:
> freeze odoo.sh; I'll download a fresh production backup; then
> `ODOOSH_PROD_DUMP_FILE=<new zip> ./03-migrate-from-odoosh.sh production` to load
> the delta; verify a clean registry load; re-enable prod side effects
> (`ir_cron`, `ir_mail_server`) and remind me to re-verify payment providers in
> the Odoo UI deliberately; then I cut DNS. Do NOT enable payments in bulk.

---

## 7. Maintenance / frequent tasks

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

**Diagnose a failed step (generic):**
> The last run of `<script>` failed. Read the relevant log on the box
> (`/tmp/{bootstrap,restore,reconcile,harden}.log` or `/var/log/odoo/odoo.log`),
> identify the root cause, propose a fix, and wait for my go-ahead before
> applying it. If it's a script bug, patch the script and re-run.

---

## 8. Teardown only (decommission)

> Show me exactly what `./99-teardown.sh` will delete for project
> `<PROJECT_NAME>` and wait for my explicit confirmation. This is irreversible.
> After I confirm, run it, then verify no instances/VPC remain under the Project
> tag. Leave odoo.sh alone.

---

### Tips

- Claude Code prompts before running commands — approve destructive ones
  deliberately. You can pre-approve safe read-only commands in its settings.
- Keep your AWS session fresh; if a step says "not authenticated", run
  `aws sso login` (or paste fresh credentials) and retry.
- After changing any script, re-copy to this repo isn't needed if you're already
  editing here — just commit. If editing elsewhere, keep this repo the source of
  truth.
