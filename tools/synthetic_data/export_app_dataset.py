"""Exports the three-year world as one FWMCore Dataset the iPhone app can load.

September 2026 is the current period: each account's opening and balance are its September statement's opening and
closing balances, so the app's balance check reconciles. Every ledger transaction (October 2023 through September 2026)
is history. The user profile, dinner receipt, contacts, split example and budget catalog come from seed-v1 so the
Split and Budget screens work unchanged.

Trades, settlements and dividends inside investment accounts move money between cash and holdings; they aren't
spending, so only those accounts' transfers to and from other accounts are kept, and each investment account's
September cash balance is recomputed from what is kept. What the world holds beyond that cash (securities, open
prediction positions, the condo's estimated value) becomes holdings accounts with no transactions, sized from the
world's September summary, so assets, liabilities and net worth match it exactly. Run from the repository root:

    python3 -m tools.synthetic_data.export_app_dataset
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORLD = ROOT / 'fixtures/world-v1/full_financial_world'
OUT = ROOT / 'Packages/FWMFeatureUI/Sources/FWMFeatureUI/Resources/world-3y.json'
ACCOUNT_KEYS = ('account_id', 'institution', 'kind', 'asset_or_liability')
TXN_KEYS = ('transaction_id', 'account_id', 'posted_at', 'signed_amount_cents', 'merchant', 'category', 'pending',
            'transfer_pair_id', 'refund_of', 'source_id')


def main():
    seed = json.loads((ROOT / 'fixtures/seed-v1.json').read_text())
    september = json.loads((WORLD / 'september.json').read_text())
    ledger = json.loads((WORLD / 'ledger.json').read_text())
    snapshot = json.loads((WORLD / 'snapshot.json').read_text())
    statements = {s['account_id']: s for s in september['statements']}
    summary = september['summary']
    as_of = '2026-09-30T23:59:59-07:00'
    user_id = seed['user']['user_id']
    investing = {a['account_id'] for a in september['accounts'] if a['kind'] in ('brokerage', 'prediction_market')}
    # Investment accounts keep only paired transfers; their internal trading is not spending.
    kept = [t for t in ledger['transactions'] if t['account_id'] not in investing or t.get('transfer_pair_id')]
    september_activity = {}
    for t in kept:
        if t['posted_at'].startswith('2026-09') and not t['pending']:
            september_activity[t['account_id']] = september_activity.get(t['account_id'], 0) + t['signed_amount_cents']

    def account(account_id, institution, kind, side, opening, balance, source):
        return {'account_id': account_id, 'institution': institution, 'kind': kind, 'asset_or_liability': side, 'user_id': user_id,
                'as_of': as_of, 'opening_balance_cents': opening, 'balance_cents': balance, 'source_id': source}

    accounts = []
    for a in september['accounts']:
        st = statements[a['account_id']]
        closing = st['closing_balance_cents']
        if a['account_id'] in investing:
            closing = st['opening_balance_cents'] + september_activity.get(a['account_id'], 0)
        accounts.append(account(a['account_id'], a['institution'], a['kind'], a['asset_or_liability'], st['opening_balance_cents'], closing, a['source_id']))
    cash = {a['account_id']: a['balance_cents'] for a in accounts}
    brokerage_cash = sum(v for k, v in cash.items() if k in investing and k == 'robinhood')
    prediction_cash = sum(v for k, v in cash.items() if k in investing and k != 'robinhood')
    holdings = [
        account('robinhood_securities', 'Robinhood', 'securities', 'asset', None, summary['liquid_investment_equity_cents'] - brokerage_cash,
                'fixture:summary:liquid_investment_equity'),
        account('prediction_positions', 'Prediction markets', 'open_positions', 'asset', None, summary['prediction_equity_cents'] - prediction_cash,
                'fixture:summary:prediction_equity'),
        account('home_value', 'Cedar condo', 'property', 'asset', None, summary['illiquid_property_cents'], 'fixture:summary:illiquid_property'),
    ]
    for h in holdings:
        h['opening_balance_cents'] = h['balance_cents']  # no activity, so September opens and closes at the same value
    accounts += holdings
    transactions = [{k: t.get(k) for k in TXN_KEYS} for t in kept]
    transactions.sort(key=lambda t: (t['posted_at'], t['transaction_id']))
    dataset = {
        'dataset_version': ledger['dataset_version'],
        'data_mode': 'fixture',
        'as_of': as_of,
        'demo_clock': snapshot.get('demo_clock') or seed.get('demo_clock'),
        'user': seed['user'],
        'accounts': accounts,
        'transactions': transactions,
        **{k: seed[k] for k in ('receipts', 'contacts', 'split_example', 'category_targets_sep_cents', 'catalog') if k in seed},
    }
    OUT.write_text(json.dumps(dataset, separators=(',', ':'), sort_keys=True) + '\n')
    print(json.dumps({'out': str(OUT.relative_to(ROOT)), 'accounts': len(accounts), 'transactions': len(transactions),
                      'bytes': OUT.stat().st_size}))


if __name__ == '__main__':
    main()
