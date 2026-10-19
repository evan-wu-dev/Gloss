#!/bin/bash
# 打发布用的包：ad-hoc 签名（不带任何人的证书信息），压成 dist/Gloss-<版本>.zip。
#   VERSION=0.1.0 ./scripts/release.sh
# 打完会用本机证书重新构建一次 dist/Gloss.app，免得自己在用的那份辅助功能授权失效。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?需要指定版本号，例如 VERSION=0.1.0}"
ZIP="$PROJECT_DIR/dist/Gloss-$VERSION.zip"

SIGNING_IDENTITY=- VERSION="$VERSION" "$PROJECT_DIR/scripts/build.sh"
rm -f "$ZIP"
# ditto 保留扩展属性和签名，Finder 双击就能解压。
ditto -c -k --keepParent "$PROJECT_DIR/dist/Gloss.app" "$ZIP"
shasum -a 256 "$ZIP"

unset SIGNING_IDENTITY
VERSION="$VERSION" "$PROJECT_DIR/scripts/build.sh" > /dev/null
printf 'Release: %s\n' "$ZIP"
