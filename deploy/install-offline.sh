#!/usr/bin/env bash
# ============================================================================
# 폐쇄망 서버 설치 스크립트 (번들 압축 해제된 디렉터리 안에서 실행)
#
# 전제: 서버에 Docker Engine + docker compose 플러그인이 설치되어 있을 것.
#       (없으면 Ubuntu용 .deb 패키지를 별도 반입해 설치해야 함)
#
# 사용법:  ./install-offline.sh
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# ── 0. 전제 조건 확인 ───────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker가 설치되어 있지 않습니다." >&2
  echo "       Ubuntu 오프라인 설치: docker-ce/docker-ce-cli/containerd.io/docker-compose-plugin .deb 반입 후 dpkg -i" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose 플러그인이 없습니다. docker-compose-plugin .deb를 설치하세요." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker 데몬에 접근할 수 없습니다. (sudo 필요 여부, 데몬 기동 상태 확인)" >&2
  exit 1
fi

# ── 1. 이미지 load ──────────────────────────────────────────────────────
echo "== 이미지 load 중... (수 분 소요) =="
docker load -i images/images.tar.gz

# ── 2. .env 준비 ────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  cp .env.example .env
  echo "주의: .env.example을 .env로 복사했습니다. 비밀번호를 반드시 수정한 뒤 재기동하세요."
fi

# ── 3. 기동 ─────────────────────────────────────────────────────────────
echo "== 스택 기동 =="
docker compose up -d

echo ""
echo "== 상태 =="
docker compose ps

cat <<'EOF'

설치 완료. 확인:
  - MongoDB : localhost:44370
  - Milvus  : localhost:44380 (헬스: localhost:44381)
  - MinIO   : localhost:44385 (콘솔 44386)
  - Fuseki  : http://localhost:44390
  - Neo4j   : http://localhost:44395 (bolt 44396)
  - Redis   : localhost:44375
EOF
