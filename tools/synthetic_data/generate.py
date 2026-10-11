#!/usr/bin/env python3
"""Offline synthetic world. Money is cents; quantities and prices use Decimal.
Stages export usable snapshot/September first; history is exported only in full.
"""
import argparse
import calendar
import copy
import hashlib
import json
import random
from collections import defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'fixtures/world-v1'
VERSION = 'synthetic-world-v1'
SEED = 261011
TZ = ZoneInfo('America/Los_Angeles')
CLOCK = '2026-10-11T21:00:00-07:00'
MONTHS = [f'{2023 + (9+i)//12}-{(9+i)%12+1:02}' for i in range(36)]


def cents(value):
    return int((Decimal(value) * 100).quantize(Decimal('1'), rounding=ROUND_HALF_UP))


def rounded(value):
    return int(Decimal(value).quantize(Decimal('1'), rounding=ROUND_HALF_UP))


def stamp(day, hour=12):
    return datetime.fromisoformat(f'{day}T{hour:02}:00:00').replace(tzinfo=TZ).isoformat()


def end(period):
    y, m = map(int, period.split('-'))
    return f'{period}-{calendar.monthrange(y, m)[1]:02}'


def rec(record_id, scenario='full_financial_world', **fields):
    return dict(record_id=record_id, synthetic=True, scenario_id=scenario,
                dataset_version=VERSION, currency='USD', source_id=f'fixture:{record_id}', **fields)


def envelope(scenario, **fields):
    return dict(synthetic=True, scenario_id=scenario, dataset_version=VERSION,
                data_mode='fixture', currency='USD', timezone=str(TZ), seed=SEED,
                demo_clock=CLOCK, **fields)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(payload)
    temporary.replace(path)


ACCOUNT_SPECS = [
    ('chase_checking', 'Chase', 'checking', 'asset', '2022-05-01', 750000),
    ('chase_savings', 'Chase', 'savings', 'asset', '2022-05-01', 400000),
    ('capital_one_checking', 'Capital One', 'checking', 'asset', '2024-07-01', 0),
    ('capital_one_savings', 'Capital One', 'savings', 'asset', '2024-07-01', 0),
    ('chase_card', 'Chase', 'credit_card', 'liability', '2022-05-01', 30000),
    ('capital_one_card', 'Capital One', 'credit_card', 'liability', '2024-07-01', 0),
    ('robinhood', 'Robinhood', 'brokerage', 'asset', '2023-04-01', 600000),
    ('kalshi', 'Kalshi', 'prediction_market', 'asset', '2024-01-01', 0),
    ('polymarket', 'Polymarket', 'prediction_market', 'asset', '2024-07-01', 0),
    ('mortgage', 'Fictional Home Loan', 'mortgage', 'liability', '2022-06-01', 28150000),
    ('student', 'Fictional Education Loan', 'student_loan', 'liability', '2020-08-01', 1850000),
]
INSTRUMENTS = [('VTI', 'US broad equity ETF', '210.00'), ('VXUS', 'International equity ETF', '55.00'),
               ('BND', 'Bond ETF', '70.00'), ('AAPL', 'US equity', '170.00')]
MERCHANTS = {
    'payroll': ('Fictional Harbor Software payroll', 'Income'),
    'hoa': ('Fictional Cedar HOA', 'Housing'), 'tax': ('Fictional County property tax', 'Housing'),
    'insurance': ('Fictional condo insurance', 'Housing'), 'mortgage_interest': ('Fictional mortgage interest', 'Housing'),
    'student_interest': ('Fictional student loan interest', 'Debt interest'),
    'grocer': ('Neighborhood Pantry (synthetic)', 'Groceries'), 'oat': ('Preferred oat milk (synthetic)', 'Groceries'),
    'pantry': ('Pantry staples (synthetic)', 'Groceries'), 'detergent': ('Preferred detergent (synthetic)', 'Other'),
    'beans': ('Preferred coffee beans (synthetic)', 'Other'), 'phone': ('Fictional coverage phone plan', 'Bills and subscriptions'),
    'utilities': ('Fictional utility service', 'Bills and subscriptions'), 'internet': ('Fictional home internet', 'Bills and subscriptions'),
    'music': ('Fictional music subscription', 'Bills and subscriptions'), 'video': ('Fictional video subscription', 'Bills and subscriptions'),
    'dining': ('Cedar lunch counter (synthetic)', 'Dining'), 'restaurant': ('Juniper dinner house (synthetic)', 'Dining'),
    'transit': ('Fictional transit pass', 'Transport'), 'rideshare': ('Fictional rideshare', 'Transport'),
    'other': ('Fictional neighborhood shop', 'Other'), 'laptop': ('Fictional electronics shop', 'Other'),
    'travel': ('Fictional travel booking', 'Travel'), 'repair': ('Fictional condo repair', 'Housing'),
    'card_fee': ('Synthetic card finance terms', 'Interest and fees'),
    'interest': ('Synthetic savings interest', 'Income'), 'reimbursement': ('Fictional employer reimbursement', 'Reimbursement'),
    'dinner': ('Juniper Table - SYNTHETIC DINNER', 'Dining'),
}


class World:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.accounts = [rec('account_'+a, account_id=a, institution=p, kind=k, asset_or_liability=s,
                             opened_on=d, opening_as_of='2023-10-01', opening_balance_cents=b,
                             credit_limit_cents=1200000 if a == 'chase_card' else 800000 if k == 'credit_card' else None,
                             balance_representation='cash_or_collateral' if a in ('robinhood','kalshi','polymarket') else 'posted_balance')
                         for a,p,k,s,d,b in ACCOUNT_SPECS]
        self.by_account = {a['account_id']:a for a in self.accounts}
        self.balances = {a['account_id']:a['opening_balance_cents'] for a in self.accounts}
        self.ledger = []
        self.trades, self.lots, self.position_marks, self.portfolio_months = [], defaultdict(list), [], []
        self.market_events, self.markets, self.market_positions, self.market_marks, self.market_months = [], [], {}, [], []
        self.debts, self.property_values, self.summaries, self.statements = [], [], [], []
        self.prices = {symbol:Decimal(p) for symbol,_,p in INSTRUMENTS}
        self.realized = 0
        self.unpaid_card = 0
        self.property_value = 36500000

    def add(self, day, account, amount, kind, merchant=None, **extras):
        period=day[:7]
        seq=sum(t['posted_at'][:7]==period for t in self.ledger)+1
        tid=f'fw_{period}_{seq:04}'
        label, category = MERCHANTS.get(merchant, (f'Synthetic {kind}', None))
        t=rec(tid, transaction_id=tid, account_id=account, posted_at=stamp(day), signed_amount_cents=amount,
              activity_kind=kind, merchant=label, merchant_id=merchant, category=category,
              pending=False, status='observed', transfer_pair_id=None, refund_of=None, **extras)
        self.ledger.append(t)
        if not t['pending']:
            self.balances[account] += amount if self.by_account[account]['asset_or_liability']=='asset' else -amount
        return tid

    def transfer(self, day, src, dst, amount, kind='internal_transfer'):
        pair=f'pair_{day}_{src}_{dst}_{len(self.ledger):04}'
        first=self.add(day,src,-amount,kind)
        second=self.add(day,dst,amount,kind)
        for t in self.ledger[-2:]:
            t['transfer_pair_id']=pair
            t['category']='Transfer'
            t['counterpart_transaction_id']=second if t['transaction_id']==first else first
        return first,second

    def trade(self, day, symbol, side, quantity):
        qty=Decimal(quantity); price=self.prices[symbol]
        value=cents(qty*price); basis=0
        if side=='buy':
            self.lots[symbol].append(dict(quantity=qty, basis_cents=value, acquired_on=day,
                                         lot_id=f'lot_{day}_{symbol}_{len(self.trades):03}'))
        else:
            remaining=qty
            for lot in self.lots[symbol]:
                take=min(lot['quantity'],remaining)
                allocated=lot['basis_cents'] if take==lot['quantity'] else rounded(Decimal(lot['basis_cents'])*take/lot['quantity'])
                lot['quantity']-=take; lot['basis_cents']-=allocated
                remaining-=take; basis+=allocated
                if not remaining: break
            assert remaining==0, ('oversold',symbol,day)
        rid=f'trade_{day}_{symbol}_{side}'
        tid=self.add(day,'robinhood',-value if side=='buy' else value,'security_trade',instrument_id=symbol, domain_record_id=rid)
        gain=value-basis if side=='sell' else 0
        self.realized+=gain
        self.trades.append(rec(rid, trade_id=rid, account_id='robinhood', instrument_id=symbol, executed_at=stamp(day),
                               side=side, quantity=str(qty), price_usd=str(price), gross_cents=value, fee_cents=0,
                               cost_basis_cents=value if side=='buy' else basis, realized_gain_cents=gain,
                               cash_transaction_id=tid, price_provenance='synthetic_price_path'))

    def market_event(self, day, provider, market_id, kind, qty, price, fee=0, **extras):
        rid=f'me_{day}_{provider}_{len(self.market_events):04}'
        q=Decimal(qty); p=Decimal(price); gross=cents(q*p)
        amount= -gross-fee if kind=='buy' else gross-fee
        tid=self.add(day,provider,amount,'market_trade' if kind=='buy' else 'market_settlement',domain_record_id=rid)
        event=rec(rid,event_id=rid,account_id=provider,market_id=market_id,occurred_at=stamp(day),kind=kind,
                  quantity=str(q),price_usd=str(p),gross_cents=gross,fee_cents=fee,cash_transaction_id=tid, **extras)
        self.market_events.append(event)
        if kind=='buy':
            self.market_positions[market_id]=dict(quantity=q,cost_cents=gross+fee,event_id=rid,account_id=provider)
        else:
            pos=self.market_positions.pop(market_id)
            event['cost_basis_cents']=pos['cost_cents']
            event['realized_gain_cents']=gross-fee-pos['cost_cents']
        return event

    def prediction_month(self, period, i, provider):
        if period+'-01' < self.by_account[provider]['opened_on']: return
        # Resolve the previous month's carry; the final September carry remains open.
        for mid,pos in list(self.market_positions.items()):
            if pos['account_id']==provider:
                self.market_event(period+'-03',provider,mid,'settlement',str(pos['quantity']), '1.00' if i%3 else '0.00',outcome='synthetic_resolved_yes' if i%3 else 'synthetic_resolved_no')
                market=next(m for m in self.markets if m['market_id']==mid)
                market.update(resolved_on=period+'-03',outcome='synthetic_yes' if i%3 else 'synthetic_no')
        busy=period in ('2026-06','2026-07','2026-08')
        deposit=(25000 if busy else 5000) if provider=='kalshi' else (18000 if busy else 3000)
        self.transfer(period+'-06','chase_checking',provider,deposit,'investment_funding')
        for j,category in enumerate(('weather','economics','sports')):
            mid=f'{provider}_{period}_{category}'
            self.markets.append(rec(mid,market_id=mid,account_id=provider,category=category,
                                    question=f'SYNTHETIC: Will fictional Cedar {category} index exceed demo threshold {i+1}?',
                                    resolution_policy='Fictional binary YES pays 1 USD equivalent per contract; NO pays zero.',
                                    opened_on='2026-08-20' if provider=='polymarket' and period=='2026-09' and j==2 else period+'-08',resolved_on=period+'-24' if j<2 else None,
                                    outcome=('synthetic_yes' if j==0 else 'synthetic_no') if j<2 else 'unresolved'))
            qty='100' if busy else '10'
            self.market_event(period+'-08',provider,mid,'buy',qty,('0.40','0.60','0.50')[j],20 if provider=='kalshi' else 0)
            if j<2:
                self.market_event(period+'-24',provider,mid,'settlement',qty,'1.00' if j==0 else '0.00',outcome='synthetic_yes' if j==0 else 'synthetic_no')
            else:
                mark=Decimal('0.56') if i%2 else Decimal('0.43')
                stale=provider=='polymarket' and period=='2026-09'
                self.market_marks.append(rec('mark_'+mid,market_id=mid,account_id=provider,quantity=qty,
                                             price_usd=str(mark),value_cents=cents(Decimal(qty)*mark),
                                             valuation_as_of=stamp('2026-08-31' if stale else end(period)),
                                             observation_as_of=stamp(end(period)),stale=stale,source_type='synthetic_manual_mark',
                                             cost_basis_cents=self.market_positions[mid]['cost_cents']))
        if i%8==7:
            self.transfer(period+'-27',provider,'chase_checking',1000,'investment_proceeds')
        cash=self.balances[provider]
        previous=next((m['equity_cents'] for m in reversed(self.market_months) if m['account_id']==provider),0)
        withdrawal=1000 if i%8==7 else 0
        reserve=200
        marks=[m for m in self.market_marks if m['market_id'].startswith(provider+'_'+period)]
        position_value=sum(m['value_cents'] for m in marks)
        self.market_months.append(rec(f'market_{provider}_{period}',account_id=provider,period=period,
                                      cash_or_collateral_cents=cash,collateral_asset='SYNTHETIC_USDC' if provider=='polymarket' else 'USD',
                                      collateral_quantity=str(Decimal(cash)/100) if provider=='polymarket' else None,
                                      collateral_usd_per_unit='1.00' if provider=='polymarket' else None,
                                      reserved_cents=reserve,available_cents=cash-reserve,positions_cents=position_value,
                                      equity_cents=cash+position_value,funding_cents=deposit,withdrawals_cents=withdrawal,period_return_cents=cash+position_value-previous-deposit+withdrawal,realized_gain_cents=sum(e.get('realized_gain_cents',0) for e in self.market_events if e['account_id']==provider and e['occurred_at'][:7]==period),unrealized_gain_cents=sum(m['value_cents']-m['cost_basis_cents'] for m in marks),open_order=rec(f'order_{provider}_{period}',account_id=provider,
                                      market_id=f'{provider}_{period}_sports',status='open',quantity='5',limit_price_usd='0.40',reserved_cents=reserve),
                                      valuation_as_of=stamp(end(period)),mark_ids=[m['record_id'] for m in marks],
                                      stale=any(m['stale'] for m in marks)))

    def loan_month(self, period, account, rate, payment, extra=0):
        opening=self.balances[account]
        interest=rounded(Decimal(opening)*Decimal(rate)/12)
        principal=min(opening,payment-interest+extra)
        day=period+'-02'
        it=self.add(day,'chase_checking',-interest,'interest','mortgage_interest' if account=='mortgage' else 'student_interest')
        legs=self.transfer(day,'chase_checking',account,principal,'debt_principal')
        self.debts.append(rec(f'amort_{account}_{period}',account_id=account,period=period,opening_principal_cents=opening,
                              interest_cents=interest,principal_cents=principal,additional_principal_cents=extra,
                              payment_cents=interest+principal,escrow_cents=0,closing_principal_cents=self.balances[account],
                              annual_rate=rate,policy='synthetic_monthly_opening_balance_rate_divided_by_12_half_up',
                              transaction_ids=[it,*legs]))

    def run_month(self, period, i):
        start=dict(self.balances)
        income=720000 if period<'2024-07' else 820000 if period<'2025-07' else 900000
        for d in ('15','28'): self.add(period+'-'+d,'chase_checking',income//2,'income','payroll')
        self.loan_month(period,'mortgage','0.05',160000)
        self.loan_month(period,'student','0.045',22000,10000 if period>='2025-07' else 0)
        for merchant,amount,day in [('hoa',27000,1),('tax',22000,4),('insurance',6500,4)]:
            self.add(f'{period}-{day:02}','chase_checking',-amount,'consumption',merchant)
        cap=period>='2024-07'
        if cap: self.transfer(period+'-01','chase_checking','capital_one_checking',45000)
        for merchant,amount,day in [('phone',8500,4),('utilities',17000+(4500 if period[5:] in ('12','01','02') else 0),7),
                                   ('internet',6500,9),('music',1199,12)]:
            self.add(f'{period}-{day:02}','capital_one_checking' if cap else 'chase_checking',-amount,'consumption',merchant)
        if period<'2025-03': self.add(period+'-12','chase_card',-1549,'consumption','video')
        # Pay preceding statement in full, except one intentional December shortfall.
        for card in ('chase_card','capital_one_card') if cap else ('chase_card',):
            amount=start[card]-(10000 if period=='2024-12' and card=='chase_card' else 0)
            if amount: self.transfer(period+'-05','chase_checking',card,amount,'card_payment')
        if period=='2025-01':
            self.add(period+'-01','chase_card',-200,'interest','card_fee',synthetic_policy='2 percent of prior unpaid 100 USD, not issuer terms')
            self.add(period+'-01','chase_card',-1500,'fee','card_fee',synthetic_policy='fixed synthetic late fee')
        self.transfer(period+'-16','chase_checking','chase_savings',30000)
        if cap: self.transfer(period+'-16','chase_checking','capital_one_savings',20000)
        for a in ('chase_savings','capital_one_savings') if cap else ('chase_savings',):
            interest=rounded(Decimal(start[a])*Decimal('0.002'))
            if interest: self.add(end(period),a,interest,'income','interest')
        card='capital_one_card' if cap else 'chase_card'
        # Stable merchant identities, varying synthetic descriptions, realistic drilldown.
        for j in range(12):
            amount=self.rng.randint(3400,6500)
            tid=self.add(f'{period}-{2+j*2:02}',card,-amount,'consumption','grocer')
            self.ledger[-1]['merchant']=f'PANTRY STORE #{j%3+1} SYNTHETIC'
        for d in (6,13,20,27): self.add(f'{period}-{d:02}',card,-3000,'consumption','pantry')
        for d in (8,18,28): self.add(f'{period}-{d:02}',card,-600,'consumption','oat')
        self.add(period+'-11',card,-4800,'consumption','detergent')
        self.add(period+'-06','chase_card',-4000,'consumption','beans')
        for j in range(12): self.add(f'{period}-{1+j*2:02}','chase_card',-self.rng.randint(1400,3100),'consumption','dining')
        for d in (9,23): self.add(f'{period}-{d:02}','chase_card',-self.rng.randint(5500,8500),'consumption','restaurant')
        for d in (3,10,17,24): self.add(f'{period}-{d:02}','chase_checking',-1500,'consumption','transit')
        for d in (14,21): self.add(f'{period}-{d:02}','chase_card',-2800,'consumption','rideshare')
        for j in range(6): self.add(f'{period}-{3+j*4:02}',card,-self.rng.randint(1100,3900),'consumption','other')
        if period[5:]=='12': self.add(period+'-19',card,-42000,'consumption','other',event_label='holiday_gifts')
        if period[5:]=='08': self.add(period+'-18','chase_card',-96000,'consumption','travel',event_label='annual_trip')
        if period=='2025-11': self.add(period+'-18','chase_card',-235000,'consumption','repair',event_label='unusually_expensive_condo_repair')
        if period=='2024-09': self.add(period+'-18','chase_card',-180000,'consumption','laptop',event_label='one_time_laptop')
        if period=='2025-02':
            original=self.add(period+'-10',card,-14500,'consumption','other',event_label='returned_coat')
            self.add(period+'-22',card,14500,'refund','other',original_purchase_id=original)
            self.ledger[-1]['refund_of']=original
        if period=='2026-04':
            purchase=self.add(period+'-08','chase_checking',-18000,'consumption','travel',event_label='employer_trip')
            self.add(period+'-26','chase_checking',18000,'reimbursement','reimbursement',reimburses_transaction_id=purchase)
        contribution=45000 if period<'2025-07' else 65000
        self.transfer(period+'-17','chase_checking','robinhood',contribution,'investment_funding')
        # Paths intentionally synthetic, with an abrupt drawdown visible in charts.
        for symbol in self.prices:
            factor=Decimal(self.rng.randint(970,1050))/1000
            if period=='2025-04': factor=Decimal('0.89') if symbol!='BND' else Decimal('1.02')
            self.prices[symbol]=(self.prices[symbol]*factor).quantize(Decimal('.01'),rounding=ROUND_HALF_UP)
        if i==0:
            for symbol,qty in [('VTI','10'),('VXUS','10'),('BND','10'),('AAPL','5')]: self.trade(period+'-03',symbol,'buy',qty)
        for symbol,qty in [('VTI','1'),('VXUS','2'),('BND','1')]: self.trade(period+'-19',symbol,'buy',qty)
        if i%9==8:
            self.trade(period+'-22','VTI','sell','2')
            self.transfer(period+'-25','robinhood','chase_checking',15000,'investment_proceeds')
        if period[5:] in ('03','06','09','12'):
            for symbol in ('VTI','VXUS','BND'):
                q=sum(l['quantity'] for l in self.lots[symbol])
                amount=cents(q*Decimal('0.25'))
                self.add(period+'-26','robinhood',amount,'dividend',instrument_id=symbol)
        position_ids=[]; holdings=0; unrealized=0
        for symbol in self.prices:
            qty=sum(l['quantity'] for l in self.lots[symbol]); basis=sum(l['basis_cents'] for l in self.lots[symbol])
            value=cents(qty*self.prices[symbol]); holdings+=value; unrealized+=value-basis
            mid=f'position_{period}_{symbol}'; position_ids.append(mid)
            self.position_marks.append(rec(mid,account_id='robinhood',instrument_id=symbol,period=period,quantity=str(qty),
                                           price_usd=str(self.prices[symbol]),value_cents=value,cost_basis_cents=basis,
                                           unrealized_gain_cents=value-basis,valuation_as_of=stamp(end(period)),stale=False,
                                           price_provenance='synthetic_price_path',
                                           lots=[dict(lot_id=l['lot_id'],quantity=str(l['quantity']),cost_basis_cents=l['basis_cents'],acquired_on=l['acquired_on'],synthetic=True) for l in self.lots[symbol] if l['quantity']]))
        self.portfolio_months.append(rec('portfolio_'+period,account_id='robinhood',period=period,cash_cents=self.balances['robinhood'],
                                         holdings_cents=holdings,equity_cents=self.balances['robinhood']+holdings,
                                         funding_cents=contribution,withdrawals_cents=15000 if i%9==8 else 0,period_return_cents=self.balances['robinhood']+holdings-(self.portfolio_months[-1]['equity_cents'] if self.portfolio_months else 600000)-contribution+(15000 if i%9==8 else 0),realized_gain_to_date_cents=self.realized,unrealized_gain_cents=unrealized,
                                         valuation_as_of=stamp(end(period)),position_ids=position_ids))
        for p in ('kalshi','polymarket'): self.prediction_month(period,i,p)
        self.property_value+=self.rng.randint(-350000,500000)
        if period=='2025-04': self.property_value-=2200000
        self.property_values.append(rec('property_'+period,property_id='property_cedar_condo',period=period,
                                        gross_value_cents=self.property_value,ownership_fraction='1.00',attributable_value_cents=self.property_value,
                                        loan_account_id='mortgage',attributable_loan_principal_cents=self.balances['mortgage'],
                                        equity_cents=self.property_value-self.balances['mortgage'],
                                        valuation_as_of=stamp(end(period)),source_type='synthetic_manual_estimate',uncertain=True,liquid=False))
        tx=[t for t in self.ledger if t['posted_at'][:7]==period]
        self.make_statements(period,start,tx)
        self.summaries.append(self.summary(period,start,tx))

    def make_statements(self,period,start,tx):
        for a in self.accounts:
            aid=a['account_id']
            if a['opened_on']>end(period): continue
            rows=[t for t in tx if t['account_id']==aid and not t['pending']]
            s=rec(f'statement_{aid}_{period}',account_id=aid,period=period,period_start=period+'-01',period_end=end(period),
                  closing_date=end(period),opening_balance_cents=start[aid],closing_balance_cents=self.balances[aid],
                  transaction_ids=[t['transaction_id'] for t in rows],transaction_source_ids=[t['source_id'] for t in rows],
                  account_side=a['asset_or_liability'],account_kind=a['kind'],institution=a['institution'],
                  terms_label='SYNTHETIC DEMO STATEMENT - no issuer terms or real account number',
                  inflows_cents=sum(t['signed_amount_cents'] for t in rows if t['signed_amount_cents']>0),
                  outflows_cents=-sum(t['signed_amount_cents'] for t in rows if t['signed_amount_cents']<0))
            if a['kind']=='credit_card':
                s.update(purchases_cents=-sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='consumption'),
                         credits_cents=sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='refund'),
                         payments_cents=sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='card_payment'),
                         interest_cents=-sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='interest'),
                         fees_cents=-sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='fee'),
                         credit_limit_cents=a['credit_limit_cents'],minimum_due_cents=min(self.balances[aid],max(2500,rounded(Decimal(self.balances[aid])*Decimal('.02')))),
                         due_date=(date.fromisoformat(end(period))+timedelta(days=25)).isoformat(),
                         interest_policy='Only January 2025: 2% of December unpaid 100 USD; fixed 15 USD fee. Otherwise paid in full. Fictional policy.')
            self.statements.append(s)

    def summary(self,period,start,tx):
        cats=defaultdict(int)
        evidence=defaultdict(list)
        for t in tx:
            if t['activity_kind'] in ('consumption','interest','fee','refund'):
                cats[t['category']]-=t['signed_amount_cents']; evidence[t['category']].append(t['transaction_id'])
        expense=sum(cats.values())
        income=sum(t['signed_amount_cents'] for t in tx if t['activity_kind']=='income')
        reimburse=sum(t['signed_amount_cents'] for t in tx if t['activity_kind']=='reimbursement')
        banks=[a['account_id'] for a in self.accounts if a['kind'] in ('checking','savings') and a['opened_on']<=end(period)]
        checking=[a for a in banks if self.by_account[a]['kind']=='checking']
        inv=[t for t in tx if t['activity_kind']=='investment_funding' and t['signed_amount_cents']<0]
        withdrawn=[t for t in tx if t['activity_kind']=='investment_proceeds' and t['signed_amount_cents']>0]
        saved=[t for t in tx if t['activity_kind']=='internal_transfer' and t['signed_amount_cents']>0 and self.by_account[t['account_id']]['kind']=='savings']
        principal=[t for t in tx if t['activity_kind']=='debt_principal' and t['signed_amount_cents']<0]
        card_pay=[t for t in tx if t['activity_kind']=='card_payment' and t['signed_amount_cents']<0]
        bank_cash=sum(self.balances[a] for a in banks)
        rh=self.portfolio_months[-1]
        pm=[m for m in self.market_months if m['period']==period]
        prop=self.property_values[-1]
        assets=bank_cash+rh['equity_cents']+sum(m['equity_cents'] for m in pm)+prop['attributable_value_cents']
        liabilities=sum(self.balances[a['account_id']] for a in self.accounts if a['asset_or_liability']=='liability')
        previous_rh=self.portfolio_months[-2]['equity_cents'] if len(self.portfolio_months)>1 else 600000
        funded=-sum(t['signed_amount_cents'] for t in inv if t['account_id']=='chase_checking' and self.ledger[self.ledger.index(t)+1]['account_id']=='robinhood')
        rh_withdraw=sum(t['signed_amount_cents'] for t in withdrawn if t['account_id']=='chase_checking' and self.ledger[self.ledger.index(t)-1]['account_id']=='robinhood')
        allocation=income+reimburse-expense-sum(-t['signed_amount_cents'] for t in principal)-sum(t['signed_amount_cents'] for t in saved)-sum(-t['signed_amount_cents'] for t in inv)+sum(t['signed_amount_cents'] for t in withdrawn)
        return rec('summary_'+period,period=period,status='observed',income_cents=income,consumption_spending_cents=expense,
                   reimbursements_cents=reimburse,category_totals_cents=dict(cats),category_evidence_ids=dict(evidence),
                   savings_contributions_cents=sum(t['signed_amount_cents'] for t in saved),
                   investment_funding_cents=sum(-t['signed_amount_cents'] for t in inv),investment_proceeds_cents=sum(t['signed_amount_cents'] for t in withdrawn),
                   debt_principal_cents=sum(-t['signed_amount_cents'] for t in principal),card_payments_cents=sum(-t['signed_amount_cents'] for t in card_pay),
                   accrual_allocation_remainder_cents=allocation,
                   net_checking_cash_retained_cents=sum(self.balances[a]-start[a] for a in checking),
                   net_bank_cash_change_cents=sum(self.balances[a]-start[a] for a in banks),
                   total_bank_cash_outflow_cents=-sum(t['signed_amount_cents'] for t in tx if t['account_id'] in banks and t['signed_amount_cents']<0),
                   bank_cash_cents=bank_cash,liquid_investment_equity_cents=rh['equity_cents'],prediction_equity_cents=sum(m['equity_cents'] for m in pm),
                   illiquid_property_cents=prop['attributable_value_cents'],property_equity_cents=prop['equity_cents'],
                   assets_cents=assets,liabilities_cents=liabilities,net_worth_cents=assets-liabilities,
                   robinhood_return_cents=rh['equity_cents']-previous_rh-funded+rh_withdraw,prediction_return_cents=sum(m['period_return_cents'] for m in pm),
                   account_balances_cents=dict(self.balances),
                   credit_utilization={a['account_id']:dict(balance_cents=self.balances[a['account_id']],limit_cents=a['credit_limit_cents'],ratio=str(Decimal(self.balances[a['account_id']])/a['credit_limit_cents'])) for a in self.accounts if a['kind']=='credit_card' and a['opened_on']<=end(period)},
                   observation_as_of=stamp(end(period)),evidence_ids=[t['transaction_id'] for t in tx],
                   valuation_ids=[rh['record_id'],prop['record_id']]+[m['record_id'] for m in pm])

    def build(self):
        for i,period in enumerate(MONTHS): self.run_month(period,i)
        return self


def profile():
    return envelope('full_financial_world', person=rec('person_cedar',fictional_name='Morgan Cedar',age_at_demo=32,
        dinner_demo_self_alias='Ashwin is a synthetic payer label for Morgan Cedar in this demo, not a verified real person or contact.',
        biography='Fictional software engineer living alone in an owner-occupied condo in fictional Cedar District, Northern California. No rental business.',
        income_schedule='Net payroll twice monthly on the 15th and 28th; synthetic amounts after withheld tax.',
        monthly_net_pay_cents={'2023-10':720000,'2024-07':820000,'2025-07':900000},
        changes=['2024-07 promotion and second bank for bill sinking funds','2024-09 laptop purchase','2024-12 short-paid card; January synthetic interest/fee',
                 '2025-02 coat refund','2025-03 video subscription cancelled','2025-04 synthetic market drawdown','2025-07 raise and extra student principal',
                 '2025-11 condo repair','2026-06 through 2026-08 more prediction-market activity'],
        bank_roles={'chase_checking':'payroll, housing, card payments and investments','chase_savings':'emergency fund',
                    'capital_one_checking':'bill envelope opened July 2024','capital_one_savings':'annual expenses and travel sinking fund'},
        card_policy='Every month pay prior month opening balance. December 2024 leaves 100 USD; cure next month. Purchases recognized when posted.',
        investing='Initial cash seeds four instruments; monthly deposits, long-only buys, quarterly dividends and occasional FIFO sales/withdrawals.',
        prediction_policy='Small fictional weather/economics/sports binary markets; illustrative risk, not actual provider mechanics.',
        housing='100% owner-occupied condo; HOA, tax and insurance paid directly. No escrow, rent or rental income.',
        preferences={'brand_locks':['oat_milk'],'phone_coverage':'must retain necessary coverage','rejected':['instant_coffee'],'accepted':['alternate_coffee_beans']},
        goals=[rec('goal_emergency',target_cents=1500000,purpose='emergency cash in Chase savings'),rec('goal_annual',target_cents=500000,purpose='travel and annual expenses in Capital One savings'),rec('goal_future_home',target_cents=15000000,purpose='future home upgrade; deliberately keeps excess payroll cash in checking',target_date='2028-06-01')]),
        property=rec('property_cedar_condo',property_id='property_cedar_condo',location='Fictional Cedar District, Northern California (no street address)',
                     acquisition_date='2022-06-01',purchase_price_cents=36000000,ownership_fraction='1.00',loan_ownership_fraction='1.00',
                     original_mortgage_cents=28800000,loan_account_id='mortgage',source_type='synthetic_manual_estimate',liquid=False),
        opening_provenance='Opening balances are synthetic boundary conditions on 2023-10-01. Pre-coverage acquisition and amortization not reproduced.',
        provider_assumptions={'robinhood':'Long-only, zero trade fee, FIFO basis, synthetic prices; no tax forms.',
           'kalshi':'USD cash; binary contracts; 20 cent fee on each buy; settlement no fee; reserved order cash is a subset of cash.',
           'polymarket':'SYNTHETIC_USDC collateral, exact quantity; fixed synthetic 1.00 USD per unit. Zero fees; binary share ledger; no wallets, chain, or actual protocol mechanics.'})


def canonical():
    legacy=json.loads((ROOT/'fixtures/seed-v1.json').read_text())
    data=copy.deepcopy(legacy)
    data['transactions']=[t for t in data['transactions'] if t['posted_at'].startswith('2026-09')]
    data.update(synthetic=True,scenario_id='canonical_demo',seed=SEED,currency='USD',timezone=str(TZ))
    for section in ('accounts','transactions','receipts','contacts'):
        for row in data[section]: row.update(synthetic=True,scenario_id='canonical_demo',currency='USD')
    for c in data['contacts']: c.update(phone='SYNTHETIC-NOT-A-CONTACT',venmo_handle=None,verified=False)
    for r in data['receipts']:
        for item in r['items']: item['synthetic']=True
    data['user']['synthetic']=True
    data['user']['display_name']='Ashwin (synthetic dinner label)'
    data['catalog']=[]
    data.pop('_catalog_note',None)
    return data


def recommendations(scenario,transactions):
    def ids(merchant,cat=None):
        if scenario=='full_financial_world': return [t['transaction_id'] for t in transactions if t['merchant_id']==('restaurant' if merchant=='dining' else 'rideshare' if merchant=='transit' else merchant) and t['activity_kind']=='consumption'][:2] if merchant in ('dining','other') else [t['transaction_id'] for t in transactions if t['merchant_id']==('rideshare' if merchant=='transit' else merchant) and t['activity_kind']=='consumption']
        pattern={'pantry':"Trader Joe",'detergent':'Tide','beans':'Blue Bottle','phone':'Verizon','dining':'Nopa','transit':'Uber','other':'Target'}[merchant]
        return [t['transaction_id'] for t in transactions if pattern in t['merchant']]
    specs=[('pantry','Groceries','Pantry staples','Comparable store pantry staples',4,3000,2100,'four 1 kg baskets',3600),
           ('detergent','Other','Preferred detergent','Comparable concentrated detergent',2,2400,1200,'two 32 load bottles',2400),
           ('beans','Other','Preferred coffee beans','Accepted alternate coffee beans',2,2000,1000,'two 340 g bags',2000),
           ('phone','Bills and subscriptions','Fictional coverage phone plan','Comparable coverage plan',1,8500,6500,'one monthly line',2000),
           ('dining','Dining','Two restaurant visits','Lower cost ordering at same visits',2,6500,5500,'two comparable meals',2000),
           ('transit','Transport','Two rideshare trips','Transit for two discretionary trips',2,2800,2300,'two comparable trips',1000),
           ('other','Other','Discretionary shopping','Reduce two discretionary baskets',2,3500,2500,'two comparable baskets',2000)]
    rows=[]
    for group,cat,current,alternative,q,unit,proposed,size,saving in specs:
        evidence=ids(group)
        if scenario=='full_financial_world' and group in ('dining','other'):
            q=1
            unit=-sum(t['signed_amount_cents'] for t in transactions if t['transaction_id'] in evidence)
            proposed=unit-saving
            size='one monthly bundle containing two meals' if group=='dining' else 'one monthly bundle containing two shopping baskets'
        # Compact purchases are bundled; only modeled relevant basket portions are compared.
        if scenario=='canonical_demo' and group=='detergent': q,unit,proposed=1,2765,365
        if scenario=='canonical_demo' and group=='dining': q,unit,proposed=1,9650,7650
        if scenario=='canonical_demo' and group=='transit': q,unit,proposed=1,4320,3320
        if scenario=='canonical_demo' and group=='other': q,unit,proposed=1,6890,4890
        rid=f'{scenario}_swap_{group}'
        rows.append(rec(rid,scenario,recommendation_id=rid,current_product=current,alternative_product=alternative,unit_size=size,
                        monthly_quantity=q,current_unit_cost_cents=unit,proposed_unit_cost_cents=proposed,
                        current_monthly_cost_cents=q*unit,proposed_monthly_cost_cents=q*proposed,projected_savings_cents=saving,
                        category=cat,evidence_transaction_ids=evidence,purchase_evidence_id=rid+'_purchase',constraints=['Keep preferred oat milk','Preserve necessary phone coverage','Instant coffee rejected'],
                        eligibility='synthetic_person_eligible_assumption',price_provenance='synthetic_comparison_catalog_2026-09-30',status='projected',
                        portion_of_bundled_purchase=scenario=='canonical_demo'))
    return envelope(scenario,recommendations=rows,purchase_evidence=[rec(r['purchase_evidence_id'],scenario,transaction_ids=r['evidence_transaction_ids'],product=r['current_product'],unit_size=r['unit_size'],quantity=r['monthly_quantity'],unit_cost_cents=r['current_unit_cost_cents'],extended_cost_cents=r['current_monthly_cost_cents'],source_type='synthetic_itemization_of_referenced_purchases') for r in rows],total_projected_savings_cents=sum(r['projected_savings_cents'] for r in rows),
        decision_history=[rec(f'{scenario}_decision_1',scenario,group='coffee',candidate='instant_coffee',potential_savings_cents=3000,
                               decision='rejected',reason='preference for brewed beans',status='user_reported',occurred_at=stamp('2026-09-22')),
                          rec(f'{scenario}_decision_2',scenario,group='coffee',candidate='alternate_coffee_beans',potential_savings_cents=2000,
                               decision='accepted_for_projection',reason='different bean brand acceptable',status='user_reported',occurred_at=stamp('2026-09-23'))],
        keewano_result=rec(f'{scenario}_keewano_fixture',scenario,mode='fixture',live_integration_verified=False,
                          normalized_query={'group':'coffee','unit_size':'340 g','quantity':2,'exclude':['instant_coffee'],'preserve':['oat_milk']},
                          results=[{'synthetic':True,'candidate_id':'instant_coffee','eligible':False,'excluded_reason':'decision_history_rejection','savings_cents':3000},
                                   {'synthetic':True,'candidate_id':'alternate_coffee_beans','eligible':True,'savings_cents':2000}]),
        adoption=rec(f'{scenario}_plan_preview',scenario,status='projected',observed_ledger_mutation=False,extra_savings_cents=15000))


def dinner():
    c=canonical()
    receipt=copy.deepcopy(c['receipts'][0]); receipt.update(scenario_id='dinner_2026_10_11',merchant='Juniper Table - SYNTHETIC DINNER',status='reviewed',source_id='fixture:receipt_dinner',linked_transaction_id='oct_dinner_purchase')
    contacts=copy.deepcopy(c['contacts'][:3])
    for contact in contacts: contact['scenario_id']='dinner_2026_10_11'
    states=[]
    for n,status in enumerate(['extraction_draft','reviewed','split_preview','approved','handoff_opened','request_sent','delivery_unknown','payment_reported','disputed','verified_settlement']):
        states.append(rec('dinner_state_'+status,'dinner_2026_10_11',status=status,simulated=True,
                          outstanding_cents=0 if status=='verified_settlement' else 8060,
                          reported_unverified_cents=3640 if status=='payment_reported' else 0,
                          next_reminder_active=status in ('request_sent','delivery_unknown'),
                          observed_bank_settlement=status=='verified_settlement',settlement_evidence_id='synthetic_settlement_event' if status=='verified_settlement' else None,requires_evidence_for_verified_settlement=True))
    return envelope('dinner_2026_10_11',receipt=receipt,contacts=contacts,default_state='reviewed',state_snapshots_are_alternatives=True,
                    settlement_evidence=rec('synthetic_settlement_event','dinner_2026_10_11',status='projected',simulated=True,amount_cents=8060,apply_to_observed_ledger=False),
                    transcript='I paid for dinner with Tanish and Aryan. Split the appetizer evenly and divide tax and tip proportionally.',
                    aliases=[rec('alias_'+name,'dinner_2026_10_11',label=name,contact_id='c_'+name.lower(),verified_contact=False) for name in ('Ashwin','Tanish','Aryan')],
                    split_example=c['split_example'],states=states,
                    reminder=rec('dinner_reminder','dinner_2026_10_11',due_at='2026-10-12T21:00:00-07:00',status='projected',
                                 cancel_on=['payment_reported','dispute_opened','verified_settlement'],scope='per_participant',
                                 participant_contact_ids=['c_tanish','c_aryan'],no_dispatch_implemented=True),
                    transitions=[{'synthetic':True,'event':e,'from':f,'to':t,'expected':x} for e,f,t,x in [
                        ('open_venmo','approved','handoff_opened','no_request_sent'),('dispatch_ack','handoff_opened','request_sent','not_settled'),
                        ('manual_payment_report','request_sent','payment_reported','cancel_participant_reminder_no_verified_settlement'),
                        ('dispute_opened','request_sent','disputed','cancel_participant_reminder'),('duplicate_approval','approved','approved','no_second_effect')]])


def core_adapter(world,period):
    summary=next(s for s in world.summaries if s['period']==period)
    statements={s['account_id']:s for s in world.statements if s['period']==period}
    p=profile()['person']
    return envelope('full_financial_world',as_of=stamp(end(period)),
        adapter_scope='Dataset wire compatibility only; NOT a full-world MoneyEngine input. Use supplemental summary for expanded finances.',
        user=dict(user_id='person_cedar',synthetic=True,display_name=p['fictional_name'],timezone=str(TZ),currency='USD',brand_locks=['oat_milk'],dietary_rules=[],savings_goal_cents=15000,preferences_version=2),
        accounts=[dict(a,balance_cents=summary['account_balances_cents'][a['account_id']],opening_balance_cents=statements[a['account_id']]['opening_balance_cents'],as_of=stamp(end(period))) for a in world.accounts if a['account_id'] in statements],
        transactions=[t for t in world.ledger if t['posted_at'][:7]==period],receipts=[],contacts=[])


def current(world):
    s=copy.deepcopy(world.summaries[-1]); balances=dict(s['account_balances_cents'])
    rows=[]
    def add(tid,day,aid,amount,kind,merchant,pending=False,pair=None):
        row=rec(tid,transaction_id=tid,account_id=aid,posted_at=stamp(day,20 if tid=='oct_dinner_purchase' else 12),signed_amount_cents=amount,
                activity_kind=kind,merchant=MERCHANTS[merchant][0] if merchant else 'Synthetic '+kind,merchant_id=merchant,
                category=MERCHANTS[merchant][1] if merchant else 'Transfer',pending=pending,status='observed',transfer_pair_id=pair,refund_of=None)
        rows.append(row)
        if not pending: balances[aid]+=amount if world.by_account[aid]['asset_or_liability']=='asset' else -amount
    # Follow the biography's schedule: next payroll is October 15, beyond the demo clock.
    # Include October's already-due housing and loan obligations before the dinner.
    amortization=[]
    for aid,rate,payment in [('mortgage','0.05',160000),('student','0.045',32000)]:
        opening=balances[aid]
        interest=rounded(Decimal(opening)*Decimal(rate)/12)
        principal=payment-interest
        add('oct_'+aid+'_interest','2026-10-02','chase_checking',-interest,'interest','mortgage_interest' if aid=='mortgage' else 'student_interest')
        pair='oct_'+aid+'_principal'
        add(pair+'_out','2026-10-02','chase_checking',-principal,'debt_principal',None,pair=pair)
        add(pair+'_in','2026-10-02',aid,principal,'debt_principal',None,pair=pair)
        rows[-2]['counterpart_transaction_id']=rows[-1]['transaction_id']; rows[-1]['counterpart_transaction_id']=rows[-2]['transaction_id']
        amortization.append(rec('amort_'+aid+'_2026-10',account_id=aid,period='2026-10',opening_principal_cents=opening,
              interest_cents=interest,principal_cents=principal,payment_cents=payment,closing_principal_cents=balances[aid],annual_rate=rate,escrow_cents=0))
    for mid,amount,day,aid in [('hoa',27000,1,'chase_checking'),('tax',22000,4,'chase_checking'),('insurance',6500,4,'chase_checking'),
                              ('phone',8500,4,'capital_one_checking'),('utilities',17000,7,'capital_one_checking'),('internet',6500,9,'capital_one_checking')]:
        add('oct_'+mid,f'2026-10-{day:02}',aid,-amount,'consumption',mid)
    add('oct_grocery','2026-10-03','capital_one_card',-6200,'consumption','grocer')
    for card in ('chase_card','capital_one_card'):
        due=s['account_balances_cents'][card]; pair='oct_pay_'+card
        add(pair+'_out','2026-10-05','chase_checking',-due,'card_payment',None,pair=pair)
        add(pair+'_in','2026-10-05',card,due,'card_payment',None,pair=pair)
        rows[-2]['counterpart_transaction_id']=rows[-1]['transaction_id']; rows[-1]['counterpart_transaction_id']=rows[-2]['transaction_id']
    add('oct_dinner_purchase','2026-10-11','chase_checking',-10920,'consumption','dinner')
    add('oct_pending_beans','2026-10-11','chase_card',-4000,'consumption','beans',pending=True)
    bank_ids=[a['account_id'] for a in world.accounts if a['kind'] in ('checking','savings')]
    bank_cash=sum(balances[a] for a in bank_ids)
    assets=s['assets_cents']+bank_cash-s['bank_cash_cents']
    liability=sum(balances[a['account_id']] for a in world.accounts if a['asset_or_liability']=='liability')
    upcoming=[rec('due_'+aid,due_on=due,account_id=aid,amount_cents=amount,status='projected',obligation_type=kind) for aid,amount,kind,due in [
        ('chase_savings',30000,'savings_transfer','2026-10-16'),('capital_one_savings',20000,'savings_transfer','2026-10-16'),
        ('robinhood',65000,'investment_funding','2026-10-17'),('kalshi',5000,'investment_funding','2026-10-18'),('polymarket',3000,'investment_funding','2026-10-18'),
        ('chase_card',1199,'music_subscription','2026-10-12'),('mortgage',160000,'mortgage_cash_payment','2026-11-02'),('student',32000,'student_cash_payment','2026-11-02')]]
    upcoming+= [rec('annual_travel',due_on='2027-08-18',account_id='capital_one_savings',amount_cents=96000,status='projected',obligation_type='annual_trip_estimate_based_on_prior_august_spending',included_in_available_to_spend=False)]
    checking=sum(balances[a['account_id']] for a in world.accounts if a['kind']=='checking')
    return envelope('full_financial_world',as_of=CLOCK,last_completed_month='2026-09',completed_month_summary_id=s['record_id'],
                    snapshot=rec('snapshot_demo_clock',observation_as_of=CLOCK,valuation_as_of=stamp('2026-09-30'),
                        account_balances_cents=balances,bank_cash_cents=bank_cash,assets_cents=assets,liabilities_cents=liability,net_worth_cents=assets-liability,
                        illiquid_property_cents=s['illiquid_property_cents'],property_equity_cents=s['illiquid_property_cents']-balances['mortgage'],investment_equity_cents=s['liquid_investment_equity_cents']+s['prediction_equity_cents'],
                        available_to_spend_cents=max(0,checking-124199),
                        available_policy='Posted checking cash minus 124199 cents remaining October scheduled contributions and subscription reserve; excludes savings, securities, prediction positions and property.',
                        pending_cents=4000,receivables_in_net_worth=False,reimbursement_status='unrequested_reviewed_split',
                        stale_valuation_ids=['mark_polymarket_2026-09_sports'],
                        source_ids=[s['source_id']]+[t['source_id'] for t in rows],valuation_ids=s['valuation_ids']),
                    october_activity=rows,october_amortization=amortization,upcoming_obligations=upcoming)


def annual(world):
    rows=[]
    for year in ('2023','2024','2025','2026'):
        months=[s for s in world.summaries if s['period'].startswith(year)]
        cats=defaultdict(int)
        for s in months:
            for cat,value in s['category_totals_cents'].items(): cats[cat]+=value
        rows.append(rec('annual_'+year,year=year,covered_months=[s['period'] for s in months],partial_calendar_year=len(months)!=12,
                        income_cents=sum(s['income_cents'] for s in months),consumption_spending_cents=sum(s['consumption_spending_cents'] for s in months),
                        category_totals_cents=dict(cats),summary_ids=[s['record_id'] for s in months]))
    return envelope('full_financial_world',annual_summaries=rows)


def recurring():
    return envelope('full_financial_world',obligations=[rec('recurring_'+mid,merchant_id=mid,category=MERCHANTS[mid][1],cadence='monthly',
        current_amount_cents=amt,status='projected',source_matching_rule='merchant_id',active=mid!='video',
        ended_on='2025-03-01' if mid=='video' else None) for mid,amt in [('hoa',27000),('tax',22000),('insurance',6500),('phone',8500),('internet',6500),('utilities',17000),('music',1199),('video',1549)]])


def edges():
    legacy=json.loads((ROOT/'fixtures/edge-v1.json').read_text())
    legacy.update(synthetic=True,scenario_id='edge_cases')
    legacy['user']['synthetic']=True
    for section in ('accounts','transactions'):
        for row in legacy[section]: row.update(synthetic=True,scenario_id='edge_cases')
    original=next(t for t in legacy['transactions'] if t['transaction_id']=='e2')
    pending=dict(original,transaction_id='e2_pending_ingestion',pending=True)
    legacy['transactions'].insert(0,pending)
    dup=copy.deepcopy(next(t for t in legacy['transactions'] if t['transaction_id']=='e9'))
    dup['transaction_id']='e9_duplicate_ingestion'
    legacy['transactions'].append(dup)
    cases=[
      ('duplicate_ingestion',{'source_id':'fixture:e9','ingestion_count':2},'one_source_effect_9000_cents'),
      ('pending_becomes_posted',{'source_id':'fixture:e2','updates':['pending','posted']},'posted_supersedes_pending_no_double_count'),
      ('internal_transfer',{'legs_cents':[-10000,10000],'pair_id':'p_sav'},'zero_income_expense_wealth_change'),
      ('card_payment',{'legs_cents':[-27000,27000],'pair_id':'p_card'},'cash_and_liability_reduce_no_consumption'),
      ('refund',{'original_id':'e2','refund_id':'e3','purchase_cents':12000,'refund_cents':3000},'category_net_9000_cents'),
      ('unknown_merchant_category',{'merchant_id':None,'category':None,'signed_amount_cents':-100},'display_uncategorized_require_review'),
      ('stale_valuation',{'mark_id':'mark_polymarket_2026-09_sports','valuation_as_of':'2026-08-31','observed_on':'2026-09-30'},'show_stale_do_not_offer_position_as_cash'),
      ('missing_statement',{'remove_record_id':'statement_chase_checking_2023-10'},'STATEMENT_COVERAGE_validation_failure'),
      ('unresolved_market',{'market_id':'kalshi_2026-09_sports','outcome':'unresolved'},'keep_position_mark_no_settlement'),
      ('property_fraction',{'gross_value_cents':40000000,'gross_loan_cents':30000000,'ownership_fraction':'0.50','loan_ownership_fraction':'0.50'},'attributable_asset_20000000_loan_15000000_equity_5000000'),
      ('principal_interest',{'payment_cents':160000,'principal_cents':42708,'interest_cents':117292},'principal_reduces_debt_interest_consumption'),
      ('receipt_mismatch',{'subtotal_cents':8400,'tax_cents':840,'tip_cents':1680,'total_cents':10922},'RECEIPT_MISMATCH'),
      ('ambiguous_participant',{'label':'Tan','candidates':['c_tanish','synthetic_tanya']},'AMBIGUOUS_CONTACT_no_dispatch'),
      ('rounding_remainder',{'total_cents':1,'participant_ids':['a','b','c'],'weights':[1,1,1]},'shares_1_0_0_sorted_tie_break'),
      ('duplicate_approval',{'action_id':'synthetic_split_approval','deliveries':2},'one_effect_contract_expectation'),
      ('unknown_delivery',{'request_status':'sent','delivery_status':'unknown'},'not_settled_no_blind_redispatch'),
      ('reminder_cancelled_payment',{'contact_id':'c_tanish','event':'payment_reported','verification':'user_reported'},'cancel_tanish_reminder_not_verified_settlement'),
      ('reminder_cancelled_dispute',{'contact_id':'c_aryan','event':'dispute_opened'},'cancel_aryan_reminder_keep_dispute_visible'),
    ]
    return envelope('edge_cases',ingestion_dataset=legacy,cases=[rec('edge_'+name,'edge_cases',case_id=name,input=data,expected_outcome=expected,
         execution_scope='fixture_contract_only; app/relay delivery not implemented') for name,data,expected in cases])


def export(stage='full',out=OUT,seed=SEED):
    world=World(seed).build()
    base=out/'full_financial_world'
    write(out/'profile.json',profile())
    write(base/'snapshot.json',current(world))
    write(base/'september.json',envelope('full_financial_world',period='2026-09',accounts=world.accounts,
        transactions=[t for t in world.ledger if t['posted_at'][:7]=='2026-09'],summary=world.summaries[-1],
        statements=[s for s in world.statements if s['period']=='2026-09']))
    write(base/'core-september.json',core_adapter(world,'2026-09'))
    if stage!='snapshot':
        can=canonical(); write(out/'canonical_demo/dataset.json',can)
        write(out/'canonical_demo/swaps.json',recommendations('canonical_demo',can['transactions']))
        d=dinner(); write(out/'dinner_2026_10_11/scenario.json',d)
        receipt_text='SYNTHETIC DEMO RECEIPT\nJuniper Table - fictional dinner\n2026-10-11\nShort rib 24.00\nDuck breast 30.00\nMushroom risotto 18.00\nShared burrata 12.00\nSUBTOTAL 84.00\nTAX 8.40\nTIP 16.80\nTOTAL 109.20 USD\nNot a real purchase or verified contact.\n'
        (out/'dinner_2026_10_11/ocr.txt').write_text(receipt_text)
        write(out/'dinner_2026_10_11/reviewed-extraction.json',envelope('dinner_2026_10_11',receipt=d['receipt'],extraction_status='reviewed',parser_tested=False,ocr_source='ocr.txt'))
        write(base/'swaps.json',recommendations('full_financial_world',[t for t in world.ledger if t['posted_at'][:7]=='2026-09']))
        write(base/'recurring.json',recurring())
    if stage=='full':
        write(out/'edge-cases.json',edges())
        write(base/'accounts.json',envelope('full_financial_world',accounts=world.accounts,
              merchants=[rec('merchant_'+mid,merchant_id=mid,name=name,category=cat) for mid,(name,cat) in MERCHANTS.items()],
              instruments=[rec('instrument_'+s,instrument_id=s,name=name,prices_synthetic=True) for s,name,_ in INSTRUMENTS]))
        write(base/'ledger.json',envelope('full_financial_world',transactions=world.ledger))
        write(base/'statements.json',envelope('full_financial_world',statements=world.statements))
        write(base/'summaries.json',envelope('full_financial_world',monthly_summaries=world.summaries))
        write(base/'annual.json',annual(world))
        write(base/'events.json',envelope('full_financial_world',events=[rec('narrative_'+t['transaction_id'],event_label=t['event_label'],occurred_at=t['posted_at'],signed_amount_cents=t['signed_amount_cents'],evidence_ids=[t['transaction_id']],source_ids=[t['source_id']]) for t in world.ledger if t.get('event_label')],income_changes=[rec('income_change_'+period,period=period,monthly_payroll_cents=sum(t['signed_amount_cents'] for t in world.ledger if t['merchant_id']=='payroll' and t['posted_at'][:7]==period),evidence_ids=[t['transaction_id'] for t in world.ledger if t['merchant_id']=='payroll' and t['posted_at'][:7]==period]) for period in ('2023-10','2024-07','2025-07')],investment_events=[rec('narrative_market_drawdown',event_label='synthetic_April_2025_drawdown',period='2025-04',return_cents=next(s['robinhood_return_cents'] for s in world.summaries if s['period']=='2025-04'),evidence_ids=[m['record_id'] for m in world.position_marks if m['period'] in ('2025-03','2025-04')])],prediction_activity=[rec('narrative_prediction_'+period,event_label='higher_prediction_activity',period=period,event_count=sum(e['occurred_at'][:7]==period for e in world.market_events),evidence_ids=[e['event_id'] for e in world.market_events if e['occurred_at'][:7]==period]) for period in ('2026-06','2026-07','2026-08')]))
        write(base/'portfolio.json',envelope('full_financial_world',trades=world.trades,position_marks=world.position_marks,monthly_accounts=world.portfolio_months))
        write(base/'prediction-markets.json',envelope('full_financial_world',markets=world.markets,events=world.market_events,position_marks=world.market_marks,monthly_accounts=world.market_months))
        write(base/'property-debt.json',envelope('full_financial_world',property=profile()['property'],valuations=world.property_values,amortization=world.debts))
    make_manifest(out,stage)
    return world


def make_manifest(out,stage):
    # Scenario-local manifests explicitly bind each consumer to one ledger.
    for scenario in ('full_financial_world','canonical_demo','dinner_2026_10_11'):
        folder=out/scenario
        if not folder.exists(): continue
        members=[]
        for path in sorted(folder.rglob('*')):
            if not path.is_file() or path.name=='manifest.json': continue
            members.append(dict(path=path.relative_to(folder).as_posix(),synthetic=True,
                                sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        entry={'full_financial_world':'snapshot.json','canonical_demo':'dataset.json','dinner_2026_10_11':'scenario.json'}[scenario]
        write(folder/'manifest.json',envelope(scenario,entrypoint=entry,files=members,
              do_not_merge_ledgers=True,completed_period='2026-09' if scenario=='canonical_demo' else None,
              supplementary_profile='../profile.json' if scenario=='full_financial_world' else None))
    files=[]
    for path in sorted(out.rglob('*')):
        if not path.is_file() or path==out/'manifest.json': continue
        relative=path.relative_to(out).as_posix()
        scenario=relative.split('/')[0] if '/' in relative else 'shared'
        content=path.read_bytes()
        schema='world.schema.json' if path.suffix=='.json' else 'human_readable_synthetic_asset'
        consumer='Claude UI / Aryan adapters / Tanish fixture tools'
        if 'canonical_demo' in relative: consumer='FWMCore canonical regression / original demo'
        if 'core-' in relative: consumer='Dataset decoder only; supplemental MoneyView required'
        files.append(dict(path=relative,scenario_id=scenario,schema=schema,consumer=consumer,sha256=hashlib.sha256(content).hexdigest(),bytes=len(content),synthetic=True))
    write(out/'manifest.json',envelope('shared',stage=stage,completed_start='2023-10-01',completed_end='2026-09-30',
          default_scenario='full_financial_world',scenario_selection_required=True,
          scenarios=[dict(scenario_id=s,synthetic=True,entrypoint=p) for s,p in [('full_financial_world','full_financial_world/snapshot.json'),('canonical_demo','canonical_demo/dataset.json'),('dinner_2026_10_11','dinner_2026_10_11/scenario.json')]],files=files))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage',choices=['snapshot','demo','full'],default='full')
    parser.add_argument('--output',type=Path,default=OUT)
    parser.add_argument('--seed',type=int,default=SEED)
    args=parser.parse_args()
    if args.seed!=SEED: parser.error(f'Dataset version fixes seed {SEED}; choose a new version before changing it.')
    w=export(args.stage,args.output,args.seed)
    print(json.dumps(dict(stage=args.stage,transactions=len(w.ledger),completed_months=36,
                         september_net_worth_cents=w.summaries[-1]['net_worth_cents'],snapshot_net_worth_cents=current(w)['snapshot']['net_worth_cents'])))


if __name__=='__main__': main()
