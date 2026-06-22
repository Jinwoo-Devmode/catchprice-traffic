#!/usr/bin/env python3
"""
Chunk 처리 — 받은 도메인 리스트에 대해 SimilarWeb 호출
- 403 차단 시: 재시도 X (다른 잡이 재시도 풀)
- 결과: JSON Lines (도메인당 1줄)
- 최대 5건 연속 차단 시 잡 종료 (다음 워크플로 회차에서 미수집 도메인 재챕터)
"""
import requests
import sys
import os
import json
import time
import random

UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0'
API = 'https://data.similarweb.com/api/v1/data?domain={}'

chunk_path = sys.argv[1]
out_path = sys.argv[2]
chunk_id = sys.argv[3] if len(sys.argv) > 3 else 'unknown'

with open(chunk_path) as f:
    domains = [d.strip() for d in f if d.strip()]

# 재실행마다 다른 순서로 처리 → 같은 chunk 반복 실행 시 chunk 전체가 점진 수집됨(꼬리 방지)
random.shuffle(domains)

# 잡 시작 시 IP 확인 (차단 여부 사전 판단)
try:
    ip = requests.get('https://api.ipify.org', timeout=10).text
except:
    ip = '?'
print(f'[{chunk_id}] IP={ip}, 처리 대상: {len(domains)}건')

# 사전 체크 — musinsa로 테스트
try:
    pre = requests.get(API.format('musinsa.com'), headers={'User-Agent': UA}, timeout=10)
    if pre.status_code != 200:
        print(f'[{chunk_id}] IP 사전 차단됨 → 잡 종료 (재시도 풀로)')
        # 미처리로 종료, 결과 비움
        with open(out_path, 'w') as f:
            pass
        sys.exit(1)  # 잡 실패로 마크 → 재시도
except Exception as e:
    print(f'[{chunk_id}] 사전 체크 실패: {e}')
    sys.exit(1)

ok = blocked = err = 0
block_streak = 0
results = []
start = time.time()

for d in domains:
    try:
        r = requests.get(API.format(d), headers={'User-Agent': UA}, timeout=15)
        if r.status_code == 200:
            j = r.json()
            v = j.get('Engagments', {}).get('Visits') or 0
            try: v = int(float(v))
            except: v = 0
            gr = j.get('GlobalRank') or {}
            gr_r = gr.get('Rank') if isinstance(gr, dict) else None
            cr = j.get('CountryRank') or {}
            cr_r = cr.get('Rank') if isinstance(cr, dict) else None
            results.append({
                'domain': d, 'status': 'ok', 'visits': v,
                'global_rank': gr_r, 'country_rank': cr_r,
                'category': j.get('Category') or '',
                'country': j.get('Country') or '',
            })
            block_streak = 0
            ok += 1
        elif r.status_code == 403:
            block_streak += 1
            blocked += 1
            if block_streak >= 5:
                print(f'[{chunk_id}] 연속 차단 5회 → 잡 중단 ({d}까지)')
                break
        else:
            results.append({'domain': d, 'status': f'http_{r.status_code}'})
            err += 1
    except Exception as e:
        results.append({'domain': d, 'status': 'error', 'msg': str(e)[:80]})
        err += 1
    time.sleep(0.5)

# 결과 저장 (JSON Lines)
with open(out_path, 'w') as f:
    for r in results:
        f.write(json.dumps(r, ensure_ascii=False) + '\n')

elapsed = time.time() - start
print(f'[{chunk_id}] ok={ok}, blocked={blocked}, err={err}, {elapsed:.0f}초')

# 진짜 0건 ok인 경우 실패 처리 → 재시도
if ok == 0:
    sys.exit(2)
