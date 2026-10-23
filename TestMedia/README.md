# TestMedia

Medios de prueba generados por `Tools/generate-testmedia.sh` (H · T60). **Los binarios no se
versionan**: solo este README y `manifest.json` (descripción de cada archivo: códec, resolución,
fps, duración, alfa, audio, propósito, rango del código de fotograma y el conjunto `playlist_mixed`).

```bash
Tools/generate-testmedia.sh            # ~190 MB, ~1,5 min en MacBook Neo; idempotente
Tools/generate-testmedia.sh --force    # regenerar todo
```

Requisitos: `ffmpeg` (`brew install ffmpeg`, se usa `/opt/homebrew/bin/ffmpeg` o `$FFMPEG`), `jq`,
`sips` (de serie en macOS). Los tests que necesitan TestMedia se desactivan si falta.

## Contenido

| Carpeta | Contenido |
|---|---|
| `video/` | H.264 (23,976/25/29,97/50/59,94; 1080p, 720p, vertical 1080×1920; clip de 60 s), HEVC, HEVC con alfa, ProRes 422, ProRes 4444 con alfa |
| `image/` | PNG con alfa (horizontal y vertical), JPEG (1080p y 6000×4000), TIFF, HEIC |
| `audio/` | WAV, AIFF, MP3, M4A × 44,1/48 kHz × mono/estéreo |
| `playlist_mixed/` | vídeo 25p (4 s) → imagen (5 s) → vídeo 30p (4 s) → color (3 s, solo en el manifiesto; **sin código de fotograma**: en los tests gapless usa `FrameSequenceAnalysis(…, isFiller:)`) |

Todos los vídeos e imágenes llevan:

- **Contador visible** (`testsrc2`: timecode y número de frame arriba a la izquierda).
- **Código de fotograma** legible por máquina abajo a la izquierda: 23 celdas de `s = min(w,h)/45`
  px — `[blanco][negro][bit0…bit15][paridad par][CRC-4]`; valor = `clipID << 11 | frame`. Cada archivo
  tiene un `clipID` distinto, así que un test gapless sabe qué clip y qué frame ve (0 negros,
  0 repetidos, 0 saltos). Lector: `Tests/Sources/TestSupport/FrameCode.swift`.
- **Claqueta**: parche blanco de 4s×4s abajo a la derecha en el primer frame de cada segundo
  y pitido de 1 kHz / 40 ms en el audio en cada segundo exacto (sobre un tono de 300/450 Hz a
  −26 dBFS). La diferencia entre ambos mide el desfase A/V.

Los archivos con alfa usan una máscara: fondo transparente, rectángulo central opaco, una banda
horizontal al 50 % y el código/claqueta opacos.

## Determinismo

Mismos parámetros → mismo contenido. Los codificadores software (libx264, libx265, prores_ks,
png, mjpeg, tiff, aac, libmp3lame, PCM) y `sips` (HEIC) dan archivos idénticos byte a byte
(`checksums.sha256`, local). **Excepción**: `hevc_alpha_1080p25.mov` usa VideoToolbox (el único
codificador de ffmpeg que escribe HEVC con alfa que AVFoundation reconoce); su contenido es
equivalente pero un par de bytes del SEI del codificador cambian entre ejecuciones.

Notas: el MP3 añade el retardo del codificador (~1105 muestras) al principio; el M4A (AAC) lleva
su priming en la lista de edición. Los sellos (`.stamps/`) incluyen la versión de ffmpeg: si se
actualiza ffmpeg, la siguiente ejecución regenera todo.
