# El stack del host

Helm no corre agentes: los mira. Todo lo que ves en la app vive en tu
Mac, dentro de un multiplexor. Este documento arma ese lado.

Si solo querés conectar la app a una Mac que **ya** tiene todo esto,
andá a [`SETUP_GUIDE.md`](SETUP_GUIDE.md). Este documento es el paso
anterior: dejar la Mac en condiciones de que valga la pena conectarse.

## Las piezas

| Pieza | Qué aporta | Obligatoria |
| --- | --- | --- |
| **herdr** | El multiplexor. Sesiones, workspaces, pestañas, y el estado de cada agente | Sí (o tmux/zellij, con menos) |
| **Pi** | El agente de código que corre dentro de cada pestaña | No, pero es el punto |
| **gentle-pi** | Convierte a Pi en un orquestador con disciplina de trabajo | No |
| **Tailscale** | El único camino de red hasta la Mac | Sí, siempre |
| **whisper.cpp** | Transcribe el dictado por voz en la Mac | Solo para la voz |
| **helm-notifier** | Avisa al teléfono (FCM) cuando un agente se bloquea o termina; vive en `host/notifier/` | Solo para las notificaciones |

Helm habla con **herdr, tmux o zellij**. Con tmux y zellij tenés
terminal; con herdr además tenés el estado de los agentes (trabajando,
bloqueado, terminado), que es lo que hace útil mirar desde el teléfono.

---

## 1. Acceso remoto

```bash
sudo systemsetup -setremotelogin on
```

Esto expone el puerto 22. Con Tailscale ese puerto queda alcanzable
únicamente desde tu propio tailnet, no desde internet.

Equivale a `System Settings → General → Sharing → Remote Login`. Pide
contraseña de administrador, y según la versión de macOS puede requerir
que tu terminal tenga Full Disk Access; si falla, hacelo desde la
interfaz.

Verificalo sin confiar en el mensaje de salida:

```bash
nc -z 127.0.0.1 22 && echo "escuchando"
```

Es el único lugar de esta guía donde loopback es la pregunta correcta,
porque acá todavía no hay VPN y lo único que se está preguntando es si
`sshd` arrancó. De acá en adelante todo se verifica contra el nombre
MagicDNS.

## 2. Tailscale

Instalalo en la **Mac y en el teléfono**, con la misma cuenta.

```bash
brew install --cask tailscale
```

El perfil de la app usa el **nombre MagicDNS**, nunca una dirección:

```bash
tailscale status --peers=false --json | grep -o '"DNSName": "[^"]*"'
```

`scripts/host_setup_report.sh` ya lo resuelve e imprime. El README
explica en su sección Setup por qué una dirección es la respuesta
equivocada.

> **No hay camino local, a propósito.** Un simulador de iOS comparte la
> pila de red de la Mac, así que `127.0.0.1` ahí funciona — y por eso
> mismo es una trampa: es un camino que ningún teléfono recorre. Los
> scripts usan el nombre MagicDNS incluso en el simulador, para que lo
> que probás sea lo que vas a usar. `provision_simulator.sh` se niega a
> correr si no encuentra un nombre MagicDNS, en vez de caer en loopback.

## 3. herdr

```bash
brew install herdr
```

Verificado contra `herdr 0.9.0`. Arranca como LaunchAgent, así que
**necesita una sesión gráfica iniciada**: si la Mac está apagada o
nadie hizo login, las sesiones vuelven vacías y la app muestra un
terminal sin nada.

```bash
herdr session list        # al menos una sesión corriendo
herdr status              # el servidor tiene que decir running
```

### La integración del agente

Sin ella herdr adivina el estado del agente leyendo la pantalla. Con
ella, el agente lo reporta directo, y eso es lo que la app muestra como
*trabajando / bloqueado / terminado*.

```bash
herdr integration install pi
```

Hay integraciones para `claude`, `codex`, `opencode`, `copilot`,
`cursor`, `grok`, `qwen` y varias más. Instalá la del agente que uses:
`herdr integration` sin argumentos las lista todas.

## 4. Pi

Pi es un paquete de npm. Verificado contra **Pi 1.4.0** sobre Node 24.

```bash
npm install -g @earendil-works/pi-coding-agent
pi --version
```

Después hay que autenticarlo contra tu proveedor de modelos:

```bash
pi auth
```

> **Esto no se puede automatizar y no se debe compartir.** Son tus
> credenciales, viven en `~/.pi/agent/auth.json`, y no salen de tu
> máquina. Lo mismo vale para `~/.pi/agent/mcp.json`: la configuración
> de MCP suele contener tokens.

## 5. gentle-pi y el resto de los paquetes

`gentle-pi` convierte a Pi en un orquestador con flujo de trabajo
explícito. Verificado contra **gentle-pi 4.3.0**.

Pi instala sus propios paquetes:

```bash
pi install npm:gentle-pi
```

Esta es la lista completa que usa esta máquina, tal como queda en
`~/.pi/agent/settings.json` bajo `packages`:

```bash
pi install npm:gentle-pi          # orquestador y disciplina de trabajo
pi install npm:pi-lens            # LSP, diagnósticos, ast-grep
pi install npm:pi-background-tasks # tareas en segundo plano
pi install npm:pi-intercom        # mensajes entre sesiones de Pi
pi install npm:pi-web-access      # búsqueda y fetch
pi install npm:pi-claude-bridge   # puente a modelos de Anthropic
pi install npm:pi-btw             # conversaciones laterales
pi install npm:gentle-engram      # memoria persistente entre sesiones
```

Ninguno es obligatorio para que Helm funcione: Helm solo necesita un
multiplexor con algo corriendo adentro. Están acá porque son el setup
que esta máquina usa, y porque `gentle-pi` y `gentle-engram` son los
que cambian cómo se comporta el agente que vas a mirar desde el
teléfono.

Comprobá qué quedó instalado:

```bash
pi list
```

## 6. whisper.cpp, para el dictado por voz

Solo hace falta si vas a usar el botón de micrófono. El teléfono graba y
**la Mac transcribe**: el audio viaja por la misma conexión SSH, se
transcribe local y se borra. Nada sale a un servicio de terceros.

```bash
brew install whisper.cpp
whisper-cli --help | head -1
```

Verificado contra **whisper.cpp 1.9.2**. La fórmula se llamó
`whisper-cpp` antes; `brew` resuelve el nombre viejo igual. El binario
queda como `whisper-cli`, no `whisper.cpp`.

### El modelo hay que bajarlo aparte

Homebrew **no** descarga modelos, y lo dice en sus caveats. Helm espera
`ggml-large-v3-turbo`, que es el que tiene los números medidos en
`odd/tasks/voice-and-share-input.md`: 0.26x tiempo real, y con el prompt
de vocabulario corre **más rápido** que sin él.

```bash
mkdir -p ~/.cache/whisper-cpp
curl -L -o ~/.cache/whisper-cpp/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

**Pesa ~1.6 GB.** Esa ruta exacta es la que Helm busca por defecto, así
que cualquier otra ubicación necesita configurar `modelPath` a mano.

Comprobá que carga antes de depender de él:

```bash
whisper-cli -m "$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin" \
  -f /dev/null -nt -np; echo "exit=$?"
```

Un `exit=3` con *"failed to initialize whisper context"* significa que no
encontró el modelo. **Medido**: pasarle el NOMBRE del modelo en vez de la
ruta al `.bin` falla exactamente así — `whisper-cli` no resuelve nombres.

> Un modelo más chico (`ggml-base`, ~150 MB) también funciona y baja
> mucho más rápido, a costa de precisión en términos técnicos. Si lo
> usás, apuntá `modelPath` ahí.

### gentle-ai (opcional, aparte)

`gentle-pi` es un paquete de Pi. `gentle-ai` es una herramienta de línea
de comandos distinta, de la misma familia, que se instala por Homebrew:

```bash
brew install gentleman-programming/tap/gentle-ai
```

Esta máquina la usa para CodeGraph (`gentle-ai codegraph init`). No
hace falta para Helm.

### helm-agentd (opcional, agentes desde el teléfono)

El daemon que maneja Pi en modo RPC y sirve el protocolo al teléfono vive en
`packages/helm_agentd`. Se instala como LaunchAgent con `host/agentd/install.sh`, que
**compila** el daemon (`dart compile exe`) para que launchd no dependa de un SDK de Dart.

```bash
host/agentd/install.sh --dry-run   # muestra el plan, no escribe ni compila nada
host/agentd/install.sh             # compila, renderiza el plist, imprime el launchctl
host/agentd/install.sh --load      # igual, y además ejecuta launchctl bootstrap
```

- **Escucha solo en la IP de Tailscale.** La resuelve con `tailscale ip -4` (la primera
  línea, que debe estar en `100.64.0.0/10`) o la tomás con `--host IP`. Un valor fuera de ese
  rango y que no sea loopback exige `--allow-non-tailnet`; `0.0.0.0` se rechaza siempre.
  Puerto por defecto 7480 (`--port`). La IP de Tailscale es estable por dispositivo, pero
  cambia si el nodo se vuelve a registrar: en ese caso, volvé a correr `install.sh`.
- **Pi con ruta absoluta.** Toma `pi` de `command -v pi` o de `--pi RUTA`, y la escribe en el
  plist. launchd no hereda el PATH del login, así que el plist fija
  `PATH=<carpeta de pi>:/usr/bin:/bin:/usr/sbin:/sbin` (Pi necesita `node`, que vive al lado).
- **Todo en `~/.helm-agentd/`** (o `HELM_AGENTD_DIR` / `--base-dir`), directorios `0700`:
  `bin/helm-agentd` (`0700`), `sessions/`, y `agentd.out` / `agentd.err` en `0600`.
  El plist fija `Umask` 077.
- **El token** vive en `~/.helm-agentd/token` (`0600`). Lo crea el daemon al primer arranque;
  el instalador nunca lo crea, lo lee ni lo imprime, solo muestra la ruta. El teléfono lo
  copia **una sola vez** por la conexión SFTP existente y lo guarda en el Keychain del iPhone.
- Etiqueta `dev.helm.agentd`. No detiene ni descarga ningún agente existente. Es idempotente.
  Tests: `python3 -m unittest discover -s host/agentd/tests`.

Desinstalar:

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/dev.helm.agentd.plist
rm ~/Library/LaunchAgents/dev.helm.agentd.plist
rm -r ~/.helm-agentd    # opcional: borra también el token y las sesiones
```

### helm-notifier (opcional, notificaciones)

El daemon que se suscribe a herdr y empuja a FCM vive en este repo, en
`host/notifier/`. Usa solo `/usr/bin/python3` y `openssl`.

```bash
host/notifier/install.sh --dry-run   # muestra el plan, no escribe nada
host/notifier/install.sh             # copia los scripts y renderiza el plist
```

`install.sh` imprime el comando `launchctl bootstrap gui/$(id -u) <plist>`; solo lo
ejecuta si le pasás `--load`. Etiqueta por defecto: `dev.helm.notifier`. Opciones:
`--install-dir`, `--label`, `--python`, `--plist-dir`.

Lo que **no** instala, a propósito: la credencial de servicio FCM (`fcm-sa.json`), los
tokens de dispositivo (`device-tokens.json`) y el `topic` de ntfy. Van en el directorio de
instalación (por defecto `~/helm-notifier/`, o `HELM_NOTIFIER_DIR`), con permisos `0600`, y
nunca en el repo. Para generar la credencial una vez:
`python3 host/notifier/provision_fcm.py --project <id-de-tu-proyecto-firebase>`.

El log rota solo (1 MB × 3, `notifier.log` en el directorio de instalación) y no registra
tokens, credenciales ni el texto de los mensajes. Todo queda en `0600`: el plist fija
`Umask` 077, `install.sh` pre-crea `notifier.out` y `notifier.err` en `0600`, y al arrancar
el daemon ajusta a `0600` un log o respaldo que ya existiera. La clave privada ya no se deja
en disco: se escribe en un directorio temporal `0700` solo mientras `openssl` firma (con
timeout de 15 s) y se borra enseguida. Las respuestas HTTP que redirigen a `http://` se
rechazan.

**Un canal por dispositivo.** `device-tokens.json` tiene la forma
`{"tokens": ["<token FCM>", ...], "ntfy_topics": ["helm-...", ...]}`. Cada teléfono se
registra solo, por SSH, cuando se conecta: con token FCM agrega el token; sin FCM (iOS hoy)
agrega un topic de ntfy aleatorio propio. Un archivo con solo `tokens` sigue funcionando, y
el registro conserva la otra clave. Ante cada aviso el notifier envía a **todos** los tokens
y a **todos** los topics, cada destino por separado: si uno falla, los demás igual reciben
el aviso. Cada destino que falla se reintenta hasta 2 veces (2 s y 5 s); si no llegó a
ninguno, el evento no se da por consumido y el siguiente aviso equivalente vuelve a intentar.
El archivo se lee en `devices.py`, independiente de FCM: si `fcm.py` no carga, los topics de
ntfy siguen recibiendo (los tokens FCM se cuentan como no entregables). El registro deja
`~/helm-notifier` en 0700 y `device-tokens.json` en 0600. El log dice solo cuántos (`pushed[fcm x1, ntfy x2]`), nunca un token ni un topic.

Cada teléfono con topic se suscribe en la app ntfy con el topic que muestra
**Ajustes → Notifications on this device** (**+**, pegar, servidor `ntfy.sh`). El topic es un
secreto: quien lo conoce lee los avisos.

El archivo `topic` (o `HELM_NOTIFIER_TOPIC`) es el canal heredado de todo el host y se usa
**solo si ningún dispositivo registró nada** (ni tokens ni topics); así un host sin
configurar sigue como antes y no hay avisos duplicados al registrarse dispositivos. Los
dispositivos que ya no usás se acumulan en el archivo: se quitan a mano editándolo (borrarlos
desde la app es trabajo futuro).

**Migrar una instalación anterior es manual.** El instalador no detiene ni recarga el
agente viejo. Orden: `launchctl bootout` del agente anterior, `install.sh`, comprobar que
la credencial y los tokens estén en el directorio de instalación, y recién entonces
`launchctl bootstrap` del nuevo. Dos agentes a la vez mandarían cada aviso duplicado.

---

## Verificación de punta a punta

En este orden, porque cada paso depende del anterior:

```bash
MAC="$(tailscale status --peers=false --json \
  | grep -o '"DNSName": "[^"]*"' | cut -d'"' -f4 | sed 's/\.$//')"

[ -n "$MAC" ] && echo "1. tailscale OK: $MAC"
nc -z -G 5 "$MAC" 22 && echo "2. sshd alcanzable por la VPN OK"
herdr session list && echo "3. herdr OK"
pi --version && echo "4. pi OK"
pi list | grep -q gentle-pi && echo "5. gentle-pi OK"

# Solo si vas a usar el dictado por voz:
whisper-cli -m "$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin" \
  -f /dev/null -nt -np >/dev/null 2>&1
[ $? -ne 3 ] && echo "6. whisper.cpp y su modelo OK"
```

El paso 6 se fija en que el código de salida **no** sea 3, que es el que
`whisper-cli` devuelve cuando no puede cargar el modelo. El error por el
`/dev/null` vacío es esperado y no importa: lo que se mide es que el
modelo exista y cargue.

El paso 2 sondea el **nombre MagicDNS**, no loopback. No es un detalle:
loopback responde aunque Tailscale esté desconectado, así que una
verificación por ahí daría verde justo en el caso que rompe la app.

Y entonces, desde el repo de Helm:

```bash
scripts/host_setup_report.sh
```

Si ese script imprime `LISTENING`, un nombre MagicDNS y al menos una
sesión de herdr, el host está listo y podés seguir con
[`SETUP_GUIDE.md`](SETUP_GUIDE.md).

---

## Qué necesita una persona y qué no

Es la pregunta que importa si querés que un orquestador haga todo esto
solo.

**Automatizable sin intervención:**

- Instalar herdr, Tailscale, Pi y los paquetes.
- Configurar la app, autorizar su clave pública y verificar la
  conexión: `scripts/provision_simulator.sh` lo hace entero con Maestro,
  sin que nadie toque la pantalla.

**Requiere una persona, y no hay forma de evitarlo:**

- **Contraseña de administrador** para activar Remote Login.
- **Login de Tailscale**, en la Mac y en el teléfono.
- **`pi auth`**, contra tu proveedor de modelos.
- **Confiar el perfil de desarrollo**, si instalás en un teléfono físico:
  Ajustes → General → VPN y gestión de dispositivos → Confiar. Hasta que
  eso pase, la app **no arranca** y el error habla de firma inválida sin
  mencionar el ajuste que lo resuelve.
- **Todo el resto de la configuración, si el destino es un iPhone
  físico**, porque ahí no hay automatización posible. Ver abajo.

Los primeros cuatro son credenciales o permisos del dueño del aparato.
Un orquestador puede dejar todo lo demás listo y parar ahí, y en
simulador puede hacerlo entero.

---

## Cuando algo no está

**Las sesiones vuelven vacías.** herdr corre como LaunchAgent y necesita
una sesión gráfica iniciada. Si la Mac está apagada, dormida sin red, o
nadie hizo login, no hay servidor al que conectarse.

**herdr existe pero la app no lo encuentra.** La app repara el `PATH`
por su cuenta (`/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`,
`~/bin`) y resuelve el binario a ruta absoluta, así que un `PATH` pelado
de SSH no es el problema. Revisá que `herdr status` diga `running`.

**El agente aparece como `unknown`.** Falta la integración:
`herdr integration install <tu-agente>`.

**Una pestaña de tmux nacida por SSH no lee el Keychain**, mientras que
un pane de herdr sí. Medido. Si un agente te pide credenciales que ya
tenías guardadas, es por ahí.

---

## Automatizar un iPhone físico

**Maestro solo sirve en simulador.** Para un dispositivo real compila y
firma su propio driver de UITest, y falla al registrar un identificador
que pertenece a **mobile.dev**:

```text
Failed Registering Bundle Identifier: The app identifier
"dev.mobile.maestro-driver-ios" cannot be registered to your
development team because it is not available.
```

Ninguna otra cuenta puede registrarlo, ni gratuita ni de pago, y Maestro
no expone forma de cambiarlo.

**`maestro-runner` de DeviceLab sí funciona**, y corre los mismos YAML:

```bash
curl -fsSL https://open.devicelab.dev/install/maestro-runner | bash

export DEVICELAB_IOS_AGENT_BUNDLE_ID=com.tunombre.devicelab.agent
maestro-runner --platform ios --team-id <TEAM_ID> \
  --device <udid> test <flow.yaml>
```

Esa variable **no es opcional** con una cuenta personal de Apple: sin
ella falla igual que Maestro, con la diferencia de que el error te dice
qué variable poner. Verificado contra un iPhone 16 con iOS 26.7.1.

Es **software de terceros**, no de mobile.dev. Se instala aislado en
`$HOME/.maestro-runner`, sin `sudo`, verifica checksum SHA-256 y no toca
tu instalación de Maestro.

> Escribe reportes en `reports/` dentro del directorio desde el que lo
> corras. Ese directorio está en `.gitignore`.

**Consecuencia práctica**: el host se automatiza entero, el simulador
también, y un teléfono físico se automatiza con `maestro-runner`
siguiendo [`SETUP_GUIDE.md`](SETUP_GUIDE.md).

```bash
flutter build ios --release        # firmado, requiere certificado vigente
xcrun devicectl device install app \
  --device <udid> build/ios/iphoneos/Runner.app
```

> **`--release`, no `--debug`.** Medido: un build debug se instala bien y
> después **se niega a abrir desde el teléfono**, mostrando una pantalla
> negra que dice *"In iOS 14+, debug mode Flutter apps can only be
> launched from Flutter tooling, IDEs with Flutter plugins or from
> Xcode"*. No es un fallo de firma ni del perfil: es una restricción de
> iOS para builds debug. Para alguien que va a **usar** la app, la
> respuesta es `--release`; `--debug` sirve solo mientras estés
> depurando desde la Mac con `flutter run`.

Y para ver qué hay en pantalla sin tocar el teléfono:

```bash
xcrun devicectl device capture screenshot \
  --device <udid> --destination /tmp/pantalla.png
```

> **Verificá la vigencia del certificado con `openssl`, no con
> `security find-identity`**, que lista identidades vencidas entre las
> “valid identities found”. Y el Team ID se lee del campo `OU`, nunca
> del paréntesis del `CN`:
>
> ```bash
> security find-certificate -c "Apple Development" -p \
>   | openssl x509 -noout -subject -dates
> ```
