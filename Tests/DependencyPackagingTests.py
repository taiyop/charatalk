#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Regression checks for the app-focused dependency graph and built artifact."""
import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP_BUNDLE = None
REMOVED_SYMBOLS = ("IrodoriLocalBridge", "IrodoriEngine", "ReazonSpeechBridge",
                   "SpeechRecognitionEngine", "MToonShader", "MToonParameterTexture")


@lru_cache(maxsize=None)
def targets(package):
    value = json.loads(subprocess.check_output([
        "swift", "package", "--package-path", str(ROOT / package), "dump-package"
    ]))
    return {target["name"]: target for target in value["targets"]}


class DependencyPackagingTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swift"), "Requires Swift")
    def test_shared_sdk_has_no_legacy_native_target(self):
        graph = targets(".")
        self.assertEqual(set(graph), {"IrodoriTTS"})
        self.assertEqual(graph["IrodoriTTS"]["dependencies"], [])
        self.assertFalse((ROOT / "Sources/IrodoriTTS/IrodoriEngine.swift").exists())
        self.assertFalse(any((ROOT / "Sources/IrodoriNative").rglob("*.*")))
        self.assertTrue((ROOT / "Sources/IrodoriTTS/SpeechTypes.swift").is_file())
        self.assertTrue((ROOT / "Sources/IrodoriTTS/AudioWatermark.swift").is_file())

    @unittest.skipUnless(shutil.which("swift"), "Requires Swift")
    def test_speech_cpp_exposes_only_the_tts_bridge(self):
        graph = targets("Packages/IrodoriSpeechCpp")
        self.assertEqual(graph["IrodoriSpeechNative"]["sources"], ["IrodoriSpeechBridge.mm"])
        sources = ROOT / "Packages/IrodoriSpeechCpp/Sources"
        self.assertFalse(list(sources.rglob("*Reazon*")))
        self.assertFalse(list(sources.rglob("*Recognition*")))
        header = sources / "IrodoriSpeechNative/include/IrodoriSpeechBridge.h"
        self.assertNotIn("ReazonSpeech", header.read_text())

    def test_shared_speech_runtime_is_not_modified(self):
        artifact = ROOT / "Packages/IrodoriSpeechCpp/Artifacts"
        metadata = json.loads((artifact / "runtime.json").read_text())
        raw = (artifact / "SpeechCpp.xcframework.zip").read_bytes()
        self.assertEqual(len(raw), metadata["bytes"])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), metadata["sha256"])

    def test_llama_runtime_matches_pinned_lfm3_build(self):
        artifact = ROOT / "Packages/LlamaCpp/Artifacts"
        metadata = json.loads((artifact / "runtime.json").read_text())
        raw = (artifact / "llama.xcframework.zip").read_bytes()
        self.assertEqual(len(raw), metadata["bytes"])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), metadata["sha256"])
        script = (ROOT / "Packages/LlamaCpp/Scripts/build-runtime.sh").read_text()
        self.assertIn(f"llama_tag={metadata['llamaTag']}", script)
        self.assertIn(f"llama_revision={metadata['llamaRevision']}", script)
        for path, digest in metadata["sourceFiles"].items():
            with self.subTest(path=path):
                self.assertEqual(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), digest)

    @unittest.skipUnless(shutil.which("swift"), "Requires Swift")
    def test_vrm_renderer_has_no_mtoon_shader_or_resources(self):
        graph = targets("Packages/VRMKit")
        self.assertEqual(graph["VRMRealityKit"]["resources"], [])
        sources = ROOT / "Packages/VRMKit/Sources/VRMRealityKit"
        for name in ("MToon", "Shaders", "Resources"):
            self.assertFalse(any(path.is_file() for path in (sources / name).rglob("*")))
        self.assertFalse((sources / "CustomType/GLTFEntity+MToon.swift").exists())
        loader = (sources / "GLTFEntityLoader.swift").read_text()
        self.assertIn("defaultShaders: [any GLTFMaterialShader] { [] }", loader)
        # Keep VRM material data parsing and the existing Unlit approximation.
        builder = (sources / "Loading/GLTFSceneBuilder.swift").read_text()
        self.assertIn("let useUnlit = isMToon || isUnlit", builder)

    def test_authentication_services_is_not_a_direct_dependency(self):
        for path in ("project.yml", "CharaTalk.xcodeproj/project.pbxproj",
                     "App/Services/ChatGPTAuthManager.swift"):
            with self.subTest(path=path):
                self.assertNotIn("AuthenticationServices", (ROOT / path).read_text())
        auth = (ROOT / "App/Services/ChatGPTAuthManager.swift").read_text()
        self.assertIn("SFSafariViewController(url: authURL)", auth)
        self.assertIn("NWListener(using:", auth)

    def test_built_app_has_no_removed_resources_or_symbols(self):
        if APP_BUNDLE is None:
            self.skipTest("Pass --app-bundle to inspect a built app")
        self.assertTrue(APP_BUNDLE.is_dir())
        self.assertFalse(list(APP_BUNDLE.rglob("*MToon*.metallib")))
        if not shutil.which("xcrun"):
            self.skipTest("Symbol/link inspection requires Xcode tools")
        info = plistlib.loads((APP_BUNDLE / "Info.plist").read_bytes())
        executable = info["CFBundleExecutable"]
        for name in (executable, f"{executable}.debug.dylib"):
            binary = APP_BUNDLE / name
            if not binary.exists():
                continue
            with self.subTest(binary=name):
                links = subprocess.check_output(["xcrun", "otool", "-L", str(binary)], text=True)
                self.assertNotIn("AuthenticationServices.framework", links)
                symbols = subprocess.check_output(["xcrun", "nm", "-gU", str(binary)], text=True)
                for removed in REMOVED_SYMBOLS:
                    self.assertNotIn(removed, symbols)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-bundle", type=Path)
    args, remaining = parser.parse_known_args()
    APP_BUNDLE = args.app_bundle
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
