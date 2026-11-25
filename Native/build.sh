#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
rev=5bedbd0713d6262c6f58cdbb75e31c2aaca2b598
if [ ! -d vendor/stream/.git ]; then
  git clone --no-checkout https://github.com/OpenXPlay/OpenXPlay-Stream.git vendor/stream
fi
git -C vendor/stream checkout --detach "$rev"
test "$(git -C vendor/stream rev-parse HEAD)" = "$rev"
# Darwin sockaddr_in includes sin_len on both macOS and iOS.
python3 - <<'PY'
from pathlib import Path
p = Path('vendor/stream/rust/oxp-clink/src/bound_socket.rs')
s = p.read_text()
p.write_text(s.replace('#[cfg(target_os = "macos")]', '#[cfg(target_vendor = "apple")]'))
PY
cp vendor/stream/rust/Cargo.lock Native/Cargo.lock
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  cargo build --release --manifest-path Native/Cargo.toml --target "$target"
done
mkdir -p Native/lib/iphoneos Native/lib/iphonesimulator
cp Native/target/aarch64-apple-ios/release/libchangan_clink.a Native/lib/iphoneos/
lipo -create Native/target/{aarch64-apple-ios-sim,x86_64-apple-ios}/release/libchangan_clink.a -output Native/lib/iphonesimulator/libchangan_clink.a
