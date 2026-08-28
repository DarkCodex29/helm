# Helm

App Flutter para manejar los agentes de código que corren en tu Mac, desde el celular.

No es un terminal genérico. Está construida alrededor de una idea concreta: los agentes
corren en la Mac, la Mac es la que sabe cuándo te necesitan, y el teléfono es la superficie
para atenderlos desde cualquier lado.

## Qué hace

**Terminal**

- Terminal SSH real con renderizado TUI completo (colores, alternate screen, 256 colores)
- Pestañas, cada una adjunta a una sesión del multiplexor en la Mac
- Multiplexores soportados: **herdr** (primario), tmux y zellij
- Drawer de proyectos con el estado de cada agente en vivo (working / idle / blocked)
- Barra de teclas especiales: CTRL, ESC, TAB, flechas, PgUp/PgDn
- Autenticación biométrica antes de cualquier conexión
- Sesiones persistentes: el multiplexor mantiene todo vivo aunque cierres la app

**Archivos**

- Explorador SFTP sobre la conexión que ya está abierta, sin segundo handshake
- Descarga con progreso, cancelación y verificación de integridad
- Guardado en una carpeta que elegís vos, vía Storage Access Framework
- Apertura con el visor del sistema (Word, PDF, imágenes)

**Notificaciones**

- Push nativo: cuando un agente te necesita o termina, te llega al teléfono con la app cerrada
- La notificación dice qué agente, en qué proyecto, y qué estaba haciendo
- Tocarla abre esa sesión
- Una notificación por agente: dos agentes no se pisan

**Segundo plano**

- Un perfil puede pedir que su sesión se mantenga conectada mientras estás en otras apps
- Corre como foreground service con notificación persistente y botón de parada
- Se apaga solo tras 4 horas sin que vuelvas a la app

## Arquitectura

Helm tiene dos mitades, y eso es deliberado.

```
┌─────────────────────┐         ┌──────────────────────────────┐
│  Teléfono (helm)    │         │  Mac                         │
│                     │  SSH    │                              │
│  terminal ──────────┼────────▶│  herdr / tmux / zellij       │
│  explorador SFTP    │         │    └── agentes de código     │
│                     │         │                              │
│  notificaciones ◀───┼─ FCM ───┼── helm-notifier (LaunchAgent)│
└─────────────────────┘         └──────────────────────────────┘
```

**El teléfono no vigila. La Mac avisa.** Un socket abierto desde el celular no sobrevive a
iOS ni es barato en Android, así que quien detecta que un agente cambió de estado es un
daemon en la Mac, suscrito al socket de herdr. Ese daemon firma su propio push y lo manda
directo a FCM: no hay servicio intermedio ni cuenta de terceros.

### Componente del host

Vive fuera de este repo, en `~/helm-notifier/`:

| Archivo | Rol |
|---|---|
| `notifier.py` | Se suscribe a `events.subscribe` de herdr, enriquece el evento y entrega |
| `fcm.py` | Firma un JWT con `openssl` y empuja a FCM HTTP v1 |
| `provision_fcm.py` | Provisiona la credencial una sola vez |

Se instala como LaunchAgent (`~/Library/LaunchAgents/com.gian.helm-notifier.plist`).
Usa solo el Python del sistema y `openssl` — sin dependencias que un `brew upgrade` pueda
huerfanizar meses después.

### Estructura del código

```
lib/
  core/
    constants/   host/       # Contrato del host, adaptadores de multiplexor, probe
    router/      testing/    # GoRouter + guards, ids semánticos para tests
    theme/       utils/
  features/
    auth/         # Gate biométrico
    connection/   # SSH, llaves, perfiles, confianza de host keys
    files/        # Explorador SFTP, descarga, destino SAF
    notifications/# Push, presentación local, ruteo a sesión
    session_hold/ # Foreground service y su ciclo de vida
    settings/     # CRUD de perfiles
    setup/        # Primer arranque
    shortcuts/    # Drawer de proyectos
    terminal/     # Emulación, pestañas, teclado
android/app/src/main/kotlin/com/darkcodex/helm/
  SessionHoldService.kt   # El foreground service (no ejecuta Dart)
  SessionHoldPlugin.kt    # Puente method/event channel
```

## Requisitos

### En la Mac

- **SSH habilitado** — `System Settings → General → Sharing → Remote Login`
- **Un multiplexor** — `brew install herdr` (recomendado), o tmux, o zellij
- **Tailscale** — para llegar desde fuera de la red local
- **La integración de tu agente en herdr** — `herdr integration install opencode`
  (o `claude`, `codex`, etc.). Sin ella herdr detecta el estado leyendo la pantalla;
  con ella el agente lo reporta directo.

### En el celular

- **Tailscale**, conectado a la misma cuenta que la Mac

## Setup

1. Abrí Helm y autenticá con huella o Face ID
2. La app genera una SSH key Ed25519 en el Keystore / Secure Enclave
3. Copiá la public key desde Settings y agregala en la Mac:
   ```bash
   echo "<public-key>" >> ~/.ssh/authorized_keys
   ```
4. Creá el perfil con la **IP de Tailscale** de tu Mac (`tailscale ip -4`), tu usuario y el puerto 22

   Usá la IP de Tailscale, no la de la LAN: funciona en los dos lados. En casa el túnel va
   directo por la red local, y afuera sale por internet. Con la IP de la LAN el perfil
   deja de conectar en cuanto salís de tu WiFi.
5. Probá con **Test Connection** antes de guardar

### Notificaciones (opcional)

Requiere provisionar FCM una vez y dejar el notifier corriendo en la Mac. El proyecto
Firebase solo transporta el push: el contenido lo compone la Mac y la credencial de envío
nunca sale de ella.

## Stack

| Componente | Versión |
|---|---|
| Flutter / Dart | 3.41.7 / 3.11.5 (`sdk: ^3.11.3`) |
| SSH y SFTP | `dartssh2` 3.3.1 |
| Terminal | `xterm` 4.0.0 |
| Estado | `flutter_riverpod` 2.6.1 — **`Notifier` manual, no code-gen `@riverpod`** |
| Navegación | `go_router` 14.6.3 |
| Modelos | `freezed` 2.5.7 |
| Biometría | `local_auth` 2.3.0 |
| Llaves | `flutter_secure_storage` 10.0.0 |
| Push | `firebase_core` 4.14.0, `firebase_messaging` 16.6.0 |
| Notificaciones | `flutter_local_notifications` 22.3.0 |
| Almacenamiento Android | `saf_util` 2.2.0, `saf_stream` 2.0.0 (pineadas: las 3.x piden Dart ^3.12) |
| Archivos | `path_provider`, `open_filex` 4.7.0 |

Android `minSdk 24`, `targetSdk 36`. iOS 15+.

## Desarrollo

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze     # tiene que quedar limpio
flutter test        # 1303 tests
flutter build apk --debug
```

Dos cosas que conviene saber antes de tocar el repo:

- **No corras `dart format`.** El repo no está format-clean y reescribe ~60 archivos ajenos.
- **Los tests viajan con su código** y no cuentan contra el presupuesto de revisión de
  400 líneas, que mide solo producción.

### Verificar en un dispositivo

```bash
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Cuatro trampas ya pagadas, para no repetirlas:

- **`am force-stop` borra las notificaciones de la app** y marca el paquete como detenido,
  lo que bloquea la entrega de FCM. Para matar el proceso conservando notificaciones: `am kill`.
- **FCM revive el proceso** para entregar un push. Para un arranque en frío real hay que
  matar *después* de que la notificación llegó.
- **Maestro no puede tocar el panel de notificaciones** — está hecho para la app bajo prueba,
  y el panel es systemui. Reporta éxito y no activa nada.
- **Los logs de Dart salen con tag `flutter`** (`adb logcat -s flutter:V`). El prefijo
  `[TabsNotifier]` es parte del mensaje, no del tag.

Y una de método: cualquier verificación que requiera que la app **conecte** necesita la
huella. Tras matar el proceso la app queda en el prompt biométrico y no avanza — eso es el
diseño de seguridad funcionando, no un bug.

## Licencia

Proyecto personal. No distribuido públicamente.
