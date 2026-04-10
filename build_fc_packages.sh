#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
TARGET_PLATFORM="${FC_TARGET_PLATFORM:-manylinux2014_x86_64}"
TARGET_PYTHON="${FC_TARGET_PYTHON:-310}"

DOMAIN_BUILD_DIR="$BUILD_DIR/domain_inventory"
SSL_BUILD_DIR="$BUILD_DIR/ssl_checker"

DOMAIN_ZIP="$DIST_DIR/domain_inventory.zip"
SSL_ZIP="$DIST_DIR/ssl_checker.zip"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DOMAIN_BUILD_DIR" "$SSL_BUILD_DIR" "$DIST_DIR"

echo "[1/5] Copy source files"
cp -R "$ROOT_DIR/common" "$DOMAIN_BUILD_DIR/"
cp -R "$ROOT_DIR/domain_inventory" "$DOMAIN_BUILD_DIR/"
cp -R "$ROOT_DIR/common" "$SSL_BUILD_DIR/"
cp -R "$ROOT_DIR/ssl_checker" "$SSL_BUILD_DIR/"

echo "[2/5] Install runtime dependencies for domain_inventory"
python3 -m pip install \
  --platform "$TARGET_PLATFORM" \
  --implementation cp \
  --python-version "$TARGET_PYTHON" \
  --only-binary=:all: \
  -r "$ROOT_DIR/requirements.txt" \
  -t "$DOMAIN_BUILD_DIR"

echo "[3/5] Install runtime dependencies for ssl_checker"
python3 -m pip install \
  --platform "$TARGET_PLATFORM" \
  --implementation cp \
  --python-version "$TARGET_PYTHON" \
  --only-binary=:all: \
  -r "$ROOT_DIR/requirements.txt" \
  -t "$SSL_BUILD_DIR"

echo "[4/5] Build zip for domain_inventory"
(
  cd "$DOMAIN_BUILD_DIR"
  find . -type d -name '__pycache__' -prune -exec rm -rf {} +
  zip -qr "$DOMAIN_ZIP" .
)

echo "[5/5] Build zip for ssl_checker"
(
  cd "$SSL_BUILD_DIR"
  find . -type d -name '__pycache__' -prune -exec rm -rf {} +
  zip -qr "$SSL_ZIP" .
)

echo
echo "Packages created:"
echo "  $DOMAIN_ZIP"
echo "  $SSL_ZIP"
echo "Target platform: $TARGET_PLATFORM"
echo "Target Python ABI: $TARGET_PYTHON"
