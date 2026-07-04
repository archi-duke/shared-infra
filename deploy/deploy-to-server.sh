#!/usr/bin/env bash
# ============================================================================
# 번들을 SSH로 폐쇄망 서버에 전송하고 설치까지 실행 (개발 PC의 WSL에서 실행)
#
# 사용법:  ./deploy/deploy-to-server.sh <user@server> [원격경로(기본 ~/shared-infra)]
# 예시:    ./deploy/deploy-to-server.sh deploy@10.0.0.5
#
# rsync가 양쪽에 있으면 재개 가능한 전송(rsync --partial)을, 없으면 scp를 쓴다.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:?사용법: $0 <user@server> [원격경로]}"
REMOTE_DIR="${2:-~/shared-infra}"

# 최신 번들 선택
BUNDLE=$(ls -1t dist/shared-infra-offline-*.tar 2>/dev/null | head -1 || true)
if [ -z "$BUNDLE" ]; then
  echo "ERROR: dist/에 번들이 없습니다. 먼저 ./deploy/package-offline.sh 를 실행하세요." >&2
  exit 1
fi
echo "== 전송할 번들: $BUNDLE =="

# ── 1. 전송 ─────────────────────────────────────────────────────────────
ssh "$TARGET" "mkdir -p $REMOTE_DIR"
if command -v rsync >/dev/null 2>&1 && ssh "$TARGET" "command -v rsync" >/dev/null 2>&1; then
  rsync -avP "$BUNDLE" "$TARGET:$REMOTE_DIR/"
else
  scp "$BUNDLE" "$TARGET:$REMOTE_DIR/"
fi

# ── 2. 원격 압축 해제 + 설치 ────────────────────────────────────────────
BASENAME=$(basename "$BUNDLE" .tar)
ssh -t "$TARGET" "cd $REMOTE_DIR && tar -xf $(basename "$BUNDLE") && cd $BASENAME && ./install-offline.sh"

echo ""
echo "== 배포 완료: $TARGET:$REMOTE_DIR/$BASENAME =="
