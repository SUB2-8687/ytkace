import base64
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))

import resolve_ipa_url  # noqa: E402


class ResolveIpaUrlTests(unittest.TestCase):
    def test_dropbox_forces_direct_download(self):
        url = "https://www.dropbox.com/scl/fi/abc/app.ipa?rlkey=KEY&st=x&dl=0"
        result, fallback = resolve_ipa_url.candidates(url)
        self.assertIn("dl=1", result)
        self.assertNotIn("dl=0", result)
        self.assertIn("rlkey=KEY", result)
        self.assertTrue(result.startswith("https://www.dropbox.com/scl/fi/abc/app.ipa?"))
        self.assertTrue(fallback.startswith("https://dl.dropboxusercontent.com/scl/fi/abc/app.ipa?"))
        self.assertIn("rlkey=KEY", fallback)
        self.assertIn("dl=1", fallback)

    def test_dropbox_usercontent_has_no_extra_fallback(self):
        result = resolve_ipa_url.candidates("https://dl.dropboxusercontent.com/s/abc/app.ipa?dl=0")
        self.assertEqual(len(result), 1)
        self.assertIn("dl=1", result[0])

    def test_dropbox_raw_link_is_converted(self):
        result = resolve_ipa_url.candidates("https://www.dropbox.com/s/abc/app.ipa?raw=1")[0]
        self.assertNotIn("raw=", result)
        self.assertIn("dl=1", result)

    def test_dropbox_folder_is_rejected(self):
        with self.assertRaises(ValueError):
            resolve_ipa_url.candidates("https://www.dropbox.com/scl/fo/abc/xyz?rlkey=K&dl=0")

    def test_google_drive_file_link(self):
        file_id = "1AbCdEfGhIjKlMnOpQrStUvWxYz012345"
        for url in (
            f"https://drive.google.com/file/d/{file_id}/view?usp=sharing",
            f"https://drive.google.com/open?id={file_id}",
            f"https://drive.google.com/uc?id={file_id}&export=download",
            f"https://drive.google.com/file/u/0/d/{file_id}/view",
        ):
            result = resolve_ipa_url.candidates(url)
            self.assertEqual(len(result), 2, url)
            self.assertTrue(result[0].startswith("https://drive.usercontent.google.com/download?"))
            self.assertIn(f"id={file_id}", result[0])
            self.assertIn("confirm=t", result[0])
            self.assertIn(f"id={file_id}", result[1])

    def test_google_drive_resource_key_is_kept(self):
        url = "https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUv/view?resourcekey=0-RK"
        for result in resolve_ipa_url.candidates(url):
            self.assertIn("resourcekey=0-RK", result)

    def test_google_drive_folder_is_rejected(self):
        with self.assertRaises(ValueError):
            resolve_ipa_url.candidates("https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUv")

    def test_onedrive_share_api(self):
        url = "https://1drv.ms/u/s!AbCdEf"
        result = resolve_ipa_url.candidates(url)[0]
        token = base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")
        self.assertEqual(result, f"https://api.onedrive.com/v1.0/shares/u!{token}/root/content")

    def test_sharepoint_download_flag(self):
        url = "https://contoso.sharepoint.com/:u:/s/team/EabC?e=xyz"
        (result,) = resolve_ipa_url.candidates(url)
        self.assertIn("download=1", result)
        self.assertIn("e=xyz", result)

    def test_plain_url_is_unchanged(self):
        url = "https://example.com/files/app.ipa"
        self.assertEqual(resolve_ipa_url.candidates(url), [url])

    def test_quotes_and_whitespace_are_stripped(self):
        self.assertEqual(
            resolve_ipa_url.candidates('  "https://example.com/a.ipa" \n'),
            ["https://example.com/a.ipa"],
        )

    def test_invalid_url_is_rejected(self):
        with self.assertRaises(ValueError):
            resolve_ipa_url.candidates("not a url")

    def test_confirm_form_is_followed(self):
        page = (
            '<form id="download-form" action="https://drive.usercontent.google.com/download" method="get">'
            '<input type="hidden" name="id" value="FILEID">'
            '<input type="hidden" name="export" value="download">'
            '<input type="hidden" name="confirm" value="t">'
            '<input type="hidden" name="uuid" value="a&amp;b"></form>'
        )
        result = resolve_ipa_url.confirm_form_url(page)
        self.assertTrue(result.startswith("https://drive.usercontent.google.com/download?"))
        self.assertIn("id=FILEID", result)
        self.assertIn("uuid=a%26b", result)

    def test_cli_prints_candidates_and_reports_errors(self):
        script = ROOT / "Tools" / "resolve_ipa_url.py"
        ok = subprocess.run([sys.executable, str(script), "https://example.com/a.ipa"],
                            capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0)
        self.assertEqual(ok.stdout.strip(), "https://example.com/a.ipa")
        bad = subprocess.run([sys.executable, str(script), "ftp://x"],
                             capture_output=True, text=True)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("error:", bad.stderr)

    def test_confirm_form_cli(self):
        script = ROOT / "Tools" / "resolve_ipa_url.py"
        with tempfile.TemporaryDirectory() as tmp:
            page = pathlib.Path(tmp) / "page.html"
            page.write_text("<html>no form</html>", encoding="utf-8")
            result = subprocess.run([sys.executable, str(script), "--confirm-form", str(page)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
