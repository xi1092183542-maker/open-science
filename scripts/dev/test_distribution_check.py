"""Exercise corrupt and misleading distribution evidence with synthetic files."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("distribution_check", Path(__file__).with_name("check-distribution.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class DistributionCheckTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.index = self.root / "index.json"
        (self.root / "LICENSE").write_bytes(b"synthetic notice")
        self.data = {"schema": 1, "distributionCleared": False,
                     "components": [{"kind": "npm", "name": "fixture", "version": "1",
                                     "notices": [{"path": "LICENSE", "sha256": hashlib.sha256(b"synthetic notice").hexdigest()}]}],
                     "missingNoticeFiles": [], "licenseReviewIssues": [],
                     "prebundledJavaScript": [], "remainingReview": ["Unreviewed sidecar"]}

    def run_check(self, purpose="internal"):
        self.index.write_text(json.dumps(self.data), encoding="utf8")
        return checker.check(self.index, purpose)

    def test_internal_integrity_does_not_imply_public_clearance(self):
        self.assertTrue(self.run_check()["pass"])
        self.assertFalse(self.run_check("public")["pass"])

    def test_flag_cannot_override_outstanding_review(self):
        self.data["distributionCleared"] = True
        self.assertFalse(self.run_check("public")["pass"])

    def test_altered_notice_is_rejected_even_internally(self):
        (self.root / "LICENSE").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "altered"):
            self.run_check()

    def test_escaping_notice_is_rejected(self):
        self.data["components"][0]["notices"][0]["path"] = "../outside-LICENSE"
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.run_check()

    def test_hidden_missing_notice_is_rejected(self):
        self.data["components"][0]["notices"] = []
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.run_check()

    def test_missing_inventory_is_rejected(self):
        self.data["components"] = []
        with self.assertRaisesRegex(ValueError, "nonempty"):
            self.run_check()

    def test_synthetic_review_complete_case(self):
        self.data["distributionCleared"] = True
        self.data["remainingReview"] = []
        self.assertTrue(self.run_check("public")["pass"])


if __name__ == "__main__":
    unittest.main()
