#!/usr/bin/env python3
"""Independent fixture audit + existing Swift engine goldens, offline in one command."""
import argparse
import copy
import hashlib
import json
import re
import subprocess
import tempfile
from collections import defaultdict
from datetime import datetime, date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
DATA=ROOT/'fixtures/world-v1'
MONTHS=[f'{2023+(9+i)//12}-{(9+i)%12+1:02}' for i in range(36)]
checks=defaultdict(int)


def check(condition,code,context=''):
    if not condition: raise ValueError(f'{code}: {context}')
    checks[code]+=1


def exact(value):
    return int(Decimal(value).quantize(Decimal('1'),rounding=ROUND_HALF_UP))


def money(value):
    return exact(Decimal(value)*100)


def read(path):
    return json.loads(path.read_text())


def schema_check(value,schema,root,path='$'):
    if isinstance(schema,bool):
        check(schema,'SCHEMA_BOOLEAN',path)
        return
    if '$ref' in schema:
        target=root
        for part in schema['$ref'].removeprefix('#/').split('/'): target=target[part]
        schema_check(value,target,root,path)
    for s in schema.get('allOf',[]): schema_check(value,s,root,path)
    if 'anyOf' in schema:
        success=False
        for s in schema['anyOf']:
            try: schema_check(value,s,root,path); success=True; break
            except ValueError: continue
        check(success,'SCHEMA_ANYOF',path)
    if 'type' in schema:
        allowed={'object':isinstance(value,dict),'array':isinstance(value,list),'string':isinstance(value,str),
                 'integer':type(value)==int,'boolean':type(value)==bool,'null':value is None}
        check(allowed[schema['type']],'SCHEMA_TYPE',path)
    if 'const' in schema: check(type(value)==type(schema['const']) and value==schema['const'],'SCHEMA_CONST',path)
    if 'enum' in schema: check(value in schema['enum'],'SCHEMA_ENUM',path)
    if 'pattern' in schema: check(isinstance(value,str) and re.search(schema['pattern'],value),'SCHEMA_PATTERN',path)
    if isinstance(value,dict):
        for key in schema.get('required',[]): check(key in value,'SCHEMA_REQUIRED',path+'.'+key)
        for key,s in schema.get('properties',{}).items():
            if key in value: schema_check(value[key],s,root,path+'.'+key)
    if isinstance(value,list) and 'items' in schema:
        for i,item in enumerate(value): schema_check(item,schema['items'],root,f'{path}[{i}]')


def walk_types(value,path=''):
    if isinstance(value,dict):
        for k,v in value.items():
            if k.endswith('_cents') and not isinstance(v,(dict,list)) and v is not None:
                check(type(v)==int,'EXACT_CENTS',path+'.'+k)
            if k in ('price_usd','quantity','ownership_fraction','annual_rate','collateral_quantity','collateral_usd_per_unit') and v is not None:
                # Legacy receipt item quantities are integral, which are exact too.
                check(isinstance(v,str) or type(v)==int,'EXACT_DECIMAL',path+'.'+k)
                check(Decimal(v).is_finite(),'FINITE_DECIMAL',path+'.'+k)
            walk_types(v,path+'.'+k)
    elif isinstance(value,list):
        for i,v in enumerate(value): walk_types(v,f'{path}[{i}]')


def unique(rows,key,label):
    ids=[r[key] for r in rows]
    check(len(ids)==len(set(ids)),'UNIQUE_IDS',label)
    return {r[key]:r for r in rows}


def ledger_check(transactions,accounts):
    by=unique(transactions,'transaction_id','ledger')
    sources=[t['source_id'] for t in transactions]
    check(len(sources)==len(set(sources)),'UNIQUE_SOURCES','ledger')
    pairs=defaultdict(list)
    for t in transactions:
        aid=t['account_id']; check(aid in accounts,'ACCOUNT_REFERENCE',t['transaction_id'])
        check(t['posted_at'][:10]>=accounts[aid]['opened_on'],'OPENED_BEFORE_ACTIVITY',t['transaction_id'])
        datetime.fromisoformat(t['posted_at'])
        check(t['synthetic'] and t['scenario_id']=='full_financial_world','SCENARIO_ISOLATION',t['transaction_id'])
        if t['transfer_pair_id']: pairs[t['transfer_pair_id']].append(t)
        if t['refund_of']:
            original=by.get(t['refund_of'])
            check(original is not None,'REFUND_REFERENCE',t['transaction_id'])
            check(original['account_id']==aid and original['merchant_id']==t['merchant_id'] and original['signed_amount_cents']<0,'REFUND_IDENTITY',t['transaction_id'])
            check(0<t['signed_amount_cents']<=-original['signed_amount_cents'],'REFUND_AMOUNT',t['transaction_id'])
    for pair,rows in pairs.items():
        check(len(rows)==2,'TRANSFER_LEGS',pair)
        check(sum(t['signed_amount_cents'] for t in rows)==0,'TRANSFER_CONSERVATION',pair)
        check(rows[0]['account_id']!=rows[1]['account_id'],'TRANSFER_ACCOUNTS',pair)
        check(rows[0]['posted_at']==rows[1]['posted_at'],'TRANSFER_DATE',pair)
        check(all(t['counterpart_transaction_id'] in {r['transaction_id'] for r in rows} and t['counterpart_transaction_id']!=t['transaction_id'] for t in rows),'TRANSFER_REFERENCES',pair)
        check(rows[0]['activity_kind']==rows[1]['activity_kind'],'TRANSFER_KIND',pair)
        incoming=next(t for t in rows if t['signed_amount_cents']>0)
        if incoming['activity_kind']=='card_payment': check(accounts[incoming['account_id']]['kind']=='credit_card','CARD_PAYMENT_TARGET',pair)
        if incoming['activity_kind']=='debt_principal': check(accounts[incoming['account_id']]['kind'] in ('student_loan','mortgage'),'PRINCIPAL_TARGET',pair)
    return by


def audit(root=DATA):
    schema=read(root/'world.schema.json')
    manifest=read(root/'manifest.json')
    check(manifest['stage']=='full','DELIVERY_STAGE')
    listed={f['path'] for f in manifest['files']}
    actual={p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() and p!=root/'manifest.json'}
    check(listed==actual,'MANIFEST_COMPLETENESS')
    for entry in manifest['files']:
        path=root/entry['path']
        check(hashlib.sha256(path.read_bytes()).hexdigest()==entry['sha256'],'MANIFEST_HASH',entry['path'])
        if path.suffix=='.json' and path.name!='world.schema.json':
            value=read(path); schema_check(value,schema,schema,entry['path']); walk_types(value,entry['path'])
    for scenario in ('full_financial_world','canonical_demo','dinner_2026_10_11'):
        local=read(root/scenario/'manifest.json')
        check(local['scenario_id']==scenario and local['do_not_merge_ledgers'] is True,'LOCAL_MANIFEST_ISOLATION',scenario)
        for member in local['files']:
            check((root/scenario/member['path']).is_file(),'LOCAL_MANIFEST_REFERENCE',scenario+member['path'])
            check(hashlib.sha256((root/scenario/member['path']).read_bytes()).hexdigest()==member['sha256'],'LOCAL_MANIFEST_HASH',scenario+member['path'])
    full=root/'full_financial_world'
    accounts=unique(read(full/'accounts.json')['accounts'],'account_id','accounts')
    merchants=unique(read(full/'accounts.json')['merchants'],'merchant_id','merchants')
    tx=read(full/'ledger.json')['transactions']
    by=ledger_check(tx,accounts)
    check({t['posted_at'][:7] for t in tx}==set(MONTHS),'EXACT_MONTH_COVERAGE')
    for t in tx:
        check(t['merchant_id'] is None or t['merchant_id'] in merchants,'MERCHANT_REFERENCE',t['transaction_id'])
    statements=read(full/'statements.json')['statements']
    unique(statements,'record_id','statements')
    stm={(s['account_id'],s['period']):s for s in statements}
    check(len(stm)==len(statements),'UNIQUE_STATEMENT_PERIODS')
    summaries=read(full/'summaries.json')['monthly_summaries']
    check([s['period'] for s in summaries]==MONTHS,'SUMMARY_MONTH_COVERAGE')
    cash={aid:a['opening_balance_cents'] for aid,a in accounts.items()}
    tx_by_month=defaultdict(list)
    for t in tx: tx_by_month[t['posted_at'][:7]].append(t)
    history={}
    for period in MONTHS:
        opening=dict(cash)
        month=sorted(tx_by_month[period],key=lambda t:(t['posted_at'],t['transaction_id']))
        for t in month:
            if t['pending']: continue
            aid=t['account_id']; cash[aid]+=t['signed_amount_cents']*(1 if accounts[aid]['asset_or_liability']=='asset' else -1)
            check(cash[aid]>=0,'NONNEGATIVE_POSTED_BALANCE',t['transaction_id'])
        for aid,a in accounts.items():
            rows=[t for t in month if t['account_id']==aid and not t['pending']]
            if a['opened_on']>period+'-31':
                check((aid,period) not in stm,'NO_PREOPEN_STATEMENT',aid+period); continue
            check((aid,period) in stm,'STATEMENT_COVERAGE',aid+period)
            s=stm[aid,period]
            check(s['opening_balance_cents']==opening[aid] and s['closing_balance_cents']==cash[aid],'CHRONOLOGICAL_RECONCILIATION',s['record_id'])
            check(set(s['transaction_ids'])=={t['transaction_id'] for t in rows},'STATEMENT_LEDGER_IDS',s['record_id'])
            check(s['transaction_source_ids']==[by[tid]['source_id'] for tid in s['transaction_ids']],'STATEMENT_SOURCE_IDS',s['record_id'])
            check(s['inflows_cents']==sum(t['signed_amount_cents'] for t in rows if t['signed_amount_cents']>0),'STATEMENT_INFLOWS',s['record_id'])
            check(s['outflows_cents']==-sum(t['signed_amount_cents'] for t in rows if t['signed_amount_cents']<0),'STATEMENT_OUTFLOWS',s['record_id'])
            if a['kind']=='credit_card':
                parts={'purchases_cents':('consumption',-1),'credits_cents':('refund',1),'payments_cents':('card_payment',1),'interest_cents':('interest',-1),'fees_cents':('fee',-1)}
                for field,(kind,sign) in parts.items(): check(s[field]==sign*sum(t['signed_amount_cents'] for t in rows if t['activity_kind']==kind),'CARD_COMPONENTS',s['record_id']+field)
                closing=s['opening_balance_cents']+s['purchases_cents']+s['interest_cents']+s['fees_cents']-s['payments_cents']-s['credits_cents']
                check(closing==s['closing_balance_cents'],'CARD_EQUATION',s['record_id'])
                check(0<=closing<=s['credit_limit_cents'],'CARD_LIMIT',s['record_id'])
                check(date.fromisoformat(s['due_date'])==date.fromisoformat(s['closing_date'])+timedelta(days=25),'SYNTHETIC_DUE_DATE',s['record_id'])
        history[period]=(opening,dict(cash))
    # Investment replay is independent of generator: FIFO lots, exact cash, all historical marks.
    portfolio=read(full/'portfolio.json')
    instruments=set(i['instrument_id'] for i in read(full/'accounts.json')['instruments'])
    unique(portfolio['trades'],'trade_id','trades')
    unique(portfolio['position_marks'],'record_id','security marks')
    lots=defaultdict(list); realized=0
    for period in MONTHS:
        for trade in sorted([t for t in portfolio['trades'] if t['executed_at'][:7]==period],key=lambda t:(t['executed_at'],t['trade_id'])):
            symbol=trade['instrument_id']; q=Decimal(trade['quantity']); gross=money(q*Decimal(trade['price_usd']))
            check(symbol in instruments and q>0,'INSTRUMENT_REFERENCE',trade['trade_id'])
            check(gross==trade['gross_cents'],'TRADE_MONEY',trade['trade_id'])
            cash_row=by[trade['cash_transaction_id']]
            check(cash_row['domain_record_id']==trade['trade_id'] and cash_row['account_id']=='robinhood','TRADE_CASH_REFERENCE',trade['trade_id'])
            basis=0
            if trade['side']=='buy':
                check(cash_row['signed_amount_cents']==-gross-trade['fee_cents'],'TRADE_CASH',trade['trade_id'])
                lots[symbol].append([q,gross+trade['fee_cents']])
                check(trade['cost_basis_cents']==gross+trade['fee_cents'],'BUY_BASIS',trade['trade_id'])
            else:
                remaining=q
                for lot in lots[symbol]:
                    take=min(lot[0],remaining)
                    part=lot[1] if take==lot[0] else exact(Decimal(lot[1])*take/lot[0])
                    lot[0]-=take;lot[1]-=part;remaining-=take;basis+=part
                    if not remaining: break
                check(remaining==0,'NO_OVERSELL',trade['trade_id'])
                check(basis==trade['cost_basis_cents'],'FIFO_BASIS',trade['trade_id'])
                check(cash_row['signed_amount_cents']==gross-trade['fee_cents'],'TRADE_CASH',trade['trade_id'])
                check(trade['realized_gain_cents']==gross-trade['fee_cents']-basis,'REALIZED_GAIN',trade['trade_id'])
                realized+=trade['realized_gain_cents']
        marks=[m for m in portfolio['position_marks'] if m['period']==period]
        check({m['instrument_id'] for m in marks}==instruments,'POSITION_COVERAGE',period)
        for mark in marks:
            symbol=mark['instrument_id']; quantity=sum(l[0] for l in lots[symbol]); basis=sum(l[1] for l in lots[symbol])
            check(Decimal(mark['quantity'])==quantity and mark['cost_basis_cents']==basis,'HOLDINGS_ACTIVITY',mark['record_id'])
            check(sum(Decimal(l['quantity']) for l in mark['lots'])==quantity and sum(l['cost_basis_cents'] for l in mark['lots'])==basis,'LOT_REPRESENTATION',mark['record_id'])
            check(mark['value_cents']==money(quantity*Decimal(mark['price_usd'])),'POSITION_VALUE',mark['record_id'])
            check(mark['unrealized_gain_cents']==mark['value_cents']-basis,'UNREALIZED_GAIN',mark['record_id'])
        monthly=next(m for m in portfolio['monthly_accounts'] if m['period']==period)
        check(monthly['cash_cents']==history[period][1]['robinhood'],'PORTFOLIO_CASH',period)
        check(monthly['holdings_cents']==sum(m['value_cents'] for m in marks),'PORTFOLIO_HOLDINGS',period)
        check(monthly['equity_cents']==monthly['cash_cents']+monthly['holdings_cents'],'PORTFOLIO_EQUITY',period)
        check(monthly['realized_gain_to_date_cents']==realized,'PORTFOLIO_REALIZED',period)
    prediction=read(full/'prediction-markets.json')
    markets=unique(prediction['markets'],'market_id','markets'); unique(prediction['events'],'event_id','market events')
    open_positions={}
    for period in MONTHS:
        for event in sorted([e for e in prediction['events'] if e['occurred_at'][:7]==period],key=lambda e:(e['occurred_at'],e['event_id'])):
            mid=event['market_id']; check(mid in markets,'MARKET_REFERENCE',event['event_id'])
            q=Decimal(event['quantity']);gross=money(q*Decimal(event['price_usd']))
            check(gross==event['gross_cents'],'MARKET_TRADE_MONEY',event['event_id'])
            row=by[event['cash_transaction_id']]
            check(row['account_id']==event['account_id'] and row['domain_record_id']==event['event_id'],'MARKET_CASH_REFERENCE',event['event_id'])
            if event['kind']=='buy':
                check(mid not in open_positions,'POSITION_ID',mid)
                open_positions[mid]=(q,gross+event['fee_cents'],event['account_id'])
                check(row['signed_amount_cents']==-gross-event['fee_cents'],'MARKET_CASH',event['event_id'])
            else:
                check(mid in open_positions,'SETTLEMENT_POSITION',event['event_id'])
                check(markets[mid]['resolved_on']==event['occurred_at'][:10] and markets[mid]['outcome']==('synthetic_yes' if event['price_usd']=='1.00' else 'synthetic_no'),'RESOLVED_MARKET_METADATA',event['event_id'])
                quantity,basis,provider=open_positions.pop(mid)
                check(quantity==q,'SETTLEMENT_QUANTITY',event['event_id'])
                check(event['cost_basis_cents']==basis and event['realized_gain_cents']==gross-event['fee_cents']-basis,'SETTLEMENT_GAIN',event['event_id'])
                check(row['signed_amount_cents']==gross-event['fee_cents'],'SETTLEMENT_CASH',event['event_id'])
        month_marks=[m for m in prediction['position_marks'] if m['market_id'].split('_')[1]==period]
        check({m['market_id'] for m in month_marks}==set(open_positions),'OPEN_POSITION_MARKS',period)
        for m in month_marks:
            q,basis,provider=open_positions[m['market_id']]
            check(Decimal(m['quantity'])==q and m['cost_basis_cents']==basis,'MARKET_POSITION_BASIS',m['record_id'])
            check(m['value_cents']==money(q*Decimal(m['price_usd'])),'MARKET_MARK_VALUE',m['record_id'])
            check(m['valuation_as_of'][:10]>=markets[m['market_id']]['opened_on'],'MARK_EXISTS_AT_QUOTE',m['record_id'])
            age=(datetime.fromisoformat(m['observation_as_of'])-datetime.fromisoformat(m['valuation_as_of'])).days
            check(m['stale']==(age>7),'STALE_MARK_FLAG',m['record_id'])
        for monthly in [m for m in prediction['monthly_accounts'] if m['period']==period]:
            aid=monthly['account_id']; pm=[m for m in month_marks if m['account_id']==aid]
            check(monthly['cash_or_collateral_cents']==history[period][1][aid],'MARKET_CASH_REPLAY',monthly['record_id'])
            check(monthly['available_cents']+monthly['reserved_cents']==monthly['cash_or_collateral_cents'],'RESERVE_SUBSET',monthly['record_id'])
            check(monthly['reserved_cents']==monthly['open_order']['reserved_cents'] and monthly['available_cents']>=0,'OPEN_ORDER_RESERVE',monthly['record_id'])
            check(money(Decimal(monthly['open_order']['quantity'])*Decimal(monthly['open_order']['limit_price_usd']))==monthly['reserved_cents'],'ORDER_PRICE',monthly['record_id'])
            check(monthly['positions_cents']==sum(m['value_cents'] for m in pm),'MARKET_POSITIONS',monthly['record_id'])
            check(monthly['equity_cents']==monthly['cash_or_collateral_cents']+monthly['positions_cents'],'MARKET_EQUITY',monthly['record_id'])
            check(monthly['realized_gain_cents']==sum(e.get('realized_gain_cents',0) for e in prediction['events'] if e['account_id']==aid and e['occurred_at'][:7]==period),'MARKET_REALIZED',monthly['record_id'])
            check(monthly['unrealized_gain_cents']==sum(m['value_cents']-m['cost_basis_cents'] for m in pm),'MARKET_UNREALIZED',monthly['record_id'])
            prior=[m for m in prediction['monthly_accounts'] if m['account_id']==aid and m['period']<period]
            previous=prior[-1]['equity_cents'] if prior else 0
            funded=sum(t['signed_amount_cents'] for t in tx_by_month[period] if t['account_id']==aid and t['activity_kind']=='investment_funding')
            withdrawn=-sum(t['signed_amount_cents'] for t in tx_by_month[period] if t['account_id']==aid and t['activity_kind']=='investment_proceeds')
            check(monthly['funding_cents']==funded and monthly['withdrawals_cents']==withdrawn,'MARKET_FUNDING',monthly['record_id'])
            check(monthly['period_return_cents']==monthly['equity_cents']-previous-funded+withdrawn,'MARKET_PERIOD_RETURN',monthly['record_id'])
            if aid=='polymarket':
                check(monthly['collateral_asset']=='SYNTHETIC_USDC' and monthly['collateral_usd_per_unit']=='1.00','COLLATERAL_POLICY',monthly['record_id'])
                check(money(Decimal(monthly['collateral_quantity'])*Decimal(monthly['collateral_usd_per_unit']))==monthly['cash_or_collateral_cents'],'COLLATERAL_QUANTITY',monthly['record_id'])
    debt=read(full/'property-debt.json')
    for loan in debt['amortization']:
        aid=loan['account_id'];period=loan['period'];opening,closing=history[period]
        check(loan['opening_principal_cents']==opening[aid] and loan['closing_principal_cents']==closing[aid],'DEBT_BALANCE',loan['record_id'])
        interest=exact(Decimal(opening[aid])*Decimal(loan['annual_rate'])/12)
        check(interest==loan['interest_cents'],'DEBT_INTEREST',loan['record_id'])
        check(loan['closing_principal_cents']==opening[aid]-loan['principal_cents'],'DEBT_AMORTIZATION',loan['record_id'])
        check(loan['payment_cents']==loan['principal_cents']+loan['interest_cents'] and loan['escrow_cents']==0,'DEBT_PAYMENT_SPLIT',loan['record_id'])
        rows=[by[i] for i in loan['transaction_ids']]
        check(sum(-t['signed_amount_cents'] for t in rows if t['account_id']=='chase_checking')==loan['payment_cents'],'DEBT_LEDGER',loan['record_id'])
    for p in debt['valuations']:
        fraction=Decimal(p['ownership_fraction'])
        check(0<fraction<=1 and fraction==Decimal(debt['property']['loan_ownership_fraction']),'OWNERSHIP_TREATMENT',p['record_id'])
        check(p['attributable_value_cents']==exact(Decimal(p['gross_value_cents'])*fraction),'PROPERTY_FRACTION',p['record_id'])
        check(p['attributable_loan_principal_cents']==history[p['period']][1]['mortgage'],'PROPERTY_LOAN',p['record_id'])
        check(p['equity_cents']==p['attributable_value_cents']-p['attributable_loan_principal_cents'],'PROPERTY_EQUITY',p['record_id'])
    # Derived summaries independently recomputed from source activity and valuations.
    for s in summaries:
        period=s['period'];rows=tx_by_month[period];opening,closing=history[period];cats=defaultdict(int);evidence=defaultdict(list)
        for t in rows:
            if t['activity_kind'] in ('consumption','interest','fee','refund') and not t['pending']:
                cats[t['category']]-=t['signed_amount_cents'];evidence[t['category']].append(t['transaction_id'])
        check(s['category_totals_cents']==dict(cats) and s['consumption_spending_cents']==sum(cats.values()),'SUMMARY_SPENDING',period)
        check(s['category_evidence_ids']==dict(evidence),'CATEGORY_EVIDENCE',period)
        check(s['income_cents']==sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='income'),'SUMMARY_INCOME',period)
        check(s['reimbursements_cents']==sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='reimbursement'),'SUMMARY_REIMBURSEMENT',period)
        fields={'debt_principal_cents':'debt_principal','card_payments_cents':'card_payment','investment_funding_cents':'investment_funding'}
        for field,kind in fields.items(): check(s[field]==-sum(t['signed_amount_cents'] for t in rows if t['activity_kind']==kind and t['signed_amount_cents']<0),'ALLOCATION_COMPONENT',period+field)
        savings=sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='internal_transfer' and t['signed_amount_cents']>0 and accounts[t['account_id']]['kind']=='savings')
        proceeds=sum(t['signed_amount_cents'] for t in rows if t['activity_kind']=='investment_proceeds' and t['signed_amount_cents']>0)
        check(s['savings_contributions_cents']==savings and s['investment_proceeds_cents']==proceeds,'SUMMARY_CONTRIBUTIONS',period)
        allocation=s['income_cents']+s['reimbursements_cents']-s['consumption_spending_cents']-s['debt_principal_cents']-savings-s['investment_funding_cents']+proceeds
        check(s['accrual_allocation_remainder_cents']==allocation,'ACCRUAL_ALLOCATION',period)
        banks=[a for a in accounts if accounts[a]['kind'] in ('checking','savings')];checking=[a for a in banks if accounts[a]['kind']=='checking']
        bankcash=sum(closing[a] for a in banks)
        check(s['bank_cash_cents']==bankcash and s['net_bank_cash_change_cents']==sum(closing[a]-opening[a] for a in banks),'BANK_CASH_CHANGE',period)
        check(s['net_checking_cash_retained_cents']==sum(closing[a]-opening[a] for a in checking),'CHECKING_RETAINED',period)
        check(s['total_bank_cash_outflow_cents']==-sum(t['signed_amount_cents'] for t in rows if t['account_id'] in banks and t['signed_amount_cents']<0),'CASH_OUTFLOW',period)
        check(s['account_balances_cents']==closing,'SUMMARY_BALANCES',period)
        rh=next(m for m in portfolio['monthly_accounts'] if m['period']==period)
        pm=[m for m in prediction['monthly_accounts'] if m['period']==period]
        prop=next(p for p in debt['valuations'] if p['period']==period)
        assets=bankcash+rh['equity_cents']+sum(m['equity_cents'] for m in pm)+prop['attributable_value_cents']
        liabilities=sum(closing[a] for a in accounts if accounts[a]['asset_or_liability']=='liability')
        check((s['assets_cents'],s['liabilities_cents'],s['net_worth_cents'])==(assets,liabilities,assets-liabilities),'CONSOLIDATED_NET_WORTH',period)
        valuation_ids={rh['record_id'],prop['record_id']}|{m['record_id'] for m in pm}
        check(set(s['valuation_ids'])==valuation_ids and set(s['evidence_ids'])=={t['transaction_id'] for t in rows},'SUMMARY_PROVENANCE',period)
        previous=portfolio['monthly_accounts'][MONTHS.index(period)-1]['equity_cents'] if period!=MONTHS[0] else accounts['robinhood']['opening_balance_cents']
        funded=sum(t['signed_amount_cents'] for t in rows if t['account_id']=='robinhood' and t['activity_kind']=='investment_funding')
        withdrawn=-sum(t['signed_amount_cents'] for t in rows if t['account_id']=='robinhood' and t['activity_kind']=='investment_proceeds')
        check(s['robinhood_return_cents']==rh['equity_cents']-previous-funded+withdrawn==rh['period_return_cents'],'PERFORMANCE_NOT_CONTRIBUTIONS',period)
        check(rh['funding_cents']==funded and rh['withdrawals_cents']==withdrawn,'PORTFOLIO_FUNDING',period)
        check(s['prediction_return_cents']==sum(m['period_return_cents'] for m in pm),'PREDICTION_PERFORMANCE',period)
    all_sources=set(by)|{r['record_id'] for r in portfolio['position_marks']}|{e['event_id'] for e in prediction['events']}
    narratives=read(full/'events.json')
    for section in ('events','income_changes','investment_events','prediction_activity'):
        for narrative in narratives[section]:
            check(all(e in all_sources for e in narrative['evidence_ids']),'NARRATIVE_EVIDENCE',narrative['record_id'])
    september=read(full/'september.json')
    check(september['summary']==summaries[-1] and september['transactions']==tx_by_month['2026-09'],'SEPTEMBER_SLICE')
    for a in read(full/'annual.json')['annual_summaries']:
        included=[s for s in summaries if s['period'] in a['covered_months']]
        check(a['income_cents']==sum(s['income_cents'] for s in included) and a['consumption_spending_cents']==sum(s['consumption_spending_cents'] for s in included),'ANNUAL_ROLLUP',a['year'])
    snapshot=read(full/'snapshot.json'); snap=snapshot['snapshot']; octrows=snapshot['october_activity']
    ledger_check(octrows,accounts)
    balances=dict(history['2026-09'][1])
    for t in sorted(octrows,key=lambda t:(t['posted_at'],t['transaction_id'])):
        if not t['pending']:
            aid=t['account_id'];balances[aid]+=t['signed_amount_cents']*(1 if accounts[aid]['asset_or_liability']=='asset' else -1)
    check(snap['account_balances_cents']==balances,'OCTOBER_REPLAY')
    for loan in snapshot['october_amortization']:
        aid=loan['account_id']
        check(loan['opening_principal_cents']==history['2026-09'][1][aid] and loan['closing_principal_cents']==balances[aid],'OCTOBER_DEBT_BALANCE',aid)
        check(loan['interest_cents']==exact(Decimal(loan['opening_principal_cents'])*Decimal(loan['annual_rate'])/12),'OCTOBER_DEBT_INTEREST',aid)
        check(loan['principal_cents']+loan['interest_cents']==loan['payment_cents'],'OCTOBER_DEBT_SPLIT',aid)
    bankcash=sum(balances[a] for a in accounts if accounts[a]['kind'] in ('checking','savings'))
    assets=summaries[-1]['assets_cents']+bankcash-summaries[-1]['bank_cash_cents']
    liability=sum(balances[a] for a in accounts if accounts[a]['asset_or_liability']=='liability')
    check((snap['assets_cents'],snap['liabilities_cents'],snap['net_worth_cents'])==(assets,liability,assets-liability),'CURRENT_NET_WORTH')
    reserve=sum(o['amount_cents'] for o in snapshot['upcoming_obligations'] if o['due_on'].startswith('2026-10'))
    available=max(0,sum(balances[a] for a in accounts if accounts[a]['kind']=='checking')-reserve)
    check(snap['available_to_spend_cents']==available,'AVAILABLE_EXCLUDES_ILLIQUID')
    check(all(t['posted_at'][:7]=='2026-10' and t['posted_at']<=snapshot['demo_clock'] for t in octrows),'OCTOBER_ISOLATION')
    expected=read(root/'documents/expected-extraction.json')
    primary={s['record_id']:s for s in statements}
    primary.update({m['record_id']:m for m in portfolio['monthly_accounts']})
    primary.update({m['record_id']:m for m in prediction['monthly_accounts']})
    for report in expected['reports']:
        check(report['parser_tested'] is False and report['expected_extracted_fields']==primary[report['report_id']],'DOCUMENT_EXPECTED_FIELDS',report['record_id'])
        check((root/'documents'/report['document']).is_file(),'PDF_PRESENT',report['record_id'])
    edges=read(root/'edge-cases.json')
    check(len(edges['cases'])==18,'EDGE_COVERAGE')
    unique(edges['cases'],'case_id','edge cases')
    fraction=next(e for e in edges['cases'] if e['case_id']=='property_fraction')['input']
    asset=exact(Decimal(fraction['gross_value_cents'])*Decimal(fraction['ownership_fraction']))
    liability=exact(Decimal(fraction['gross_loan_cents'])*Decimal(fraction['loan_ownership_fraction']))
    check((asset,liability,asset-liability)==(20000000,15000000,5000000),'FRACTIONAL_OWNERSHIP_EDGE')
    states={s['status']:s for s in read(root/'dinner_2026_10_11/scenario.json')['states']}
    check(not states['handoff_opened']['next_reminder_active'] and states['request_sent']['next_reminder_active'],'REMINDER_AFTER_SEND')
    check(not states['payment_reported']['next_reminder_active'] and not states['payment_reported']['observed_bank_settlement'],'REPORTED_NOT_VERIFIED')
    check(not states['disputed']['next_reminder_active'],'DISPUTE_CANCELS_REMINDER')
    can=read(root/'canonical_demo/dataset.json')
    check(can['scenario_id']=='canonical_demo' and all(t['scenario_id']=='canonical_demo' for t in can['transactions']),'CANONICAL_ISOLATION')
    check({t['posted_at'][:7] for t in can['transactions']}=={'2026-09'},'CANONICAL_PERIOD')
    check(sum(a['balance_cents']*(1 if a['asset_or_liability']=='asset' else -1) for a in can['accounts'])==1155000,'CANONICAL_NET_WORTH')
    for scenario,rows in [('canonical_demo',can['transactions']),('full_financial_world',tx_by_month['2026-09'])]:
        swaps=read(root/scenario/'swaps.json');lookup={t['transaction_id']:t for t in rows}
        purchase={p['record_id']:p for p in swaps['purchase_evidence']}
        for r in swaps['recommendations']:
            check(r['current_monthly_cost_cents']==r['monthly_quantity']*r['current_unit_cost_cents'] and r['proposed_monthly_cost_cents']==r['monthly_quantity']*r['proposed_unit_cost_cents'],'SWAP_UNIT_MONEY',r['record_id'])
            check(r['projected_savings_cents']==r['current_monthly_cost_cents']-r['proposed_monthly_cost_cents'],'SWAP_SAVINGS',r['record_id'])
            check(all(tid in lookup for tid in r['evidence_transaction_ids']),'SWAP_EVIDENCE_REFERENCES',r['record_id'])
            available=-sum(lookup[tid]['signed_amount_cents'] for tid in r['evidence_transaction_ids'])
            check(available>=r['current_monthly_cost_cents'],'SWAP_INCURRED_COST',r['record_id'])
            p=purchase[r['purchase_evidence_id']]
            check(p['extended_cost_cents']==r['current_monthly_cost_cents'] and p['transaction_ids']==r['evidence_transaction_ids'],'PURCHASE_EVIDENCE',r['record_id'])
            check(r['category']==lookup[r['evidence_transaction_ids'][0]]['category'],'SWAP_CATEGORY',r['record_id'])
        check(sum(r['projected_savings_cents'] for r in swaps['recommendations'])==swaps['total_projected_savings_cents']==15000,'BUDGET_150')
        result=swaps['keewano_result']['results']
        check(result[0]['eligible'] is False and result[0]['savings_cents']==3000 and result[1]['eligible'] is True and result[1]['savings_cents']==2000,'PREFERENCE_HISTORY')
        check(swaps['adoption']['status']=='projected' and swaps['adoption']['observed_ledger_mutation'] is False,'PLAN_NOT_HISTORY')
    dinner=read(root/'dinner_2026_10_11/scenario.json');r=dinner['receipt'];split=dinner['split_example']
    check(sum(i['extended_price_cents'] for i in r['items'])==r['subtotal_cents']==8400,'RECEIPT_SUBTOTAL')
    check(r['subtotal_cents']+r['tax_cents']+r['tip_cents']==r['total_cents']==10920,'RECEIPT_TOTAL')
    check(split['expected_shares_cents']=={'c_ashwin':2860,'c_tanish':3640,'c_aryan':4420} and sum(split['expected_shares_cents'].values())==10920,'RECEIPT_SHARES')
    check(split['expected_outstanding_cents']==sum(v for k,v in split['expected_shares_cents'].items() if k!='c_ashwin')==8060,'REIMBURSEMENT_TOTAL')
    linked=[t for t in octrows if t['transaction_id']==r['linked_transaction_id']]
    check(len(linked)==1 and linked[0]['signed_amount_cents']==-r['total_cents'],'ONE_DINNER_EXPENSE')
    check(all(not c.get('verified',False) and c['venmo_handle'] is None and c['phone']=='SYNTHETIC-NOT-A-CONTACT' for c in dinner['contacts']),'UNVERIFIED_ALIASES')
    check(dinner['reminder']['cancel_on']==['payment_reported','dispute_opened','verified_settlement'],'REMINDER_CANCEL_POLICY')
    return dict(transactions=len(tx),months=len(summaries),statements=len(statements),security_trades=len(portfolio['trades']),market_events=len(prediction['events']),
                september_net_worth_cents=summaries[-1]['net_worth_cents'],current_net_worth_cents=snap['net_worth_cents'])


def negative_tests():
    # Mutation tests: one real accounting fault per copy; fail with the named invariant.
    mutations=[('duplicate_id','ledger.json',lambda d:d['transactions'].append(copy.deepcopy(d['transactions'][0])),'UNIQUE_IDS'),
               ('unbalanced_transfer','ledger.json',lambda d:next(t for t in d['transactions'] if t['transfer_pair_id']).__setitem__('signed_amount_cents',-123),'TRANSFER_CONSERVATION'),
               ('incorrect_statement','statements.json',lambda d:d['statements'][0].__setitem__('closing_balance_cents',0),'CHRONOLOGICAL_RECONCILIATION'),
               ('missing_statement','statements.json',lambda d:d['statements'].pop(0),'STATEMENT_COVERAGE'),
               ('bad_quantity','portfolio.json',lambda d:d['position_marks'][0].__setitem__('quantity','999'),'HOLDINGS_ACTIVITY'),
               ('bad_market_equity','prediction-markets.json',lambda d:d['monthly_accounts'][0].__setitem__('equity_cents',1),'MARKET_EQUITY'),
               ('bad_loan_interest','property-debt.json',lambda d:d['amortization'][0].__setitem__('interest_cents',1),'DEBT_INTEREST'),
               ('property_double_count','summaries.json',lambda d:d['monthly_summaries'][0].__setitem__('assets_cents',1),'CONSOLIDATED_NET_WORTH'),
               ('budget_wrong_savings','swaps.json',lambda d:d['recommendations'][0].__setitem__('projected_savings_cents',1),'SWAP_SAVINGS')]
    import shutil
    for name,filename,mutate,expected in mutations:
        with tempfile.TemporaryDirectory(prefix='fwm-negative-') as tmp:
            target=Path(tmp)/'world';shutil.copytree(DATA,target)
            p=target/'full_financial_world'/filename;data=read(p);mutate(data);p.write_text(json.dumps(data))
            # Refresh checksum so validation reaches the invariant under test.
            local_path=target/'full_financial_world/manifest.json'
            local=read(local_path)
            next(e for e in local['files'] if e['path']==filename)['sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
            local_path.write_text(json.dumps(local))
            manifest=read(target/'manifest.json')
            next(e for e in manifest['files'] if e['path']=='full_financial_world/manifest.json')['sha256']=hashlib.sha256(local_path.read_bytes()).hexdigest()
            next(e for e in manifest['files'] if e['path']==f'full_financial_world/{filename}')['sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
            (target/'manifest.json').write_text(json.dumps(manifest))
            try: audit(target)
            except ValueError as error: check(str(error).startswith(expected+':'),'NEGATIVE_REJECTED',name+': '+str(error))
            else: check(False,'NEGATIVE_NOT_REJECTED',name)
    return len(mutations)


def deterministic_test():
    from tools.synthetic_data.generate import export
    import shutil
    with tempfile.TemporaryDirectory(prefix='fwm-repro-') as tmp:
        first=Path(tmp)/'a';second=Path(tmp)/'b'
        export(out=first);export(out=second)
        generated={p.relative_to(first).as_posix() for p in first.rglob('*') if p.is_file()}
        # Supply versioned, separately authored schemas/assets as manifest inputs.
        for p in DATA.rglob('*'):
            if not p.is_file() or p.relative_to(DATA).as_posix() in generated: continue
            for folder in (first,second):
                target=folder/p.relative_to(DATA);target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
        export(out=first);export(out=second)
        one={p.relative_to(first).as_posix():p.read_bytes() for p in first.rglob('*') if p.is_file()}
        two={p.relative_to(second).as_posix():p.read_bytes() for p in second.rglob('*') if p.is_file()}
        check(one==two,'SAME_SEED_IDENTICAL')
        for name,value in one.items(): check((DATA/name).read_bytes()==value,'CHECKED_IN_REPRODUCTION',name)
    return len(generated)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--skip-swift',action='store_true',help='Data-only checks; reports Swift checks skipped')
    args=p.parse_args()
    result=audit();result['negative_tests']=negative_tests();result['reproduced_files']=deterministic_test()
    result['invariant_assertions']=sum(checks.values());result['invariant_groups']=len(checks)
    if not args.skip_swift:
        subprocess.run(['swift','test','--package-path','Packages/FWMCore'],cwd=ROOT,check=True,timeout=180)
        result['swift']='passed (existing engines + synthetic fixture contract tests)'
    else: result['swift']='SKIPPED explicitly'
    result['status']='PASS'
    print(json.dumps(result,indent=2,sort_keys=True))


if __name__=='__main__': main()
