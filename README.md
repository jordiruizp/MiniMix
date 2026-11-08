# MiniMix

Switcher de vídeo en directo para macOS: preparas una fuente en **Preview** y la envías a
**Programa** con un corte, un fundido o la T-bar. Fuentes: vídeo, audio, imágenes, colores
sólidos y playlists. Pensado para un MacBook con Apple Silicon (macOS 15 o posterior).

## Instalar

En este Mac:

```bash
scripts/release.sh          # compila, firma y crea build/MiniMix-<versión>.dmg
scripts/install-local.sh    # copia la app a /Applications
```

En otro Mac (distribución manual): copia el `.dmg`, ábrelo y arrastra MiniMix a Aplicaciones.
La app no está notarizada, así que la primera vez macOS la bloqueará:

1. Intenta abrirla una vez.
2. *Ajustes del Sistema › Privacidad y seguridad* › **Abrir igualmente**.
   (Alternativa en Terminal: `xattr -dr com.apple.quarantine /Applications/MiniMix.app`.)

**Firma estable (recomendado):** ejecuta una vez `scripts/create-local-signing-cert.sh`. Crea un
certificado «MiniMix Local» en tu llavero y las siguientes compilaciones se firman con él. Así los
proyectos guardados conservan el acceso a sus archivos aunque actualices la app; sin él, tras
cada actualización puede pedirte reenlazar los medios.

## Pantalla

```
┌──────────────────────────────────────────────────────────────────┐
│  PREVIEW (verde)          T-bar · CUT · FADE        PROGRAMA (rojo)│
├──────────────────────────────────────────────────────────────────┤
│  Entradas: tarjetas numeradas 1–9 (arrastra archivos aquí) · [+]  │
├───────────────────────────────┬──────────────────────────────────┤
│  Panel de playlist            │  Mezclador: fader · mute · solo  │
├───────────────────────────────┴──────────────────────────────────┤
│  Estado: fps · perdidos · RAM · GPU · decodificadores · térmico   │
└──────────────────────────────────────────────────────────────────┘
```

## Atajos

| Tecla | Acción |
|---|---|
| 1 … 9 | Entrada N a Preview |
| Espacio | Cut |
| Intro | Fade con la duración actual |
| ← / → | Playlist en Programa: item anterior / siguiente |
| P | Play / pausa de la entrada en Preview |
| ⌘N / ⌘O / ⌘S / ⌘⇧S | Proyecto nuevo / abrir / guardar / guardar como |
| ⌘⇧F | Mostrar u ocultar la salida de Programa en la pantalla externa |
| ⌘, | Preferencias |

Los atajos de una tecla no actúan mientras escribes en un campo de texto.

## Flujos básicos

**Añadir fuentes.** Arrastra vídeos, audios o imágenes desde el Finder a la rejilla, o usa [+]
para añadir archivos, un color sólido o una playlist. Menú contextual de cada tarjeta: renombrar,
color, bucle, ajuste (encajar/rellenar/estirar), «audio sigue a Programa», mostrar en Finder, quitar.

**Conmutar.** Pulsa el número de una entrada para llevarla a Preview y luego **Cut** (Espacio),
**Fade** (Intro, duración configurable de 0,1 a 5 s) o arrastra la **T-bar**. Tras cada
transición Preview y Programa se intercambian.

**Playlists.** Selecciona una entrada playlist para ver su panel: añade items (vídeo, audio,
imagen, color), reordénalos arrastrando, actívalos o desactívalos, marca «parar después de
este», ajusta In/Out o la duración. Modos: **Continuo** (sin huecos entre items) o **Parar tras
cada item**; bucle opcional; transición entre items por corte o fundido; qué se ve al parar
(último fotograma, negro o primer fotograma del siguiente). Doble clic en un item para saltar.

**Audio.** Un canal por entrada con fader, mute, solo (escucha) y vúmetro, más Master. Con
«audio sigue a Programa» la entrada solo suena cuando está en Programa y hace el fundido con la
imagen. Si la salida externa tiene retardo, compénsalo en *Preferencias › Latencia de audio*.

**Salida externa.** Conecta un monitor o proyector y pulsa ⌘⇧F: Programa se muestra a pantalla
completa en la pantalla externa. Si se desconecta, vuelve sola al reconectarla.

**Proyectos.** ⌘S guarda un `.minimix` (JSON) con las entradas, playlists y ajustes. Si al
abrirlo faltan archivos, MiniMix te ofrece reenlazarlos eligiendo la carpeta donde están ahora.

**Formato.** El lienzo (720p, 1080p o 4K experimental) y los fps del proyecto se cambian en
*Proyecto › Formato…*; en *Preferencias* se fijan los valores para proyectos nuevos.

## Desarrollo

Ver `CLAUDE.md` (estructura, comandos, reglas) y `PROGRESS.md` (estado del proyecto).
