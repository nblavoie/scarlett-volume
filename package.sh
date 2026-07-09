#!/bin/bash
# Construit l'installeur .pkg : app → /Applications, driver → HAL,
# redémarrage de coreaudiod et ouverture de l'app en postinstall.
# Usage : ./package.sh [version]   (défaut : 1.0.0)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"

./build.sh

ROOT="build/pkgroot"
rm -rf "$ROOT" build/dist.xml build/component.pkg
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
echo "OK → build/Scarlett-Volume-$VERSION.pkg"
