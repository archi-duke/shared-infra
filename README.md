# Shared Infrastructure (RAGaaS + GoJIRA 공용)

RAGaaS(`D:\works\RAGaaS`)와 GoJIRA(`D:\Works\GoJIRA`)가 공유하는 **통합 인프라 스택**입니다.

## 분리 기준

> **서드파티 기성 이미지(상태 보유) = 이 스택 / 자체 빌드 앱 이미지 = 각 프로젝트 스택**

- 앱 스택을 재배포·재빌드해도 인프라는 재시작되지 않는다 (수명주기 분리)
- 개별 서비스만 재시작 가능: `docker compose restart fuseki`
- 폐쇄망 반입 시 "인프라 이미지 묶음 1개 + 앱 이미지 묶음 2개"로 일원화

## 제공 서비스

| 서비스 | 컨테이너 | 이미지 | 호스트 포트 | 사용 프로젝트 |
|---|---|---|---|---|
| MongoDB | `shared-mongo` | mongo:8.0 | 27017 | 공용 (DB 분리) |
| Milvus | `shared-milvus` | milvusdb/milvus:v2.3.3 | 19530, 9091 | RAGaaS |
| ├ etcd | `shared-etcd` | quay.io/coreos/etcd:v3.5.5 | - | (Milvus 내부) |
| └ MinIO | `shared-minio` | minio/minio:RELEASE.2023-03-20 | 9000, 9001 | (Milvus 내부) |
| Fuseki | `shared-fuseki` | stain/jena-fuseki:5.1.0 | 3030 | RAGaaS |
| Neo4j | `shared-neo4j` | neo4j:5.15.0 | 7474, 7687 | RAGaaS |
| Redis | `shared-redis` | redis:7-alpine | 6379 | RAGaaS |
| Gitea | `shared-gitea` | gitea/gitea:latest | 3300 | GoJIRA (**이관 대기** — compose에 주석 처리됨) |

네트워크: **`shared-net`** — 앱 compose에서 `external: true`로 조인하면
위 컨테이너 이름으로 접근 가능. 앱 간 API 호출도 이 네트워크 사용
(예: GoJIRA → `http://ragaas-backend:8000`).

## 기동

```bash
cp .env.example .env   # 비밀번호 수정 (운영 시 필수)
docker compose up -d   # 앱 스택들보다 먼저!
```

최초 기동 시 `init/01-create-users.sh`가 Mongo 앱 계정을 자동 생성합니다:

| 계정 | DB | 권한 | 비밀번호 env |
|---|---|---|---|
| `ragaas_app` | `ragaas` | dbOwner | `RAGAAS_MONGO_PASSWORD` |
| `gojira_app` | `gojira` | dbOwner | `GOJIRA_MONGO_PASSWORD` |

## 앱에서 접속하는 방법

```yaml
# 각 앱의 docker-compose.yml
services:
  my-service:
    networks: [default, shared-net]
networks:
  shared-net:
    external: true
```

| 용도 | 접속 주소 (shared-net 내부) |
|---|---|
| MongoDB (RAGaaS) | `mongodb://ragaas_app:<PW>@shared-mongo:27017/ragaas?authSource=ragaas` |
| MongoDB (GoJIRA) | `mongodb://gojira_app:<PW>@shared-mongo:27017/gojira?authSource=gojira` |
| Milvus | `shared-milvus:19530` |
| Fuseki | `http://shared-fuseki:3030` |
| Neo4j | `bolt://shared-neo4j:7687` |
| Redis | `redis://shared-redis:6379/0` |

호스트(컨테이너 밖)에서는 `localhost:<포트>`로 접근합니다.

## 데이터 관리

모든 데이터는 **네임드 볼륨**(`shared-*-data`)에 저장됩니다.
WSL에서 `/mnt/*` 바인드 마운트는 DB 엔진과 호환성 문제가 있어 사용하지 않으며,
우분투 서버에서도 동일 구성이 그대로 동작합니다.

백업 예 (Mongo):
```bash
docker exec shared-mongo mongodump -u root -p <ROOT_PW> --db gojira --archive --gzip > backup.archive.gz
```

이미 데이터가 있는 인스턴스에 Mongo 계정만 추가할 때 (init 스크립트는 빈 볼륨에서만 실행):
```bash
docker exec -it shared-mongo mongosh -u root -p <ROOT_PW> --eval '
  db.getSiblingDB("gojira").createUser({
    user: "gojira_app", pwd: "<PW>",
    roles: [{ role: "dbOwner", db: "gojira" }]
  })'
```

## 폐쇄망(우분투 서버) 반입

SSH만 가능한 폐쇄망 서버 기준. `deploy/` 스크립트 3개로 일원화되어 있습니다.

```bash
# 개발 PC의 WSL에서:
./deploy/package-offline.sh                   # 1) dist/에 오프라인 번들 tar 생성
./deploy/deploy-to-server.sh user@서버주소     # 2) SSH 전송 + 원격 설치까지 자동 실행
```

수동으로 나눠 할 경우: 번들 tar를 `scp`로 올린 뒤 서버에서
`tar -xf 번들.tar && cd 번들디렉토리 && ./install-offline.sh`.

번들 내용물: 이미지 전체 tar.gz(공유 레이어 중복 제거) + docker-compose.yml +
init/ + .env(있으면, 없으면 .env.example) + install-offline.sh.

**서버 전제 조건**: Docker Engine + docker compose 플러그인.
없으면 Ubuntu용 `.deb`(docker-ce, docker-ce-cli, containerd.io,
docker-compose-plugin)를 별도 반입해 `dpkg -i`로 설치.

참고: Neo4j의 APOC 플러그인은 이미지에 내장된 core 버전을 사용하므로
폐쇄망에서도 별도 다운로드 없이 동작합니다.

기동 순서: **shared-infra → RAGaaS → GoJIRA** (앱 순서는 무관)

## 알려진 이슈 / TODO

- `stain/jena-fuseki`: 서드파티 이미지, 갱신 중단 상태 — 공식 배포판 기반
  자체 이미지로 교체 검토. (반입용 버전 고정 완료: latest → `5.1.0` re-tag)
- Gitea 이관: GoJIRA 측 확인 후 compose 주석 해제 + 기존 볼륨 데이터 승계 필요.
