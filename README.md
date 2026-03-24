# Helm

App Flutter para controlar tu Mac remotamente desde tu celular via SSH + tmux.

No es un terminal genérico — está diseñada específicamente para usar [OpenCode](https://github.com/anthropics/claude-code) (Claude Code) desde cualquier parte del mundo.

## Qué hace

- **Terminal SSH real** con renderizado completo de TUI (colores, alternate screen buffer, 256 colores)
- **Múltiples pestañas** — cada una es una sesión tmux independiente en tu Mac
- **Autenticación biométrica** — Face ID / huella dactilar para proteger el acceso
- **Sesiones persistentes** — tmux mantiene todo vivo aunque cierres la app
- **Acceso remoto** — via Tailscale, funciona desde cualquier red (WiFi, 4G, 5G)
- **Barra de teclas especiales** — CTRL, ESC, TAB, flechas, PgUp/PgDn, Home/End, pipe, etc.

## Requisitos

### En tu Mac
- **SSH habilitado** — `System Settings → General → Sharing → Remote Login`
- **tmux** — `brew install tmux`
- **Tailscale** — [tailscale.com/download/mac](https://tailscale.com/download/mac)

### En tu celular
- **Tailscale** — App Store / Play Store
- Conectado con la misma cuenta que tu Mac

## Setup inicial

1. Abrí Helm en tu celular
2. Autenticá con huella / Face ID
3. La app genera una SSH key Ed25519 automáticamente
4. Copiá la public key y agregala a tu Mac:
   ```bash
   echo "<tu-public-key>" >> ~/.ssh/authorized_keys
   ```
5. Ingresá la IP de Tailscale de tu Mac, tu usuario y puerto 22
6. Tocá "Save and Continue"

## Stack técnico

| Componente | Tecnología |
|-----------|-----------|
| Framework | Flutter 3.41+ / Dart 3.11+ |
| SSH | dartssh2 (Dart puro, funciona en iOS y Android) |
| Terminal | xterm.dart v4 (renderizado completo VT100+) |
| Auth | local_auth (Face ID, Touch ID, huella) |
| Keys | flutter_secure_storage (Secure Enclave / Keystore) |
| Estado | Riverpod 3.x |
| Navegación | go_router |
| Red | Tailscale (mesh VPN) |
| Sesiones | tmux (server-side) |

## Arquitectura

```
lib/
  core/
    constants/      # Constantes de la app
    router/         # GoRouter + auth guards
    theme/          # Dark theme + Monokai terminal
    utils/          # Logger
  features/
    auth/           # Biometric gate
    connection/     # SSH service, key management, perfiles
    settings/       # CRUD de perfiles de conexión
    setup/          # First-time setup flow
    terminal/       # Terminal emulation, tabs, tmux, special keys
```

## Plataformas

- iOS 15+
- Android 10+ (API 29+)

## Licencia

Proyecto personal. No distribuido públicamente.
