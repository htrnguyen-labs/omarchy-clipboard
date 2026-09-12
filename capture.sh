#!/bin/bash

# Captures the current clipboard as a JSON entry on stdout. In watch mode,
# wl-paste invokes this with the payload on stdin and the mime as $1. Without
# arguments, it snapshots the current selection itself.

set -o pipefail

STATE_HELPER="${0%/*}/clipboard-state"
MAX_TEXT_BYTES=65536
MAX_TYPES_BYTES=8192
[[ $STATE_HELPER == /* && -f $STATE_HELPER && ! -L $STATE_HELPER ]] || exit 0

types=$(
  /usr/bin/timeout --signal=TERM --kill-after=1s 2s /usr/bin/wl-paste --list-types 2>/dev/null |
    /usr/bin/head -c "$((MAX_TYPES_BYTES + 1))"
) || exit 0
(( ${#types} <= MAX_TYPES_BYTES )) || exit 0

if [[ ${CLIPBOARD_STATE:-} == "sensitive" ]] || /usr/bin/grep -qx 'x-kde-passwordManagerHint' <<<"$types"; then
  exit 0
fi

emit_image() {
  /usr/bin/python3 "$STATE_HELPER" image "$1"
}

emit_text() {
  /usr/bin/head -c "$((MAX_TEXT_BYTES + 1))" | /usr/bin/perl -MEncode=decode,FB_CROAK,LEAVE_SRC -MJSON::PP=encode_json -0777 -e '
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
text) emit_text; exit 0 ;;
image/*) emit_image "$1"; exit 0 ;;
esac

for mime in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
  if /usr/bin/grep -qx "$mime" <<<"$types"; then
    /usr/bin/timeout 2s /usr/bin/wl-paste --type "$mime" 2>/dev/null | emit_image "$mime"
    exit 0
  fi
done

if /usr/bin/grep -q '^text/' <<<"$types" || /usr/bin/grep -qx 'UTF8_STRING' <<<"$types" || /usr/bin/grep -qx 'STRING' <<<"$types"; then
  /usr/bin/wl-paste --type text --no-newline 2>/dev/null | emit_text
fi
