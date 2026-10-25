# MERIDIAN — Design-Dokument

*Ein ruhiges, perspektivisches Architektur-Puzzle in einem einzigen, zusammenhängenden Level.*

## 1. Game-Design-Übersicht

Eine kleine Wanderin trägt ein Licht durch ein schwebendes Monument, das sich spiralförmig um einen
zentralen Turm nach oben windet. Sie bewegt sich nur dorthin, wohin die Architektur sie lässt. Der Spieler
steuert nicht die Figur, sondern das Bauwerk: Er dreht Brücken, verschiebt Plattformen, betätigt Platten
und dreht schließlich die ganze Welt, bis sich Wege schließen, die es im gewöhnlichen Raum nicht gibt.

- **Plattform:** Desktop-Browser (Maus; Touch funktioniert ebenfalls).
- **Spielzeit:** ca. 15–25 Minuten.
- **Steuerung:** Klick auf ein Wegfeld → Figur läuft dorthin (Pfadsuche). Ziehen an Kurbeln/Knäufen →
  Architektur bewegt sich. Ziehen am Himmel (oder `Q`/`E`) → Welt dreht sich in 90°-Schritten (sobald freigeschaltet).
- **Kein** Inventar, keine Questmarker, keine Gegner, keine Zeitbegrenzung.

## 2. Visuelles Konzept

**Leitbild: „Ein Aufstieg von der Morgendämmerung in die Abenddämmerung.“**

| Bereich | Himmel / Dunst | Architektur | Akzent |
|---|---|---|---|
| Unten (Hof, Terrasse) | Mintgrün → Creme | Sand, Elfenbein | Türkis (Wasser), Orange (Zypressen) |
| Mitte (Drehbrücke, Gitterwerk) | Koralle → Pfirsich | Terrakotta, Koralle | Creme-Kappen, Türkis-Glyphen |
| Oben (Brücke, Krone, Gipfel) | Violett → Rosé | Elfenbein, Rosé | Violett, Gold |

- Flächen werden über **gerichtetes Licht** gelesen: Deckflächen hell, linke Flanken mittel, rechte Flanken dunkel.
- **Höhendunst:** Alles unterhalb des Monuments löst sich in der Hintergrundfarbe auf – das Bauwerk schwebt.
- **Weiche Schatten** von genau einer Lichtquelle; Hemisphärenlicht als Umgebungslicht.
- **Hintergrund:** Farbverlauf, entfernte, im Dunst versinkende Ruinen-Silhouetten, langsam treibende Lichtpartikel.
- **Kappen:** Jede begehbare Fläche trägt eine leicht hellere, minimal überstehende Deckplatte – sie definiert
  die visuelle Hierarchie „hier kann man gehen“ ohne Linien oder Marker.
- Interaktive Teile sind **elfenbeinfarben mit Koralle/Gold**, Platten tragen **türkise Glyphen**.

## 3. Kamera

- Orthografisch, **exakt isometrisch** (Blickrichtung `(±1, 1, ±1)`). Nur in dieser Projektion liegen Punkte, die sich
  um `k·v` unterscheiden, exakt übereinander – die mathematische Basis aller Täuschungen.
- Pro Zone eine komponierte Einstellung (Zielpunkt + Zoom). Weiche, gedämpfte Übergänge (kritisch gedämpfte Feder).
- **Weltdrehung** (ab Abschnitt 2): 90°-Schritte um die Hochachse, 1,2 s ease-in-out. Das Wegenetz wird nach jeder
  Drehung neu berechnet.

## 4. Mechaniken

| | Mechanik | Umsetzung |
|---|---|---|
| A | **Perspektivische Verbindung (Naht)** | Kanten mit Nahtmarkierung verbinden sich, wenn ihre Kantenmittelpunkte in der aktuellen Projektion zusammenfallen (`eB − eA ∥ v`) und entgegengesetzt zeigen. Überlagerung allein genügt nie. |
| B | **Drehbare Architektur** | Körper rotieren um definierte Pivot-Achsen in 90°-Schritten (Kurbel ziehen, beim Loslassen einrasten). Die Figur kann mitfahren, wenn erlaubt. |
| C | **Verschiebbare Bauteile** | Körper gleiten entlang einer Achse zu diskreten Haltepunkten (Knauf ziehen oder plattengesteuert). |
| D | **Vertikale Übergänge** | Treppen (Kanten mit unterschiedlichen Höhen), Aufzüge (Schieber mit Mitfahrer), aufsteigende Treppen. |
| E | **Kombination** | Platten setzen Mechanismen und schalten Kurbeln frei; Drehungen machen Platten erreichbar, deren Schieber Nähte vorbereiten. |
| – | **Weltdrehung** | Kameraquadrant 0–3 ist Teil des Puzzlezustands. |

### Navigationsregel (formal)
Jedes Wegfeld hat einen Standpunkt und bis zu vier offene Kanten (Richtung `d`, Kantenhöhe `h`).
Kantenpunkt `e = pos + d/2` mit `e.y = h`. Nach Anwendung der Körpertransformation gilt:
- Feld ist begehbar ⇔ transformierte Normale ≈ `+Y` und der Raum darüber ist frei (kein Festkörper).
- **Physische Kante:** `eA == eB` und `dA == −dB`.
- **Nahtkante:** beide Kanten nahtmarkiert, `dA == −dB`, `eA ≠ eB` und `(eB − eA) ∥ v`
  (geprüft über den projizierten Schlüssel `(e.x − v.x·e.y, e.z − v.z·e.y)`).
- Beim Überqueren einer Naht springt die Figur entlang `v` – auf dem Bildschirm unsichtbar.

## 5. Levelstruktur — „Meridian“ (ein zusammenhängendes, verschachteltes Bauwerk)

Der **Zentralturm** steht im Ursprung. Die Abschnitte liegen dicht übereinander: Das Gitterwerk (IV) steht direkt
über der Drehbrücke (III), die Drehscheibe (V) direkt am Ausgang des Gitterwerks, und das Schiebestück führt ohne
Zwischenwege per Naht an die Krone (VI). **Jede der vier Ansichten hat eine Aufgabe** (q3: erste Täuschung,
q0: Südbalkon, q1: Nordlandung, q2: Gipfel). Alle Stützen reichen bis in die Wolkendecke.

| # | Abschnitt | Mechanik | Lösung |
|---|---|---|---|
| I | Der Hof (y 0) | Platte P1 | Zur Platte laufen → Treppe steigt aus den Wolken |
| II | Die erste Täuschung (y 2) | Auge, Weltdrehung, Naht | Auge betreten → Welt drehen (q3) → Steg verbindet sich mit der hohen Insel B |
| III | Die Drehbrücke (y 4) | Rotator R1 (Mitfahren), P2 | R1 längs → aufsteigen → mitfahrend quer → Westbalkon P2 → zurück, mitfahrend längs → Nordplattform |
| IV | Das Gitterwerk (y 7–13) | Aufzug (Schieber, Mitfahren), P3, Tor | Aufzug auf 10 → unter dem oberen Steg hindurch zu P3 (öffnet Tor) → Aufzug auf 13 |
| V | Die Brücke der zwei Blicke (y 13) | L-Drehscheibe R5, P4, Schiebestück | R5 → Balkon P4 (Stück gleitet auf seiner Schiene in die Lücke) → R5 → Stück |
| VI | Die Krone (y 17) | Nähte q0/q1, P5, Kronen-Rotator R6 | q0: Stückende trifft den Südbalkon (P5 entsperrt die Krone) · q1: Stückende trifft die Nordlandung (P6) |
| VII | Die finale Wendung | P6, Lift, R6 mitfahrend, Naht q2 | P6 lässt den Gipfel aus den Wolken steigen → Krone nach Norden → mitfahrend nach Westen → Welt auf q2 → Gipfel |
| VIII | Abschluss | — | Licht in der Laterne, Lichtsäule, Türme wachsen aus den Wolken, Totale |

Kürzeste Lösung (vom Löser): 28 Aktionen. Laufwege zwischen Rätseln: meist 1–4 Felder.

**Lesbarkeit in jeder Ansicht:**
- *Cutaway:* Bauteile zwischen Kamera und Figur, den Griffen des aktuellen Abschnitts oder dessen offenen Platten
  werden weich durchscheinend und sind dann nicht mehr anklickbar.
- *Griffe:* Kurbeln sind um 45° versetzt, sodass die Griffe nie unter den Brückenarmen liegen; verdeckte Teile
  erscheinen als zarte Silhouette und bleiben greifbar.
- *Figur:* Silhouette durch Verdeckungen.
- *Ursache und Wirkung:* Jede Platte schickt ein Licht zu dem Teil, das sie bewegt; Griffe eines neuen Abschnitts
  pulsieren einmal.

Automatische Prüfungen (`tests/`):
- Ziel erreichbar, keine Sackgasse in irgendeinem erreichbaren Zustand, keine Durchdringung beweglicher Teile,
  jede Mechanik und die Weltdrehung notwendig, jede Naht wird benutzt (`solver.test.ts`).
- **Nichts schwebt:** Jeder Körper, jede Säule, jeder Bogen reicht in die Wolkendecke oder berührt (transitiv)
  etwas, das es tut; abgesenkte Lifte liegen vollständig in den Wolken (`support.test.ts`).

## 6. Technische Architektur

TypeScript + Three.js + Vite. Spiellogik ist vollständig vom Rendering getrennt und headless testbar.

```
src/
  core/        math, easing, tween (AnimationSystem), events
  logic/       types, LevelLogic (Transformationen, Wegenetz, Nähte), Puzzle (Zustand, Regeln), pathfinding
  level/       kit (Baukasten: Box, Treppe, Bogen, Kuppel …), level (das eine Level)
  render/      palette, materials, builder (Teile → Meshes), environment, character, camera, effects
  game/        Game (Orchestrierung), interaction, ui, audio, progress, debug
tests/         solver.test.ts, nav.test.ts
```

Systeme gemäß Vorgabe: SceneManager (`render/builder` + `Game`), CameraController, ArchitectureSystem
(`logic/LevelLogic` + `render/builder`), PuzzleSystem (`logic/Puzzle`), NavigationSystem (`logic/nav`),
CharacterController, InteractionSystem, AnimationSystem (`core/tween`), UIManager, AudioManager,
ProgressManager, DebugTools (Taste `` ` `` oder `?debug`).

## 7. Qualitätskriterien

- Jede Kante, Naht und Treppe wird vom Löser abgedeckt; das Level ist garantiert lösbar und ohne Sackgassen.
- Keine sichtbaren Teleports außer entlang der Blickachse (unsichtbar).
- Alle Bewegungen mit Easing; Drehungen mit Beschleunigung, leichtem Nachschwingen.
- 60 fps auf integrierter Grafik (eine Schattenquelle, geteilte Geometrien/Materialien, keine Allokation pro Frame im Hot-Path).
- UI verschwindet im Spiel bis auf einen kleinen Kreis-Knopf.
