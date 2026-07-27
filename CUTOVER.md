# Odoo.sh → AWS — Cutover Runbook

State after migration (both environments on **Odoo 19.0 Enterprise**, behind
Cloudflare with Full (strict), origin locked to Cloudflare IP ranges):

| Env | URL | EIP | Instance | DB | Status |
|-----|-----|-----|----------|----|--------|
| Production | https://syncoria-demo-master-aws-prod.syncoria.tech | 3.136.2.205 | t3.large | `main` | **Dormant** (crons/mail/payments OFF) until cutover |
| Staging | https://syncoria-demo-master-aws-stg.syncoria.tech | 18.218.238.152 | t3.medium | `Staging` | Neutralized (safe test copy) |

The AWS production copy is a **point-in-time snapshot**. odoo.sh keeps accumulating
data until you cut over, so the steps below re-sync the delta at go-live.

---

## Pre-cutover checklist

- [ ] Stakeholders informed of a maintenance window.
- [ ] Reconcile the earlier test run's side effects: confirm with the team whether
      the 8 "Moneris Recurring Payment" jobs that fired during migration testing
      hit the gateway (they may need voiding). Payment providers are currently
      disabled on AWS prod, so nothing new is firing.
- [ ] Confirm nightly backups are running: `systemctl list-timers | grep odoo-backup`
- [ ] Decide the real production hostname that will point at AWS.
- [ ] Refresh your AWS SSO session and set `ODOOSH_PROD_SSH_HOST` is not needed
      (using `local_file` backup method).

## Cutover steps

1. **Freeze odoo.sh.** Put the production branch into maintenance / notify users so
   no new writes occur after the final backup.

2. **Final backup.** In odoo.sh → main branch → Backups, create + download a fresh
   `*_exact_fs.zip` (captures everything since the migration snapshot).

3. **Re-migrate production with the final data** (recreates `main`; deps + schema
   reconcile now run automatically):
   ```bash
   ODOOSH_PROD_DUMP_FILE="$HOME/Downloads/<final-backup>.zip" \
     ./03-migrate-from-odoosh.sh production
   ```
   Confirm a clean load:
   ```bash
   IP=3.136.2.205; KEY="secrets/syncoria-demo-master-key.pem"
   ssh -i "$KEY" ubuntu@$IP 'curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8069/web/login; sudo tail -15 /var/log/odoo/odoo.log'
   ```

4. **Wake production** (it was deliberately dormant):
   ```bash
   ssh -i secrets/syncoria-demo-master-key.pem ubuntu@3.136.2.205 \
     "sudo -u postgres psql -d main -c \"UPDATE ir_cron SET active=true; UPDATE ir_mail_server SET active=true;\" && sudo systemctl restart odoo"
   ```
   Re-enable and re-verify **payment providers in the Odoo UI deliberately**
   (Moneris / Rotessa credentials) — do NOT bulk-enable blindly.

5. **Cut DNS.** Point the real production hostname at Cloudflare → this origin
   (proxied, Full strict). The `*.syncoria.tech` origin cert already covers it; if
   using a different apex domain, generate/point an origin cert accordingly.

6. **Verify + monitor.** Load the site, place a test transaction in a controlled
   way, watch `/var/log/odoo/odoo.log`, confirm outbound mail and scheduled jobs.

7. **Decommission odoo.sh** only once AWS is confirmed stable for a full business
   cycle (payroll run, recurring payments, EDI/integrations).

## Rollback

Until step 5 (DNS cut), odoo.sh is still authoritative — rollback = simply don't
cut DNS. After cutover, if a blocker appears, point DNS back at odoo.sh and
re-freeze AWS (disable crons/mail/payments again with the inverse of step 4).

## Operational notes

- **SSH access** is IP-restricted. On a new network run `./update-my-ip.sh` first.
  (Use the key `secrets/syncoria-demo-master-key.pem` — not a glob, since
  `secrets/` also holds the Cloudflare origin cert.)
- **Origin is Cloudflare-only.** Direct-to-IP web access is blocked. To open
  temporarily: `./restrict-web-to-cloudflare.sh --open` (re-lock afterward).
- **Backups**: nightly `pg_dump` + filestore to `/opt/odoo/backups`, 7-day
  retention. Set `BACKUP_S3_BUCKET` in `config.env` to also push off-box.
- **Re-running** any step is safe (idempotent). Provisioning reuses tagged
  resources; deploy/restore/harden re-apply cleanly.
