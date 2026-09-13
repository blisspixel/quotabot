"""Keep public OAuth exceptions bounded across Git diff fragment positions."""

from __future__ import annotations

import re
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PUBLIC_CLIENTS = (
    ("collector/lib/auth/google_auth.dart", "_publicClientSecret"),
    ("collector/lib/adapters/antigravity.dart", "_geminiClientSecret"),
)


class SecretScanPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with (ROOT / ".gitleaks.toml").open("rb") as stream:
            cls.config = tomllib.load(stream)
        cls.oauth = cls.config["allowlists"][0]

    def allowed(self, path: str, line: str) -> bool:
        # fullmatch preserves Go's absolute end anchor; Python's $ alone also
        # accepts the position before a trailing LF.
        return any(re.search(pattern, path) for pattern in self.oauth["paths"]) and any(
            re.fullmatch(pattern, line) for pattern in self.oauth["regexes"]
        )

    @staticmethod
    def declaration(name: str) -> str:
        return f"  static const {name} = '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ure';"

    def test_exception_keeps_default_rules_and_exact_scope(self) -> None:
        self.assertTrue(self.config["extend"]["useDefault"])
        self.assertEqual(self.oauth["targetRules"], ["generic-api-key"])
        self.assertEqual(self.oauth["condition"], "AND")
        self.assertEqual(self.oauth["regexTarget"], "line")
        self.assertEqual(len(self.oauth["paths"]), 2)
        self.assertEqual(len(self.oauth["regexes"]), 2)
        self.assertNotIn("commits", self.oauth)
        self.assertNotIn("stopwords", self.oauth)

    def test_first_and_interior_fragment_lines_are_allowed(self) -> None:
        for path, name in PUBLIC_CLIENTS:
            for prefix in ("", "\n"):
                with self.subTest(path=path, prefix=repr(prefix)):
                    self.assertTrue(self.allowed(path, prefix + self.declaration(name)))

    def test_only_one_leading_lf_is_allowed(self) -> None:
        for path, name in PUBLIC_CLIENTS:
            for prefix in ("\n\n", "\r\n", "\r", "unrelated\n"):
                with self.subTest(path=path, prefix=repr(prefix)):
                    self.assertFalse(
                        self.allowed(path, prefix + self.declaration(name))
                    )

    def test_additional_secret_content_is_rejected(self) -> None:
        for path, name in PUBLIC_CLIENTS:
            line = self.declaration(name)
            extra = self.declaration("_otherClientSecret")
            for content in (line + "\n" + extra, extra + "\n" + line, line + extra):
                with self.subTest(path=path, content=content):
                    self.assertFalse(self.allowed(path, content))

    def test_unrelated_declarations_and_paths_are_rejected(self) -> None:
        for path, name in PUBLIC_CLIENTS:
            line = self.declaration(name)
            for content in (
                self.declaration("_otherClientSecret"),
                line.replace("GOCSPX-", "private-"),
                "// " + line,
                line + " // unrelated content",
            ):
                with self.subTest(path=path, content=content):
                    self.assertFalse(self.allowed(path, content))
            for wrong_path in (
                "unrelated.dart",
                path + ".backup",
                "other/" + path[10:],
            ):
                with self.subTest(path=wrong_path):
                    self.assertFalse(self.allowed(wrong_path, line))


if __name__ == "__main__":
    unittest.main()
