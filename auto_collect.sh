#!/bin/bash
# 자동 수집 루프: 미수집 도메인만 재chunk → push → trigger → 머지 → 반복
# 최대 30회 또는 잔여 < 100건 시 종료

set -e
OUT="/Users/incorrupt/Documents/cafe 24/outbound"
GA="$OUT/github_actions"
cd "$GA"

for i in $(seq 1 30); do
  echo ""
  echo "============================================"
  echo "라운드 $i 시작 - $(date '+%H:%M:%S')"
  echo "============================================"

  # 1. 미수집 도메인 → 새 chunks 생성
  cd "$OUT" && source .venv/bin/activate && python3 - << 'PY'
import csv, sqlite3, os, random, glob
for f in glob.glob('github_actions/data/chunks/*.txt'): os.remove(f)
conn = sqlite3.connect('pipeline/data/scan_state.sqlite')
done = {r[0] for r in conn.execute('SELECT domain FROM similarweb_traffic WHERE status="ok"')}
rev_subs = {r[0] for r in conn.execute('SELECT domain FROM company_data WHERE revenue_value > 0 AND domain LIKE "%.cafe24.com"')}
conn.close()
pending = []
with open('pipeline/data/brands_enriched.csv', 'r', encoding='utf-8-sig') as f:
    for row in csv.DictReader(f):
        d = (row.get('도메인') or '').strip().lower()
        if not d or d in done: continue
        if d.endswith('.cafe24.com') and d not in rev_subs: continue
        pending.append(d)
for d in rev_subs:
    if d not in done and d not in pending: pending.append(d)
random.shuffle(pending)
CHUNK = 150
chunks = [pending[i:i+CHUNK] for i in range(0, len(pending), CHUNK)]
for i, ch in enumerate(chunks):
    with open(f'github_actions/data/chunks/chunk_{i:03d}.txt', 'w') as f:
        f.write('\n'.join(ch))
with open('github_actions/data/manifest.txt', 'w') as f:
    f.write(f'total_pending={len(pending)}\nchunk_count={len(chunks)}\n')
print(f'  미수집: {len(pending)}건, chunks: {len(chunks)}개')
PY

  # 2. 잔여 100건 미만 → 종료
  REMAIN=$(grep 'total_pending' "$GA/data/manifest.txt" | cut -d= -f2)
  CHUNK_CNT=$(ls "$GA/data/chunks/" | wc -l | tr -d ' ')
  echo "  잔여: $REMAIN건 / chunks: $CHUNK_CNT개"
  if [ "$REMAIN" -lt 100 ]; then
    echo "✓ 잔여 100건 미만 → 종료"
    break
  fi

  # 3. push
  cd "$GA"
  git add -A
  git -c user.email="devtestjinwoo@gmail.com" -c user.name="Jinwoo-Devmode" commit -q -m "round $i: $REMAIN domains, $CHUNK_CNT chunks" || true
  git push -q

  # 4. trigger offset=0 (그리고 chunks 100+ 있으면 offset=100도)
  gh workflow run collect.yml -f offset=0
  sleep 3
  RUN0=$(gh run list --workflow=collect.yml --limit 1 --json databaseId --jq '.[0].databaseId')
  echo "  배치1 (offset=0): $RUN0"

  if [ "$CHUNK_CNT" -gt 100 ]; then
    gh workflow run collect.yml -f offset=100
    sleep 3
    RUN1=$(gh run list --workflow=collect.yml --limit 1 --json databaseId --jq '.[0].databaseId')
    echo "  배치2 (offset=100): $RUN1"
  fi

  # 5. 완료 대기
  echo "  완료 대기..."
  gh run watch "$RUN0" --exit-status 2>&1 > /dev/null || true
  if [ -n "$RUN1" ]; then
    gh run watch "$RUN1" --exit-status 2>&1 > /dev/null || true
  fi

  # 6. 결과 다운로드 + 머지
  rm -rf artifacts/round
  mkdir -p artifacts/round
  cd artifacts/round
  gh run download "$RUN0" 2>&1 | tail -2 || true
  if [ -n "$RUN1" ]; then
    gh run download "$RUN1" 2>&1 | tail -2 || true
  fi
  cd "$OUT"

  python3 - << PY
import json, glob, sqlite3, time
conn = sqlite3.connect('pipeline/data/scan_state.sqlite')
now = time.strftime('%Y-%m-%d %H:%M:%S')
added = 0
for f in glob.glob('github_actions/artifacts/round/*/*.jsonl'):
    for line in open(f):
        try:
            r = json.loads(line)
            if r.get('status') == 'ok':
                conn.execute('INSERT OR REPLACE INTO similarweb_traffic (domain, status, visits, global_rank, country_rank, category, country, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                    (r['domain'], 'ok', r.get('visits') or 0, r.get('global_rank'), r.get('country_rank'),
                     r.get('category') or '', r.get('country') or '', now))
                added += 1
        except: pass
conn.commit()
total_ok = conn.execute('SELECT COUNT(*) FROM similarweb_traffic WHERE status="ok"').fetchone()[0]
visits_pos = conn.execute('SELECT COUNT(*) FROM similarweb_traffic WHERE visits > 0').fetchone()[0]
conn.close()
print(f'  신규 {added}건, 누적 ok={total_ok}, 트래픽보유={visits_pos}')
PY

  cd "$GA"
done
echo ""
echo "===== 자동 수집 종료 ====="
