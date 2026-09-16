# AVIATOR Sync iPhone v4.4

Natív SwiftUI + CoreBluetooth iPhone alkalmazás az AVIATOR F-Series Mark 1 / AVW79215G360 órához.

A Mac v4.4 működéséből átvéve:

- csak AVIATOR nevű BLE eszközök jelennek meg;
- csatlakozás / lecsatlakoztatás;
- idő- és dátumszinkron;
- napi lépésszám lekérése a `6E 01 1B 01 8F` paranccsal;
- akkumulátor lekérése külön a `6E 01 0F 01 8F` paranccsal, a gyári `raw × 5` értelmezéssel;
- távolság: 0,726 m/lépés;
- kcal kézi kalibráció;
- havi oszlopdiagram lépéshez, távolsághoz és kcal-hoz;
- diagnosztikai TX/RX napló;
- napi adatok helyi tárolása az iPhone-on.

## Build Xcode nélkül

1. Töltsd fel a projekt teljes tartalmát egy GitHub repositoryba.
2. GitHub → Actions → **Build AVIATOR Sync iPhone** → **Run workflow**.
3. A kész artifact neve: `AVIATOR-Sync-iPhone-unsigned`.
4. Az artifactban egy aláíratlan `.ipa` található.

Az aláíratlan IPA-t közvetlenül az iPhone nem telepíti. Sideloadly / AltStore / más aláíró eszköz szükséges hozzá, vagy Apple Developer tanúsítványos aláírás.
