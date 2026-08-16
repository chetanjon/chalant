#!/usr/bin/env bash
# Record one WAV per utterance. Usage: ./record.sh <context> [start_index]
# Contexts: short | longform | technical | rambling | propernoun
#
# FIRST TIME: find your mic's device index with
#   ffmpeg -f avfoundation -list_devices true -i ""
# then set AUDIO_DEV below (":0" is usually the built-in mic).
#
# Deliberately records from the BUILT-IN mic at mono/48k — the conditions your
# users will actually be in. Do not "improve" this with a USB mic.

AUDIO_DEV="${AUDIO_DEV:-:0}"
CTX="${1:?usage: ./record.sh <context> [start_index]}"
N="${2:-1}"
OUT="audio/$CTX"; mkdir -p "$OUT"

echo "Context: $CTX   Device: $AUDIO_DEV"
echo "ENTER = start/stop recording   |   q + ENTER = quit"
echo

while true; do
  printf "[%s-%02d] ready > " "$CTX" "$N"
  read -r key
  [ "$key" = "q" ] && break

  F=$(printf "%s/%s-%02d.wav" "$OUT" "$CTX" "$N")
  ffmpeg -nostdin -loglevel error -f avfoundation -i "$AUDIO_DEV" \
         -ar 48000 -ac 1 -y "$F" &
  PID=$!
  printf "  ● RECORDING — ENTER to stop "
  read -r _
  kill -INT "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$F" 2>/dev/null)
  printf "  saved %s (%.1fs)\n\n" "$F" "${DUR:-0}"
  N=$((N+1))
done
echo "Done. Next index for $CTX: $N"
