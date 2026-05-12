Infrastructure folder for HAProxy (canonical config: haproxy.cfg next to these dirs):
  certs/  — PEM files only (full chain + private key, one file per bundle, .pem names).
            HAProxy bind uses ssl crt …/certs/ and loads every non-hidden file there;
            do not put README or other text in certs/ (only *.pem). *.pem is gitignored.
  maps/   — host.map (Host header -> backend name)

If the NAS already has /volume2/docker/haproxy.cfg (sibling of dockge/), keep that file as
a thin include of this tree only, or change HAProxy to -f /volume2/docker/ce-stacks/stacks/_haproxy/haproxy.cfg.

This is not a Dockge compose stack. Traefik stacks (traefik-ots / traefik-mft) remain the TLS path for services that use them; HAProxy here is the optional edge for host-published ports.

TLS — fixing “cannot open …/certs/otsorundscore.olutechsys.com.pem” (or any missing PEM)
  HAProxy refuses to start until every certificate path referenced on bind ssl crt … is readable.
  - Repo bind line uses a directory: ssl crt …/stacks/_haproxy/certs/  (trailing slash). HAProxy loads
    every *.pem in that directory for SNI. You need at least one valid bundle whose SANs cover the
    Host names you expose (often a wildcard under *.otsorundscore.olutechsys.com plus other zones as separate PEMs).
  - If your Synology copy under /volume1/@appdata/haproxy/haproxy.cfg still points at a single file
    …/certs/otsorundscore.olutechsys.com.pem, that file must exist OR change line 59 to match the repo directory form
    after git pull, then reload.
  - Build a HAProxy PEM (full chain + private key, concatenated in that order) from acme.sh output. Use one
    shell line — do not break inside the single-quoted sh -c '…' string (newlines become bogus cat args):
      sudo sh -c 'cat /volume2/certs/acme/otsorundscore/fullchain.pem /volume2/certs/acme/otsorundscore/privkey.pem > /volume2/docker/ce-stacks/stacks/_haproxy/certs/otsorundscore.olutechsys.com.pem'
    (Any *.pem name is fine when bind uses the certs/ directory.)
    Adjust paths if your acme layout differs (see stacks/acme-sh/SETUP.md). Then: chmod 640 that PEM.
  - Validate before reload (use the same -f path your package actually loads):
      sudo /volume1/@appstore/haproxy/sbin/haproxy -c -f /volume1/@appdata/haproxy/haproxy.cfg
    or: … -f /volume2/docker/ce-stacks/stacks/_haproxy/haproxy.cfg

Missing LF on last line (HAProxy 3.x — “file might have been truncated”)
  Package UI paste/copy often strips the final newline. Prefer deploy via sudo cp from git checkout:
      sudo cp /volume2/docker/ce-stacks/stacks/_haproxy/haproxy.cfg /volume1/@appdata/haproxy/haproxy.cfg
  Or normalize EOF on the NAS (ensure exactly one trailing newline):
      sudo python3 <<'PY'
      from pathlib import Path
      p = Path("/volume1/@appdata/haproxy/haproxy.cfg")
      t = p.read_text(encoding="utf-8", errors="surrogateescape")
      p.write_text(t.rstrip("\n") + "\n", encoding="utf-8")
      PY
  Then run haproxy -c again.

Synology Package Center HAProxy — “password prompt” / can’t save / config not sticking
  DSM may use more than one path; confirm which file the running process loads, e.g.:
      ps auxww | grep '[h]aproxy'
  Common locations: /var/packages/haproxy/var/haproxy.cfg  and/or  /volume1/@appdata/haproxy/haproxy.cfg
  Package stock config uses: user sc-haproxy, daemon, log ring@httplog, ring httplog { … }. Repository
  stacks/_haproxy/haproxy.cfg merges those globals with Dockge frontends/backends (paste-ready for DSM).
  Non-package HAProxy (e.g. Docker): replace global with log stdout and omit user/daemon/ring as needed.
  Always validate after edits: haproxy -c -f …
  Saving under /var/packages/ or @appdata/ from SMB/Finder often fails or loops “password” because
  only root/admin may write there. Prefer SSH as an admin-capable user:
      sudo cp /volume2/docker/ce-stacks/stacks/_haproxy/haproxy.cfg /volume1/@appdata/haproxy/haproxy.cfg
  (Adjust destination to match ps/haproxy -c.) Or: sudo vi … / sudo tee < file
  Stats page “admin:admin” vs your password: that line is HTTP Basic Auth for :8280 only — not your
  DSM login. After you change stats auth, reload HAProxy; if the browser keeps asking, use a private
  window or clear saved credentials for http://<nas-ip>:8280/ (cached wrong user/pass).
