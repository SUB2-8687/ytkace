#!/usr/bin/env python3
"""Turn a cloud-drive share link into direct-download candidate URLs.

usage:
  resolve_ipa_url.py URL                 print candidate URLs, one per line
  resolve_ipa_url.py --confirm-form FILE print the follow-up download URL found
                                         in a Google Drive "virus scan" page
"""

import base64
import html
import re
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit, quote

DROPBOX_HOSTS = ("dropbox.com", "dropboxusercontent.com")
GOOGLE_HOSTS = ("drive.google.com", "docs.google.com", "drive.usercontent.google.com")
ONEDRIVE_HOSTS = ("1drv.ms", "onedrive.live.com")


def _host(parts) -> str:
    return (parts.hostname or "").lower()


def _host_is(host: str, names) -> bool:
    return any(host == name or host.endswith("." + name) for name in names)


def _with_query(parts, drop=(), add=()):
    pairs = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
             if k not in drop]
    pairs.extend(add)
    return urlunsplit((parts.scheme, parts.netloc, parts.path,
                       urlencode(pairs, quote_via=quote), ""))


def dropbox(parts):
    if parts.path.startswith(("/scl/fo/", "/sh/", "/s/folder")):
        raise ValueError("Dropbox 폴더 링크입니다. IPA 파일 자체의 공유 링크를 넣어주세요.")
    primary = _with_query(parts, drop=("dl", "raw"), add=(("dl", "1"),))
    result = [primary]
    if _host(parts) in ("www.dropbox.com", "dropbox.com"):
        # 같은 공유 링크를 직접 다운로드 전용 호스트로도 시도 (웹앱 페이지가 내려올 때의 대비책)
        result.append(urlunsplit(urlsplit(primary)._replace(netloc="dl.dropboxusercontent.com")))
    return result


def google_drive(parts):
    if "/folders/" in parts.path or "/drive/folders" in parts.path:
        raise ValueError("Google Drive 폴더 링크입니다. IPA 파일 자체의 공유 링크를 넣어주세요.")
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    match = re.search(r"/(?:file/)?d/([A-Za-z0-9_-]{10,})", parts.path)
    file_id = match.group(1) if match else query.get("id")
    if not file_id:
        raise ValueError("Google Drive 링크에서 파일 ID를 찾지 못했습니다.")
    extra = []
    if query.get("resourcekey"):
        extra.append(("resourcekey", query["resourcekey"]))
    first = urlencode([("id", file_id), ("export", "download"), ("confirm", "t")] + extra)
    second = urlencode([("export", "download"), ("id", file_id)] + extra)
    return [
        "https://drive.usercontent.google.com/download?" + first,
        "https://drive.google.com/uc?" + second,
    ]


def onedrive_share_api(url: str) -> str:
    token = base64.urlsafe_b64encode(url.encode("utf-8")).decode("ascii").rstrip("=")
    return "https://api.onedrive.com/v1.0/shares/u!" + token + "/root/content"


def onedrive(url, parts):
    candidates = [onedrive_share_api(url)]
    if _host(parts) == "onedrive.live.com":
        path = re.sub(r"/(redir|embed|view\.aspx)$", "/download", parts.path)
        candidates.append(_with_query(parts._replace(path=path), drop=("download",),
                                      add=(("download", "1"),)))
    return candidates


def sharepoint(parts):
    return [_with_query(parts, drop=("download",), add=(("download", "1"),))]


def candidates(url: str):
    url = url.strip().strip("'\"")
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("http(s) 로 시작하는 올바른 URL이 아닙니다.")
    host = _host(parts)
    if _host_is(host, DROPBOX_HOSTS):
        return dropbox(parts)
    if _host_is(host, GOOGLE_HOSTS):
        return google_drive(parts)
    if host in ONEDRIVE_HOSTS:
        return onedrive(url, parts)
    if host.endswith(".sharepoint.com") or host.endswith(".sharepoint.cn"):
        return sharepoint(parts)
    return [url]


def confirm_form_url(page: str):
    form = re.search(r"<form[^>]+id=[\"']download-form[\"'][^>]*>", page, re.I)
    if not form:
        form = re.search(r"<form[^>]+action=[\"'][^\"']*(?:download|uc)[^\"']*[\"'][^>]*>",
                         page, re.I)
    if not form:
        return None
    action = re.search(r"action=[\"']([^\"']+)[\"']", form.group(0), re.I)
    if not action:
        return None
    body = page[form.end():page.find("</form>", form.end())]
    fields = []
    for tag in re.findall(r"<input[^>]+>", body, re.I):
        name = re.search(r"name=[\"']([^\"']*)[\"']", tag, re.I)
        value = re.search(r"value=[\"']([^\"']*)[\"']", tag, re.I)
        if name:
            fields.append((html.unescape(name.group(1)),
                           html.unescape(value.group(1)) if value else ""))
    target = html.unescape(action.group(1))
    if not fields:
        return target
    return target + ("&" if "?" in target else "?") + urlencode(fields)


def main(argv) -> int:
    if len(argv) == 3 and argv[1] == "--confirm-form":
        with open(argv[2], "r", encoding="utf-8", errors="replace") as handle:
            target = confirm_form_url(handle.read())
        if not target:
            return 1
        print(target)
        return 0
    if len(argv) != 2:
        print("usage: resolve_ipa_url.py URL", file=sys.stderr)
        return 2
    try:
        for item in candidates(argv[1]):
            print(item)
    except ValueError as error:
        print("error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
