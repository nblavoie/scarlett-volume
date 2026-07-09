#!/bin/bash
# Compile le driver virtuel « Scarlett Volume » (BlackHole renommé) puis l'app.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Scarlett Volume.app"
DRIVER="build/Scarlett Volume.driver"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"

# 1) Driver HAL : BlackHole compilé avec un nom personnalisé.
#    Le device expose un volume/mute natif → macOS gère touches + HUD système.
clang -O2 -fno-objc-arc -bundle \
  -framework CoreFoundation -framework CoreAudio -framework Accelerate \
  -DkDriver_Name='"Scarlett Volume"' \
  -DkHas_Driver_Name_Format=false \
  -DkDevice_Name='"Scarlett Volume"' \
  -DkPlugIn_BundleID='"com.kortexs.scarlett-volume.driver"' \
  -DkNumber_Of_Channels=2 \
  -o "$DRIVER/Contents/MacOS/Scarlett Volume" \
  driver/BlackHole.c
cp driver/Info.plist "$DRIVER/Contents/Info.plist"
cp driver/BlackHole.icns "$DRIVER/Contents/Resources/BlackHole.icns"
codesign --force --sign - "$DRIVER"

# 2) App de barre de menus (embarque le driver pour l'installer à la demande)
swiftc -O -o "$APP/Contents/MacOS/ScarlettVolume" main.swift \
  -framework Cocoa -framework CoreAudio -framework AVFoundation \
  -framework Accelerate -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cp -R "$DRIVER" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "OK → $APP"
