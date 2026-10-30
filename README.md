# Timetrack – Deploy

Dieser Branch enthält nur Stack-Datei, Skripte und Betriebsdokumentation für Docker Swarm, keinen Quellcode.
Er wird automatisch aus `main` erzeugt (`scripts/sync-deploy-branch.sh`); Änderungen bitte dort vornehmen.

- Anleitung: `docs/DEPLOYMENT.md`, Updates: `docs/UPDATE.md`
- Secrets: `deploy/swarm/create-secrets.sh` (bei bestehendem Stack `--add-only`)
- Update: `deploy/swarm/update.sh`
