#!/usr/bin/env python3
"""
infra_contract.py — shared-infra(C)의 연결 계약 엔진.
C의 CI 와 소비자(A/B)의 훅이 동일하게 재사용한다.

서브커맨드:
  extract <repo>                        compose/init/env → 계약 JSON(stdout)
  compare <old.json> <new(repo|json)>   구조적 diff + 분류 + 소비자 영향
        [--consumer NAME]               특정 소비자 관점으로만 필터
        [--json]                        기계판독 결과 출력

compare exit code:  0=무변경  10=additive만  20=breaking 포함
→ CI/훅이 exit code 로 분기(즉시 반영 vs 승인 게이트)한다.
"""
from __future__ import annotations
import argparse, json, re, sys, pathlib
import yaml

# 소비자 의존성 맵의 기본값. 각 앱 repo 의 .infra-deps.yml 가 있으면 그걸 우선한다.
CONSUMERS_DEFAULT = {
    "RAGaaS": {"services": ["milvus", "fuseki", "neo4j", "redis", "mongo", "minio", "etcd"],
               "mongo_dbs": ["ragaas"],
               "env_keys": ["RAGAAS_MONGO_PASSWORD", "NEO4J_PASSWORD",
                            "FUSEKI_ADMIN_PASSWORD", "MINIO_ACCESS_KEY", "MINIO_SECRET_KEY"]},
    "GoJIRA": {"services": ["mongo", "redis", "gitea"],
               "mongo_dbs": ["gojira"],
               "env_keys": ["GOJIRA_MONGO_PASSWORD"]},
}


def _major(image: str) -> str:
    tag = image.split(":", 1)[1] if ":" in image else "latest"
    m = re.match(r"v?(\d+)", tag)
    return m.group(1) if m else tag


def extract(repo: pathlib.Path) -> dict:
    compose = yaml.safe_load((repo / "docker-compose.yml").read_text())
    services = {}
    for name, spec in (compose.get("services") or {}).items():
        image = spec.get("image", "")
        host_ports, internal_ports = [], []
        for p in (spec.get("ports") or []):
            p = str(p)
            if ":" in p:
                h, c = p.split(":")[-2:]
                host_ports.append(h); internal_ports.append(c)
            else:
                internal_ports.append(p)
        services[name] = {
            "container_name": spec.get("container_name", name),
            "image": image,
            "image_major": _major(image),
            "host_ports": sorted(host_ports),
            "internal_ports": sorted(internal_ports),
            "networks": sorted(spec.get("networks", []) or []),
        }
    net_names = sorted((v or {}).get("name", k)
                       for k, v in (compose.get("networks") or {}).items())
    mongo_users = {}
    init = repo / "init" / "01-create-users.sh"
    if init.exists():
        for db, user in re.findall(
                r'use\s+(\w+)\s+db\.createUser\(\{\s*user:\s*"([^"]+)"', init.read_text()):
            mongo_users[db] = user
    env_keys = []
    envf = repo / ".env.example"
    if envf.exists():
        for line in envf.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                env_keys.append(line.split("=", 1)[0])
    return {"network": net_names, "services": services,
            "mongo_users": mongo_users, "env_keys": sorted(env_keys)}


def _strip_version(c: dict) -> dict:
    return {k: v for k, v in c.items() if k != "version"}


def diff(old: dict, new: dict) -> list[dict]:
    old, new = _strip_version(old), _strip_version(new)
    ch: list[dict] = []
    def add(s, f, o, n, b, r):
        ch.append({"service": s, "field": f, "old": o, "new": n, "breaking": b, "reason": r})

    if set(old.get("network", [])) != set(new.get("network", [])):
        add("<network>", "name", old.get("network"), new.get("network"), True,
            "shared-net 조인 지점 변경 — 모든 소비자 재설정 필요")

    old_s, new_s = old["services"], new["services"]
    for name in old_s.keys() - new_s.keys():
        add(name, "service", "present", "removed", True, "소비 중인 서비스 제거")
    for name in new_s.keys() - old_s.keys():
        add(name, "service", "absent", "added", False, "신규 서비스 추가")
    for name in old_s.keys() & new_s.keys():
        o, n = old_s[name], new_s[name]
        if o["container_name"] != n["container_name"]:
            add(name, "container_name", o["container_name"], n["container_name"], True,
                "DNS 이름 변경 — 연결 문자열 파괴")
        if o["image_major"] != n["image_major"]:
            add(name, "image_major", o["image"], n["image"], True,
                "major 버전 변경 — 데이터/프로토콜 비호환 가능")
        elif o["image"] != n["image"]:
            add(name, "image", o["image"], n["image"], False, "minor/patch 갱신")
        rem = set(o["internal_ports"]) - set(n["internal_ports"])
        addp = set(n["internal_ports"]) - set(o["internal_ports"])
        if rem:  add(name, "internal_ports", sorted(rem), None, True, "노출 포트 제거/변경")
        if addp: add(name, "internal_ports", None, sorted(addp), False, "포트 추가")
        hrem = set(o["host_ports"]) - set(n["host_ports"])
        if hrem: add(name, "host_ports", sorted(hrem), None, True, "호스트 포트 제거/변경")

    for k in set(old["env_keys"]) - set(new["env_keys"]):
        add("<env>", k, "present", "removed", True, "계약 env 키 제거/rename")
    for k in set(new["env_keys"]) - set(old["env_keys"]):
        add("<env>", k, "absent", "added", False, "신규 env 키")

    om, nm = old["mongo_users"], new["mongo_users"]
    for db in om.keys() - nm.keys():
        add("mongo", f"db:{db}", om[db], "removed", True, "Mongo DB/계정 제거")
    for db in om.keys() & nm.keys():
        if om[db] != nm[db]:
            add("mongo", f"user:{db}", om[db], nm[db], True, "Mongo 앱 계정 rename")
    return ch


def bump(old_ver: str, changes: list[dict]) -> str:
    try:
        maj, minr, pat = (int(x) for x in old_ver.split("."))
    except Exception:
        maj, minr, pat = 1, 0, 0
    if any(c["breaking"] for c in changes): return f"{maj+1}.0.0"
    if changes:                            return f"{maj}.{minr+1}.0"
    return f"{maj}.{minr}.{pat+1}"


def relevant_to(change: dict, dep: dict) -> bool:
    s = change["service"]
    return (s in dep["services"] or s == "<network>"
            or (s == "<env>" and change["field"] in dep["env_keys"])
            or (s == "mongo" and any(d in change["field"] for d in dep["mongo_dbs"])))


def impact(changes: list[dict], consumers: dict) -> dict:
    out: dict[str, list] = {}
    for who, dep in consumers.items():
        hit = [c for c in changes if relevant_to(c, dep)]
        if hit:
            out[who] = hit
    return out


def _load(p: str) -> dict:
    path = pathlib.Path(p)
    if path.is_dir():
        return extract(path)
    return json.loads(path.read_text())


def _cmd_extract(a):
    print(json.dumps(extract(pathlib.Path(a.repo)), ensure_ascii=False, indent=2))
    return 0


def _cmd_compare(a):
    old, new = _load(a.old), _load(a.new)
    changes = diff(old, new)
    ov, nv = old.get("version", "?"), new.get("version") or bump(old.get("version", "1.0.0"), changes)

    if a.consumer:
        dep = _load_deps(a.consumer) or CONSUMERS_DEFAULT.get(a.consumer)
        if dep is None:
            print(f"unknown consumer: {a.consumer}", file=sys.stderr); return 2
        changes = [c for c in changes if relevant_to(c, dep)]

    breaking = [c for c in changes if c["breaking"]]
    code = 20 if breaking else (10 if changes else 0)

    if a.json:
        print(json.dumps({"old_version": ov, "new_version": nv, "verdict": code,
                          "changes": changes, "impact": impact(changes, CONSUMERS_DEFAULT) if not a.consumer else None},
                         ensure_ascii=False, indent=2))
        return code

    scope = f" [{a.consumer}]" if a.consumer else ""
    print(f"contract {ov} -> {nv}{scope}")
    if not changes:
        print("  변경 없음"); return code
    for c in changes:
        flag = "BREAKING" if c["breaking"] else "additive"
        print(f"  [{flag}] {c['service']}.{c['field']}: {c['old']} -> {c['new']}  ({c['reason']})")
    if not a.consumer:
        print("\n소비자 영향:")
        for who, hits in impact(changes, CONSUMERS_DEFAULT).items():
            brk = any(h["breaking"] for h in hits)
            print(f"  {who}: {len(hits)}건 => {'승인 게이트' if brk else '즉시 반영'}")
    return code


def _load_deps(consumer: str) -> dict | None:
    f = pathlib.Path(".infra-deps.yml")
    if f.exists():
        d = yaml.safe_load(f.read_text()) or {}
        if d.get("name") == consumer or consumer is None:
            return {"services": d.get("services", []), "mongo_dbs": d.get("mongo_dbs", []),
                    "env_keys": d.get("env_keys", [])}
    return None


def main():
    p = argparse.ArgumentParser(prog="infra_contract")
    sub = p.add_subparsers(dest="cmd", required=True)
    pe = sub.add_parser("extract"); pe.add_argument("repo"); pe.set_defaults(fn=_cmd_extract)
    pc = sub.add_parser("compare")
    pc.add_argument("old"); pc.add_argument("new")
    pc.add_argument("--consumer"); pc.add_argument("--json", action="store_true")
    pc.set_defaults(fn=_cmd_compare)
    a = p.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
