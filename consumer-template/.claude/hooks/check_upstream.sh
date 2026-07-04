#!/usr/bin/env bash
# SessionStart 훅 — 세션 시작 시 C 최신 계약과 로컬 lock 의 드리프트를 감지해
# Claude Code 컨텍스트에 주입한다. (CI push 를 놓친 오프라인 구간 보정)
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

RAW="https://raw.githubusercontent.com/archi-duke/shared-infra/main/.contract/contract.json"
LOCK=".contract/contract.lock.json"
[ -f "$LOCK" ] || exit 0
APP="$(python3 -c "import yaml;print(yaml.safe_load(open('.infra-deps.yml'))['name'])" 2>/dev/null || echo "")"
[ -n "$APP" ] || exit 0

PUB="$(mktemp)"; curl -sSfL "$RAW" -o "$PUB" 2>/dev/null || exit 0

set +e
REPORT="$(python3 tools/infra_contract.py compare "$LOCK" "$PUB" --consumer "$APP" --json 2>/dev/null)"
CODE=$?
set -e
[ "$CODE" = "0" ] && exit 0   # 드리프트 없음 → 조용히 종료

SUMMARY="$(printf '%s' "$REPORT" | python3 -c "
import json,sys
r=json.load(sys.stdin)
lines=[f\"shared-infra 계약 드리프트 감지: {r['old_version']} -> {r['new_version']} (verdict={'BREAKING' if r['verdict']==20 else 'additive'}).\"]
for c in r['changes']:
    tag='BREAKING' if c['breaking'] else 'additive'
    lines.append(f\"- [{tag}] {c['service']}.{c['field']}: {c['old']} -> {c['new']} ({c['reason']})\")
if r['verdict']==20:
    lines.append('이 변경은 우리 연결 계약을 깨뜨릴 수 있음. 영향 받는 접속부(컨테이너명/포트/env)를 점검하고, 반영은 승인 PR 을 통해서만 진행할 것.')
else:
    lines.append('비파괴 변경이며 리스너가 lock 을 자동 갱신함. 참고만.')
print(chr(10).join(lines))
")"

# SessionStart 훅 규약: additionalContext 로 주입
python3 -c "
import json,sys
print(json.dumps({'hookSpecificOutput':{'hookEventName':'SessionStart','additionalContext':sys.argv[1]}}, ensure_ascii=False))
" "$SUMMARY"
