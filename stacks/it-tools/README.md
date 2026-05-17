# it-tools

Web utility belt -- JSON formatters, base64, regex tester, hash calculators, etc. Stateless, no DB, no auth.

## Service

- **it-tools** (8894) -- Vue.js single-container app

## Health

HTTP 200 on `/`.

## Rollback

```bash
git checkout -- it-tools/compose.yaml
docker compose -f it-tools/compose.yaml up -d
```

## Note

Lowest-risk stack in the fleet -- stateless, no volumes, no secrets, no inter-service deps. Safe to use as a smoke-test target for compose-tooling changes.

## Related docs

- Stack Optimization / Customization -- optional Traefik BasicAuth and tool hygiene.
- NAS Deployment -- fleet HTTP/HTTPS port reference (`8894` on the NAS table).
- Google Workspace OAuth / NAS Login -- identity/OAuth patterns when exposing utilities externally.
