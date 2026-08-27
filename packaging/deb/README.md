# Debian packaging for the open-appsec nano agent

Upstream distributes open-appsec as makeself self-extracting shell installers,
not as distribution packages. There is no `.deb` anywhere upstream, no apt
repository, and nothing for a configuration-management system to declare. This
directory builds one.

## How it works

`.github/workflows/build-deb.yml` downloads upstream's precompiled installers
for the target Debian codename, then `build-deb.sh` turns them into a package.

It does **not** build from source. Source builds do work on Debian 13 - CI
proved that before this was switched - but repacking upstream's binaries means
the package contains exactly the build that upstream tests and that is known to
inspect traffic. `build-deb.sh` takes a directory of `install-cp-*.sh` files, so
pointing it at `build_out/` after a `make package` still works if you ever want
the source route.

The important choice is that the makeself archives are **unpacked at build
time**, not shipped and self-extracted on the target:

```
install-cp-nano-agent.sh --noexec --target usr/share/openappsec/agent
```

That matters for three reasons:

- `dpkg` owns and can verify the ~30 MB of binaries, instead of three opaque
  blobs.
- Nothing self-extracts at install time, so a host with `/tmp` mounted
  `noexec` installs cleanly. Upstream's installer fails there with a bare
  `Permission denied` from inside the archive, and its wrapper redirects that
  to `/dev/null` and reports success anyway.
- `postinst` only runs each payload's own inner install script, which is what
  performs the host-specific setup under `/etc/cp`.

## What is deliberately not included

**The NGINX attachment.** It is compiled against one exact nginx build — the
supported combinations are listed in
[`supported-nginx.txt`](https://downloads.openappsec.io/packages/supported-nginx.txt) —
so bundling it with the agent would tie two independently versioned things
together. Install it separately and **pin your nginx package**, because apt has
no idea the module depends on a specific nginx and will happily upgrade out
from under it.

## What CI does and does not prove

CI asserts that the package builds, installs, lays its payload out correctly,
and removes cleanly.

CI **cannot** prove the agent inspects traffic. A plain container has no
systemd, so `nano_agent` never starts, orchestration never writes
`orchestration_status.json`, and `open-appsec-ctl -s` reports `Not running`.
That step is informational and deliberately non-fatal.

This distinction is not pedantic. Upstream
[issue #411](https://github.com/openappsec/openappsec/issues/411) describes
from-source builds where every service reports `Running` and
`Policy load status: Success` while the attachment sits in bypass
(`inspection mode: 0`) and every attack passes. **A green pipeline is not
evidence that the WAF works.** Verify on a real host:

```sh
apt-get install ./openappsec_<version>_amd64.deb
open-appsec-ctl -s                 # all components Running/Ready
                                   # "Management mode: Local management"
# with the attachment installed and nginx in front of something:
curl -s -o /dev/null -w '%{http_code}\n' 'http://host/?f=../../../../etc/passwd'
# 403 under a prevent-mode policy; 200 means it is not inspecting
```

Extracting the payloads requires root (the archives refuse otherwise), which
is why `build-deb.sh` is run as root in CI and needs `sudo` locally.

## Version

The upstream agent version is stated only in the makeself label, so the
workflow reads it from there (`Nano Agent Version 1.1.36`). Untagged builds are
versioned `<agent-version>~<sha>`, which sorts *below* any release. Pushing a
`v*` tag uses the tag as the package version and publishes a release with the
.deb attached, using the workflow's own `GITHUB_TOKEN` - no personal access
token needed.
