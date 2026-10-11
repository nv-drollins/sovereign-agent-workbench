#!/usr/bin/env python3
"""Prove the verifier catches a fabricated quote. MUST fail the bad case."""
import json, sys, urllib.request

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8800"

PASSAGES = [{
    "doc": "grant-award", "section": "2. Audit",
    "text": "2.1 The Recipient expending **$750,000 or more** in Federal awards "
            "during its fiscal year shall have a single audit conducted in "
            "accordance with 2 CFR 200 Subpart F, submitted within **nine months** "
            "of fiscal year end.",
}]

GOOD = ('- A single audit is required when the recipient expends '
        '"$750,000 or more" in Federal awards.\n'
        '- It must be submitted "within nine months" of fiscal year end.\n')

BAD = ('- A single audit is required when the recipient expends '
       '"$250,000 or more" in Federal awards.\n'
       '- The agency may waive the audit at its discretion.\n')


def verify(answer):
    body = json.dumps({"answer": answer, "passages": PASSAGES}).encode()
    req = urllib.request.Request(f"http://{HOST}/verify", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


ok = True

print("=== CASE 1: honest answer (quotes are real) ===")
g = verify(GOOD)
print(f"  verdict: {g['verdict']}")
print(f"  quotes {g['quotes_supported']}/{g['quotes_checked']} supported")
if g["quotes_supported"] != g["quotes_checked"]:
    print("  FAIL: verifier rejected a TRUE quote"); ok = False

print("\n=== CASE 2: fabricated answer (wrong number + invented claim) ===")
b = verify(BAD)
print(f"  verdict: {b['verdict']}")
print(f"  quotes {b['quotes_supported']}/{b['quotes_checked']} supported")
for u in b["quotes_unsupported"]:
    print(f"  FLAGGED: {u['quote']}")
print(f"  uncited claims: {b['claims_without_citation']}")
for c in b["unquoted_claims"]:
    print(f"  UNCITED: {c[:80]}")

if b["quotes_supported"] == b["quotes_checked"]:
    print("  FAIL: verifier MISSED a fabricated quote"); ok = False
if b["claims_without_citation"] < 1:
    print("  FAIL: verifier missed the uncited claim"); ok = False

print("\n" + ("VERIFIER WORKS" if ok else "VERIFIER BROKEN"))
sys.exit(0 if ok else 1)
