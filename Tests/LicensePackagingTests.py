#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline document/packaging checks, not a legal-compliance certification."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = {
    "LICENSE": "LICENSE",
    "NOTICE": "NOTICE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
}
REPOSITORY_DOCUMENTS = ("docs/MODEL_LICENSES.md", "docs/ASSET_LICENSES.md", "docs/LICENSE_REVIEW.md")
MANAGED_DOCUMENTS = ("README.md", "THIRD_PARTY_NOTICES.md", "LICENSES/README.md",
                     "Tests/README.md", "Packages/IrodoriSpeechCpp/README.md")
AVATAR_RESOURCES = {"App/Resources/default_avatar.vrm": "default_avatar.vrm"}
# Compared to the upstream sources listed in LICENSES/README.md on 2026-10-20.
# Whitespace normalization ignores line endings and trailing/outer whitespace,
# but not wording, punctuation or internal spaces. Update only after review.
VERIFIED_HASHES = {
    "LICENSE": "283ea6cc2997a1a70da0049e09adf9317bb60ca1b51279b65196b83a69e1996b",
    "LICENSES/MIT.txt": "a1c4f480b9e2c3db1ad1393deeef987603ff3b852bfb6d292271700982b1e3ce",
    "LICENSES/ModernBERT-MIT.txt": "c2142adf07ff4607749b33314f969ffca01ce0bd629eee341323bdf5ca825b3f",
    "LICENSES/AudioSeal-MIT.txt": "cf9b17822d1fcd4ff32ccbe14183386fb3adf6f2ff92dc184130823f7fc28173",
    "LICENSES/Descript-MIT.txt": "3fb4aef5b76dc0ccb1f57499d75c2fe039df5c9793778ede172f5ac7a4045681",
    "LICENSES/speech.cpp-MIT.txt": "7af748f93858d46c9e9413e14bc103c71ed730a572e05514a528c29519b12a8e",
    "LICENSES/ggml-MIT.txt": "3468798dd4eb1badf2d665d4afec49d424aa31fd4f0af91638ccd4b1a48615d0",
    "LICENSES/YaRN-MIT.txt": "c3ec00ded224ebaaa673373961babc2d79f3081914897f3325cb7927a76234c1",
    "LICENSES/VRMKit-MIT.txt": "a6dcb917c53408a3e47b53ce48c984fa33c00fe80c1c462119ef68ca7bd5e93e",
    "LICENSES/MoreCodable-MIT.txt": "a6dcb917c53408a3e47b53ce48c984fa33c00fe80c1c462119ef68ca7bd5e93e",
    "LICENSES/llama.cpp-MIT.txt": "3468798dd4eb1badf2d665d4afec49d424aa31fd4f0af91638ccd4b1a48615d0",
    "LICENSES/LFM-Open-License-1.0.txt": "5a020ce8f34b9fd3a59c4e5f000ea19d8b81c4e3ba2639f1e4f1533fb90e4f66",
    "LICENSES/CoreML-NOTICE.txt": "b0d7edad270d1b10e0adb9f66ed00b7cff7588fb83c4bf9d56645824d8122424",
}
APP_BUNDLE = None


def normalize(text):
    return "\n".join(line.rstrip() for line in text.splitlines()).strip()


class LicensePackagingTests(unittest.TestCase):
    def test_verified_license_wording_is_preserved(self):
        for path, expected in VERIFIED_HASHES.items():
            with self.subTest(path=path):
                text = normalize((ROOT / path).read_text(encoding="utf-8"))
                self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), expected)
        actual = {p.relative_to(ROOT).as_posix() for p in (ROOT / "LICENSES").glob("*.txt")}
        self.assertEqual(actual, set(VERIFIED_HASHES) - {"LICENSE"})

    def test_existing_package_license_copies_are_preserved(self):
        pairs = {
            **{f"LICENSES/{name}": f"Packages/IrodoriSpeechCpp/LICENSES/{name}"
               for name in ("speech.cpp-MIT.txt", "ggml-MIT.txt", "YaRN-MIT.txt")},
            "LICENSES/MoreCodable-MIT.txt": "Packages/VRMKit/Sources/VRMKit/Extensions/MoreCodable/LICENSE",
        }
        for copy, original in pairs.items():
            with self.subTest(path=copy):
                self.assertEqual(normalize((ROOT / copy).read_text(encoding="utf-8")),
                                 normalize((ROOT / original).read_text(encoding="utf-8")))

    def test_upstream_notice_is_preserved(self):
        # The two upstream notices have identical bodies and different titles.
        coreml = (ROOT / "LICENSES/CoreML-NOTICE.txt").read_text(encoding="utf-8")
        sdk = coreml.replace("Irodori TTS Core ML — community conversion and sample runtime",
                             "Irodori TTS for iPhone — Swift SDKs and sample applications", 1)
        notice = (ROOT / "NOTICE").read_text(encoding="utf-8")
        self.assertTrue(notice.endswith(sdk))
        self.assertIn("Copyright 2026 StackChan Pet Talk contributors", notice)

    def test_local_document_links_resolve(self):
        for document in MANAGED_DOCUMENTS:
            path = ROOT / document
            for destination in re.findall(r"\]\(([^)]+)\)", path.read_text(encoding="utf-8")):
                url = urlsplit(destination)
                if not url.scheme and url.path:
                    with self.subTest(document=str(path), link=destination):
                        target = (path.parent / unquote(url.path)).resolve()
                        self.assertTrue(target.exists())
                        self.assertFalse(target.is_relative_to(ROOT / "docs"),
                                         "Managed documents must not link to ignored docs/")

    def test_model_revisions_match_production(self):
        paths = (
            "Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechCpp/SpeechCppModelBundle.swift",
            "Packages/LlamaCpp/Sources/LlamaCpp/LocalLLMModelBundle.swift",
            "Sources/IrodoriTTS/ModelVariant.swift",
        )
        docs = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        for path in paths:
            revisions = re.findall(r'"([0-9a-f]{40})"', (ROOT / path).read_text())
            self.assertTrue(revisions, f"No model revision found in {path}")
            for revision in revisions:
                self.assertIn(revision, docs)

    def test_avatar_metadata_and_bytes_are_unchanged(self):
        raw = (ROOT / "App/Resources/default_avatar.vrm").read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
                         "81b83504bcddd4497d3d68b946060e4b9802ff0e2886ed53961e5561d3776a0f")
        self.assertEqual(raw[:4], b"glTF")
        self.assertEqual(struct.unpack_from("<II", raw, 4), (2, len(raw)))
        length, kind = struct.unpack_from("<II", raw, 12)
        self.assertEqual(kind, 0x4E4F534A)
        meta = json.loads(raw[20:20 + length])["extensions"]["VRMC_vrm"]["meta"]
        self.assertEqual(meta["name"], "vrm_sample")
        self.assertEqual(meta["creditNotation"], "unnecessary")
        self.assertEqual(meta["authors"], ["taiyop"])
        self.assertEqual(meta["commercialUsage"], "personalNonProfit")
        self.assertTrue(meta["allowRedistribution"])
        self.assertEqual(meta["modification"], "allowModificationRedistribution")
        for key in ("allowExcessivelyViolentUsage", "allowExcessivelySexualUsage",
                    "allowAntisocialOrHateUsage", "allowPoliticalOrReligiousUsage"):
            self.assertFalse(meta[key])
        self.assertEqual(meta["licenseUrl"], "https://vrm.dev/licenses/1.0/")
        for path in ("NOTICE", "README.md", "THIRD_PARTY_NOTICES.md"):
            text = (ROOT / path).read_text(encoding="utf-8")
            self.assertIn(meta["name"], text)
            self.assertIn(meta["authors"][0], text)
            self.assertIn(meta["licenseUrl"], text)

    def test_runtime_default_points_to_the_new_bundled_model(self):
        text = (ROOT / "App/Services/VRMCharacterLibrary.swift").read_text(encoding="utf-8")
        self.assertIn('forResource: "default_avatar", withExtension: "vrm"', text)
        self.assertNotIn('forResource: "vrm_sample"', text)

    @unittest.skipUnless(shutil.which("plutil"), "Requires macOS plutil")
    def test_xcode_project_copies_every_legal_resource(self):
        data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-",
                                        str(ROOT / "CharaTalk.xcodeproj/project.pbxproj")])
        objects = json.loads(data)["objects"]
        target = next(o for o in objects.values()
                      if o.get("isa") == "PBXNativeTarget" and o.get("name") == "CharaTalk")
        phases = [objects[p] for p in target["buildPhases"]]
        resource_phase = next(p for p in phases if p["isa"] == "PBXResourcesBuildPhase")
        refs = [objects[objects[f]["fileRef"]] for f in resource_phase["files"]]
        resource_paths = {ref["path"] for ref in refs}
        self.assertTrue(set(RESOURCES) | {"LICENSES"} <= resource_paths)
        self.assertTrue(set(AVATAR_RESOURCES) <= resource_paths)
        self.assertFalse(any(Path(path).name == "vrm_sample.vrm" for path in resource_paths))
        self.assertFalse(any(path.startswith("docs/") for path in resource_paths))
        folder = next(r for r in refs if r["path"] == "LICENSES")
        self.assertEqual(folder["lastKnownFileType"], "folder")

    @unittest.skipUnless(shutil.which("xcodegen"), "Requires XcodeGen")
    def test_xcodegen_preserves_the_same_resources(self):
        result = subprocess.check_output(["xcodegen", "dump", "--type", "json"], cwd=ROOT)
        sources = json.loads(result)["targets"]["CharaTalk"]["sources"]
        refs = {s["path"]: s for s in sources if s.get("buildPhase") == "resources"}
        self.assertEqual(set(refs), set(RESOURCES) | {"LICENSES"})
        self.assertFalse(any(s["path"].startswith("docs/") for s in sources))
        self.assertEqual(refs["LICENSES"]["type"], "folder")
        app_sources = next(s for s in sources if s["path"] == "App")
        self.assertNotIn("Resources/default_avatar.vrm", app_sources.get("excludes", []))

    def test_built_app_contains_identical_legal_documents(self):
        if APP_BUNDLE is None:
            self.skipTest("Pass --app-bundle to verify an actual built app")
        self.assertTrue(APP_BUNDLE.is_dir(), f"App bundle not found: {APP_BUNDLE}")
        mappings = dict(RESOURCES)
        for path in (ROOT / "LICENSES").iterdir():
            if path.is_file():
                relative = path.relative_to(ROOT).as_posix()
                mappings[relative] = relative
        for source, destination in mappings.items():
            with self.subTest(resource=destination):
                self.assertEqual((ROOT / source).read_bytes(), (APP_BUNDLE / destination).read_bytes())
        for path in REPOSITORY_DOCUMENTS:
            self.assertFalse((APP_BUNDLE / Path(path).name).exists(), f"Unexpected bundled document: {path}")

    def test_app_has_no_license_document_screen_or_references(self):
        for path in (ROOT / "App").rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            with self.subTest(source=path.name):
                for symbol in ("LicenseView", "LicenseDocument", "ライセンス・クレジット"):
                    self.assertNotIn(symbol, text)
                for document in REPOSITORY_DOCUMENTS:
                    self.assertNotIn(Path(document).name, text)

    def test_built_app_contains_only_the_new_default_avatar(self):
        if APP_BUNDLE is None:
            self.skipTest("Pass --app-bundle to verify an actual built app")
        for source, destination in AVATAR_RESOURCES.items():
            self.assertEqual((ROOT / source).read_bytes(), (APP_BUNDLE / destination).read_bytes())
        self.assertEqual({p.name for p in APP_BUNDLE.glob("*.vrm")}, {"default_avatar.vrm"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-bundle", type=Path)
    args, remaining = parser.parse_known_args()
    APP_BUNDLE = args.app_bundle
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
