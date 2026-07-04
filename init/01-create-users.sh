#!/bin/bash
# 앱별 전용 계정 생성 — 최초 기동(빈 데이터 볼륨) 시에만 실행된다.
# 이미 데이터가 있는 인스턴스에는 README의 수동 생성 절차를 사용할 것.
set -e

mongosh --quiet <<EOF
use admin
db.auth("$MONGO_INITDB_ROOT_USERNAME", "$MONGO_INITDB_ROOT_PASSWORD")

use ragaas
db.createUser({
  user: "ragaas_app",
  pwd: "$RAGAAS_MONGO_PASSWORD",
  roles: [{ role: "dbOwner", db: "ragaas" }]
})

use gojira
db.createUser({
  user: "gojira_app",
  pwd: "$GOJIRA_MONGO_PASSWORD",
  roles: [{ role: "dbOwner", db: "gojira" }]
})
EOF

echo "Created app users: ragaas_app (db: ragaas), gojira_app (db: gojira)"
