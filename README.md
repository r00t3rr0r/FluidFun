# Cross-platform GPU fluid simulation

## macOS: Interaktiver Desktophintergrund

Der native WebKit-Host in `Desktop/` laeuft auf macOS 14 oder neuer.
Er zeigt auf jedem angeschlossenen Display eine eigene Simulation in allen Spaces,
hinter Desktop-Symbolen und normalen Fenstern. Das bestehende Hintergrundbild
wird nicht veraendert; beim Beenden erscheint es wieder.

```sh
sh Desktop/build.sh
open "Export/Fluid Wallpaper.app"
```

Das Wellen-Symbol in der macOS-Menueleiste bietet:

Im Hintergrundmodus ist das Web-Menue unsichtbar. Es erscheint nur,
wenn **Menues / Interaktion** aktiviert ist.

Cursorbewegungen wirken nur auf frei liegende Desktopbereiche. Sichtbare
Fenster, Dock und Menues unter dem Mauszeiger blockieren neue Fluid-Impulse.
Bereits erzeugtes Fluid bewegt sich weiter. Beim Zurueckkehren auf den Desktop
beginnt eine neue Zeichenbewegung ohne Verbindungsspur ueber das Fenster.

Die gewaehlte Quality wird nicht automatisch bei niedrigen FPS abgesenkt.
Die Stufen steuern Partikelzahl, Fluid-Texturgroesse, Solver-Iterationen und
Ausgabeaufloesung; der Laufzeitcheck prueft alle sechs Profile pro Display.

- **Auf Cursor reagieren**: Bewegungen zeichnen automatisch Fluid, auch wenn
	ein anderes Programm aktiv ist. Desktop-Symbole bleiben anklickbar.
- **Menues / Interaktion**: Holt die Simulation nach vorne und aktiviert die
	vorhandenen Menues oben rechts: Quality, Solver Iterations, Reset Particles
	und Stop Fluid. In diesem Modus mit gedrueckter Maustaste zeichnen.
	Danach denselben Menueleisten-Schalter erneut deaktivieren.
- **Quality (alle Displays)** und **Solver Iterations (alle Displays)**:
	Einstellungen direkt aus der macOS-Menueleiste aendern, ohne den
	Hintergrund nach vorne zu holen. Die Web-Menues aendern jeweils ihr Display.
- **Einstellungen pro Display**: Unter dem Bildschirmnamen Quality und
	Solver Iterations unabhaengig einstellen. Die angezeigten Fluid- und
	Ausgabegroessen sowie Partikelzahlen stammen direkt aus der Simulation.
	Die Auswahl bleibt beim Neuladen erhalten; ein globaler Qualitaetswechsel
	ueberschreibt die individuellen Einstellungen. Ein App-Neustart setzt sie zurueck.
- **Zaehigkeit**: Schieberegler von 0 bis 100 direkt in der macOS-Menueleiste
	fuer alle Displays, oder unter **Einstellungen pro Display** fuer einen
	einzelnen Bildschirm. 0 behaelt das bisherige Verhalten bei. Hoehere Werte
	glaetten Geschwindigkeitsunterschiede staerker und daempfen kleine Wirbel.
	Der Regler ist auch im Web-Menue des Interaktionsmodus vorhanden.
	Die Einstellung bleibt beim Neuladen und bei Qualitaetswechseln erhalten.
- **Reset Particles** und **Stop Fluid** in der macOS-Menueleiste wirken
	auf alle Displays. Angeschlossene und entfernte Displays werden automatisch erkannt.
- **Neu laden** und **Beenden**.

Es werden keine Bedienungshilfen- oder Bildschirmaufnahme-Rechte benoetigt.
Die globale Cursorposition wird abgefragt, Tastatureingaben werden nicht erfasst.
Der Hintergrund ist auf dem Sperrbildschirm nicht sichtbar. Er laeuft nur,
solange die App geoeffnet ist, und verwendet dauerhaft GPU-Ressourcen.
Fuer weniger Last im Originalmenue Quality auf Low oder UltraLow setzen.

High und UltraHigh verwenden beide 1.048.576 Partikel. Gegenueber Medium
(262.144 Partikel) kann die hoehere Dichte das Bild heller machen.
UltraHigh erhoeht gegenueber High die Fluidaufloesung pro Achse von 1/4 auf
1/2 der Canvasgroesse und die Solver-Iterationen von 20 auf 30. Die
Ausgabeaufloesung bleibt gleich. Auf dem externen 3840x1080-Display bedeutet
das 960x270 Fluidtexel bei High und 1920x540 bei UltraHigh; beide geben
3840x1080 aus. Eine feinere Simulation ist daher besonders in Bewegung
sichtbar, nicht zwangslaeufig als helleres oder schaerferes ruhendes Bild.

**SuperResolution** ist eine zusaetzliche Option in allen Quality-Menues.
Sie verdoppelt die tatsaechliche Canvas- und Ausgabeaufloesung pro Achse,
ohne die Desktopgroesse zu aendern. Die Fluidaufloesung entspricht dabei
der bisherigen vollen Canvasgroesse. Auf dem externen Display wird mit
7680x2160 ausgegeben und mit 3840x1080 Fluidtexeln simuliert. Die Ausgabe
wird auf 3840x1080 heruntergerechnet (Supersampling). Auf dem internen
Retina-Display liefert diese Option 3024x1964 statt 1512x982 Ausgabepixel.
Partikelzahl und Standard-Solver-Iterationen bleiben wie bei UltraHigh:
1.048.576 und 30. Diese Option erhoeht also echte Renderdetails statt
nur die Partikeldichte. Sie benoetigt deutlich mehr GPU-Leistung und Speicher;
Groessen oberhalb der GPU-Textur- oder Viewportgrenzen werden abgewiesen.

### Simulation und Build

Die Zaehigkeit wird durch einen impliziten GPU-Diffusionsschritt fuer das
Geschwindigkeitsfeld umgesetzt, nicht durch Aendern der Helligkeit oder
Partikelzahl. Bei Werten ueber 0 kommen zwoelf Jacobi-Iterationen und eine
Kopierpassage vor der Druckprojektion hinzu. Bei 0 ist der Zusatzschritt
ausgeschaltet. Die Skala ist dimensionslos, keine Angabe in SI-Einheiten.

`Desktop/build.sh` buendelt einen vorhandenen lokalen Build aus
`Export/html5/bin/`. Ohne diesen wird beim ersten Build die vom Originalautor
veroeffentlichte `GLFluid.js` ueber HTTPS geladen und in `Export/wallpaper-web/`
zwischengespeichert. Danach laeuft die App offline, ohne Analytics.
Dieser Fallback enthaelt keine lokalen Aenderungen am Haxe-Quellcode.
Der urspruengliche Lime-2.0.6-Build kann auf Apple Silicon an seinen
Intel-Bibliotheken scheitern; der native Host benoetigt nur die Xcode
Command Line Tools und aendert keine Haxe-Abhaengigkeiten.

Ein anderer Web-Export kann direkt geladen werden:

```sh
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --html /absoluter/pfad/index.html
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --url https://example.com/fluid/
```

Der Laufzeitcheck prueft Canvas, Menue, Mausereignisse und sichtbares Fluid
in einem WebKit-Snapshot und beendet sich danach:

```sh
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check
```

Die Pruefbilder liegen pro Display unter `Export/wallpaper-check-<display-id>.png`.
Die Fenstererkennung und Displaykoordinaten lassen sich separat pruefen:

```sh
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check-desktop
```

Die native Cursorweiterleitung auf frei liegenden Bereichen aller Displays
laesst sich ohne Bewegen des echten Mauszeigers pruefen:

```sh
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check-cursor
```

Dabei muss auf jedem Display ein Desktopbereich frei liegen. Der Fensterfilter
beruecksichtigt auch den nicht geteilten, bildschirmgrossen Dock-Backdrop,
den macOS auf einem externen Display melden kann. Normale Dock-Panels und
Anwendungsfenster bleiben blockierend.

Unterschiedliche Displayeinstellungen, ihre gemeldeten Renderwerte und ihr
Erhalt beim Neuladen lassen sich mit zwei angeschlossenen Displays pruefen:

```sh
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check-displays
```

Die hoeher aufgeloesten Ausgabe- und Fluidbuffer, ihre sichtbare Darstellung,
skalierte Cursorpositionen und getrennte Displayeinstellungen werden so geprueft:

```sh
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check --super-resolution
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check-cursor --super-resolution
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check-displays --super-resolution
```

Fuer automatischen Start kann die App in den macOS-Systemeinstellungen unter
Allgemein > Anmeldeobjekte hinzugefuegt werden.

Auf diesem Mac ist der automatische Start bereits als Benutzer-LaunchAgent
unter `~/Library/LaunchAgents/com.fluidfun.wallpaper.plist` eingerichtet.
Er startet die App bei der grafischen Anmeldung, nicht vor dem Login.
Die App muss am aktuellen Ort `Export/Fluid Wallpaper.app` bleiben.
Beenden ueber die Menueleiste bleibt moeglich; der Agent erzwingt keinen Neustart.
Zum Deaktivieren fuer die aktuelle Sitzung:

```sh
launchctl bootout "gui/$(id -u)/com.fluidfun.wallpaper"
```

Fuer dauerhaftes Deaktivieren danach die genannte LaunchAgent-Datei entfernen.

Der Zaehigkeitstest prueft die native Reglerweiterleitung und die GPU-Diffusion
an definierten Geschwindigkeitsfeldern. Der zweite Befehl prueft die sichtbare
Simulation mit aktivierter Zaehigkeit:

```sh
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check-viscosity
"Export/Fluid Wallpaper.app/Contents/MacOS/FluidWallpaper" --check --viscous
```

### [Demo](http://haxiomic.github.io/GPU-Fluid-Experiments/html5/)

This repo is a little old and dusty and likely doesn't build with the latest tools, If you're looking for a version with working build instructions check out [this fork: BathBombFluidDynamics](https://github.com/ollyc2015/BathBombFluidDynamics) by [Oliver Curtis](https://github.com/ollyc2015) which adds some interesting effects.

I'm currently working on a rewrite so watch this space :)

------

If you have an idea and you want to collaborate, feel free to get in touch with me [haxiomic@gmail.com](mailto:haxiomic@gmail.com)
