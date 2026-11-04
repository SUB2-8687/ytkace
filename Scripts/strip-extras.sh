#!/usr/bin/env bash
# YouTube.app 정리 스크립트
#  1) PlugIns / Extensions(앱 확장, 위젯, 공유 확장 등) 전체 삭제
#  2) YTKACE.bundle 안에서 en.lproj, ko.lproj 외 언어팩 삭제
#     (YouTube 앱 자체의 언어팩은 건드리지 않음)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: strip-extras.sh YouTube.app" >&2
  exit 2
fi

APP="$(cd "$1" && pwd)"
test -d "$APP"

# 1) 플러그인(앱 확장) 전체 삭제 — 삭제 후 서명 대상에서도 제외됨
rm -rf "$APP/PlugIns" "$APP/Extensions"
find "$APP" -type d -name '*.appex' -prune -exec rm -rf {} + 2>/dev/null || true

# 2) YTKACE 트윅 언어팩만 정리 (en / ko 유지)
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

echo "strip-extras: removed PlugIns/Extensions and $removed YTKACE language packs"
