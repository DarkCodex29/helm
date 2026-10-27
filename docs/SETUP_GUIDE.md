# Guía de configuración

Helm es un cliente de terminal. No aloja nada: abre una conexión SSH a
una máquina tuya y se engancha a una sesión de [herdr](https://github.com/senna-lang/herdr)
que ya está corriendo ahí. Nada funciona hasta que esa máquina sea
alcanzable y confíe en tu dispositivo, así que casi toda esta guía es
sobre la Mac, no sobre la app.

Hay dos caminos y terminan en el mismo lugar.

- **[Automático](#automático-simulador-de-ios)** — un comando, solo simulador.
- **[A mano](#a-mano-cualquier-dispositivo)** — cuatro pasos, sirve en un teléfono real.

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

### Paso 2 — llenar la app

Abrí Helm. En el primer arranque genera su propia clave SSH y te muestra
el formulario. Escribí los valores del paso 1 y guardá.

### Paso 3 — autorizar el dispositivo

La app muestra su clave pública en esa misma pantalla, y después en
`Settings → SSH key`. Tocá copiar, y entonces:

```bash
scripts/host_setup_report.sh --from-clipboard
```

Rechaza cualquier cosa que no sea una clave pública SSH parseable, y no
agrega la misma clave dos veces.

### Paso 4 — reiniciar la app

No es opcional ni superstición: ver
[Una pestaña conserva el perfil con el que se abrió](#una-pestaña-conserva-el-perfil-con-el-que-se-abrió).

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

### Conecta, pero a otra pestaña de la que venías usando

Eso es herdr, no Helm. La app se engancha al **servidor** de herdr y
entra como cliente nuevo, en la pestaña que ese cliente abra. Tus otras
pestañas siguen estando: cambiá entre ellas desde el terminal, igual que
en la Mac.

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

### Por qué los flows están escritos así

Si vas a escribir tus propios flows de Maestro contra Helm, cuatro cosas
se comportan distinto en iOS de lo que esperarías. Las cuatro medidas
sobre esta app.

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
