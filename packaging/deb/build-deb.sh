#!/usr/bin/env bash
#
# Assemble a .deb from the makeself packages that `make package` produces.
#
# Upstream ships open-appsec as self-extracting shell installers, not distro
# packages, so this wraps them: the .deb carries the installers and its
# maintainer scripts drive them. That gives apt-managed install/upgrade/removal
# and a real version number, without re-deriving the /etc/cp layout that
# install-cp-nano-agent.sh builds.
#
# Usage: build-deb.sh <version> [build_out_dir] [output_dir]
set -euo pipefail

VERSION="${1:?usage: build-deb.sh <version> [build_out] [outdir]}"
BUILD_OUT="${2:-build_out}"
OUTDIR="${3:-dist}"

# Strip a leading v so v1.2.3 and 1.2.3 both yield a valid Debian version.
VERSION="${VERSION#v}"

ARCH="$(dpkg --print-architecture)"
PKGNAME="openappsec"

# The six artifacts nodes/*/CMakeLists.txt declare via gen_package().
REQUIRED=(
    install-cp-nano-agent.sh
    install-cp-nano-service-http-transaction-handler.sh
    install-cp-nano-attachment-registration-manager.sh
)
OPTIONAL=(
    install-cp-nano-agent-cache.sh
    install-cp-nano-service-prometheus.sh
    install-cp-nano-central-nginx-manager.sh
)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

install -d "$root/DEBIAN"
install -d "$root/usr/share/openappsec"
# Payload extraction happens here rather than /tmp, which is mounted noexec on
# hardened hosts - makeself archives cannot run from a noexec filesystem.
install -d "$root/var/lib/openappsec/tmp"

missing=()
for p in "${REQUIRED[@]}"; do
    if [ -f "$BUILD_OUT/$p" ]; then
        install -m 0755 "$BUILD_OUT/$p" "$root/usr/share/openappsec/$p"
    else
        missing+=("$p")
    fi
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "error: 'make package' did not produce: ${missing[*]}" >&2
    echo "       looked in: $BUILD_OUT" >&2
    exit 1
fi

for p in "${OPTIONAL[@]}"; do
    [ -f "$BUILD_OUT/$p" ] && install -m 0755 "$BUILD_OUT/$p" "$root/usr/share/openappsec/$p"
done

echo "$VERSION" > "$root/usr/share/openappsec/VERSION"

installed_kb="$(du -sk "$root" | cut -f1)"

sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@ARCH@|$ARCH|g" \
    -e "s|@INSTALLED_SIZE@|$installed_kb|g" \
    "$here/control.in" > "$root/DEBIAN/control"

for script in postinst prerm postrm; do
    if [ -f "$here/$script" ]; then
        install -m 0755 "$here/$script" "$root/DEBIAN/$script"
    fi
done

# The agent writes its whole runtime state under /etc/cp; tell dpkg not to
# treat anything we ship as a conffile, since none of it lives in /etc.
mkdir -p "$OUTDIR"
deb="$OUTDIR/${PKGNAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$root" "$deb" >/dev/null

echo "built $deb"
dpkg-deb --info "$deb"
echo "--- contents ---"
dpkg-deb --contents "$deb"
