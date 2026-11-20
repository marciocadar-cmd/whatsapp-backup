# Encrypted wacli backup

This private repository holds an age-encrypted snapshot of the wacli SQLite
databases (`wacli-backup.tar.age`: a gzip-compressed tar of `*.db` files).

Helper scripts from the box are included for convenience:

- `wacli` — wrapper that points the store at `/workspace/.wacli-store`
- `wacli-backup.sh` — online DB snapshot, encrypt, and force-push a single orphan commit
- `wacli-restore.sh` — decrypt and restore the store (refuses if the current store is authenticated unless `--force`)

Secrets are not stored in this repository. The age identity and the GitHub
deploy key live only on the box (the age identity is also kept in the bot
store). To restore, run `wacli-restore.sh` on a box that has the age identity.

Each push replaces history with one new orphan commit so the repo stays small.
