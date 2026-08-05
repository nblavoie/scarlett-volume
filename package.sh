#!/bin/bash
# Build the .pkg installer: app → /Applications, driver → HAL,
# restart coreaudiod and open the app in postinstall.
# Usage: ./package.sh [version]   (default: 1.0.0)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"

./build.sh

# pkgroot in a temp folder: pkgbuild sets its contents to root:wheel,
# so it must not live in build/ (otherwise the following rm -rf fails)
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scarlett-volume-pkgroot.XXXXXX")"
rm -f build/dist.xml build/component.pkg
mkdir -p "$ROOT/Applications" "$ROOT/Library/Audio/Plug-Ins/HAL"
cp -R "build/Scarlett Volume.app" "$ROOT/Applications/"
cp -R "build/Scarlett Volume.driver" "$ROOT/Library/Audio/Plug-Ins/HAL/"

pkgbuild --root "$ROOT" \
  --scripts installer/scripts \
  --identifier com.kortexs.scarlett-volume \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  build/component.pkg

cat > build/dist.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Scarlett Volume</title>
    <options customize="never" rootVolumeOnly="true"/>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="Scarlett Volume">
        <pkg-ref id="com.kortexs.scarlett-volume"/>
    </choice>
    <pkg-ref id="com.kortexs.scarlett-volume" version="$VERSION">component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild --distribution build/dist.xml --package-path build \
  "build/Scarlett-Volume-$VERSION.pkg"
rm -f build/component.pkg build/dist.xml
rm -rf "$ROOT" 2>/dev/null || true
echo "OK → build/Scarlett-Volume-$VERSION.pkg"
