# code-server Secrets

Docker secret files for the code-server stack. Mounted at `/run/secrets/<name>`
and injected into the s6 environment by `scripts/init-secrets.sh` before
code-server starts.

## Required

| File | Variable injected | Description |
|------|-------------------|-------------|
| `code_server_password.txt` | `PASSWORD` | Web UI login password for code-server |
| `sudo_password.txt` | `SUDO_PASSWORD` | `sudo` password inside the IDE terminal |

## Creating secret files

```bash
# On the NAS:
echo "YOUR_CODE_SERVER_PASSWORD" > stacks/code-server/secrets/code_server_password.txt
echo "YOUR_SUDO_PASSWORD"        > stacks/code-server/secrets/sudo_password.txt
chmod 600 stacks/code-server/secrets/*.txt
```

## Security notes

- Never commit these files -- they are in `.gitignore`
- `init-secrets.sh` writes the values to `/var/run/s6/container_environment/`
  which s6-overlay exports into the running process. They do **not** appear in
  `docker inspect CodeServer` Env output.
- To rotate: update the `.txt` file, then `docker compose restart code-server`
