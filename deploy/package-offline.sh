#!/usr/bin/env bash
# ============================================================================
# 폐쇄망 반입용 오프라인 번들 생성 (개발 PC의 WSL에서 실행)
#
# compose에 정의된 모든 이미지를 하나의 tar.gz로 save 하고,
# compose/init/.env 파일과 설치 스크립트를 묶어 단일 번들 tar를 만든다.
#
# 사용법:  ./deploy/package-offline.sh
# 산출물:  dist/shared-infra-offline-<날짜>.tar
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP=$(date +%Y%m%d)
BUNDLE_NAME="shared-infra-offline-${STAMP}"
WORK="dist/${BUNDLE_NAME}"

rm -rf "$WORK"
mkdir -p "$WORK/images"

# ── 1. compose가 참조하는 이미지 목록 추출 ──────────────────────────────
IMAGES=$(docker compose config --images | sort -u)
echo "== 포함될 이미지 =="
echo "$IMAGES"

# 로컬에 모두 존재하는지 확인 (없으면 pull 시도 전에 실패시킴 — 폐쇄망 준비 단계이므로)
for img in $IMAGES; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "ERROR: 로컬에 이미지가 없습니다: $img" >&2
    echo "       docker pull 또는 docker tag 후 다시 실행하세요." >&2
    exit 1
  fi
done

# ── 2. 이미지 save (한 파일로 묶으면 공유 레이어가 중복 저장되지 않음) ──
GZIP_BIN=$(command -v pigz || command -v gzip)
echo "== docker save 중... (수 분 소요, 압축: $(basename "$GZIP_BIN")) =="
# shellcheck disable=SC2086
docker save $IMAGES | "$GZIP_BIN" > "$WORK/images/images.tar.gz"

# ── 3. 배포 파일 복사 ───────────────────────────────────────────────────
cp docker-compose.yml "$WORK/"
cp .env.example "$WORK/"
cp -r init "$WORK/"
cp deploy/install-offline.sh "$WORK/"
chmod +x "$WORK/install-offline.sh"

if [ -f .env ]; then
  cp .env "$WORK/"
  echo "주의: 로컬 .env가 번들에 포함됩니다. 운영 서버에서는 반드시 비밀번호를 변경하세요."
fi

# ── 4. 단일 tar로 묶기 (이미지가 이미 gz이므로 외부 tar는 무압축) ───────
tar -cf "dist/${BUNDLE_NAME}.tar" -C dist "$BUNDLE_NAME"
rm -rf "$WORK"

echo ""
echo "== 완료 =="
ls -lh "dist/${BUNDLE_NAME}.tar"
echo ""
echo "다음 단계: ./deploy/deploy-to-server.sh <user@server> [원격경로]"
