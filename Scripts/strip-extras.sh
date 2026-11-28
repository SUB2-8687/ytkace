#!/usr/bin/env bash
# YouTube.app 정리 스크립트
#  YTKACE.bundle 안에서 en.lproj, ko.lproj 외 언어팩 삭제
#  (YouTube 앱 자체의 언어팩은 건드리지 않음)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: strip-extras.sh YouTube.app" >&2
  exit 2
fi

APP="$(cd "$1" && pwd)"
test -d "$APP"

# YTKACE 트윅 언어팩만 정리 (en / ko 유지)
BUNDLE="$APP/YTKACE.bundle"
removed=0
if [[ -d "$BUNDLE" ]]; then
  while IFS= read -r lproj; do
    case "$(basename "$lproj")" in
      en.lproj|ko.lproj) ;;
      *) rm -rf "$lproj"; removed=$((removed + 1)) ;;
    esac
  done < <(find "$BUNDLE" -type d -name '*.lproj' -prune)
fi

echo "strip-extras: removed $removed YTKACE language packs"
