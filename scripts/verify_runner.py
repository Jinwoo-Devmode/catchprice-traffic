#!/usr/bin/env python3
"""검증 — GitHub runner IP + SimilarWeb 통과 여부"""
import requests
import sys

UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0'

ip = requests.get('https://api.ipify.org', timeout=10).text
print(f'IP: {ip}')

test = ['musinsa.com', 'kurly.com', 'orgalim.co.kr', 'soundpower.co.kr', 'crbag.kr']
ok = 0
for d in test:
    try:
        r = requests.get(f'https://data.similarweb.com/api/v1/data?domain={d}',
                         headers={'User-Agent': UA}, timeout=15)
        if r.status_code == 200:
            j = r.json()
            v = j.get('Engagments', {}).get('Visits') or 0
            try: v = int(float(v))
            except: v = 0
            print(f'  {d}: 200, Visits={v:,}')
            ok += 1
        else:
            print(f'  {d}: HTTP {r.status_code}')
    except Exception as e:
        print(f'  {d}: ERROR {str(e)[:50]}')

print(f'\nResult: {ok}/5 통과')
sys.exit(0 if ok > 0 else 1)
