#!/usr/bin/env python3
"""Temporary-fixture tests for stamp_article_version.py."""

from __future__ import annotations

import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("stamp_article_version.py")


class StampArticleVersionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "article.md"
        self.html = self.root / "article" / "index.html"
        self.html.parent.mkdir()
        self.source.write_bytes(b"---\ntitle: Example\n---\n\n# Exact source\n")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--source", str(self.source), "--html", str(self.html), *extra],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_stamp_is_idempotent_and_check_is_read_only(self) -> None:
        self.html.write_text("<!doctype html><html><head><title>A</title></head><body>Body</body></html>")

        first = self.command()
        stamped = self.html.read_bytes()
        second = self.command()
        checked = self.command("--check")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout.strip(), "stamped")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout.strip(), "already-stamped")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(checked.stdout.strip(), "verified")
        self.assertEqual(self.html.read_bytes(), stamped)
        self.assertIn(self.digest(), self.html.read_text())

    def test_check_reports_missing_and_mismatched_marker_without_writing(self) -> None:
        self.html.write_text("<html><head></head><body>Body</body></html>")
        missing = self.command("--check")
        before = self.html.read_bytes()
        self.assertEqual(missing.returncode, 1)
        self.assertIn("unknown", missing.stdout)
        self.assertEqual(self.html.read_bytes(), before)

        self.html.write_text(
            '<html><head><meta name="repopress:source-digest" content="' + "0" * 64
            + '"></head><body>Body</body></html>'
        )
        mismatch = self.command("--check")
        self.assertEqual(mismatch.returncode, 1)
        self.assertIn("failed", mismatch.stdout)
        repaired = self.command()
        self.assertEqual(repaired.returncode, 0, repaired.stderr)
        self.assertEqual(self.command("--check").returncode, 0)

    def test_rejects_ambiguous_or_invalid_head_inputs(self) -> None:
        for body in [
            "<html><body>no head</body></html>",
            "<html>< head></ head></html>",
            '<head><meta name="repopress:source-digest" content="bad"></head>',
            "<html><head></head><head></head><body>two heads</body></html>",
            '<html><head><meta name="repopress:source-digest" content="' + "1" * 64
            + '"><meta name="repopress:source-digest" content="' + "2" * 64
            + '"></head></html>',
        ]:
            with self.subTest(body=body):
                self.html.write_text(body)
                result = self.command()
                self.assertEqual(result.returncode, 2)
                self.assertTrue(result.stderr.startswith("error:"))

    def test_comment_and_script_marker_text_do_not_count_as_a_head_marker(self) -> None:
        fake = '<meta name="repopress:source-digest" content="' + "a" * 64 + '">'
        self.html.write_text(
            "<html><head><!-- " + fake + " -->"
            + "<script>const marker = '" + fake + "';</script>"
            + "<title>" + fake + "</title><textarea>" + fake + "</textarea>"
            + "<template>" + fake + "</template><noscript>" + fake + "</noscript>"
            + "</head><body>Body</body></html>"
        )

        self.assertEqual(self.command("--check").returncode, 1)
        stamped = self.command()
        after = self.html.read_text()

        self.assertEqual(stamped.returncode, 0, stamped.stderr)
        self.assertIn("<!-- " + fake + " -->", after)
        self.assertIn("const marker = '" + fake + "';", after)
        self.assertIn("<title>" + fake + "</title>", after)
        self.assertIn("<textarea>" + fake + "</textarea>", after)
        self.assertIn("<template>" + fake + "</template>", after)
        self.assertIn("<noscript>" + fake + "</noscript>", after)
        self.assertIn(
            '<meta name="repopress:source-digest" content="' + self.digest() + '">',
            after,
        )
        self.assertEqual(self.command("--check").returncode, 0)

    def test_nested_template_and_script_comparisons_preserve_real_head_marker(self) -> None:
        fake = '<meta name="repopress:source-digest" content="' + self.digest() + '">'
        template = "<template><template><script>const s = '</template>';</script></template>" + fake + "</template>"
        script = "<script>if(a<b){} </script-not-real>" + fake + "</SCRIPT >"
        self.html.write_text("<html><head>" + template + script + "</head><body>Body</body></html>")
        self.assertEqual(self.command("--check").returncode, 1)
        result = self.command()
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.html.read_text()
        self.assertIn(template, after)
        self.assertIn(script, after)
        self.assertEqual(after.count("repopress:source-digest"), 3)
        self.assertEqual(self.command("--check").returncode, 0)

    def test_case_and_entity_spelled_marker_is_updated_instead_of_duplicated(self) -> None:
        self.html.write_text(
            '<html><head><META NAME="RepoPress&#58;Source-Digest" CONTENT="' + "0" * 64
            + '"></head><body>Body</body></html>'
        )

        self.assertIn("failed", self.command("--check").stdout)
        result = self.command()
        output = self.html.read_text()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.count("repopress:source-digest"), 1)
        self.assertIn(self.digest(), output)
        self.assertEqual(self.command("--check").returncode, 0)

    def test_rejects_same_file_and_non_utf8_html(self) -> None:
        same = subprocess.run(
            [sys.executable, str(SCRIPT), "--source", str(self.source), "--html", str(self.source)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(same.returncode, 2)
        self.assertIn("different files", same.stderr)

        alias = self.root / "article-alias.html"
        alias.symlink_to(self.source)
        through_alias = subprocess.run(
            [sys.executable, str(SCRIPT), "--source", str(self.source), "--html", str(alias)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(through_alias.returncode, 2)
        self.assertIn("different files", through_alias.stderr)

        self.html.write_bytes(b"\xff\xfe")
        invalid_encoding = self.command()
        self.assertEqual(invalid_encoding.returncode, 2)
        self.assertIn("UTF-8", invalid_encoding.stderr)

    def digest(self) -> str:
        return hashlib.sha256(self.source.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
