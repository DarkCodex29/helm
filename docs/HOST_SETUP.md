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

### gentle-ai (opcional, aparte)

`gentle-pi` es un paquete de Pi. `gentle-ai` es una herramienta de línea
de comandos distinta, de la misma familia, que se instala por Homebrew:

```bash
brew install gentleman-programming/tap/gentle-ai
```

Esta máquina la usa para CodeGraph (`gentle-ai codegraph init`). No
hace falta para Helm.

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
```

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

## En un iPhone físico no hay automatización

Maestro solo sirve en simulador, y el límite es de Apple, no nuestro.

Para manejar un dispositivo real, Maestro compila y firma su propio
driver de UITest. El comando está oculto del `--help`:

```bash
maestro driver-setup --apple-team-id <TEAM> \
  --destination "platform=iOS,id=<udid>"
```

Con el Team ID correcto igual falla:

```text
Failed Registering Bundle Identifier: The app identifier
"dev.mobile.maestro-driver-ios" cannot be registered to your
development team because it is not available.
```

Ese identificador es de **mobile.dev**. Ninguna otra cuenta puede
registrarlo, ni gratuita ni de pago.

**Consecuencia práctica**: en un teléfono, la app se instala por comando
pero se configura a mano, siguiendo
[`SETUP_GUIDE.md`](SETUP_GUIDE.md). Lo que sí se automatiza es el host
entero y, en simulador, la configuración completa.

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
