import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class InstallerSecurityTests(unittest.TestCase):
    def test_windows_installer_requires_checksum_sidecar(self) -> None:
        script = (ROOT / "install.ps1").read_text(encoding="utf-8")

        self.assertIn("Invoke-WebRequest -Uri $checksumUrl", script)
        self.assertNotIn("$checksumFound", script)
        self.assertNotIn("continuing with HTTPS verification only", script)

    def test_posix_installer_requires_checksum_sidecar(self) -> None:
        script = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn('curl -fsSL "${URL}.sha256" -o "$checksum_file"', script)
        self.assertNotIn('if curl -fsSL "${URL}.sha256"', script)
        self.assertNotIn("continuing with HTTPS verification only", script)


if __name__ == "__main__":
    unittest.main()
