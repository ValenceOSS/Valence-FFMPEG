#!/usr/bin/env bash

# Reports what a machine's video hardware can actually do, using the same
# ffmpeg, the same render node and the same probe arguments as Valence's media
# service. Run it on a host with a GPU, either inside the Valence image or against
# a plain Debian container that has installed the valence-ffmpeg deb.
#
# It lives here rather than in Valence because Valence is private, and this has to be
# reachable from a machine with no checkout — a NAS with a Dockge panel and a
# graphics card in it. See tools/compose.probe.yml.
#
# set -u is the point of this file existing. The first attempt at checking an
# RX 580 was an ad hoc compose file that used an unset $FF, so every probe ran
# as `-hide_banner ...` and reported FAILS. Three sections produced no result
# and the machine was returned before anyone noticed. A missing variable has to
# stop this script, not decorate it.
set -euo pipefail

FFMPEG="${VALENCE_FFMPEG:-/usr/lib/valence-ffmpeg/ffmpeg}"
DEVICE="${VALENCE_VAAPI_DEVICE:-/dev/dri/renderD128}"

# Matches PROBE_SIZE in apps/transcoder/src/capability.rs. Kept in step by hand,
# because a probe that passes here and fails in the service is worse than no
# probe at all. See FLUX-85 for what a too-small picture costs.
PROBE_SIZE=640x480

VAAPI_ENCODERS=(h264_vaapi hevc_vaapi av1_vaapi)

heading() {
  printf '\n=== %s ===\n' "$1"
}

# Aborts rather than letting a missing binary read as a hardware fault.
require_executable() {
  local path="$1" variable="$2"

  if [ ! -x "$path" ]; then
    printf 'cannot run: %s is not executable\n' "$path" >&2
    printf 'set %s to the ffmpeg this image ships, or run inside the Valence image\n' "$variable" >&2
    exit 1
  fi
}

# The last non-empty line of a complaint, which is usually the useful one.
# Mirrors summarise_failure in apps/transcoder/src/capability.rs.
#
# Except when ffmpeg signs off with its muxer summary. "Nothing was written into
# output file" is what it says whenever anything upstream produced no frames, so
# it is the last line of every failure here and tells you nothing about which.
# An RX 580 reported it for a missing AV1 encoder and for a tone mapper its
# driver cannot do, which read identically and were not remotely the same fault.
# The real complaint is the line before it.
#
# When that summary is the only thing ffmpeg said, it goes back in: an unhelpful
# line beats a blank one, and "it produced no frames and would not say why" is
# itself worth reading.
last_line() {
  local lines useful
  lines="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' || true)"
  useful="$(printf '%s\n' "$lines" | grep -v 'Nothing was written into output file' | tail -n 1 || true)"

  if [ -n "$useful" ]; then
    printf '%s\n' "$useful"
    return 0
  fi

  printf '%s\n' "$lines" | tail -n 1 || true
}

# Reproduces probe_arguments from apps/transcoder/src/capability.rs.
#
# `vaapi` names a device and uploads the frame to it, which is what the service
# does for a backend whose needs_device_to_probe is true. `bare` is the same
# probe without either, kept so the difference stays visible on any machine
# rather than being something one AMD box demonstrated once.
probe_encoder() {
  local encoder="$1" mode="$2"
  local -a arguments=(-hide_banner -loglevel error)

  if [ "$mode" = vaapi ]; then
    arguments+=(-init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va)
  fi

  arguments+=(-f lavfi -i "testsrc2=size=$PROBE_SIZE:rate=1" -frames:v 1)

  if [ "$mode" = vaapi ]; then
    arguments+=(-vf format=nv12,hwupload)
  fi

  arguments+=(-c:v "$encoder" -f null -)

  local complaint status=0
  complaint="$("$FFMPEG" "${arguments[@]}" 2>&1 >/dev/null)" || status=$?

  if [ "$status" -eq 0 ]; then
    printf '  %-14s VERIFIES\n' "$encoder"
    return 0
  fi

  printf '  %-14s FAILS — %s\n' "$encoder" "$(last_line "$complaint")"
}

require_executable "$FFMPEG" VALENCE_FFMPEG

heading 'the card, and the render node the transcoder will open'
ls -l /dev/dri || printf 'no /dev/dri — pass the device through\n'
printf '\nVALENCE_VAAPI_DEVICE=%s\n' "$DEVICE"

if [ ! -e "$DEVICE" ]; then
  printf 'that node does not exist, so every VAAPI result below is meaningless\n' >&2
fi

if command -v lspci >/dev/null; then
  lspci -nn | grep -Ei 'vga|display|3d' || true
else
  printf 'lspci not installed, skipping the card name\n'
fi

heading 'which ffmpeg this is'
"$FFMPEG" -hide_banner -version | head -n 2

# Only where drivers actually live. Scanning from / walks every mounted media
# volume on a NAS, which is where this script is most likely to be run.
heading 'VA drivers this image can reach'
driver_directories=(
  "$(dirname "$FFMPEG")/lib/dri"
  /usr/lib/x86_64-linux-gnu/dri
  /usr/lib/aarch64-linux-gnu/dri
  /usr/local/lib/x86_64-linux-gnu/dri
)

if [ -n "${LIBVA_DRIVERS_PATH:-}" ]; then
  driver_directories+=("$LIBVA_DRIVERS_PATH")
fi

searched=0

for directory in "${driver_directories[@]}"; do
  if [ -d "$directory" ]; then
    searched=1
    found="$(find "$directory" -maxdepth 1 -name '*_drv_video.so' -exec basename {} \; | sort || true)"
    printf '%s:\n' "$directory"
    printf '%s\n' "${found:-  none}" | sed 's/^\([^ ]\)/  \1/'
  fi
done

if [ "$searched" -eq 0 ]; then
  printf 'none of the usual driver directories exist on this machine\n'
fi

heading 'what the card reports'
VAINFO="$(dirname "$FFMPEG")/vainfo"

if [ -x "$VAINFO" ]; then
  "$VAINFO" --display drm --device "$DEVICE" || true
elif command -v vainfo >/dev/null; then
  vainfo --display drm --device "$DEVICE" || true
else
  printf 'no vainfo alongside %s and none on PATH, skipping\n' "$FFMPEG"
fi

heading 'hardware encoders compiled into this build'
"$FFMPEG" -hide_banner -encoders |
  grep -E '(vaapi|amf|qsv|nvenc|videotoolbox|rkmpp)' || printf 'none\n'

# An encoder absent from the list above cannot verify below, and its failure
# says nothing about the hardware. Read the two sections together.

heading 'encoders WITHOUT a device — what a deviceless probe reports'
for encoder in "${VAAPI_ENCODERS[@]}"; do
  probe_encoder "$encoder" bare
done

heading 'encoders WITH a device — what the transcoder actually does'
for encoder in "${VAAPI_ENCODERS[@]}"; do
  probe_encoder "$encoder" vaapi
done

# FLUX-79. The probes above prove an encoder opens; this proves decode, scale
# and encode can pass frames without a round trip through system memory, which
# is the difference the pipeline was built for. It needs a real encoded input,
# so lavfi output is written to a file first — decoding a software-generated
# frame would test nothing.
heading 'the zero-copy chain'
WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$WORKSPACE"' EXIT

SAMPLE="$WORKSPACE/sample.mp4"

if "$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1280x720:rate=25 -frames:v 50 \
  -c:v libx264 -preset ultrafast "$SAMPLE" 2>/dev/null; then
  chain_complaint=''
  chain_status=0
  chain_complaint="$("$FFMPEG" -hide_banner -loglevel error \
    -init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va \
    -hwaccel vaapi -hwaccel_output_format vaapi \
    -i "$SAMPLE" \
    -vf 'scale_vaapi=w=640:h=360:format=nv12' \
    -c:v h264_vaapi -frames:v 25 -f null - 2>&1 >/dev/null)" || chain_status=$?

  if [ "$chain_status" -eq 0 ]; then
    printf '  decode → scale_vaapi → encode: WORKS, frames stayed on the device\n'
  else
    printf '  decode → scale_vaapi → encode: FAILS — %s\n' "$(last_line "$chain_complaint")"
  fi
else
  printf '  could not build a sample to decode, so the chain was not tested\n'
fi

# Runs one filter chain and reports whether ffmpeg accepted it.
#
# Every chain below is copied from what apps/transcoder/src/transcode_plan.rs
# emits for VAAPI, and has to be kept in step with it by hand. A probe that
# passes while differing from what the service sends is worse than no probe,
# which is the same reasoning PROBE_SIZE carries.
#
# Run more than once, because one of these is not deterministic. The text
# subtitle chain passed twice and then aborted inside the VAAPI encoder on an
# RX 580 — `Assertion !avpkt->data && !avpkt->buf failed at encode.c:112` —
# with nothing changed between the runs. A single pass cannot tell "this works"
# from "this works two times in three", and the difference decides whether the
# route is shippable.
CHAIN_ATTEMPTS="${VALENCE_CHAIN_ATTEMPTS:-5}"

probe_chain() {
  local label="$1"
  shift

  local passes=0 complaint='' status attempt
  for attempt in $(seq 1 "$CHAIN_ATTEMPTS"); do
    status=0
    local output
    output="$("$FFMPEG" -hide_banner -loglevel error "$@" 2>&1 >/dev/null)" || status=$?

    if [ "$status" -eq 0 ]; then
      passes=$((passes + 1))
    elif [ -z "$complaint" ]; then
      complaint="$output"
    fi
  done

  if [ "$passes" -eq "$CHAIN_ATTEMPTS" ]; then
    printf '  %-34s WORKS  %d/%d\n' "$label" "$passes" "$CHAIN_ATTEMPTS"
    return 0
  fi

  if [ "$passes" -gt 0 ]; then
    printf '  %-34s FLAKY  %d/%d — %s\n' \
      "$label" "$passes" "$CHAIN_ATTEMPTS" "$(last_line "$complaint")"
    return 0
  fi

  printf '  %-34s FAILS  0/%d — %s\n' "$label" "$CHAIN_ATTEMPTS" "$(last_line "$complaint")"
}

# A build either has a filter or it does not, and Valence probes for exactly these
# before choosing a route. Reporting them separately means a missing filter
# reads as "not compiled in" rather than as a broken chain further down.
heading 'the filters each route needs'
LISTED_FILTERS="$("$FFMPEG" -hide_banner -filters 2>/dev/null | awk '{print $2}')"

for filter in scale_vaapi overlay_vaapi tonemap_vaapi; do
  if printf '%s\n' "$LISTED_FILTERS" | grep -qx "$filter"; then
    printf '  %-16s present\n' "$filter"
  else
    printf '  %-16s MISSING — Valence falls back for anything needing it\n' "$filter"
  fi
done

# Burning subtitles in no longer brings the video down: the subtitle is built as
# its own small stream, uploaded, and composited on the device. Both kinds are
# tested because they reach the compositor by different routes — a bitmap
# subtitle is already a picture, and text is drawn onto a transparent canvas.
heading 'burning subtitles in without bringing the video down'

if [ ! -s "$SAMPLE" ]; then
  printf '  no sample to work from, so nothing here was tested\n'
else
  SUBTITLES="$WORKSPACE/subs.srt"
  printf '1\n00:00:00,000 --> 00:00:10,000\nValence burns this in on the device\n' >"$SUBTITLES"

  TEXT_SAMPLE="$WORKSPACE/text.mkv"

  if "$FFMPEG" -hide_banner -loglevel error -y -i "$SAMPLE" -i "$SUBTITLES" \
    -c:v copy -c:s srt "$TEXT_SAMPLE" 2>/dev/null; then
    probe_chain 'text, composited on the device' \
      -init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va \
      -hwaccel vaapi -hwaccel_output_format vaapi \
      -i "$TEXT_SAMPLE" -frames:v 25 \
      -filter_complex "[0:v]scale_vaapi=w=640:h=360[base];alphasrc=s=640x360:r=25,format=bgra,subtitles='$TEXT_SAMPLE':si=0:alpha=1:sub2video=1,hwupload=derive_device=vaapi[sub];[base][sub]overlay_vaapi=eof_action=pass:repeatlast=0[v]" \
      -map '[v]' -c:v h264_vaapi -f null -
  else
    printf '  could not mux text subtitles, so that chain was not tested\n'
  fi

  # An image stands in for the subtitle stream, because ffmpeg will not make one:
  # it refuses to encode text to a bitmap format at all, so there is no way to
  # synthesise a PGS or dvdsub track without a disc rip to hand.
  #
  # What this still proves is the whole hardware path — the pad and crop, the
  # conversion, the upload and overlay_vaapi itself. What it does not cover is
  # ffmpeg turning a real subtitle stream into frames, which is ordinary
  # subtitle decoding rather than anything the pipeline work changed.
  OVERLAY_IMAGE="$WORKSPACE/overlay.png"

  if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i 'color=c=white@0.5:s=720x576' -frames:v 1 "$OVERLAY_IMAGE" 2>/dev/null; then
    probe_chain 'bitmap, composited on the device' \
      -init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va \
      -hwaccel vaapi -hwaccel_output_format vaapi \
      -i "$SAMPLE" -i "$OVERLAY_IMAGE" -frames:v 25 \
      -filter_complex '[0:v]scale_vaapi=w=640:h=360[base];[1:v]scale,scale=-1:360:fast_bilinear,crop,pad=max(640\,iw):max(360\,ih):(ow-iw)/2:(oh-ih)/2:black@0,crop=640:360,format=bgra,hwupload=derive_device=vaapi[sub];[base][sub]overlay_vaapi=eof_action=pass:repeatlast=0[v]' \
      -map '[v]' -c:v h264_vaapi -f null -
  else
    printf '  could not build an overlay, so that chain was not tested\n'
  fi
fi

# Converting HDR used to send the whole session into software, because the
# conversion has to precede the scale and a round trip around it would drag the
# scale down too. tonemap_vaapi does it where the frames already are.
heading 'converting HDR without bringing the video down'
HDR_SAMPLE="$WORKSPACE/hdr.mkv"

if "$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1280x720:rate=25 -frames:v 50 \
  -pix_fmt yuv420p10le -c:v libx265 -preset ultrafast \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  "$HDR_SAMPLE" 2>/dev/null; then
  probe_chain 'tone map then scale, on the device' \
    -init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va \
    -hwaccel vaapi -hwaccel_output_format vaapi \
    -i "$HDR_SAMPLE" -frames:v 25 \
    -vf 'tonemap_vaapi=format=nv12:p=bt709:t=bt709:m=bt709,scale_vaapi=w=640:h=360' \
    -c:v h264_vaapi -f null -

  # The combination is worth its own probe: it is the chain an HDR film with
  # forced subtitles produces, and the one with the most to go wrong.
  if [ -s "${OVERLAY_IMAGE:-}" ]; then
    probe_chain 'tone map and composite together' \
      -init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va \
      -hwaccel vaapi -hwaccel_output_format vaapi \
      -i "$HDR_SAMPLE" -i "$OVERLAY_IMAGE" -frames:v 25 \
      -filter_complex '[0:v]tonemap_vaapi=format=nv12:p=bt709:t=bt709:m=bt709,scale_vaapi=w=640:h=360[base];[1:v]scale,scale=-1:360:fast_bilinear,crop,pad=max(640\,iw):max(360\,ih):(ow-iw)/2:(oh-ih)/2:black@0,crop=640:360,format=bgra,hwupload=derive_device=vaapi[sub];[base][sub]overlay_vaapi=eof_action=pass:repeatlast=0[v]' \
      -map '[v]' -c:v h264_vaapi -f null -
  fi
else
  printf '  could not build an HDR sample, so tone mapping was not tested\n'
fi

# The chains above ask what the hardware can do. This asks what Valence will
# decide about it, by running the probe the service runs — tone_map_probe_
# arguments in apps/transcoder/src/capability.rs, kept in step with this by
# hand like the rest.
#
# Worth reporting separately because the two answers differ on purpose. A card
# that cannot tone map is not a fault to fix; it is a machine that converts HDR
# in software, which is what every machine did until recently. What would be a
# fault is Valence believing otherwise, and this is the line that says which.
heading 'what Valence will conclude about tone mapping'

if printf '%s\n' "$LISTED_FILTERS" | grep -qx tonemap_vaapi; then
  # Which half failed. The probe uploads a ten-bit frame and then tone maps it,
  # and a driver can refuse either — Polaris takes P010 for HEVC Main10 decode,
  # which says nothing about whether it will accept one uploaded. Reporting
  # only the pair leaves the reader unable to tell "this card cannot tone map"
  # from "this probe asks for the wrong thing", and those want opposite fixes.
  upload_status=0
  "$FFMPEG" -hide_banner -loglevel error \
    -init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va \
    -f lavfi -i "testsrc2=size=${PROBE_SIZE}:rate=1" -frames:v 1 \
    -vf 'format=p010,hwupload' -f null - >/dev/null 2>&1 || upload_status=$?

  if [ "$upload_status" -eq 0 ]; then
    printf '  ten-bit frames upload to the device\n'
  else
    printf '  ten-bit frames will NOT upload to this device\n'
  fi

  tonemap_status=0
  tonemap_complaint="$("$FFMPEG" -hide_banner -loglevel error \
    -init_hw_device "vaapi=va:$DEVICE" -filter_hw_device va \
    -f lavfi -i "testsrc2=size=${PROBE_SIZE}:rate=1" -frames:v 1 \
    -vf 'format=p010,hwupload,tonemap_vaapi=format=nv12:p=bt709:t=bt709:m=bt709' \
    -f null - 2>&1 >/dev/null)" || tonemap_status=$?

  if [ "$tonemap_status" -eq 0 ]; then
    printf '  HDR converts on the device\n'
  else
    printf '  HDR converts in software — the filter would not run\n'
    printf '    %s\n' "$(last_line "$tonemap_complaint")"

    # Only where there was a device to refuse it. Without one this says nothing
    # about the driver, and naming a vendor would be a guess dressed as a
    # finding.
    if [ -e "$DEVICE" ]; then
      printf '    expected on AMD: VAAPI VPP tone mapping is an Intel capability\n'
    fi
  fi
else
  printf '  HDR converts in software — this build has no tonemap_vaapi\n'
fi

heading 'done'
