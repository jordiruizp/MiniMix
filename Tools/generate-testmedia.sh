#!/usr/bin/env bash
# Tools/generate-testmedia.sh — generador reproducible de TestMedia (H · T60).
#
# Uso:
#   Tools/generate-testmedia.sh                 # genera lo que falte o haya cambiado
#   Tools/generate-testmedia.sh --force         # regenera todo
#   Tools/generate-testmedia.sh --only 'h264'   # solo archivos cuyo nombre case con la regex
#   Tools/generate-testmedia.sh --out DIR       # genera en otro directorio (comprobar determinismo)
#   Tools/generate-testmedia.sh --manifest-only # solo reescribe manifest.json
#
# Idempotente: cada archivo lleva un sello (.stamps/<archivo>) con el hash de sus parámetros, la
# versión del generador y la de ffmpeg; si el archivo existe y el sello coincide, no se toca.
# Determinista: codificadores software (libx264, libx265, prores_ks, png, mjpeg, tiff, aac, lame,
# PCM) con hilos fijos y -bitexact → mismo binario byte a byte. Excepción: HEVC con alfa usa
# VideoToolbox (único codificador de ffmpeg que escribe HEVC+alfa compatible con AVFoundation);
# su contenido es equivalente pero puede diferir en un par de bytes del SEI del codificador.
#
# Contenido común a todos los vídeos e imágenes (ver "frameCode" en manifest.json):
#   - testsrc2 de ffmpeg: barras en movimiento + contador visible (timecode y nº de frame) arriba izq.
#   - Código de fotograma legible por máquina abajo a la izquierda (19 celdas de s×s px,
#     s = min(ancho, alto) / 45): [blanco][negro][16 bits LSB→MSB][paridad par].
#     valor = clipID << 11 | nº de frame. Lector: Tests/Sources/TestSupport/FrameCode.swift.
#   - Claqueta: parche de 4s×4s abajo a la derecha, blanco en el primer frame con pts ≥ k s
#     (k entero) y negro el resto; el audio lleva un pitido de 1 kHz de 40 ms en t = k s
#     sobre un tono continuo bajo (300 Hz izq. / 450 Hz der.).
set -euo pipefail
export LC_ALL=C

GENERATOR_VERSION=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/TestMedia"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
FORCE=0
ONLY=""
MANIFEST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --only) ONLY="${2:?--only necesita una regex}"; shift ;;
    --out) OUT="${2:?--out necesita un directorio}"; shift ;;
    --manifest-only) MANIFEST_ONLY=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "argumento desconocido: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ $MANIFEST_ONLY -eq 0 ]]; then
  [[ -x "$FFMPEG" ]] || { echo "ffmpeg no encontrado en $FFMPEG (brew install ffmpeg)" >&2; exit 1; }
  FFMPEG_VERSION="$("$FFMPEG" -version | head -1)"
else
  FFMPEG_VERSION="n/a"
fi
command -v jq >/dev/null || { echo "jq no encontrado" >&2; exit 1; }

mkdir -p "$OUT/video" "$OUT/image" "$OUT/audio" "$OUT/playlist_mixed" "$OUT/.stamps"
FF=(-hide_banner -loglevel error -nostdin -y)
BITEXACT=(-fflags +bitexact -flags:v +bitexact -flags:a +bitexact -map_metadata -1 -map_chapters -1)
ENTRIES=()
GENERATED=0
SKIPPED=0

# MARK: - utilidades

fps_of() { awk -v r="$1" 'BEGIN { n = split(r, a, "/"); printf "%.6f", (n == 2 ? a[1] / a[2] : a[1]) }'; }
frames_of() { awk -v d="$1" -v f="$2" 'BEGIN { printf "%d", d * f + 0.5 }'; }
cell_of() { awk -v w="$1" -v h="$2" 'BEGIN { m = (w < h ? w : h); printf "%d", m / 45 }'; }

# Ejecuta "$@" para producir $1 (ruta relativa a OUT) salvo que el sello coincida.
# El comando recibe la ruta temporal en lugar de __OUT__ y el directorio de salida en lugar de
# __OUTDIR__; el sello se calcula con los marcadores, así que no depende de --out.
produce() {
  local rel="$1"; shift
  local dest="$OUT/$rel"
  local stamp_file="$OUT/.stamps/${rel//\//__}"
  local key
  key="$(printf '%s\n' "gen=$GENERATOR_VERSION" "$FFMPEG_VERSION" "${KEY_EXTRA:-}" "$@" | shasum -a 256 | cut -d' ' -f1)"
  if [[ $MANIFEST_ONLY -eq 1 ]]; then return 0; fi
  if [[ -n "$ONLY" && ! "$rel" =~ $ONLY ]]; then return 0; fi
  if [[ $FORCE -eq 0 && -f "$dest" && -f "$stamp_file" && "$(cat "$stamp_file")" == "$key" ]]; then
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  local tmp; tmp="$(dirname "$dest")/.partial-$(basename "$dest")"
  local args=() a
  for a in "$@"; do a="${a//__OUTDIR__/$OUT}"; args+=("${a//__OUT__/$tmp}"); done
  echo "▶ $rel"
  "${args[@]}" > /dev/null
  mv -f "$tmp" "$dest"
  printf '%s\n' "$key" > "$stamp_file"
  GENERATED=$((GENERATED + 1))
}

# Filtro drawbox del código de fotograma, la claqueta y el fondo negro de ambos.
# $1 ancho, $2 alto, $3 base del código (clipID << 11), $4 duración de frame (s), $5 claqueta 0/1
overlay_filters() {
  local w="$1" h="$2" base="$3" fd="$4" clap="$5"
  local s; s="$(cell_of "$w" "$h")"
  local y=$((h - 2 * s)) f parity="" k pow bit
  f="drawbox=x=$((s / 2)):y=$((h - 5 * s / 2)):w=$((20 * s)):h=$((2 * s)):color=black:t=fill"
  f+=",drawbox=x=$s:y=$y:w=$s:h=$s:color=white:t=fill"
  for k in $(seq 0 15); do
    pow=$((1 << k))
    bit="mod(floor((n+$base)/$pow),2)"
    parity+="${parity:++}$bit"
    f+=",drawbox=x=$((s * (k + 3))):y=$y:w=$s:h=$s:color=white:t=fill:enable='$bit'"
  done
  f+=",drawbox=x=$((s * 19)):y=$y:w=$s:h=$s:color=white:t=fill:enable='mod($parity,2)'"
  if [[ "$clap" -eq 1 ]]; then
    f+=",drawbox=x=$((w - 5 * s)):y=$((h - 5 * s)):w=$((4 * s)):h=$((4 * s)):color=black:t=fill"
    f+=",drawbox=x=$((w - 5 * s)):y=$((h - 5 * s)):w=$((4 * s)):h=$((4 * s)):color=white:t=fill"
    f+=":enable='lt(mod(t,1),$fd)'"
  fi
  printf '%s' "$f"
}

# Máscara de alfa: fondo transparente, rectángulo central opaco, banda semitransparente (50 %)
# y código/claqueta opacos.
alpha_mask() {
  local w="$1" h="$2" rate="$3" s; s="$(cell_of "$w" "$h")"
  printf '%s' "color=c=black:s=${w}x${h}:r=$rate,format=gray"
  printf '%s' ",drawbox=x=$((w / 5)):y=$((h / 5)):w=$((3 * w / 5)):h=$((3 * h / 5)):color=white:t=fill"
  printf '%s' ",drawbox=x=0:y=$((h / 10)):w=$w:h=$((h / 20)):color=0x808080:t=fill"
  printf '%s' ",drawbox=x=0:y=$((h - 3 * s)):w=$((21 * s)):h=$((3 * s)):color=white:t=fill"
  printf '%s' ",drawbox=x=$((w - 6 * s)):y=$((h - 6 * s)):w=$((6 * s)):h=$((6 * s)):color=white:t=fill"
}

# Señal de audio: tono bajo continuo + pitido de claqueta. $1 canales
audio_expr() {
  local beep="if(lt(mod(t,1),0.04),0.6*sin(2*PI*1000*t),0)"
  if [[ "$1" -eq 1 ]]; then
    printf '%s' "0.05*sin(2*PI*300*t)+$beep"
  else
    printf '%s' "0.05*sin(2*PI*300*t)+$beep|0.05*sin(2*PI*450*t)+$beep"
  fi
}

json_audio() { # codec rate channels | none
  if [[ "$1" == none ]]; then printf 'null'; else
    printf '{"codec":"%s","sampleRate":%d,"channels":%d}' "$1" "$2" "$3"; fi
}

# MARK: - vídeo

# video REL CODEC W H RATE DUR CLIPID AUDIO(codec:rate:ch|none) PURPOSE
video() {
  local rel="$1" codec="$2" w="$3" h="$4" rate="$5" dur="$6" clip="$7" audio="$8" purpose="$9"
  local fps frames fd base alpha=false
  fps="$(fps_of "$rate")"; frames="$(frames_of "$dur" "$fps")"
  # Umbral de la claqueta: 1 frame menos 1 µs → solo el primer frame con pts ≥ k s.
  fd="$(awk -v f="$fps" 'BEGIN { printf "%.9f", 1 / f - 0.000001 }')"
  base=$((clip << 11))
  (( frames < 2048 )) || { echo "$rel: demasiados frames para el código ($frames)" >&2; exit 1; }
  local gop; gop="$(frames_of 1 "$fps")"
  local vf; vf="testsrc2=s=${w}x${h}:r=$rate,$(overlay_filters "$w" "$h" "$base" "$fd" 1)"
  local inputs=() maps=() venc=() aenc=()
  case "$codec" in
    h264) venc=(-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -threads 4 -g "$gop" -tag:v avc1) ;;
    hevc) venc=(-c:v libx265 -preset fast -crf 24 -pix_fmt yuv420p -tag:v hvc1
                -x265-params "log-level=error:pools=4:frame-threads=1:keyint=$gop:min-keyint=$gop") ;;
    hevc_alpha) alpha=true
      venc=(-c:v hevc_videotoolbox -q:v 65 -alpha_quality 0.75 -pix_fmt bgra -tag:v hvc1 -g "$gop") ;;
    prores422) venc=(-c:v prores_ks -profile:v 2 -pix_fmt yuv422p10le -vendor apl0 -threads 4) ;;
    prores4444) alpha=true
      venc=(-c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le -alpha_bits 16 -vendor apl0 -threads 4) ;;
    *) echo "códec desconocido $codec" >&2; exit 1 ;;
  esac
  if [[ "$alpha" == true ]]; then
    inputs+=(-f lavfi -i "$vf" -f lavfi -i "$(alpha_mask "$w" "$h" "$rate")")
    local fmt=yuva444p10le; [[ "$codec" == hevc_alpha ]] && fmt=bgra
    inputs+=(-filter_complex "[0:v][1:v]alphamerge,format=$fmt[v]")
    maps+=(-map "[v]")
  else
    inputs+=(-f lavfi -i "$vf"); maps+=(-map 0:v)
  fi
  local acodec=none arate=0 ach=0 aidx=1
  [[ "$alpha" == true ]] && aidx=2
  if [[ "$audio" != none ]]; then
    IFS=: read -r acodec arate ach <<< "$audio"
    local adur; adur="$(awk -v n="$frames" -v f="$fps" 'BEGIN { printf "%.6f", n / f }')"
    inputs+=(-f lavfi -i "aevalsrc=exprs='$(audio_expr "$ach")':s=$arate:d=$adur")
    maps+=(-map "$aidx:a")
    case "$acodec" in
      aac) aenc=(-c:a aac -b:a 192k) ;;
      pcm_s16le) aenc=(-c:a pcm_s16le) ;;
      *) echo "códec de audio desconocido $acodec" >&2; exit 1 ;;
    esac
  fi
  produce "$rel" "$FFMPEG" "${FF[@]}" "${inputs[@]}" "${maps[@]}" -frames:v "$frames" \
    "${venc[@]}" ${aenc[@]+"${aenc[@]}"} "${BITEXACT[@]}" __OUT__
  ENTRIES+=("$(jq -cn --arg file "$rel" --arg codec "$codec" --arg rate "$rate" --arg purpose "$purpose" \
    --argjson w "$w" --argjson h "$h" --argjson fps "$fps" --argjson frames "$frames" \
    --argjson dur "$(awk -v n="$frames" -v f="$fps" 'BEGIN { printf "%.6f", n / f }')" \
    --argjson alpha "$alpha" --argjson clip "$clip" --argjson audio "$(json_audio "$acodec" "$arate" "$ach")" \
    '{file: $file, kind: "video", codec: $codec, width: $w, height: $h, frameRate: $rate, fps: ($fps + 0),
      frames: $frames, duration: ($dur + 0), alpha: $alpha, audio: $audio,
      frameCode: {clipID: $clip, first: ($clip * 2048), last: ($clip * 2048 + $frames - 1)},
      clapper: true, purpose: $purpose}')")
}

# MARK: - imágenes

# image REL FORMAT W H CLIPID ALPHA PURPOSE
image() {
  local rel="$1" format="$2" w="$3" h="$4" clip="$5" alpha="$6" purpose="$7"
  local vf; vf="testsrc2=s=${w}x${h}:r=25,$(overlay_filters "$w" "$h" $((clip << 11)) 0.04 0)"
  local inputs=() enc=()
  if [[ "$alpha" == true ]]; then
    inputs=(-f lavfi -i "$vf" -f lavfi -i "$(alpha_mask "$w" "$h" 25)"
            -filter_complex "[0:v][1:v]alphamerge,format=rgba[v]" -map "[v]")
  else
    inputs=(-f lavfi -i "$vf" -map 0:v)
  fi
  case "$format" in
    png) enc=(-c:v png -pred mixed) ;;
    jpeg) enc=(-c:v mjpeg -q:v 2 -pix_fmt yuvj420p) ;;
    tiff) enc=(-c:v tiff -pix_fmt rgb24 -compression_algo deflate) ;;
    *) echo "formato desconocido $format" >&2; exit 1 ;;
  esac
  produce "$rel" "$FFMPEG" "${FF[@]}" "${inputs[@]}" -frames:v 1 -update 1 "${enc[@]}" "${BITEXACT[@]}" __OUT__
  image_entry "$rel" "$format" "$w" "$h" "$clip" "$alpha" "$purpose"
}

# HEIC: ffmpeg no lo escribe; se convierte con sips (ImageIO) desde un PNG ya generado.
heic() {
  local rel="$1" src="$2" w="$3" h="$4" clip="$5" purpose="$6"
  local src_stamp="$OUT/.stamps/${src//\//__}"
  if [[ $MANIFEST_ONLY -eq 0 && ( -z "$ONLY" || "$rel" =~ $ONLY ) && ! -f "$OUT/$src" ]]; then
    echo "$rel: falta la fuente $src en $OUT; genérala antes (p. ej. --only '$(basename "$src")|$(basename "$rel")')" >&2
    exit 1
  fi
  KEY_EXTRA="src=$(cat "$src_stamp" 2>/dev/null || echo none)" \
    produce "$rel" /usr/bin/sips -s format heic -s formatOptions 80 "__OUTDIR__/$src" --out __OUT__
  image_entry "$rel" heic "$w" "$h" "$clip" false "$purpose"
}

image_entry() {
  ENTRIES+=("$(jq -cn --arg file "$1" --arg codec "$2" --argjson w "$3" --argjson h "$4" \
    --argjson clip "$5" --argjson alpha "$6" --arg purpose "$7" \
    '{file: $file, kind: "image", codec: $codec, width: $w, height: $h, alpha: $alpha, audio: null,
      frameCode: {clipID: $clip, first: ($clip * 2048), last: ($clip * 2048)}, clapper: false,
      purpose: $purpose}')")
}

# MARK: - audio

# audio REL FORMAT RATE CHANNELS DUR
audio() {
  local rel="$1" format="$2" rate="$3" ch="$4" dur="$5" enc=()
  case "$format" in
    wav) enc=(-c:a pcm_s16le) ;;
    aiff) enc=(-c:a pcm_s16be) ;;
    mp3) enc=(-c:a libmp3lame -b:a 192k -write_xing 0) ;;
    m4a) enc=(-c:a aac -b:a 192k) ;;
    *) echo "formato desconocido $format" >&2; exit 1 ;;
  esac
  produce "$rel" "$FFMPEG" "${FF[@]}" -f lavfi -i "aevalsrc=exprs='$(audio_expr "$ch")':s=$rate:d=$dur" \
    "${enc[@]}" "${BITEXACT[@]}" __OUT__
  local codec="${enc[1]}"
  ENTRIES+=("$(jq -cn --arg file "$rel" --arg fmt "$format" --argjson dur "$dur" \
    --argjson audio "$(json_audio "$codec" "$rate" "$ch")" \
    '{file: $file, kind: "audio", codec: $fmt, duration: $dur, alpha: false, audio: $audio, clapper: true,
      purpose: "Matriz de audio: formato × frecuencia × canales; pitido de claqueta cada segundo"}')")
}

# MARK: - matriz (sección 10.1 del plan)

A48="aac:48000:2"
video video/h264_1080p25.mp4          h264 1920 1080 25         5 1 "$A48" "Referencia H.264 1080p25 con audio"
video video/h264_1080p23976.mp4       h264 1920 1080 24000/1001 5 2 "$A48" "Cadencia 23,976 (pulldown sobre lienzo 60/59,94)"
video video/h264_1080p2997.mp4        h264 1920 1080 30000/1001 5 3 "$A48" "Cadencia 29,97 NTSC"
video video/h264_1080p50.mp4          h264 1920 1080 50         5 4 "$A48" "Cadencia 50"
video video/h264_1080p5994.mp4        h264 1920 1080 60000/1001 5 5 "$A48" "Cadencia 59,94 (lienzo nativo)"
video video/h264_720p25.mp4           h264 1280 720  25         5 6 "aac:44100:2" "720p escalado al lienzo; audio 44,1 kHz"
video video/h264_720p5994.mp4         h264 1280 720  60000/1001 5 7 none "720p59,94 sin pista de audio"
video video/h264_vertical_1080x1920p30.mp4 h264 1080 1920 30    5 8 "aac:48000:1" "Vertical (fit/fill/stretch); audio mono"
video video/h264_1080p25_60s.mp4      h264 1920 1080 25        60 9 "$A48" "Clip largo: deriva A/V, bucle, seek"
video video/hevc_1080p25.mp4          hevc 1920 1080 25         5 10 "$A48" "HEVC 8 bit 1080p25"
video video/hevc_1080p5994.mp4        hevc 1920 1080 60000/1001 5 11 "$A48" "HEVC 1080p59,94"
video video/hevc_720p2997.mp4         hevc 1280 720  30000/1001 5 12 "aac:44100:2" "HEVC 720p29,97"
video video/hevc_alpha_1080p25.mov    hevc_alpha 1920 1080 25   3 13 none "HEVC con alfa (VideoToolbox): transparencia en el compositor"
video video/prores422_1080p25.mov     prores422 1920 1080 25    3 14 "pcm_s16le:48000:2" "ProRes 422 + PCM"
video video/prores422_1080p2997.mov   prores422 1920 1080 30000/1001 3 15 "pcm_s16le:48000:2" "ProRes 422 29,97"
video video/prores4444_alpha_1080p25.mov prores4444 1920 1080 25 3 16 none "ProRes 4444 con alfa 16 bit"

image image/png_alpha_1920x1080.png   png  1920 1080 20 true  "PNG con alfa (fondo transparente, banda al 50 %)"
image image/png_alpha_1080x1920.png   png  1080 1920 21 true  "PNG vertical con alfa"
image image/jpeg_1920x1080.jpg        jpeg 1920 1080 22 false "JPEG 4:2:0"
image image/jpeg_6000x4000.jpg        jpeg 6000 4000 23 false "Imagen grande: decodificar una vez reducida al lienzo"
image image/tiff_1920x1080.tif        tiff 1920 1080 24 false "TIFF RGB deflate"
image image/heic_src_1920x1080.png    png  1920 1080 25 false "Fuente del HEIC (PNG opaco)"
heic  image/heic_1920x1080.heic       image/heic_src_1920x1080.png 1920 1080 25 "HEIC (sips/ImageIO)"

for fmt in wav aiff mp3 m4a; do
  for rate in 44100 48000; do
    for ch in 1 2; do
      label=$([[ $ch -eq 1 ]] && echo mono || echo stereo)
      audio "audio/tone_${rate}_${label}.$fmt" "$fmt" "$rate" "$ch" 4
    done
  done
done

# Conjunto playlist_mixed (D · T35): vídeo 25p → imagen 5 s → vídeo 30p → color 3 s.
video playlist_mixed/01_h264_1080p25.mp4 h264 1920 1080 25 4 26 "$A48" "playlist_mixed 1/4: vídeo 25p"
image playlist_mixed/02_image_1920x1080.png png 1920 1080 27 false "playlist_mixed 2/4: imagen 5 s"
video playlist_mixed/03_h264_1080p30.mp4 h264 1920 1080 30 4 28 "$A48" "playlist_mixed 3/4: vídeo 30p"

# MARK: - manifiesto

SETS='[{"name": "playlist_mixed",
  "purpose": "Playlist mixta para gapless (D): vídeo 25p → imagen 5 s → vídeo 30p → color 3 s; 16 s en total",
  "items": [
    {"type": "video", "file": "playlist_mixed/01_h264_1080p25.mp4", "duration": null},
    {"type": "image", "file": "playlist_mixed/02_image_1920x1080.png", "duration": 5},
    {"type": "video", "file": "playlist_mixed/03_h264_1080p30.mp4", "duration": null},
    {"type": "color", "color": {"red": 0.125, "green": 0.25, "blue": 0.75, "alpha": 1}, "duration": 3}
  ]}]'

printf '%s\n' "${ENTRIES[@]}" | jq -s --argjson gen "$GENERATOR_VERSION" --argjson sets "$SETS" '{
  schemaVersion: 1,
  generatorVersion: $gen,
  generator: "Tools/generate-testmedia.sh",
  frameCode: {
    description: "Tira de 19 celdas cuadradas abajo a la izquierda: [blanco][negro][bit0..bit15][paridad par]",
    cellSize: "min(width, height) / 45",
    origin: "x = cellSize, y = height - 2 * cellSize (celda i en x = cellSize * (1 + i))",
    value: "clipID << 11 | frameIndex",
    reader: "Tests/Sources/TestSupport/FrameCode.swift"
  },
  clapper: {
    video: "Parche 4s×4s (s = cellSize) en x = width - 5s, y = height - 5s: blanco en el primer frame con pts >= k s",
    audio: "Pitido 1 kHz, amplitud 0,6, 40 ms desde t = k s; tono continuo 0,05 a 300 Hz (L) / 450 Hz (R)"
  },
  files: .,
  sets: $sets
}' > "$OUT/manifest.json"

if [[ $MANIFEST_ONLY -eq 0 ]]; then
  (cd "$OUT" && find video image audio playlist_mixed -type f ! -name '.partial-*' | LC_ALL=C sort \
    | xargs shasum -a 256 > checksums.sha256)
  echo "✔ TestMedia: $GENERATED generados, $SKIPPED sin cambios; $(du -sh "$OUT" | cut -f1) en $OUT"
fi
