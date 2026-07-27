# Odoo.sh → AWS Migration

Automated, checkpoint-based migration of an Odoo instance from **odoo.sh** to
**AWS**, one **single box per environment** (Odoo app + PostgreSQL on the same
VM), with **Production** and **Staging** under one AWS project.

Everything is driven by `config.env` and runs from bash + the AWS CLI. Designed
to run **seamlessly on a fresh project**: an interactive configurator collects
every choice, a comprehensive preflight validates every prerequisite, and each
step is idempotent and fails loudly with a clear message.

---

## TL;DR — running it for a new project

```bash
./configure.sh        # 1. interactively choose region, per-env instance specs,
                      #    Odoo version, backup source, TLS mode, domains, creds
./00-preflight.sh     # 2. validate EVERY prerequisite (fix anything it flags)
./run-all.sh          # 3. execute all four checkpoints with a gate between each
```

Recommended: prove it end-to-end on staging first — `./run-all.sh staging` —
then `./run-all.sh production`.

---

## Prerequisites (fix these before you start — preflight checks them all)

- **AWS CLI v2**, authenticated with rights to create VPC/EC2/EIP and (ideally)
  `ec2:DescribeImages` + `ec2:DescribeInstanceTypes`. Keep the session fresh; if
  you use SSO, `aws sso login` before long AWS-touching steps.
- **GitHub PAT (classic, `repo` scope)** on an account that has **`odoo/enterprise`
  access** (tied to your Odoo Enterprise subscription) **and** access to your
  odoo.sh **project repo**. Preflight verifies both.
- **The DB + filestore from odoo.sh.** Production SSH on odoo.sh is often
  admin-only, so the default and most reliable method is `local_file`: download
  the backup `.zip` from odoo.sh → Branch → **Backups → Download**.
- **TLS**: if the site is proxied through **Cloudflare** (Full/Full-strict), a
  **Cloudflare Origin Certificate** (SSL/TLS → Origin Server). If direct DNS,
  Let's Encrypt via certbot instead.
- Local tools: `jq git ssh scp curl openssl`.
- A network that permits **outbound SSH (port 22)** to the boxes (some
  guest/carrier networks block it — preflight warns).

---

## The four checkpoints

| # | Script | Checkpoint | What it does |
|---|--------|-----------|--------------|
| 0 | `00-preflight.sh` | Preflight | Validates tooling, AWS, GitHub access, version branch, backup/cert inputs, network. Changes nothing. |
| 1 | `01-provision-aws.sh` | **AWS provisioning** | VPC, subnet, IGW, routes, security group, key pair, EC2 per env (your chosen specs), data EBS volume, Elastic IP. Idempotent (matches by Name tag). |
| 2 | `02-deploy-odoo.sh` | **Deploy Odoo Enterprise** | PostgreSQL 16 + Odoo (chosen version) Enterprise on Python 3.12 + wkhtmltopdf + systemd. Clones `odoo` + `odoo/enterprise` at the target version. |
| 3 | `03-migrate-from-odoosh.sh` | **Backup from odoo.sh & deploy** | Pulls DB + filestore, clones custom addons (with submodules), installs their Python deps, restores per env, runs a `-u all` schema reconcile, and neutralizes staging. Version-downgrade guard included. |
| 4 | `04-harden-and-tune.sh` | **Security hardening & fine tuning** | nginx reverse proxy + TLS (Cloudflare Origin or Let's Encrypt), Odoo worker + PostgreSQL tuning sized to the box, `dbfilter`/`list_db`, UFW, fail2ban, unattended-upgrades, SSH hardening, CloudWatch (where monitoring is on), nightly backups. |

Run them individually, or `./run-all.sh` to chain all four with a validation
gate between each.

### Helper scripts

| Script | Purpose |
|--------|---------|
| `configure.sh` | Interactive setup — the entry point for a new project. Choose instance specs and everything else; writes `config.env`. |
| `update-my-ip.sh` | Lock SSH (22) to your current public IP. Re-run when you change networks. NAT-safe: never revokes a manually-added broader rule. |
| `restrict-web-to-cloudflare.sh` | Lock origin 80/443 to Cloudflare's IP ranges (when proxied). `--open` reverts. |

```
odoo-aws-migration/
├── configure.sh              # interactive config generator (start here)
├── config.env.example        # template (copied to config.env)
├── 00-preflight.sh
├── 01-provision-aws.sh
├── 02-deploy-odoo.sh
├── 03-migrate-from-odoosh.sh
├── 04-harden-and-tune.sh
├── run-all.sh                # orchestrator
├── update-my-ip.sh
├── restrict-web-to-cloudflare.sh
├── CUTOVER.md                # go-live runbook
├── lib/common.sh             # shared helpers (logging, state, ssh, aws lookups)
└── remote/                   # scripts executed ON the EC2 boxes
    ├── odoo-bootstrap.sh
    ├── odoo-restore.sh
    └── odoo-harden.sh
```

---

## Key configuration choices (`config.env`)

- **Instance specs per environment** — `PRODUCTION_INSTANCE_TYPE`,
  `PRODUCTION_EBS_GB`, `PRODUCTION_MONITORING`, `PRODUCTION_TENANCY`, and the
  `STAGING_*` equivalents. Chosen interactively in `configure.sh` and validated
  against AWS in preflight.
- **`ODOO_VERSION`** — the control parameter (`19.0`, `18.0`, …). Overridable per
  run: `ODOO_VERSION=18.0 ./02-deploy-odoo.sh`. **Must be ≥ the odoo.sh source
  version** — a newer DB can't be restored onto an older codebase (step 3 has a
  guard that stops before touching the DB if you get this wrong).
- **`ODOOSH_PULL_METHOD`** — `local_file` (download backup zip; most reliable),
  `ssh_dump` (SSH into the odoo.sh build; needs the right role), or
  `https_backup` (signed URL).
- **`RECONCILE_MODULES`** — post-restore `odoo-bin -u` pass (default `all`). If
  `-u all` is rolled back by one module's error, the restore automatically falls
  back to updating each installed **custom** module in its own transaction.
- **`TLS_MODE`** — `cloudflare_origin` (install a Cloudflare Origin cert; for
  proxied sites) or `letsencrypt` (certbot; for direct DNS).
- **`NEUTRALIZE_STAGING`** — disable mail/crons/payments on staging (default on).

### Reserved Instances / Savings Plan (manual billing step)

`run-instances` launches on-demand capacity. Any 1- or 3-year commitment (No
Upfront etc.) is a separate billing purchase — buy a Compute Savings Plan or
Standard RIs matched to your running shapes once the instances are stable.

---

## Design notes / lessons baked in

These are hardened in the scripts from real run experience:

- **Idempotent**: AWS resources matched by Name tag before create; remote steps
  re-apply cleanly; `config.env` is the single source of truth. Discovered IDs
  go to `.state/<env>.env`; generated secrets to `secrets/`.
- **Fail loudly**: remote steps run under `set -o pipefail` with the real exit
  status surfaced (no `tee` masking); the orchestrators stop on a failed
  bootstrap/restore/harden instead of reporting false success.
- **Python 3.12 venv** (not Ubuntu 22.04's 3.10) so pinned deps like `gevent`
  install as wheels instead of failing to compile.
- **Custom-addon deps auto-installed**: each module's `requirements.txt` +
  manifest `external_dependencies` + a curated common set (pandas, openpyxl,
  xmltodict, phonenumbers, …), and a reassert of `urllib3`/`requests` so an addon
  can't downgrade Odoo's HTTP stack.
- **Submodules**: addon repos are cloned `--recurse-submodules` with token auth
  applied to every github URL (parent + private submodules).
- **Schema reconcile** after restore, with per-module fallback.
- **apt lock waits** (`DPkg::Lock::Timeout`) so background `unattended-upgrades`
  can't fail a step.
- **Quoted env files** so a value with a space (e.g. a pasted `ssh user@host`)
  can't break sourcing.
- **NAT-aware SSH**: `update-my-ip.sh` only manages its own `/32`; add a broader
  `/24` by hand for carrier-NAT networks and it won't be clobbered.
- **Data volume**: the data EBS volume is mounted at `/var/lib/odoo`, so the DB
  and filestore live on durable, resizable storage separate from the OS disk.

## Security summary (checkpoint 4)

nginx TLS (auto-renew for Let's Encrypt; 15-yr Cloudflare Origin cert otherwise),
HTTP→HTTPS, HSTS + security headers, Cloudflare real-IP restoration; Odoo
`proxy_mode` + `list_db=False` + `dbfilter` pinned to the one DB; UFW; fail2ban;
unattended security upgrades; SSH password/root login disabled; nightly `pg_dump`
+ filestore backups (retention + optional S3); origin optionally locked to
Cloudflare IP ranges.

## Cutover & rollback

Until you cut DNS, odoo.sh stays authoritative — rollback is simply not cutting
over. See **`CUTOVER.md`** for the go-live runbook (freeze odoo.sh → final backup
→ re-migrate the delta → re-enable crons/mail/payments → switch DNS → verify).

## Troubleshooting

- Remote logs on each box: `/tmp/bootstrap.log`, `/tmp/restore.log`,
  `/tmp/reconcile.log`, `/tmp/harden.log`, `/tmp/certbot.log`, and
  `/var/log/odoo/odoo.log`.
- SSH uses the key at `secrets/<PROJECT_NAME>-key.pem`. Reference it explicitly
  (not `secrets/*.pem`) since `secrets/` may also hold a TLS cert.
- `column ... does not exist` after restore → the addon code is newer than the
  backup; the `-u all` reconcile handles it, or run `-u <module>` for the one
  named in the log.

> Version note: odoo.sh SSH host/backup mechanics and `odoo/enterprise` access
> can change; verify against odoo.sh right before a run. Backup download links
> and odoo.sh SSH build hosts are time-limited/ephemeral.
