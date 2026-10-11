#!/usr/bin/env python3
"""Explicit isolated fixture loader. No implicit merging, network or provider IO."""
import argparse
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2] / 'fixtures/world-v1'
SCENARIOS=('canonical_demo','full_financial_world','dinner_2026_10_11')


def load(scenario,period=None,root=ROOT):
    if scenario not in SCENARIOS: raise ValueError('Select exactly one known scenario')
    if scenario=='canonical_demo':
        if period not in (None,'2026-09'): raise ValueError('Canonical demo covers September only')
        path=root/scenario/'dataset.json'
    elif scenario=='dinner_2026_10_11':
        if period is not None: raise ValueError('Dinner has its own October date, not a reporting month')
        path=root/scenario/'scenario.json'
    elif period is None:
        path=root/scenario/'snapshot.json'
    elif period=='2026-09':
        path=root/scenario/'september.json'
    else:
        from tools.synthetic_data.generate import MONTHS
        if period not in MONTHS: raise ValueError('Choose a completed month 2023-10 through 2026-09')
        history=json.loads((root/scenario/'ledger.json').read_text())
        summaries=json.loads((root/scenario/'summaries.json').read_text())
        history['transactions']=[t for t in history['transactions'] if t['posted_at'][:7]==period]
        history['summary']=next(s for s in summaries['monthly_summaries'] if s['period']==period)
        return history
    data=json.loads(path.read_text())
    if data['scenario_id']!=scenario: raise ValueError('Scenario isolation violation')
    return data


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--scenario',required=True,choices=SCENARIOS)
    p.add_argument('--period')
    args=p.parse_args()
    print(json.dumps(load(args.scenario,args.period),indent=2,sort_keys=True))
