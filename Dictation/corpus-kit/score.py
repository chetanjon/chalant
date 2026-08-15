#!/usr/bin/env python3
"""Corpus scorer. Primary metric: corrections per 100 words, broken out by error class."""
import json, sys, re, argparse
from collections import Counter

def toks(s):
    return re.findall(r"[\w'@./_-]+|[^\w\s]", s.lower())

def align(ref, hyp):
    """Levenshtein backtrace -> list of (op, ref_tok, hyp_tok)."""
    n, m = len(ref), len(hyp)
    d = [[0]*(m+1) for _ in range(n+1)]
    for i in range(n+1): d[i][0] = i
    for j in range(m+1): d[0][j] = j
    for i in range(1, n+1):
        for j in range(1, m+1):
            d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1,
                          d[i-1][j-1] + (ref[i-1] != hyp[j-1]))
    ops, i, j = [], n, m
    while i > 0 or j > 0:
        if i>0 and j>0 and ref[i-1]==hyp[j-1] and d[i][j]==d[i-1][j-1]:
            ops.append(('ok', ref[i-1], hyp[j-1])); i-=1; j-=1
        elif i>0 and j>0 and d[i][j]==d[i-1][j-1]+1:
            ops.append(('sub', ref[i-1], hyp[j-1])); i-=1; j-=1
        elif j>0 and d[i][j]==d[i][j-1]+1:
            ops.append(('ins', None, hyp[j-1])); j-=1
        else:
            ops.append(('del', ref[i-1], None)); i-=1
    return list(reversed(ops))

def classify(tok, terms):
    if tok is None: return 'other'
    if tok in terms: return 'proper_noun'
    if re.fullmatch(r"[\d.,:$%/-]+", tok): return 'number'
    if tok in {'.',',','?','!',';',':','-'}: return 'punctuation'
    return 'other'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('manifest'); ap.add_argument('--terms', default=None)
    ap.add_argument('--split', default=None, help='dev | holdout')
    a = ap.parse_args()

    terms = set()
    if a.terms:
        terms = {t.strip().lower() for t in open(a.terms) if t.strip()}

    rows = [json.loads(l) for l in open(a.manifest) if l.strip()]
    if a.split: rows = [r for r in rows if r.get('split') == a.split]

    by_ctx, cls, tot_ref, tot_err = Counter(), Counter(), 0, 0
    ctx_words, worst = Counter(), []

    for r in rows:
        ref, hyp = toks(r['desired']), toks(r.get('output', ''))
        ops = align(ref, hyp)
        errs = [o for o in ops if o[0] != 'ok']
        tot_ref += len(ref); tot_err += len(errs)
        ctx = r.get('context', 'unknown')
        by_ctx[ctx] += len(errs); ctx_words[ctx] += len(ref)
        for op, rt, ht in errs:
            cls[classify(rt if rt else ht, terms)] += 1
        if errs: worst.append((len(errs)/max(len(ref),1), r.get('id'), ctx, errs[:3]))

    print(f"utterances: {len(rows)}   reference words: {tot_ref}")
    if tot_ref == 0: return
    print(f"\n>>> CORRECTIONS PER 100 WORDS: {100*tot_err/tot_ref:.2f}   (total {tot_err})\n")
    print("by context:")
    for c, n in by_ctx.most_common():
        w = ctx_words[c]
        print(f"  {c:<20} {100*n/max(w,1):>6.2f} per 100w   ({n} errs / {w} words)")
    print("\nby error class:")
    for c, n in cls.most_common():
        print(f"  {c:<20} {n:>4}  ({100*n/max(tot_err,1):.0f}% of all errors)")
    print("\nworst utterances:")
    for rate, uid, ctx, ex in sorted(worst, reverse=True)[:5]:
        print(f"  {uid} [{ctx}] {100*rate:.0f}% err  e.g. {ex}")

main()
