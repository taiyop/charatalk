#!/usr/bin/env bash
set -euo pipefail

# Build the pinned upstream llama.cpp xcframework (no patches) for iOS devices,
# the iOS simulator and macOS, then package it without dSYMs as the SwiftPM binary target.
llama_tag=b11946
llama_revision=8ca4060b7e30e76baaa5670ee1ec1b760b7f8552
llama_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
llama_cache="${llama_root}/.build/runtime"
llama_source="${llama_cache}/llama.cpp-${llama_tag}"
llama_output="${llama_root}/Artifacts/llama.xcframework.zip"

if [[ ! -d "${llama_source}/.git" ]]; then
  mkdir -p "${llama_cache}"
  git clone --depth 1 --branch "${llama_tag}" https://github.com/ggml-org/llama.cpp "${llama_source}"
fi
actual_revision="$(git -C "${llama_source}" rev-parse HEAD)"
if [[ "${actual_revision}" != "${llama_revision}" ]]; then
  echo "error: ${llama_tag} resolved to ${actual_revision}, expected ${llama_revision}" >&2
  exit 1
fi

(cd "${llama_source}" && ./build-xcframework.sh ios-sim ios-device macos)

built="${llama_source}/build-apple/llama.xcframework"
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/llama-runtime.XXXXXX")"
trap 'rm -rf "${package_dir}"' EXIT
xcodebuild -create-xcframework \
  -framework "${built}/ios-arm64/llama.framework" \
  -framework "${built}/ios-arm64_x86_64-simulator/llama.framework" \
  -framework "${built}/macos-arm64_x86_64/llama.framework" \
  -output "${package_dir}/llama.xcframework"
(cd "${package_dir}" && ditto -c -k --sequesterRsrc --keepParent llama.xcframework llama.xcframework.zip)
mv "${package_dir}/llama.xcframework.zip" "${llama_output}"

echo "Wrote ${llama_output}"
echo "bytes: $(stat -f %z "${llama_output}")"
echo "sha256: $(shasum -a 256 "${llama_output}" | cut -d ' ' -f 1)"
echo "Update Packages/LlamaCpp/Artifacts/runtime.json with the values above."
