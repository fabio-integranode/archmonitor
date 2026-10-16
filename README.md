# Archmonitor

Monitor de recursos nativo para **KDE Plasma 6** (Wayland): una tarjeta sobria en el escritorio que se queda en silencio mientras todo está bien y avisa solo cuando algo se sale de rango.

<p align="center">
  <a href="docs/archmonitor-reel.mp4"><img src="docs/archmonitor-reel-preview.gif" alt="Sobrecarga, diagnóstico y vuelta a NOMINAL (clic para ver el video completo)" width="240"></a>
  <img src="docs/tarjeta.png" alt="Archmonitor: la tarjeta en estado nominal" width="240">
  <img src="docs/sobrecarga.png" alt="Sobrecarga: el cajón muestra el proceso culpable, listo para detenerlo" width="240">
</p>

<p align="center"><a href="docs/archmonitor-reel.mp4"><b>▶ Ver el video completo (27 s)</b></a></p>

- **Sistema:** CPU, RAM, GPU y disco, con temperaturas, potencia del SoC y ventilador cuando hace falta.
- **Red y batería:** enlace físico, señal Wi-Fi y tasas; carga, potencia y tiempo restante.
- **Alertas que no parpadean:** persistencia e histéresis; `STALE` si la telemetría deja de llegar y `?` cuando algo importante no se puede medir.
- **Procesos:** un clic abre el cajón con los mayores consumidores de CPU y RAM; dos clics detienen el que está frenando todo (SIGTERM y, si se resiste, SIGKILL).
- **Seguridad:** LUKS sobre `/`, UFW, USBGuard y reinicio pendiente tras actualizar el kernel.
- **Música:** lo que suena en el navegador, con carátula, pausa y siguiente.

## Instalación

Requiere Arch Linux (o derivada) con KDE Plasma 6.

```bash
sudo pacman -S --needed iw inter-font ttf-jetbrains-mono playerctl
git clone https://github.com/fabio-integranode/archmonitor.git
cd archmonitor
./install.sh && systemctl --user restart plasma-plasmashell
```

Después: clic derecho en el escritorio → *Añadir elementos gráficos* → **Archmonitor**. Arrastralo a una esquina.

Para actualizar: `git pull && ./install.sh && systemctl --user restart plasma-plasmashell`.

`lm_sensors` no hace falta: los sensores se leen directo de `/sys/class/hwmon`, identificados por nombre de driver (los índices `hwmonN` cambian entre arranques). `findmnt` (util-linux) y `getconf` (glibc) ya vienen con Arch. La opacidad del fondo se ajusta en *Configurar Archmonitor…*.

> El identificador interno del widget sigue siendo `io.arquimedes.archimonitor`, para que las instalaciones existentes se actualicen en el lugar.

## Arquitectura

| Archivo | Rol |
|---|---|
| `contents/code/archi-stat.sh` | Sonda: lee `/proc` y `/sys` y emite JSON. Tres modos: rápido (2 s, ~9 ms), `sec` (30 s) y `top` (bajo demanda, ~1 s). |
| `contents/ui/main.qml` | Wrapper Plasma: muestreo, deltas (CPU %, red) y estado del motor de alertas. |
| `contents/ui/Card.qml` | Tarjeta del escritorio. Vista pura; un clic abre o cierra el cajón de detalle bajo el encabezado. |
| `contents/ui/Detail.qml` | Contenido del cajón: alertas activas, procesos por CPU y RAM, kernel. Sin fondo propio: es parte de la tarjeta. |
| `contents/ui/Logic.js` | Umbrales, formato y motor de alertas (persistencia + histéresis). |
| `tests/` | `node tests/test_logic.js` (motor) y `bash tests/test_probe.sh` (sonda, con árboles `/sys` sintéticos). |

## Semántica

- **Pill de estado**: `NOMINAL` o el peor hallazgo, más `+N` si hay más. Orden: `STALE` > crítico > advertencia > desconocido. Sólo late en crítico.
- **STALE**: si pasan más de 7 s sin una muestra válida (la sonda falló, se colgó o el JSON no parsea), la pastilla pasa a `STALE 12 s` en gris y las cifras se atenúan. Nunca se muestra `NOMINAL` con datos viejos. Lo vigila un único `Timer` de 1 s: detectar que algo *no* llegó requiere un reloj.
- **Desconocido (`?`)**: no medir no es estar bien, pero sólo dos ausencias impiden `NOMINAL`: la temperatura de CPU (`CPU TEMP ?`) y la sonda de seguridad (`SECURITY ?`, si no reporta o tiene más de 90 s). `systemctl` respondiendo `unknown` se muestra `UFW ?`, no `UFW DOWN`; un `/` que no se puede resolver, `LUKS ?`. GPU/SSD temp, ventilador o señal ausentes sólo muestran `—`.
- **Persistencia**: una alerta aparece tras 3 muestras consecutivas (6 s) en el peor nivel sostenido. Un pico aislado no dispara nada.
- **Histéresis**: una alerta se libera sólo cuando el valor cruza el umbral con margen (por ejemplo, CPU entra a 80 °C y sale por debajo de 77 °C). Un valor oscilando sobre la línea no hace parpadear la pastilla.
- **Alertas**: temperaturas, presión de memoria y disco, batería baja en descarga, señal débil, sin red, LUKS/UFW/USBGuard caídos y reinicio pendiente. La carga de CPU no es una anomalía y no alerta.
- **Color**: sólo en la cifra que supera su umbral. Todo lo demás es monocromo.
- **Clic en la tarjeta**: abre, justo bajo el encabezado, un cajón con todas las alertas y los 3 mayores consumidores de CPU y de RAM; las métricas bajan con una animación de 200 ms. Otro clic lo cierra. No hay popup de Plasma.
- **Música**: al pie de la tarjeta, sólo mientras un navegador reproduce o tiene en pausa algo (Firefox, Chromium, Chrome, Brave, Vivaldi, Edge…; Spotify y otros reproductores se ignoran). Un bloque 16:9 con la carátula a todo el ancho (recortada, no deformada) y un degradado sutil desde abajo; encima, centrados, anterior / reproducir-pausa (un único botón que alterna) / siguiente, cada uno con su disco oscuro y borde claro para leerse sobre cualquier imagen; abajo, el progreso con el tiempo **restante** (`-3:42`) y el título con artista en marquesina de bordes desvanecidos si no entra. Con YouTube / YouTube Music, si la extensión no publica la carátula (lo hace tarde tras un cambio de pista, hasta el próximo pausa/play), se usa la miniatura del propio video a partir del enlace de la página; una carátula publicada siempre tiene prioridad, y mientras sea la misma pista la carátula se conserva aunque el reproductor la deje de informar. Clic en la carátula o el título trae el navegador al frente; con la extensión **Plasma Browser Integration** enfoca la pestaña exacta. Lee MPRIS cada 2 s con `playerctl`; play/pausa cambia al instante y la posición avanza localmente entre sondeos. Sin `playerctl` no aparece. Las esquinas redondeadas de la carátula y el desvanecido usan la GPU; con renderizado por software se dibujan sin efecto.
- **Detener un proceso** (en el cajón, filas de CPU o de memoria): primer clic arma la fila (`STOP?` en rojo), segundo clic envía **SIGTERM** a todos tus procesos de ese comando (`×12` = los doce). La fila muestra `stopping…` 3 s; si el comando sigue en la lista, el siguiente intento ofrece `KILL -9?` (**SIGKILL**). Un SIGTERM de más de 60 s se olvida. Cualquier otro clic, 4 s sin confirmar o cerrar el cajón desarma la fila.
  - Sólo procesos tuyos: el widget corre con tu usuario y no escala privilegios.
  - Nunca se ofrecen los que tumbarían la sesión, el escritorio (y el propio widget), el audio, los llaveros o una shell: `plasmashell`, `kwin_wayland`, `Xwayland`, `systemd`, `dbus-*`, `pipewire`, `wireplumber`, `kwalletd6`, `bash`/`zsh`/`fish`, entre otros (`protected_name()` en la sonda). Esas filas no se arman.
  - La sonda revalida cada PID al enviar la señal: vivo, mismo nombre de comando, tuyo, no PID 1. Un PID reutilizado desde la muestra falla la comprobación de nombre.
  - CPU se mide en una ventana de ~1 s desde `/proc/PID/stat`; es % de **un** núcleo (como `top`), por eso puede superar 100 %.
  - Los procesos se agrupan por comando (`×9` = nueve procesos). La RAM es RSS sumado, así que las páginas compartidas se cuentan una vez por proceso: es aproximada y tiende a sobrestimar navegadores.
  - La sonda `top` sólo corre mientras el detalle está visible.
- **LUKS**: se resuelve el dispositivo que respalda `/` y se recorre su cadena (`slaves/`) buscando un mapeo `CRYPT-LUKS*`. Cubre LUKS directo y LVM sobre LUKS. Un LUKS que protege sólo `/home` ya no da positivo.
- **Reinicio pendiente**: se activa si el árbol `/usr/lib/modules/<kernel en ejecución>` ya no existe (lo borra el upgrade) o si hay instalado un kernel más nuevo del mismo paquete (`pkgbase`). Si el kernel no viene de un paquete de Arch, no puede saberlo y se queda callado. Con `linux-lts` instalado junto a `linux` no se mezclan.
- **GPU**: ocupación (`gpu_busy_percent`). `sclk` en reposo marca ~0 por GFXOFF.
- **Fila contextual** (altura fija, la tarjeta nunca cambia de tamaño): `FAN` en ámbar cuando Tctl ≥ 70 °C (sale bajo 65 °C) o el ventilador supera 4000 rpm; si no, `SOC` (potencia del paquete APU), tenue en reposo y normal en batería, cargando o por encima de 15 W (sale bajo 12 W).
- **Red**: se toma el enlace físico, la ruta por defecto activa (`RTF_UP`) de menor métrica en `/proc/net/route` (Ethernet del dock a métrica 100 gana al Wi-Fi a 600). Los túneles VPN enrutan por otras tablas y no se eligen a propósito: SSID y señal son del enlace físico.
- **SSID**: `iw` escapa los bytes no ASCII como `\xNN`; se decodifican, así que «Señal» se ve bien. Todo texto pasa por un escape JSON completo (incluye caracteres de control).
- **Batería**: `Not charging` con umbral de ThinkPad se muestra como `AC · held at N%`.

Los umbrales se ajustan en `Logic.js` (`TH`, `RULES`, `UP`). Para aplicar cambios: `./install.sh` y reiniciar plasmashell.

## Pruebas

```bash
node tests/test_logic.js     # 33 casos: persistencia, histéresis, flags, STALE, desconocidos, fila contextual, señales, música
bash tests/test_probe.sh     # 42 casos: LUKS, reinicio, ruta, SSID/escape, top, kill, música, JSON, uptime
```

La sonda acepta `ARCHI_SYSBLK`, `ARCHI_ROOT_DEV`, `ARCHI_MODDIR`, `ARCHI_ROUTE`, `ARCHI_IW_FILE` y `ARCHI_MEDIA_FILE` para apuntar a datos de prueba. No se usan en producción.

## Licencia

MIT. Ver [LICENSE](LICENSE).
