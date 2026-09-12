#!/bin/bash

# Captures the current clipboard as a JSON entry on stdout. In watch mode,
# wl-paste invokes this with the payload on stdin and the mime as $1. Without
# arguments, it snapshots the current selection itself.

set -o pipefail
umask 077

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/clipboard-images"
HISTORY_PATH="$STATE_DIR/clipboard-history.json"
PINNED_PATH="$STATE_DIR/clipboard-pinned.json"
MAX_TEXT_BYTES=65536
MAX_IMAGE_BYTES=$((2 * 1024 * 1024))
MAX_IMAGE_STORE_BYTES=$((32 * 1024 * 1024))
MAX_STATE_BYTES=$((1024 * 1024))

ensure_private_state() {
  [[ ! -L $STATE_DIR && ! -L $IMAGE_DIR ]] || return 1
  /usr/bin/install -d -m 700 -- "$STATE_DIR" "$IMAGE_DIR" || return 1
  for path in "$HISTORY_PATH" "$PINNED_PATH"; do
    [[ ! -L $path && ( ! -e $path || -f $path ) ]] || return 1
    [[ -e $path ]] || : >"$path"
    /usr/bin/chmod 600 -- "$path" || return 1
    local size
    size=$(/usr/bin/stat -c %s -- "$path") || return 1
    (( size <= MAX_STATE_BYTES )) || printf '[]\n' >"$path"
  done
}

image_store_bytes() {
  /usr/bin/find -P "$IMAGE_DIR" -maxdepth 1 -type f -printf '%s\n' 2>/dev/null |
    /usr/bin/awk '{ total += $1 } END { print total + 0 }'
}

prune_orphans() {
  [[ -f $HISTORY_PATH && ! -L $HISTORY_PATH ]] || return 0
  local refs file
  refs=$(/usr/bin/jq -r '.[]? | select(.type == "image") | .path' "$HISTORY_PATH" 2>/dev/null) || return 0
  while IFS= read -r -d '' file; do
    /usr/bin/grep -Fqx -- "$file" <<<"$refs" || /usr/bin/rm -f -- "$file"
  done < <(/usr/bin/find -P "$IMAGE_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
}

ensure_private_state || exit 0

if [[ ${1:-} == secure-state ]]; then
  prune_orphans
  exit 0
fi

types=$(/usr/bin/wl-paste --list-types 2>/dev/null || true)

if [[ ${CLIPBOARD_STATE:-} == "sensitive" ]] || grep -qx 'x-kde-passwordManagerHint' <<<"$types"; then
  exit 0
fi

emit_image() {
  local mime="$1"
  local ext tmp hash file

  ext=${mime#image/}
  [[ $ext == jpeg ]] && ext=jpg

  tmp=$(/usr/bin/mktemp --tmpdir="$IMAGE_DIR" clipboard.XXXXXX) || return 0
  /usr/bin/head -c "$((MAX_IMAGE_BYTES + 1))" >"$tmp"
  if [[ ! -s $tmp ]]; then
    /usr/bin/rm -f -- "$tmp"
    return 0
  fi

  local size total
  size=$(/usr/bin/stat -c %s -- "$tmp") || { /usr/bin/rm -f -- "$tmp"; return 0; }
  (( size <= MAX_IMAGE_BYTES )) || { /usr/bin/rm -f -- "$tmp"; return 0; }
  prune_orphans
  total=$(image_store_bytes)
  (( total + size <= MAX_IMAGE_STORE_BYTES )) || { /usr/bin/rm -f -- "$tmp"; return 0; }

  hash=$(/usr/bin/sha256sum "$tmp" | /usr/bin/awk '{print $1}')
  file="$IMAGE_DIR/$hash.$ext"
  if [[ -e $file ]]; then
    /usr/bin/rm -f -- "$tmp"
  else
    /usr/bin/mv -- "$tmp" "$file"
    /usr/bin/chmod 600 -- "$file"
  fi

  jq -cn --arg mime "$mime" --arg path "$file" --arg captured_at "$(date +'%A %H:%M')" \
    '{type:"image", mime:$mime, path:$path, capturedAt:$captured_at}'
}

emit_text() {
  /usr/bin/perl -MEncode=decode,FB_CROAK,LEAVE_SRC -MJSON::PP=encode_json -0777 -e '
    my $raw = <STDIN>;
    exit unless length $raw && length($raw) <= $ARGV[0];

    my $encoding;
    my $heuristic_encoding = 0;
    if ($raw =~ /^(?:\xFF\xFE|\xFE\xFF)/) {
      $encoding = "UTF-16";
    } elsif (length($raw) % 2 == 0 && index($raw, "\0") >= 0) {
      my $units = length($raw) / 2;
      my $nuls = $raw =~ tr/\0/\0/;

      # Neither byte lane can reach the padding threshold when the entire
      # payload contains fewer NULs than that, so avoid two full string passes.
      if ($nuls * 4 >= $units * 3) {
        my $even_bytes = $raw;
        $even_bytes =~ s/(.)./$1/sg;
        my $even_nuls = $even_bytes =~ tr/\0/\0/;
        undef $even_bytes;

        my $odd_bytes = $raw;
        $odd_bytes =~ s/.(.)/$1/sg;
        my $odd_nuls = $odd_bytes =~ tr/\0/\0/;

        # BOM-less UTF-16 is indistinguishable from NUL-separated bytes. Decode
        # only when at least three quarters of the code units have consistent
        # padding and fewer than one quarter have NULs in the opposite byte.
        if ($odd_nuls * 4 >= $units * 3 && $even_nuls * 4 < $units) {
          $encoding = "UTF-16LE";
          $heuristic_encoding = 1;
        } elsif ($even_nuls * 4 >= $units * 3 && $odd_nuls * 4 < $units) {
          $encoding = "UTF-16BE";
          $heuristic_encoding = 1;
        }
      }
    }

    my $text = $encoding ? eval { decode($encoding, $raw, FB_CROAK | LEAVE_SRC) } : undef;
    if ($heuristic_encoding && defined($text) && $text =~ /[\x00-\x08\x0E-\x1A\x1C-\x1F]/) {
      $text = undef;
    }
    $text = decode("UTF-8", $raw) unless defined $text;
    print "{\"type\":\"text\",\"text\":", encode_json($text), "}\n";
  ' "$MAX_TEXT_BYTES"
}

case "${1:-}" in
text) /usr/bin/head -c "$((MAX_TEXT_BYTES + 1))" | emit_text; exit 0 ;;
image/*) emit_image "$1"; exit 0 ;;
esac

for mime in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
  if grep -qx "$mime" <<<"$types"; then
    /usr/bin/timeout 2s /usr/bin/wl-paste --type "$mime" 2>/dev/null | emit_image "$mime"
    exit 0
  fi
done

if grep -q '^text/' <<<"$types" || grep -qx 'UTF8_STRING' <<<"$types" || grep -qx 'STRING' <<<"$types"; then
  /usr/bin/wl-paste --type text --no-newline 2>/dev/null | /usr/bin/head -c "$((MAX_TEXT_BYTES + 1))" | emit_text
fi
