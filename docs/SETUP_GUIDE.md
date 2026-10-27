# Guía de configuración

Helm es un cliente de terminal. No aloja nada: abre una conexión SSH a
una máquina tuya y se engancha a una sesión de [herdr](https://github.com/senna-lang/herdr)
que ya está corriendo ahí. Nada funciona hasta que esa máquina sea
alcanzable y confíe en tu dispositivo, así que casi toda esta guía es
sobre la Mac, no sobre la app.

Hay dos caminos y terminan en el mismo lugar.

- **[Automático](#automático-simulador-de-ios)** — un comando, solo simulador.
- **[A mano](#a-mano-cualquier-dispositivo)** — cinco pasos, sirve en todos lados.

> En un iPhone físico, Maestro a secas **no sirve**, pero sí hay
> automatización: ver
> [Automatizar un iPhone físico](#automatizar-un-iphone-físico).

El README cubre el resto del proyecto. Esta guía cubre solo poner la app
a funcionar por primera vez.

> Si la Mac todavía no tiene herdr, Pi ni Tailscale instalados, empezá
> por [`HOST_SETUP.md`](HOST_SETUP.md). Acá se asume que ya están.

---

## Qué tiene que estar listo antes

Tres cosas, y el script verifica las tres antes de hacer nada.

**1. Remote Login activado.** `System Settings → General → Sharing →
Remote Login`. Sin eso no hay nada escuchando en el puerto 22 y la app no
puede conectar.

**2. herdr instalado y corriendo.**

```bash
brew install herdr
herdr session list        # tiene que imprimir al menos una sesión
```

**3. Tailscale conectado**, en la Mac y en el teléfono, con la misma
cuenta. Es el único camino de red que documentamos: no hay modo local.

```bash
tailscale status
```

Para el stack completo — la integración del agente, Pi, los paquetes de
`gentle-pi` — ver [`HOST_SETUP.md`](HOST_SETUP.md).

**4. Maestro instalado**, para el camino automático.

```bash
curl -fsSL https://get.maestro.mobile.dev | bash
```

---

## Automático (simulador de iOS)

```bash
scripts/provision_simulator.sh
```

Eso es todo. Compila la app, la borra y reinstala, llena el formulario de
setup con valores leídos de tu propia Mac, lee la clave SSH generada
desde la app, la autoriza, relanza, y después comprueba que la sesión
realmente levantó.

> **Borra el simulador.** No es un efecto secundario: ver
> [Por qué hay que borrar el simulador](#por-qué-hay-que-borrar-el-simulador).
> Todo lo que tuvieras configurado ahí se pierde. Un simulador es estado
> descartable; tu Mac no se toca salvo por una línea agregada a
> `~/.ssh/authorized_keys`.

Para apuntar a un simulador específico en vez del que esté levantado:

```bash
xcrun simctl list devices        # buscar el UDID
scripts/provision_simulator.sh <udid>
```

---

## A mano (cualquier dispositivo)

### Paso 1 — preguntarle al host qué escribir

```bash
scripts/host_setup_report.sh
```

Imprime los cuatro valores que pide la pantalla de setup, y verifica que
el host pueda servirlos:

```text
== Setup fields ==
Profile Name : Mac (any label you like)
Port         : 22
Username     : vos
Host         : tu-mac.tailXXXXXX.ts.net

== Host readiness ==
sshd at tu-mac.tailXXXXXX.ts.net:22 : REACHABLE
herdr sessions visible : 1
  - default (default): running
```

**El Host es siempre el nombre MagicDNS**, también en el simulador. Un
simulador comparte la pila de red de la Mac, así que `127.0.0.1` ahí
llega — pero es un camino que ningún dispositivo real recorre. Una
configuración probada por loopback no prueba nada sobre la VPN que vas a
usar de verdad, y esa diferencia aparece recién en el teléfono.

> **Nunca una dirección**, ni la de la LAN ni la de Tailscale. La de la
> LAN deja de funcionar apenas salís de tu WiFi. La de Tailscale es
> estable por *registro de nodo*, no por máquina: una reinstalación o un
> logout/login le asigna otra, y el perfil queda apuntando a una
> dirección muerta. El síntoma es un "Connection lost" que parece
> problema de red y no lo es. El README lo explica en su sección Setup.

### Paso 2 — confiar el perfil (solo teléfono físico)

Salteá este paso en el simulador. En un teléfono, una app firmada con un
certificado de desarrollo **no arranca** hasta que la autorices a mano, y
la primera vez que la toques vas a ver esto:

> **Desarrollador no confiable**
>
> Tu configuración de administración de dispositivos no permite usar apps
> del desarrollador "Apple Development: tu@correo.com (XXXXXXXXXX)" en
> este iPhone. Puedes permitirlas en Configuración.
>
> [ Cancelar ]

**Ese diálogo solo ofrece Cancelar**, así que parece un callejón sin
salida. No lo es: la autorización vive en otra pantalla.

1. Tocá **Cancelar**.
2. **Ajustes → General → VPN y gestión de dispositivos**.
3. Entrá en **Apple Development: tu@correo.com**.
4. Tocá **Confiar en "Apple Development: tu@correo.com"** y confirmá
   **Confiar**.
5. Volvé a abrir Helm.

La frase "configuración de administración de dispositivos" es la
redacción estándar de iOS para cualquier desarrollador sin confiar. **No
significa que tu teléfono esté administrado por una empresa**, y aparece
igual en un equipo totalmente personal.

Desde la Mac el mismo bloqueo se ve así, sin mencionar en ningún lado que
la solución es un ajuste del teléfono:

```text
Unable to launch com.darkcodex.helm because it has an invalid code
signature, inadequate entitlements or its profile has not been
explicitly trusted by the user
```

> Con una cuenta de Apple gratuita el perfil **caduca cada 7 días**. Al
> vencerse la app deja de abrir y hay que reinstalarla; confiar el perfil
> es una sola vez por certificado, no por instalación.

#### Si en vez de la app ves una pantalla negra con texto

> In iOS 14+, debug mode Flutter apps can only be launched from Flutter
> tooling, IDEs with Flutter plugins or from Xcode.
>
> Alternatively, build in profile or release modes to enable launching
> from the home screen.

Entonces la app se instaló como **build debug**, y iOS no deja abrir esos
desde el home screen. **No es un problema de firma ni del perfil**, y
confiar el desarrollador otra vez no lo arregla.

La solución es reinstalar en release:

```bash
flutter build ios --release
xcrun devicectl device install app \
  --device <udid> build/ios/iphoneos/Runner.app
```

Un build debug solo sirve lanzado desde la Mac con `flutter run`. Para
usar la app en el teléfono, siempre `--release`.

### Paso 3 — llenar la app

Abrí Helm. En el primer arranque genera su propia clave SSH y te muestra
el formulario. Escribí los valores del paso 1 y guardá.

### Paso 4 — autorizar el dispositivo

La app muestra su clave pública en esa misma pantalla, y después en
`Settings → SSH key`. Tocá copiar, y entonces:

```bash
scripts/host_setup_report.sh --from-clipboard
```

Rechaza cualquier cosa que no sea una clave pública SSH parseable, y no
agrega la misma clave dos veces.

### Paso 5 — reiniciar la app

No es opcional ni superstición: ver
[Una pestaña conserva el perfil con el que se abrió](#una-pestaña-conserva-el-perfil-con-el-que-se-abrió).

---

## Dos ajustes del perfil que casi nadie encuentra

Se pueden pasar por alto sin que nada dé error, y los dos cambian el
comportamiento de la app lo suficiente como para parecer defectos.

### Session reference, o la app crea una sesión nueva cada vez

Si dejás **Session reference (optional)** vacío, la app **crea una sesión
de herdr nueva en cada conexión**. El síntoma es claro una vez que se
sabe: entrás y ves `tab 1`, `no agents`, y ninguno de tus workspaces,
mientras en la Mac se acumulan sesiones:

```text
$ herdr session list
default          running
helm-975e9b5a    running
helm-a2b322bf    running
helm-c7fc0e5d    running     <- una por cada conexión
```

Poné ahí el nombre de la sesión a la que querés engancharte — casi
siempre **`default`** — y la app entra a la tuya, con tus workspaces,
tus tabs y el estado real de tus agentes.

Para limpiar las sesiones huérfanas que hayan quedado hacen falta **dos**
comandos: `delete` solo acepta una sesión ya detenida.

```bash
herdr session list                 # ver cuáles sobran
herdr session stop <nombre>
herdr session delete <nombre>
```

O todas las `helm-*` de una vez, sin tocar `default`:

```bash
for s in $(herdr session list | awk '$1 ~ /^helm-/ {print $1}'); do
  herdr session stop "$s" && herdr session delete "$s"
done
```

### Set as default profile, o no hay reconexión automática

Un perfil creado con **+ Add profile** **no queda como default**. Sin
eso, cada vez que abrís la app aterrizás en "No active sessions" y hay
que tocar **New Session** a mano, y el paso 5 de esta guía no hace nada.

Activalo en el perfil: **Set as default profile — Opens automatically on
launch**.

---

## Cuando no funciona

### "Authentication failed"

La app llegó a tu Mac y tu Mac dijo que no. O la clave no está
autorizada, o el usuario está mal. Revisá los dos:

```bash
scripts/host_setup_report.sh
```

Compará el `Username` que imprime contra el de la app, y las huellas de
`Authorized device keys` contra la clave que muestra la app en
`Settings → SSH key`.

> Toda clave que genera Helm lleva el comentario `helm`, así que **los
> comentarios no distinguen nada**: tres instalaciones producen tres
> líneas idénticas a la vista. Solo la huella identifica un dispositivo.

### La conexión expira en vez de fallar

La app nunca llegó a la Mac. Dos causas, en este orden:

1. **Tailscale no está conectado** en alguno de los dos lados. Compro-
   balo con `tailscale status` en la Mac, y en la app del teléfono.
2. **El Host es una dirección y no un nombre.** `127.0.0.1` en un
   teléfono significa el teléfono.

El paso 1 lo detecta el propio script: sondea el puerto 22 **en el
nombre MagicDNS**, no en loopback, justamente porque loopback responde
aunque Tailscale esté desconectado.

### Conecta, pero no ves ninguno de tus workspaces

Entrás y aparece `tab 1`, `no agents`, y nada de lo que tenías abierto.
No es que la app no vea tu sesión: **creó una propia**. Falta llenar
**Session reference** en el perfil, explicado arriba en
[Session reference](#session-reference-o-la-app-crea-una-sesión-nueva-cada-vez).

### La app abre Home en vez de la pantalla de setup

Ya tiene una clave, así que no hay nada que configurar. Editá el perfil
existente desde Settings, o —en un simulador— corré
`scripts/provision_simulator.sh` para empezar limpio.

---

## Por qué las piezas son así

Cada una de estas costó una medición. Están escritas para que nadie las
pague dos veces.

### Por qué hay que borrar el simulador

Helm va a la pantalla de setup solo mientras no tenga una clave SSH, y
esa clave vive en el Keychain de iOS. El Keychain sobrevive al
`clearState` de Maestro **y** a `xcrun simctl uninstall`. Solo
`xcrun simctl erase` lo limpia.

Por eso `scripts/provision_simulator.sh` borra, y por eso
`maestro/run_ios.sh` borra una vez por flow y no una vez por corrida.

**No uses `maestro/run_ios.sh` para configurar un dispositivo que te
importe.** Borra antes de cada flow, así que la clave que acabás de
autorizar se descarta y la app genera una nueva.

### Una pestaña conserva el perfil con el que se abrió

Editar un perfil no actualiza una sesión que ya está abierta. Una
pestaña abierta antes del cambio sigue reintentando con los valores
viejos para siempre, y `Reconnect` reintenta con ese mismo estado
rancio. Solo relanzar hace que el auto-connect vuelva a leer el perfil
guardado.

Es una aspereza conocida, no un error de configuración.

### Automatizar un iPhone físico

**Maestro a secas no puede.** Necesita compilar y firmar su propio driver
de UITest contra tu equipo, y falla al registrar un identificador que no
es tuyo:

```text
Failed Registering Bundle Identifier: The app identifier
"dev.mobile.maestro-driver-ios" cannot be registered to your
development team because it is not available.
```

Ese identificador pertenece a **mobile.dev**. Ninguna otra cuenta puede
registrarlo, ni gratuita ni de pago, y Maestro no expone forma de
cambiarlo: el issue #2697 pide esa palanca y está cerrado sin
implementar. El comando `maestro driver-setup --apple-team-id <TEAM>`
existe, está oculto del `--help`, y falla igual.

**Sí funciona `maestro-runner`**, de DeviceLab. Corre los mismos YAML sin
cambios y sí deja elegir el identificador del agente:

```bash
curl -fsSL https://open.devicelab.dev/install/maestro-runner | bash

export DEVICELAB_IOS_AGENT_BUNDLE_ID=com.tunombre.devicelab.agent
maestro-runner --platform ios --team-id <TEAM_ID> \
  --device <udid> test maestro/provision/configure_profile.yaml
```

Verificado contra un iPhone 16 con iOS 26.7.1 y una cuenta personal de
Apple.

Tres cosas que conviene saber antes:

- **`DEVICELAB_IOS_AGENT_BUNDLE_ID` no es opcional** con cuenta personal.
  Sin esa variable falla igual que Maestro — aunque, a diferencia de
  Maestro, el error te dice exactamente qué variable poner.
- Se instala en `$HOME/.maestro-runner`, **sin `sudo`**, verifica
  checksum SHA-256 y **no toca tu instalación de Maestro**.
- Es **software de terceros**, no de mobile.dev.

Su `hierarchy` usa otro formato que el de Maestro (`type`/`text`/`id` en
vez de `attributes`), y `--compact` da una vista plana mucho más fácil de
grepear:

```bash
maestro-runner --platform ios --device <udid> --team-id <TEAM> \
  hierarchy --compact
```

`provision_simulator.sh` sigue siendo solo simulador, porque depende de
`simctl erase` y eso no existe para hardware.

### Por qué los flows están escritos así

Si vas a escribir tus propios flows de Maestro contra Helm — en
simulador, que es donde se puede — cuatro cosas se comportan distinto en
iOS de lo que esperarías. Las cuatro medidas sobre esta app.

**`- back` no hace nada en iOS** y aun así reporta `COMPLETED`, así que
el paso siguiente falla en la pantalla equivocada. Usá el gesto de
borde:

```yaml
- swipe:
    start: "2%, 50%"
    end: "90%, 50%"
```

**Dos corridas separadas de `maestro test` no comparten estado
transitorio.** Un menú que abrió una invocación ya está cerrado en la
siguiente. Todo lo que dependa de un overlay va en un solo flow.

**Dentro de un flow, el tap justo después de abrir un menú falla**
porque la animación sigue corriendo. Poné un `assertVisible` sobre el
destino primero; Maestro espera ahí.

**Los tiles de lista son un solo nodo con un salto de línea adentro.**
Una fila de perfil expone `"Mac\nvos@tu-mac.tailXXXXXX.ts.net:22"`, así
que un match exacto sobre el nombre falla. Usá
`tapOn: "(?s)Mac.*"` — el `(?s)` es obligatorio, porque `.` no cruza un
salto de línea.

**Los `Text` planos nunca llegan al árbol de accesibilidad de iOS.** Solo
llegan los nodos identificados, y por eso los flows direccionan todo a
través de `lib/core/testing/semantic_ids.dart` y afirman la copy visible
bajo `when: platform: Android`.

---

## Qué hay en cada lado

| Ruta | Qué es |
| --- | --- |
| `scripts/host_setup_report.sh` | Reporta los valores, verifica el host, autoriza una clave |
| `scripts/provision_simulator.sh` | Todo el camino automático, solo simulador |
| `maestro/provision/` | Flows que configuran una instalación real. No son tests |
| `maestro/flows/` | La suite de tests. En iOS se corre por `maestro/run_ios.sh` |
| `maestro/subflows/` | Bloques compartidos, no afirman nada por sí solos |
| `lib/core/testing/semantic_ids.dart` | Todos los identificadores que usan los flows |

`maestro/config.yaml` solo globa `flows/*.yaml`, así que nada de
`provision/` ni de `subflows/` se levanta jamás como test.
