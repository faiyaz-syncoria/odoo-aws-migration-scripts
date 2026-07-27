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
   terminal. When splitting/placing certs or keys, write to files and verify with
   fingerprints/counts, not by printing contents.
4. **SSH key** — reference it explicitly as `secrets/${PROJECT_NAME}-key.pem`,
   not `secrets/*.pem` (secrets/ may also hold a TLS cert `.pem`).
5. **Pause after each checkpoint** so the operator can verify before continuing.
6. **Don't invent facts** about odoo.sh state, versions, or credentials — ask the
   operator or read the actual output.

## Known gotchas (already handled; watch for them)

- **New Elastic IPs** on every fresh provision → Cloudflare A records must be
  re-pointed to the new IPs before step 4.
- **Carrier/guest-NAT networks** rotate the public IP → a `/32` SSH rule fails;
  use `./update-my-ip.sh`, and for a NAT pool add a broader `/24` by hand (the
  helper won't clobber it). Outbound port 22 may be blocked on some networks.
- **odoo.sh production SSH is often admin-only** → default pull method is
  `local_file` (download the backup zip in a browser).
- **`-u all` schema reconcile** can be rolled back by one module's RST/description
  error → the restore auto-falls back to per-custom-module updates.
- **Cloudflare Full (strict)** needs a real origin cert → `TLS_MODE=cloudflare_origin`
  installs a Cloudflare Origin Certificate; origin 80/443 lock to Cloudflare via
  `restrict-web-to-cloudflare.sh`.

## Verifying a healthy box

```bash
IP=<eip>; KEY="secrets/${PROJECT_NAME}-key.pem"
ssh -i "$KEY" ubuntu@$IP 'curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8069/web/login; sudo tail -15 /var/log/odoo/odoo.log'
```
Healthy = `Registry loaded` in the log, no `Traceback`/`UndefinedColumn`, web 200/303.
