#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

app="$PWD/Export/Fluid Wallpaper.app"
web="$app/Contents/Resources/Web"
mkdir -p "$app/Contents/MacOS" "$web"
xcrun swiftc -O Desktop/FluidWallpaper.swift -o "$app/Contents/MacOS/FluidWallpaper"
cp Desktop/Info.plist "$app/Contents/Info.plist"

if [ -f Export/html5/bin/index.html ]; then
    cp -R Export/html5/bin/. "$web/"
else
    cache="$PWD/Export/wallpaper-web"
    mkdir -p "$cache"
    if [ ! -s "$cache/GLFluid.js" ]; then
        curl --fail --location --retry 2 \
            https://haxiomic.github.io/GPU-Fluid-Experiments/html5/GLFluid.js \
            --output "$cache/GLFluid.js"
    fi
    cp "$cache/GLFluid.js" "$web/GLFluid.js"
    cp Desktop/index.html "$web/index.html"
    cp Templates/html5/template/dat.gui.min.js Templates/html5/template/iconfont.css "$web/"
    cp -R Templates/html5/template/fonts "$web/"
fi
cp Desktop/viscosity.js "$web/viscosity.js"
cp LICENSE.txt "$app/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$app"
printf '\nApp: %s\nStart: open "%s"\n' "$app" "$app"