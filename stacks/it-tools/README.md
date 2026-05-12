# it-tools

Web utility belt — JSON formatters, base64, regex tester, hash calculators, etc. Stateless, no DB, no auth.

## Service

- **it-tools** (8894) — Vue.js single-container app

## Health

HTTP 200 on `/`.

## Rollback

```bash
git checkout -- it-tools/compose.yaml
docker compose -f it-tools/compose.yaml up -d
```

## Note

Lowest-risk stack in the fleet — stateless, no volumes, no secrets, no inter-service deps. Safe to use as a smoke-test target for compose-tooling changes.

## Related docs

- [`docs/hive/STACK_OPTIMIZATION_CUSTOMIZATION.md`](../../docs/hive/STACK_OPTIMIZATION_CUSTOMIZATION.md) — optional Traefik BasicAuth and tool hygiene.
- [`docs/hive/NAS_DEPLOYMENT.md`](../../docs/hive/NAS_DEPLOYMENT.md) — fleet HTTP/HTTPS port reference (`8894` on the NAS table).
- [`docs/hive/GOOGLE_WORKSPACE_OAUTH_NAS_LOGIN.md`](../../docs/hive/GOOGLE_WORKSPACE_OAUTH_NAS_LOGIN.md) — identity/OAuth patterns when exposing utilities externally.
