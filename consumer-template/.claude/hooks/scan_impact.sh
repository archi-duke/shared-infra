#!/usr/bin/env bash
# 바뀐 계약 식별자(구 컨테이너명/포트/env 키)가 우리 코드 어디에서 쓰이는지 grep 으로 찾는다.
# 연결 계약은 리터럴 문자열로 소비되므로 grep 만으로도 실효적. (의미 분석이 필요하면
# 이 자리에서 `claude -p "..."` headless 호출로 교체 가능.)
set -euo pipefail
REPORT="${1:?usage: scan_impact.sh <report.json>}"

TOKENS="$(python3 -c "
import json
r=json.load(open('$REPORT'))
t=set()
for c in r['changes']:
    if not c['breaking']: continue
    for v in (c['old'], c['new']):
        if isinstance(v,str) and v and v not in ('present','removed','absent','added'):
            t.add(v.split(':')[0] if '/' in str(v) or ':' in str(v) else v)
    if c['field']=='container_name' and c['old']: t.add(c['old'])
    if c['service']=='<env>': t.add(c['field'])
    if 'ports' in c['field'] and c['old']:
        for p in (c['old'] if isinstance(c['old'],list) else [c['old']]): t.add(str(p))
print(chr(10).join(sorted(x for x in t if x)))
")"

[ -z "$TOKENS" ] && { echo "_스캔할 식별자 없음_"; exit 0; }

FOUND=0
while IFS= read -r tok; do
  [ -z "$tok" ] && continue
  HITS="$(grep -rnI --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.contract \
          -e "$tok" . 2>/dev/null | head -20 || true)"
  if [ -n "$HITS" ]; then
    FOUND=1
    echo "**\`$tok\`** 사용처:"
    echo '```'
    echo "$HITS"
    echo '```'
    echo
  fi
done <<< "$TOKENS"

[ "$FOUND" = "0" ] && echo "_바뀐 식별자의 직접 사용처를 코드에서 찾지 못함 (간접 참조 여부는 수동 확인 권장)_"
exit 0
