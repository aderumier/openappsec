#!/usr/bin/env bash
#
# Assemble a .deb from the makeself packages that `make package` produces.
#
# Upstream ships open-appsec as self-extracting shell installers, not distro
# packages. Rather than shipping those installers and self-extracting on the
# target, this unpacks each one at BUILD time (`--noexec --target`) and puts
# the resulting payload in the .deb. That means:
#
#   * dpkg owns the ~30 MB of binaries, so they can be listed and verified
#   * nothing self-extracts at install time, so a target with /tmp mounted
#     noexec - a common hardening choice - installs cleanly
#   * postinst only has to run each payload's own inner install script, which
#     is what performs the host-specific setup under /etc/cp
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

# component-dir : makeself artifact : inner install script
# The artifact names come from the gen_package() calls in nodes/*/CMakeLists.txt
# and the inner script is gen_package()'s third argument.
COMPONENTS=(
    "agent:install-cp-nano-agent.sh:orchestration_package.sh"
    "http-transaction-handler:install-cp-nano-service-http-transaction-handler.sh:install-http-transaction-handler.sh"
    "attachment-registration-manager:install-cp-nano-attachment-registration-manager.sh:install-attachment-registration-manager.sh"
)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

install -d "$root/DEBIAN" "$root/usr/share/openappsec"

for entry in "${COMPONENTS[@]}"; do
    dir="${entry%%:*}"
    rest="${entry#*:}"
    artifact="${rest%%:*}"
    inner="${rest#*:}"

    src="$BUILD_OUT/$artifact"
    if [ ! -f "$src" ]; then
        echo "error: 'make package' did not produce $artifact (looked in $BUILD_OUT)" >&2
        exit 1
    fi

    dest="$root/usr/share/openappsec/$dir"
    install -d "$dest"
    # --noexec unpacks without running the inner script; --target chooses where.
    if ! sh "$src" --noexec --target "$dest" >/dev/null 2>&1; then
        echo "error: could not unpack $artifact" >&2
        exit 1
    fi
    if [ ! -f "$dest/$inner" ]; then
        echo "error: $artifact unpacked but has no $inner" >&2
        ls -la "$dest" >&2
        exit 1
    fi
    chmod 0755 "$dest/$inner"
    echo "unpacked $artifact -> usr/share/openappsec/$dir ($(du -sh "$dest" | cut -f1))"
done

echo "$VERSION" > "$root/usr/share/openappsec/VERSION"

installed_kb="$(du -sk "$root" | cut -f1)"

sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@ARCH@|$ARCH|g" \
    -e "s|@INSTALLED_SIZE@|$installed_kb|g" \
    "$here/control.in" > "$root/DEBIAN/control"

for script in postinst prerm postrm; do
    [ -f "$here/$script" ] && install -m 0755 "$here/$script" "$root/DEBIAN/$script"
done

mkdir -p "$OUTDIR"
deb="$OUTDIR/${PKGNAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$root" "$deb" >/dev/null

echo "built $deb"
dpkg-deb --info "$deb"
