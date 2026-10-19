# dist-build

Baut ein nginx-clojure-Binary-Distributionspaket — dasselbe Layout wie die
Upstream-Releases auf SourceForge, aber aus einer frei wählbaren nginx-Version
und dem C-Modul aus diesem Checkout.

Hintergrund: das letzte Upstream-Release (0.6.0, März 2023) liefert nginx 1.23.3
mit statisch gelinktem OpenSSL 3.1.0. OpenSSL 3.1.x ist seit 14. März 2025 EOL.
Wer nginx-clojure produktiv einsetzt, muss die Tarballs selbst bauen.

## Welches Script wofür

| Script | erzeugt | wann |
|---|---|---|
| `build-dist.sh` | **Linux x86-64** Binary **und das Tarball** | immer — das ist das Produktionsartefakt |
| `build-macos.sh` | **macOS arm64** Binary (`out/nginx-macosx`) | optional, nur lokale Entwicklung |
| `build-dist.sh --pack-only` | nur das Tarball neu, ohne Kompilieren | um ein macOS-Binary nachträglich einzupacken |

Wichtig: **nur `build-dist.sh` schnürt das Tarball.** `build-macos.sh` legt
allein das Binary in `out/` ab; eingepackt wird es beim nächsten
`build-dist.sh` (oder `--pack-only`).

Beide Scripts lesen dieselbe `versions.env` — nginx-Version, Proxy-Patch und
Debug-Flag sind also für Linux und macOS identisch.

### Fall 1: Nur Linux (der Normalfall)

```bash
cd dist-build
./build-dist.sh
```

Braucht nur Docker. Ergebnis:
`out/nginx-clojure-<modul>-nginx-<version>.tar.gz` mit `nginx-linux-x64`.

### Fall 2: Linux + macOS in einem Durchgang

```bash
cd dist-build
brew install openssl@3 pcre2   # einmalig
./build-macos.sh               # ~2 min, legt out/nginx-macosx ab
./build-dist.sh                # ~10 min, baut Linux und packt beide ein
```

Die Reihenfolge ist entscheidend — `build-dist.sh` packt ein, was beim Packen
in `out/nginx-macosx` liegt.

### Fall 3: macOS nachträglich zu einem fertigen Tarball

```bash
./build-macos.sh
./build-dist.sh --pack-only    # Sekunden, kein Rebuild
```

### Erster Build einer neuen nginx-Version

Ist die Version noch nicht in `versions.env` gepinnt, bricht `build-dist.sh` ab
und zeigt die SHA-256-Summe des Downloads. Einmal gegen die Upstream-Signatur
prüfen (siehe unten), eintragen, erneut starten.

## Was gebaut wird

| Komponente | Herkunft | Linkung |
|---|---|---|
| nginx | Quelle von nginx.org, Version aus `versions.env` | — |
| nginx-clojure C-Modul | dieses Repo, `--add-module=<checkout>/src/c` | — |
| OpenSSL | Quelle von openssl-library.org | statisch (siehe `OPENSSL_MODE`) |
| PCRE2 | Paket des Build-Systems | dynamisch |
| zlib | Paket des Build-Systems | dynamisch |

PCRE2 und zlib werden bewusst **nicht** aus dem Quellcode gebaut: das löst einen
Jobserver-Bug in GNU make 4.3 aus (Details im `Dockerfile`) und bringt nichts —
beide SONAMEs sind überall stabil und werden auf dem Zielhost von `apt`
gepatcht. Das ersetzt zugleich das veraltete PCRE1 8.40 der Upstream-Builds.

Unter Linux liefert das Build-Image die Pakete (`ubuntu:22.04`), unter macOS
Homebrew. Auf Apple Silicon wird für den Linux-Build `linux/amd64` per QEMU
emuliert — ein vollständiger Durchgang inklusive OpenSSL dauert dort rund 10
Minuten. nginx- und OpenSSL-Quellen landen in `cache/`, Folgebuilds sparen den
Download.

### Zum macOS-Binary

Es linkt Homebrew über absolute Pfade
(`/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib`) und läuft deshalb nur auf
Apple-Silicon-Macs mit installiertem `openssl@3` und `pcre2`. Für Produktion
wird ohnehin `nginx-linux-x64` verwendet.

Beachte: Homebrew liefert in der Regel eine andere OpenSSL-Version als die in
`versions.env` gepinnte, die statisch ins Linux-Binary wandert. Dev und Prod
haben damit unterschiedliche TLS-Stacks — für Handler-Entwicklung irrelevant,
bei TLS-nahen Tests im Hinterkopf behalten.

### Zielplattform-Kompatibilität

Das Binary linkt die glibc des Build-Images, läuft also nur auf Hosts mit
gleicher oder neuerer glibc:

| | glibc | Binary läuft? |
|---|---|---|
| `ubuntu:22.04` (Build-Image) | 2.35 | — |
| Ubuntu 20.04 | 2.31 | **nein** |
| Ubuntu 22.04 | 2.35 | ja (exakt gleich) |
| Ubuntu 24.04 | 2.39 | ja |

Bis 1.30.4 war `debian:bullseye` (glibc 2.31) das Build-Image und deckte auch
Ubuntu 20.04 ab. Seit dem Ende des Bullseye-LTS (Oktober 2026) liefert dessen
Security-Mirror keine Pakete mehr, `apt-get install` im Build scheitert mit 404.
Ubuntu 20.04 ist deshalb kein Ziel mehr.

Ubuntu 22.04 ist jetzt der Grenzfall: identische glibc, **kein Puffer**. Ein
Wechsel auf `debian:bookworm` (glibc 2.36) würde 22.04 ausschließen.
`BASE_IMAGE` deshalb nicht ohne Prüfung der Zielhosts anheben.

Dynamisch gelinkt werden `libpcre2-8.so.0`, `libz.so.1`, `libcrypt.so.1` und
`libdl.so.2` — alle vier sind in den nackten Ubuntu-Images 22.04/24.04
bereits vorhanden, es muss nichts nachinstalliert werden. OpenSSL ist statisch
einkompiliert (siehe unten).

## Modulauswahl — projektspezifisch

Die Auswahl in `container-build.sh` ist **auf das konsumierende Projekt
zugeschnitten**, nicht generisch. Enthalten ist, was dessen nginx-Konfiguration
tatsächlich verwendet:

- `http_ssl_module`, `http_stub_status_module`

Dazu als billige Reserve: `http_v2_module`, `realip`, `gunzip`, `gzip_static`,
`sub`.

Bewusst **weggelassen**, obwohl im Upstream-0.6.0-Binary enthalten:

- `http_mp4_module` — hier saß CVE-2024-7347
- `http_dav_module`, `http_flv_module`, `http_random_index_module`,
  `http_secure_link_module`, `http_addition_module`, `http_image_filter_module`
- `mail` / `mail_ssl_module`

Wird eine dieser Direktiven gebraucht, das Flag in `container-build.sh` **und**
`build-macos.sh` wieder aktivieren — nginx quittiert sonst beim Start mit
`unknown directive`.

## OPENSSL_MODE

`static` (Default) entspricht dem Upstream-Verhalten: OpenSSL wird ins Binary
kompiliert. Der Tarball läuft auf jeder Distribution, aber **jede OpenSSL-CVE
erfordert einen neuen Build**. Genau so bleibt man auf einem OpenSSL von 2023
sitzen.

`system` linkt gegen die libssl des Build-Images. Dann patcht `apt upgrade` auf
dem Zielhost OpenSSL mit — deutlich weniger Wartungsaufwand. Preis: `BASE_IMAGE`
muss exakt der Zieldistribution entsprechen, und der Tarball ist nicht mehr
distributionsunabhängig.

## SHA-256 verifizieren

Einmal pro neuer Version, bevor der Hash in `versions.env` gepinnt wird:

```bash
cd cache
curl -fsSLO https://nginx.org/download/nginx-1.28.0.tar.gz.asc
curl -fsSL https://nginx.org/keys/pluknet.key | gpg --import
gpg --verify nginx-1.28.0.tar.gz.asc nginx-1.28.0.tar.gz
shasum -a 256 nginx-1.28.0.tar.gz
```

Der Signierschlüssel wechselt je nach Release-Manager — die passende `.key`-Datei
steht auf <https://nginx.org/en/pgp_keys.html>. Für 1.30.4 war es `arut.key`, für 1.30.6 `pluknet.key`.

Für OpenSSL analog, hier über den Fingerprint der Signatur:

```bash
curl -fsSLO https://github.com/openssl/openssl/releases/download/openssl-3.5.6/openssl-3.5.6.tar.gz.asc
gpg --verify openssl-3.5.6.tar.gz.asc openssl-3.5.6.tar.gz   # zeigt den Key an
curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/<FINGERPRINT>" | gpg --import
gpg --verify openssl-3.5.6.tar.gz.asc openssl-3.5.6.tar.gz
```

Den Fingerprint danach gegen die Liste auf <https://openssl-library.org/source/>
abgleichen. `gpg --recv-keys` scheitert je nach Netz an den Keyservern — der
VKS-Endpunkt oben geht über normales HTTPS und funktioniert auch dann.

Gepinnt werden nur nginx und OpenSSL — die einzigen beiden Quellen, die dieses
Kit herunterlädt. PCRE2 und zlib kommen als Distributions- bzw. Homebrew-Pakete.

## Der Proxy-Patch

Das nginx-clojure-Projekt pflegt einen eigenen nginx-Fork
(`github.com/nginx-clojure/nginx`), der gegenüber Upstream **genau eine**
Änderung enthält: zwei identische Zeilen in `ngx_http_proxy_create_request()`,
damit in einem Rewrite-Handler entfernte Header vor `proxy_pass` korrekt
ignoriert werden.

`container-build.sh` wendet diese Änderung per `sed` an und bricht ab, wenn
nicht exakt zwei Fundstellen existieren — das ist das Frühwarnsignal, dass nginx
den Code umgebaut hat und der Patch überprüft werden muss.

Abschalten mit `APPLY_PROXY_PATCH=no` in `versions.env`.

## Versionskopplung C-Modul ↔ JAR

C-Modul und `nginx-clojure`-JAR prüfen sich beim Start gegenseitig. Beide Seiten
verlangen aktuell nur `>= 0.5.2` (`nginx_clojure_required_rt_lver` in
[src/c/ngx_http_clojure_mem.h](../src/c/ngx_http_clojure_mem.h) bzw.
`NGINX_CLOJURE_RT_REQUIRED_LVER` in
[src/java/nginx/clojure/MiniConstants.java](../src/java/nginx/clojure/MiniConstants.java)).

Ein aus dem master-Stand (0.6.1) gebautes Modul läuft daher mit einem
vorhandenen 0.6.0-JAR — das JAR muss nicht neu gebaut werden. Wird die
Untergrenze irgendwann angehoben, meldet nginx beim Start:
`too low version jar of nginx-clojure, we need at least X.Y.Z`.

## Nach jedem Versionswechsel prüfen

Der Compiler findet nur einen Teil der Probleme. Das Modul hängt tief im
Request-Lifecycle (`r->count`, Body-Filter-Kette, eigener Upstream-Socket-Stack
in [src/c/ngx_http_clojure_socket.c](../src/c/ngx_http_clojure_socket.c)), und
dort ändert nginx zwischen Versionen still Dinge. Vor dem Rollout mindestens:

1. Die Integrationstest-Suite dieses Repos:
   `test/nginx-working-dir/conf/*.conf` plus
   `lein with-profile cljremotetest test :all` — und zwar in dem Modus, der
   produktiv läuft (thread-pool vs. coroutine)
2. `nginx -t` mit der echten, gerenderten Zielkonfiguration
3. Alle Routen durchspielen, die einen Java-Handler treffen
4. Lasttest — Lifecycle-Bugs zeigen sich als Hänger oder Segfault unter Last,
   nicht beim ersten Request
5. `logs/*error.log` auf `[alert]` / `[emerg]` prüfen

## Tarball in ein Zielprojekt übernehmen

Das fertige `out/*.tar.gz` von Hand ins konsumierende Projekt kopieren.

Achtung, wenn dessen Setup das Archiv per Glob sucht (etwa
`tar xvfz sources/*.tar.gz`): dann darf dort nur genau ein Archiv liegen — das
vorherige also vorher wegräumen.

## Verzeichnisse

```
cache/         heruntergeladene Quell-Tarballs (git-ignoriert)
out/           Build-Ergebnis inkl. fertigem .tar.gz (git-ignoriert)
build-macos/   Arbeitsverzeichnis des macOS-Builds (git-ignoriert)
```

## Lizenz

Copyright © Pathmate Technologies AG. Veröffentlicht unter der BSD 3-Clause
License — derselben Lizenz wie das umgebende nginx-clojure-Projekt, siehe
[../LICENSE](../LICENSE).
