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
- Teclado flotante con CTRL, ESC, TAB y flechas; abrilo u ocultalo desde el botón flotante
- Mové el panel desde el asa y ajustá su tamaño desde la esquina; si queda incómodo,
  restablecé la disposición con el botón de reinicio
- Posición y tamaño guardados en este dispositivo (`shared_preferences`), no por servidor
  ni en la exportación de perfiles; la posición se adapta al girar la pantalla
- Tamaño entre 370 y 600 píxeles lógicos de ancho y entre 144 y 480 de alto, limitado
  al espacio disponible; en ventanas más chicas, los límites se reducen y las teclas
  se pueden recorrer con desplazamiento
- El panel se superpone al terminal: mostrarlo, moverlo o redimensionarlo no cambia
  el tamaño de la sesión remota; para recorrer el terminal, arrastrá la vista (sin PgUp/PgDn)
- Autenticación biométrica antes de cualquier conexión
- Sesiones persistentes: el multiplexor mantiene todo vivo aunque cierres la app

**Archivos**

- Explorador SFTP sobre la conexión que ya está abierta, sin segundo handshake
- Creación de carpetas, renombrado y borrado de entradas en el host
- Descarga con progreso, cancelación y verificación de integridad
- En Android, guardado en una carpeta que elegís vos, vía Storage Access Framework
- Apertura con el visor del sistema (Word, PDF, imágenes)
- Subida al directorio que estás viendo en el host: primero elegís entre documentos
  o fotos y videos
- Selección múltiple de fotos y videos: cada elemento entra en una cola y se sube de
  a uno, con progreso del activo, conteos de terminados y restantes, y resultados
  por archivo; los terminados incluyen fallidos y cancelados, no solo los exitosos
- Cancelación de toda la cola desde una sola acción
- Si el nombre ya existe, se busca uno libre (`foto.jpg` → `foto(1).jpg`) y se informa
  el nombre con el que quedó guardado. La búsqueda tiene un límite de 100 candidatos
  (el original y 99 alternativas); si se agotan, se rechaza la subida: elegí otro nombre

**La subida y el selector de galería son solo para Android.** Storage Access Framework
no tiene contraparte en iOS; donde no se puede subir, la app no muestra el control.
El Photo Picker nativo requiere Android 13 o posterior, abre la galería real y no pide
permiso de almacenamiento. En versiones anteriores se usa el selector de documentos
filtrado a imágenes y videos: funciona, pero no tiene la misma interfaz de galería.

La búsqueda de nombre comprueba el destino antes de publicar, pero no es una garantía
atómica contra sobrescrituras: otro proceso puede ocuparlo entre la comprobación y el
renombrado final.

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
    files/        # Explorador SFTP, descarga, subida en cola, origen y destino SAF
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
2. La app genera una SSH key Ed25519 en memoria y la guarda con `flutter_secure_storage`
   (Keychain en iOS y almacenamiento seguro en Android)
3. Copiá la public key desde Settings y agregala en la Mac:
   ```bash
   echo "<public-key>" >> ~/.ssh/authorized_keys
   ```
4. Creá el perfil con el **nombre MagicDNS** de tu Mac, tu usuario y el puerto 22

   ```bash
   tailscale status --peers=false --json | grep -o '"DNSName": "[^"]*"'
   # → "DNSName": "tu-maquina.tailXXXXXX.ts.net."
   # --peers=false para que no liste también el nombre de los otros equipos
   ```

   Pegá ese nombre sin el punto final. También funciona el nombre corto
   (`tu-maquina`), pero el completo resuelve aunque el teléfono no esté aceptando
   el DNS de Tailscale.

   **No uses la IP de la LAN**: deja de conectar en cuanto salís de tu WiFi.
   **Y no uses tampoco la IP de Tailscale** (`tailscale ip -4`), aunque la
   documentación de Tailscale diga que no cambia. Es estable por *registro de
   nodo*, no por máquina: una reinstalación, un logout/login o una entrada nueva
   en el tailnet le asigna una IP distinta, y el perfil queda apuntando a una
   dirección muerta. El síntoma es un "Connection lost" que parece un problema
   de red y no lo es. El nombre MagicDNS sigue al nodo; la IP no.

   Con cualquiera de las dos opciones el túnel va directo por la red local
   cuando estás en casa, y sale por internet cuando no.
5. Probá con **Test Connection** antes de guardar

   Si venías usando la IP y cambiás el perfil al nombre, Helm lo trata como un
   host nuevo: va a fijar la clave del servidor en silencio, sin avisarte de
   ningún cambio, porque las claves se guardan por nombre de host. Aprovechá para
   comparar la huella contra la que imprime la Mac:

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

### Notificaciones (opcional)

Requiere provisionar FCM una vez y dejar el notifier corriendo en la Mac. El proyecto
Firebase solo transporta el push: el contenido lo compone la Mac y la credencial de envío
nunca sale de ella.

### Firma de release (Android)

`flutter build apk --release` funciona sin nada más, pero firma con el keystore de
debug: es compartido y público (viene con el SDK de Android), así que cualquiera
puede firmar un APK que Android acepte como "actualización" de Helm. El build te lo
recuerda con un warning bien visible cada vez que falta la firma real.

Para firmar de verdad:

1. Generá el keystore (elegí vos el password, no lo inventes acá ni lo anotes en
   el repo):
   ```bash
   keytool -genkey -v -keystore ~/helm-release.jks -keyalg RSA -keysize 2048 \
     -validity 10000 -alias helm
   ```
2. Creá `android/key.properties` (gitignorado a propósito, igual que el `.jks`):
   ```properties
   storePassword=<tu password>
   keyPassword=<tu password>
   keyAlias=helm
   storeFile=/ruta/absoluta/a/helm-release.jks
   ```
3. `flutter build apk --release` ahora firma con ese keystore y el warning desaparece.

**Guardá el `.jks` y el password en otro lado.** Si los perdés, no hay forma de subir
una actualización a un Helm ya instalado — Android la rechaza porque no coincide la
firma, y la única salida es desinstalar y reinstalar desde cero.

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

La subida de documentos y fotos/videos, la cola, los nombres libres y la disposición
flotante del teclado se ejercitaron solo con dobles de prueba. La validación de este
conjunto de cambios en un dispositivo real sigue pendiente.

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

[Apache License 2.0](LICENSE). Podés usarlo, modificarlo y redistribuirlo, incluso en
algo comercial, mientras conserves el aviso de copyright y la licencia.

Se eligió Apache-2.0 sobre MIT por dos cosas que a esta app le aplican: trae una
concesión explícita de patentes — MIT no dice nada al respecto, y esto implementa SSH y
criptografía — y su sección 5 hace que cualquier contribución que te manden quede bajo
los mismos términos sin que haya que acordarlo aparte.

Ojó: la licencia te deja redistribuir el código, pero el APK que sale de este repo sin un
keystore propio está firmado con la clave de debug. Ver *Firma de release* más arriba
antes de pasarle un build a alguien.
