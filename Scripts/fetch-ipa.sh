#!/usr/bin/env bash
# YouTube IPA 다운로드 스크립트
#  - Dropbox / Google Drive(공유 드라이브 포함) / OneDrive·SharePoint 공유 링크를 직접 다운로드 주소로 변환
#  - GitHub 릴리스 에셋 URL(토큰 인증), 일반 직접 링크도 지원
#  - 받은 파일이 실제 IPA(zip + Payload/)인지 검증하고, 실패하면 원인을 로그에 출력
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: fetch-ipa.sh URL output.ipa" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="$1"
OUTPUT="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TMP="$WORK/download.bin"
HDR="$WORK/headers.txt"
JAR="$WORK/cookies.txt"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
LAST_REASON=""
UA_MODE="default"

host_of() {
  python3 -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).hostname or "?")' "$1"
}

file_size() {
  if [[ -f "$1" ]]; then wc -c <"$1" | tr -d ' '; else echo 0; fi
}

# 0=IPA 확인됨, 1=아님
is_ipa() {
  local file="$1"
  [[ -s "$file" ]] || { LAST_REASON="빈 파일"; return 1; }
  local magic
  magic="$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')"
  if [[ "$magic" != "504b0304" ]]; then
    LAST_REASON="zip 파일이 아님"
    return 1
  fi
  # 파이프 대신 변수에 담아 검사 (pipefail + grep -q 의 SIGPIPE 오탐 방지)
  local listing
  listing="$(unzip -Z1 "$file" 2>/dev/null || true)"
  if ! grep -q '^Payload/' <<<"$listing"; then
    LAST_REASON="zip 이지만 Payload/ 가 없음 (IPA 아님)"
    return 1
  fi
  return 0
}

describe_failure() {
  local file="$1" label="$2" host="$3"
  [[ -f "$file" ]] || : >"$file"
  echo "fetch-ipa: [$label] 실패 - ${LAST_REASON:-알 수 없음}, 크기 $(file_size "$file") bytes" >&2
  if [[ -f "$HDR" ]]; then
    grep -i -m3 '^HTTP/\|^content-type' "$HDR" | tr -d '\r' | sed 's/^/fetch-ipa:   /' >&2 || true
  fi
  if head -c 4096 "$file" | grep -qi '<html\|<!doctype'; then
    local title
    title="$(grep -o -i -m1 '<title>[^<]*' "$file" | head -1 | sed 's/<[tT][iI][tT][lL][eE]>//' | head -c 120 || true)"
    echo "fetch-ipa:   서버가 파일 대신 웹페이지를 반환했습니다${title:+ (제목: $title)}" >&2
    case "$host" in
      *google*)
        if grep -qi 'accounts.google.com\|ServiceLogin' "$file"; then
          echo "fetch-ipa:   -> 로그인이 필요한 링크입니다. 공유 설정을 '링크가 있는 모든 사용자'로 바꿔주세요." >&2
        fi
        if grep -qi 'too many users\|download quota\|다운로드 할당량' "$file"; then
          echo "fetch-ipa:   -> Google Drive 다운로드 할당량 초과입니다. 잠시 후 다시 시도하거나 내 드라이브에 사본을 만든 뒤 그 링크를 사용하세요." >&2
        fi
        ;;
      *dropbox*)
        echo "fetch-ipa:   -> Dropbox 링크가 만료/삭제되었거나 공유 권한이 막혀 있을 수 있습니다. 브라우저(시크릿 창)에서 같은 링크로 다운로드가 시작되는지 확인하세요." >&2
        ;;
      *sharepoint*|*onedrive*|*1drv*|*live.com)
        echo "fetch-ipa:   -> 조직 외부 공유가 허용된 '링크가 있는 모든 사용자' 링크인지 확인하세요." >&2
        ;;
    esac
  fi
}

# UA_MODE=default: curl 기본 User-Agent / browser: 브라우저 User-Agent + 쿠키
curl_get() {
  local url="$1"
  shift
  : >"$HDR"
  rm -f "$TMP"
  if [[ "$UA_MODE" == "browser" ]]; then
    curl --fail --location --silent --show-error \
      --retry 3 --retry-delay 2 --connect-timeout 30 \
      --user-agent "$UA" --cookie-jar "$JAR" --cookie "$JAR" \
      --dump-header "$HDR" --output "$TMP" "$@" "$url"
  else
    curl --fail --location --silent --show-error \
      --retry 3 --retry-delay 2 --connect-timeout 30 \
      --dump-header "$HDR" --output "$TMP" "$@" "$url"
  fi
}

finish() {
  mkdir -p "$(dirname "$OUTPUT")"
  mv -f "$TMP" "$OUTPUT"
  echo "fetch-ipa: OK ($(file_size "$OUTPUT") bytes) <- $1"
}

# GitHub 릴리스 에셋 (비공개 저장소 포함)
if [[ -n "${GITHUB_REPOSITORY:-}" && "$URL" == "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/assets/"* ]]; then
  curl_get "$URL" --header "Accept: application/octet-stream" \
    --header "Authorization: Bearer ${GH_TOKEN:-}"
  if is_ipa "$TMP"; then
    finish "api.github.com"
    exit 0
  fi
  describe_failure "$TMP" "api.github.com" "api.github.com"
  exit 1
fi

if ! CANDIDATES="$(python3 "$ROOT/Tools/resolve_ipa_url.py" "$URL")"; then
  echo "fetch-ipa: 링크를 해석하지 못했습니다. Dropbox/Google Drive/OneDrive 등의 파일 공유 링크 또는 직접 다운로드 링크를 넣어주세요." >&2
  exit 1
fi

attempt=0
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  chost="$(host_of "$candidate")"
  for UA_MODE in default browser; do
    attempt=$((attempt + 1))
    label="시도 $attempt: $chost ($UA_MODE UA)"
    echo "fetch-ipa: $label"

    if ! curl_get "$candidate"; then
      LAST_REASON="다운로드 요청 실패 (HTTP 오류 또는 네트워크 오류)"
      describe_failure "$TMP" "$label" "$chost"
      continue
    fi
    if is_ipa "$TMP"; then
      finish "$chost"
      exit 0
    fi

    # Google Drive 큰 파일: 바이러스 검사 경고 페이지의 폼을 따라가서 다시 받기
    case "$chost" in
      *google*)
        if head -c 4096 "$TMP" | grep -qi '<html\|<!doctype'; then
          if follow="$(python3 "$ROOT/Tools/resolve_ipa_url.py" --confirm-form "$TMP" 2>/dev/null)"; then
            echo "fetch-ipa: 확인 페이지를 통과해 다시 다운로드합니다 ($(host_of "$follow"))"
            if curl_get "$follow" && is_ipa "$TMP"; then
              finish "$(host_of "$follow")"
              exit 0
            fi
          fi
        fi
        ;;
    esac
    describe_failure "$TMP" "$label" "$chost"
  done
done <<<"$CANDIDATES"

echo "fetch-ipa: 모든 시도가 실패했습니다. 링크가 파일(.ipa) 하나를 가리키는지, 공유 권한이 '링크가 있는 모든 사용자'인지 확인하세요." >&2
exit 1
