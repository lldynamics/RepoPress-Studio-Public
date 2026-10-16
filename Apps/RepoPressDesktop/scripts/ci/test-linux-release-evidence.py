#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("validator", HERE / "validate-linux-release-evidence.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class LinuxEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.evidence_file = self.root / "evidence.json"
        environments = []
        for index, identity in enumerate(sorted(validator.EXPECTED)):
            proof = self.root / f"proof-{index}.txt"
            proof.write_text(f"proof-{index}", encoding="utf-8")
            environment = dict(zip(("distro", "version", "desktop", "session", "locale", "scale", "ime"), identity))
            environments.append({
                "environment": environment,
                "checks": {name: "pass" for name in validator.REQUIRED_CHECKS},
                "attachments": [{"path": proof.name, "sha256": hashlib.sha256(proof.read_bytes()).hexdigest()}],
            })
        self.data = {"schema": validator.SCHEMA, "release_version": "1.2.3", "artifact_sha256": "a" * 64,
                     "recorded_at": "2026-09-04T12:00:00+08:00", "tester": "Test User", "environments": environments}

    def tearDown(self):
        self.tmp.cleanup()

    def assertReject(self, mutate):
        data = json.loads(json.dumps(self.data))
        mutate(data)
        with self.assertRaises(validator.EvidenceError):
            validator.validate(data, self.evidence_file)

    def test_valid_complete_matrix(self):
        validator.validate(self.data, self.evidence_file)

    def test_rejects_pending_and_skip(self):
        self.assertReject(lambda d: d["environments"][0]["checks"].__setitem__("launch", "pending"))
        self.assertReject(lambda d: d["environments"][0]["checks"].__setitem__("accessibility", "skip"))

    def test_rejects_duplicate_and_incomplete_matrix(self):
        self.assertReject(lambda d: d["environments"].__setitem__(1, d["environments"][0]))
        self.assertReject(lambda d: d["environments"].pop())

    def test_rejects_unknown_fields_and_path_escape(self):
        self.assertReject(lambda d: d.__setitem__("unexpected", True))
        self.assertReject(lambda d: d["environments"][0]["attachments"][0].__setitem__("path", "../proof.txt"))

    def test_rejects_hash_mismatch_and_bad_environment(self):
        self.assertReject(lambda d: d["environments"][0]["attachments"][0].__setitem__("sha256", "b" * 64))
        self.assertReject(lambda d: d["environments"][0]["environment"].__setitem__("session", "Other"))
        self.assertReject(lambda d: d["environments"][0]["environment"].__setitem__("distro", "Debian"))
        self.assertReject(lambda d: d["environments"][0]["environment"].__setitem__("version", "23.10"))
        self.assertReject(lambda d: d["environments"][0]["environment"].__setitem__("locale", "en_US.UTF-8"))

    def test_rejects_attachment_reuse_and_limits(self):
        self.assertReject(lambda d: d["environments"][1]["attachments"].__setitem__(0, d["environments"][0]["attachments"][0]))
        extra = []
        for index in range(validator.MAX_ATTACHMENTS_PER_ENVIRONMENT + 1):
            proof = self.root / f"extra-{index}.txt"
            proof.write_text(f"extra-{index}", encoding="utf-8")
            extra.append({"path": proof.name, "sha256": hashlib.sha256(proof.read_bytes()).hexdigest()})
        self.data["environments"][0]["attachments"] = extra
        with self.assertRaises(validator.EvidenceError):
            validator.validate(self.data, self.evidence_file)
        oversized = self.root / "oversized.bin"
        with oversized.open("wb") as stream:
            stream.truncate(validator.MAX_ATTACHMENT_BYTES + 1)
        self.data["environments"][0]["attachments"] = [{"path": oversized.name, "sha256": "a" * 64}]
        with self.assertRaises(validator.EvidenceError):
            validator.validate(self.data, self.evidence_file)

    def test_artifact_binding(self):
        artifact = self.root / "release.AppImage"
        artifact.write_bytes(b"release")
        self.data["artifact_sha256"] = hashlib.sha256(b"release").hexdigest()
        validator.validate(self.data, self.evidence_file, artifact)
        artifact.write_bytes(b"tampered")
        with self.assertRaises(validator.EvidenceError):
            validator.validate(self.data, self.evidence_file, artifact)


if __name__ == "__main__":
    unittest.main()
