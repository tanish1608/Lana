#!/usr/bin/env python3
"""Neutral synthetic PDF statements and code-rendered receipt. Optional ReportLab/Pillow.
Run from repo root: python3 -m tools.synthetic_data.render
Additional month: --account chase_checking --period 2024-06
PDF bytes use ReportLab invariant mode; no provider connections or fonts downloaded.
"""
import argparse
import json
from html import escape
from pathlib import Path
from decimal import Decimal
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether
from PIL import Image, ImageDraw, ImageFont

from tools.synthetic_data.generate import OUT, rec, envelope, write, make_manifest, MONTHS

INK=colors.HexColor('#203246')
TEAL=colors.HexColor('#00675E')
PALE=colors.HexColor('#EFF5F5')
GRAY=colors.HexColor('#586677')
STYLES=getSampleStyleSheet()
STYLES.add(ParagraphStyle(name='Label',fontName='Helvetica-Bold',fontSize=9,textColor=TEAL,spaceAfter=7))
STYLES.add(ParagraphStyle(name='TitleWorld',fontName='Helvetica-Bold',fontSize=22,textColor=INK,leading=26,spaceAfter=12))
STYLES.add(ParagraphStyle(name='SmallWorld',fontSize=8,leading=11,textColor=GRAY,spaceAfter=6))
STYLES.add(ParagraphStyle(name='CellWorld',fontSize=7,leading=9,textColor=INK))


def usd(value):
    return f'${Decimal(value)/100:,.2f}'


def para(value,style='SmallWorld'):
    return Paragraph(escape(str(value)),STYLES[style])


def table(headers,rows,widths):
    data=[[para(h,'Label') for h in headers]]+[[para(v,'CellWorld') for v in row] for row in rows]
    result=Table(data,colWidths=widths,repeatRows=1,hAlign='LEFT')
    result.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),PALE),('LINEBELOW',(0,0),(-1,0),.7,TEAL),
                               ('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),6),
                               ('RIGHTPADDING',(0,0),(-1,-1),6),('TOPPADDING',(0,0),(-1,-1),6),
                               ('BOTTOMPADDING',(0,0),(-1,-1),6),('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,colors.HexColor('#F8FAFC')])]))
    return result


def footer(canvas,doc):
    canvas.saveState()
    canvas.setStrokeColor(TEAL);canvas.line(42,40,570,40)
    canvas.setFont('Helvetica',7);canvas.setFillColor(GRAY)
    canvas.drawString(42,28,'SYNTHETIC DEMO ONLY | USD | America/Los_Angeles | No real account or issuer terms')
    canvas.drawRightString(570,28,f'{doc.page}')
    canvas.restoreState()


def header(title,period,source):
    return [para('SYNTHETIC DEMO STATEMENT','Label'),para(title,'TitleWorld'),
            para(f'Period: {period} | Fictional person: Morgan Cedar | Dataset: synthetic-world-v1'),
            para('Generated demonstration data. Prices, outcomes, accounts and terms are fictional. Not valid for financial or tax use.'),
            para('Source: '+source),Spacer(1,12)]


def pdf(path,story):
    path.parent.mkdir(parents=True,exist_ok=True)
    doc=SimpleDocTemplate(str(path),pagesize=letter,leftMargin=42,rightMargin=42,topMargin=38,bottomMargin=52,
                         title='SYNTHETIC DEMO STATEMENT',author='FWM synthetic fixtures',invariant=1)
    doc.build(story,onFirstPage=footer,onLaterPages=footer)


def render_statement(aid,period,out):
    data=OUT/'full_financial_world'
    ledger=json.loads((data/'ledger.json').read_text())['transactions']
    all_statements=json.loads((data/'statements.json').read_text())['statements']
    statement=next((s for s in all_statements if s['account_id']==aid and s['period']==period),None)
    if statement is None: raise ValueError('No statement for this account/period (including pre-opening months)')
    rows={t['transaction_id']:t for t in ledger}
    report_id=statement['record_id']
    title=f"{statement['institution']} - fictional {statement['account_kind'].replace('_',' ')}"
    story=header(title,period,report_id)
    story+=[table(['Opening balance','Posted inflows / credits','Posted outflows / charges','Closing balance'],
                  [[usd(statement[k]) for k in ('opening_balance_cents','inflows_cents','outflows_cents','closing_balance_cents')]], [132]*4),Spacer(1,12)]
    if statement['account_kind']=='credit_card':
        metrics=[('Purchases',statement['purchases_cents']),('Refunds / credits',statement['credits_cents']),('Payments',statement['payments_cents']),
                 ('Interest',statement['interest_cents']),('Fees',statement['fees_cents']),('Credit limit',statement['credit_limit_cents']),('Minimum due',statement['minimum_due_cents'])]
        story+=[table(['Synthetic term','Amount'],[[a,usd(v)] for a,v in metrics],[360,168]),Spacer(1,8),
                para('Synthetic due date: '+statement['due_date']),para(statement['interest_policy'])]
    story+=[Spacer(1,8),para('Posted activity and source references','Label')]
    detail=[]
    for tid in sorted(statement['transaction_ids'],key=lambda x:(rows[x]['posted_at'],x)):
        t=rows[tid]
        detail.append([t['posted_at'][:10],t['merchant']+' / '+t['activity_kind'],usd(t['signed_amount_cents']),tid])
    story.append(table(['Date','Description / accounting kind','Signed USD','Source ID'],detail,[62,225,69,172]))
    path=out/f'{aid}-{period}.pdf';pdf(path,story)
    return rec('expected_'+report_id,report_id=report_id,document=path.name,parser_tested=False,
               expected_extracted_fields=statement)


def render_portfolio(period,out):
    d=OUT/'full_financial_world';portfolio=json.loads((d/'portfolio.json').read_text())
    monthly=next(m for m in portfolio['monthly_accounts'] if m['period']==period)
    summary=next(s for s in json.loads((d/'summaries.json').read_text())['monthly_summaries'] if s['period']==period)
    marks=[m for m in portfolio['position_marks'] if m['period']==period]
    trades=[t for t in portfolio['trades'] if t['executed_at'][:7]==period]
    ledger=[t for t in json.loads((d/'ledger.json').read_text())['transactions'] if t['posted_at'][:7]==period and t['account_id']=='robinhood']
    story=header('Robinhood - fictional portfolio report',period,monthly['record_id'])
    story+=[table(['Cash','Holdings','Total account equity','Period return'],[[usd(monthly[k]) for k in ('cash_cents','holdings_cents','equity_cents')]+[usd(summary['robinhood_return_cents'])]],[132]*4),Spacer(1,12),
            para('Cash and holdings included once. Return excludes funding. Synthetic prices; FIFO basis. Marks: '+monthly['valuation_as_of']),
            table(['Symbol','Quantity','Price USD','Value','Basis','Unrealized'],
                  [[m['instrument_id'],m['quantity'],m['price_usd'],usd(m['value_cents']),usd(m['cost_basis_cents']),usd(m['unrealized_gain_cents'])] for m in marks],[64,60,76,108,108,112]),Spacer(1,12),
            para('Trades','Label'),table(['Date / ID','Side / symbol','Quantity / price','Realized gain'],
                [[t['executed_at'][:10]+' / '+t['trade_id'],t['side']+' '+t['instrument_id'],t['quantity']+' @ '+t['price_usd'],usd(t['realized_gain_cents'])] for t in trades],[185,85,148,110]),Spacer(1,12),
            para('Cash activity: funding, withdrawals, trades and dividends','Label'),
            table(['Date','Kind','Signed USD','Source'],[[t['posted_at'][:10],t['activity_kind'],usd(t['signed_amount_cents']),t['transaction_id']] for t in ledger],[74,150,94,210])]
    path=out/f'robinhood-{period}.pdf';pdf(path,story)
    return rec('expected_'+monthly['record_id'],report_id=monthly['record_id'],document=path.name,parser_tested=False,
               expected_extracted_fields=monthly)


def render_prediction(aid,period,out):
    all_data=json.loads((OUT/'full_financial_world/prediction-markets.json').read_text())
    monthly=next((m for m in all_data['monthly_accounts'] if m['account_id']==aid and m['period']==period),None)
    if monthly is None: raise ValueError('Market account not open in this period')
    marks=[m for m in all_data['position_marks'] if m['record_id'] in monthly['mark_ids']]
    events=[e for e in all_data['events'] if e['account_id']==aid and e['occurred_at'][:7]==period]
    story=header(aid.title()+' - fictional market summary',period,monthly['record_id'])
    metrics=[('Cash / collateral',monthly['cash_or_collateral_cents']),('Reserved subset',monthly['reserved_cents']),
             ('Available cash',monthly['available_cents']),('Open position marks',monthly['positions_cents']),('Account equity',monthly['equity_cents']),('Period return excluding funding',monthly['period_return_cents']),
             ('Realized profit/loss this month',monthly['realized_gain_cents']),('Unrealized profit/loss',monthly['unrealized_gain_cents'])]
    story+=[table(['Metric','USD equivalent'],[[label,usd(value)] for label,value in metrics],[360,168]),Spacer(1,12)]
    if aid=='polymarket': story.append(para('Collateral: SYNTHETIC_USDC '+monthly['collateral_quantity']+' units. Declared synthetic valuation: 1.00 USD per unit. No usable wallet address.'))
    story+=[para('Reserved funds are included in cash. Open position marks are included once in equity and are not withdrawable cash.'),
            table(['Open market','Quantity / mark','Value','Valuation as of / stale'],
                  [[m['market_id'],m['quantity']+' @ '+m['price_usd'],usd(m['value_cents']),m['valuation_as_of']+' / '+str(m['stale'])] for m in marks],[200,90,68,170]),Spacer(1,12),
            para('Fictional trades and outcomes','Label'),table(['Date / source','Market','Kind / quantity','Gross / fee / profit'],
                [[e['occurred_at'][:10]+' / '+e['event_id'],e['market_id'],e['kind']+' / '+e['quantity'],usd(e['gross_cents'])+' / '+usd(e['fee_cents'])+' / '+usd(e.get('realized_gain_cents',0))] for e in events],[180,155,80,113]),
            Spacer(1,8),para('Questions and outcomes are fictional. YES payout 1 USD equivalent; NO payout zero. Winning proceeds include returned basis. This does not reproduce actual provider mechanics.')]
    path=out/f'{aid}-{period}.pdf';pdf(path,story)
    return rec('expected_'+monthly['record_id'],report_id=monthly['record_id'],document=path.name,parser_tested=False,expected_extracted_fields=monthly)


def receipt_asset():
    target=OUT/'dinner_2026_10_11'
    text=(target/'ocr.txt').read_text().splitlines()
    # The asset is rendered from the same itemized fixture, not a photographed receipt.
    image=Image.new('RGB',(840,1000),'#f7f5ee');draw=ImageDraw.Draw(image)
    regular=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',22) if Path('/System/Library/Fonts/Menlo.ttc').exists() else ImageFont.load_default(size=22)
    draw.rounded_rectangle((32,32,808,968),radius=18,fill='white',outline='#cad5d8',width=2)
    y=74
    for index,line in enumerate(text):
        # Fixed synthetic footer wraps to avoid clipping.
        if len(line)>47: line=line.replace(' or ','\nor ')
        for part in line.splitlines():
            draw.text((62,y),part,fill='#00675e' if index==0 else '#203246',font=regular); y+=52
    image.save(target/'receipt.png',compress_level=9)
    lines=[]
    for index,line in enumerate(text):
        lines.append(f'<text x="28" y="{42+index*28}" font-family="monospace" font-size="12" fill="#203246">{escape(line)}</text>')
    (target/'receipt.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="540" height="500" viewBox="0 0 540 500"><rect width="540" height="500" fill="white"/>'+''.join(lines)+'</svg>\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--account',choices=['chase_checking','chase_savings','capital_one_checking','capital_one_savings','chase_card','capital_one_card','robinhood','kalshi','polymarket'])
    parser.add_argument('--period',choices=MONTHS)
    parser.add_argument('--output',type=Path,default=OUT/'documents')
    args=parser.parse_args()
    if bool(args.account)!=bool(args.period): parser.error('--account and --period must be used together')
    jobs=[(args.account,args.period)] if args.account else [('chase_checking','2023-11'),('capital_one_card','2025-02'),('chase_card','2025-01'),('chase_checking','2026-09'),('robinhood','2026-09'),('kalshi','2026-09'),('polymarket','2026-09')]
    expected=[]
    for aid,period in jobs:
        renderer=render_portfolio if aid=='robinhood' else render_prediction if aid in ('kalshi','polymarket') else render_statement
        expected.append(renderer(period,args.output) if aid=='robinhood' else renderer(aid,period,args.output))
    write(args.output/'expected-extraction.json',envelope('full_financial_world',reports=expected,parser_tested=False))
    if args.account is None: receipt_asset()
    make_manifest(OUT,'full')
    print(f'Rendered {len(jobs)} neutral synthetic PDF examples; expected fields provided, parser not claimed tested.')


if __name__=='__main__': main()
