#!/usr/bin/env python3
"""Offline tests for the demo API's acceptance rules and the agent's 402 loop. No network, no key.

    python3 demo/test_api.py

Receipts are built by hand in the exact shape eth_getTransactionReceipt returns, so each rule can
be broken one at a time: a fake Paid event, a replay, a wrong amount, a wrong payer, an
unregistered wallet, a fake token, a missing transfer.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "script"))
import api as A  # noqa: E402
import agent as G  # noqa: E402
import evm_rpc as E  # noqa: E402

TMP = os.path.join(HERE, "..", "cache", "test_demo")
os.makedirs(TMP, exist_ok=True)

WALLET = "0x" + "a1" * 20      # registered on chain 84532
WALLET_U = "0x" + "a2" * 20    # registered on chain 1301
STRANGER = "0x" + "a9" * 20    # a real SpendWallet nobody registered, or any other contract
TOKEN = "0x" + "c1" * 20
TOKEN_U = "0x" + "c2" * 20
FAKE_TOKEN = "0x" + "c9" * 20
VAULT = "0x" + "d1" * 20
PAYEE = "0x" + "b1" * 20
OTHER = "0x" + "b9" * 20
CID = "0x" + "11" * 32
PRICE = 1_000_000
NOW = 1_794_200_000
DAY = NOW // 86400
REG = {84532: {"token": TOKEN, "wallets": {WALLET}}, 1301: {"token": TOKEN_U, "wallets": {WALLET_U}}}
QUOTE = {"callId": CID, "resource": "/v1/snapshot?n=1", "amount": PRICE, "payee": PAYEE, "issuedAt": NOW - 10,
         "expiresAt": NOW + 3600}


def taddr(a):
    return "0x" + E.addr_word(a)


def paid(addr, payee=PAYEE, amount=PRICE, cid=CID, idx=0):
    return {"address": addr, "topics": [E.TOPIC_PAID, cid, taddr(payee)],
            "data": "0x" + E.word(amount) + E.word(DAY) + E.word(0), "logIndex": hex(idx)}


def transfer(frm, to=PAYEE, amount=PRICE, token=TOKEN, idx=1):
    return {"address": token, "topics": [E.TOPIC_TRANSFER, taddr(frm), taddr(to)], "data": "0x" + E.word(amount),
            "logIndex": hex(idx)}


def refused(addr, reason, cid=CID, idx=0):
    return {"address": addr, "topics": [E.TOPIC_REFUSED, cid], "data": "0x" + E.word(reason), "logIndex": hex(idx)}


def short(addr, short_by, idx=1):
    return {"address": addr, "topics": [E.TOPIC_SHORT], "data": "0x" + E.word(DAY) + E.word(short_by) + E.word(NOW),
            "logIndex": hex(idx)}


def rcpt(*logs, status=1, tx="0x" + "77" * 32):
    return {"status": hex(status), "logs": list(logs), "transactionHash": tx, "blockNumber": "0x10"}


def judge(receipt, quote=QUOTE, cid=CID, chain=84532, used=()):
    return A.judge(receipt, quote, cid, chain, REG, set(used), NOW)


class Accept(unittest.TestCase):
    def test_real_payment_is_accepted(self):
        v, info = judge(rcpt(paid(WALLET), transfer(WALLET)))
        self.assertEqual(v, "paid", info)
        self.assertEqual((info["wallet"], info["amount"]), (WALLET, PRICE))

    def test_a_vault_return_after_the_payment_does_not_matter(self):
        v, _ = judge(rcpt(paid(WALLET, idx=0), transfer(WALLET, idx=1), transfer(WALLET, to=VAULT, amount=5, idx=2)))
        self.assertEqual(v, "paid")

    def test_case_of_hex_does_not_matter(self):
        lg = paid(WALLET.upper().replace("0X", "0x"))
        lg["topics"] = [t.upper().replace("0X", "0x") for t in lg["topics"]]
        v, _ = judge(rcpt(lg, transfer(WALLET)), cid=CID.upper().replace("0X", "0x"))
        self.assertEqual(v, "paid")


class FakeEvent(unittest.TestCase):
    def test_fake_paid_from_another_contract_with_real_tokens_is_rejected(self):
        # the dry run's FakePaid: identical Paid log and a real token transfer, from an unregistered address
        v, why = judge(rcpt(paid(STRANGER), transfer(STRANGER)))
        self.assertEqual(v, "rejected")
        self.assertIn("unregistered", why)

    def test_paid_log_without_any_token_transfer_is_rejected(self):
        v, why = judge(rcpt(paid(WALLET)))
        self.assertEqual(v, "rejected")
        self.assertIn("Transfer", why)

    def test_transfer_from_a_fake_token_is_rejected(self):
        v, why = judge(rcpt(paid(WALLET), transfer(WALLET, token=FAKE_TOKEN)))
        self.assertEqual(v, "rejected")
        self.assertIn("Transfer", why)

    def test_the_transfer_must_come_after_the_paid_log(self):
        v, _ = judge(rcpt(transfer(WALLET, idx=0), paid(WALLET, idx=1)))
        self.assertEqual(v, "rejected")

    def test_failed_transaction_is_rejected(self):
        self.assertEqual(judge(rcpt(paid(WALLET), transfer(WALLET), status=0))[0], "rejected")

    def test_missing_receipt_is_rejected(self):
        self.assertEqual(judge(None)[0], "rejected")


class Replay(unittest.TestCase):
    def test_used_callid_is_rejected(self):
        v, why = judge(rcpt(paid(WALLET), transfer(WALLET)), used={CID})
        self.assertEqual(v, "rejected")
        self.assertIn("replay", why)

    def test_an_old_payment_cannot_answer_a_new_callid(self):
        new = dict(QUOTE, callId="0x" + "22" * 32)
        v, _ = judge(rcpt(paid(WALLET), transfer(WALLET)), quote=new, cid=new["callId"])
        self.assertEqual(v, "rejected")

    def test_unknown_and_expired_callids_are_rejected(self):
        self.assertIn("unknown", judge(rcpt(paid(WALLET), transfer(WALLET)), quote=None)[1])
        self.assertIn("expired", judge(rcpt(paid(WALLET), transfer(WALLET)), quote=dict(QUOTE, expiresAt=NOW - 1))[1])


class WrongAmount(unittest.TestCase):
    def test_less_more_or_mismatched(self):
        for p_amt, t_amt in ((PRICE - 1, PRICE - 1), (PRICE + 1, PRICE + 1), (PRICE, PRICE - 1), (PRICE - 1, PRICE)):
            v, why = judge(rcpt(paid(WALLET, amount=p_amt), transfer(WALLET, amount=t_amt)))
            self.assertEqual(v, "rejected", (p_amt, t_amt))
            self.assertIn("amount", why)

    def test_wrong_payee_in_the_event_or_the_transfer(self):
        self.assertIn("payee", judge(rcpt(paid(WALLET, payee=OTHER), transfer(WALLET, to=OTHER)))[1])
        self.assertIn("another address", judge(rcpt(paid(WALLET), transfer(WALLET, to=OTHER)))[1])


class WrongPayer(unittest.TestCase):
    def test_transfer_from_another_address_is_rejected(self):
        v, why = judge(rcpt(paid(WALLET), transfer(STRANGER)))
        self.assertEqual(v, "rejected")
        self.assertIn("paying wallet", why)

    def test_transfer_from_another_registered_wallet_is_rejected(self):
        reg = {84532: {"token": TOKEN, "wallets": {WALLET, WALLET_U}}}
        v, _ = A.judge(rcpt(paid(WALLET), transfer(WALLET_U)), QUOTE, CID, 84532, reg, set(), NOW)
        self.assertEqual(v, "rejected")


class Unregistered(unittest.TestCase):
    def test_a_real_wallet_that_is_not_registered_is_rejected(self):
        v, _ = judge(rcpt(paid(STRANGER), transfer(STRANGER)))
        self.assertEqual(v, "rejected")

    def test_a_wallet_registered_on_another_chain_is_rejected(self):
        # Unichain's wallet and token, but claimed as a Base payment
        v, _ = judge(rcpt(paid(WALLET_U), transfer(WALLET_U, token=TOKEN_U)), chain=84532)
        self.assertEqual(v, "rejected")
        self.assertEqual(judge(rcpt(paid(WALLET_U), transfer(WALLET_U, token=TOKEN_U)), chain=1301)[0], "paid")

    def test_unknown_chain_is_rejected(self):
        self.assertIn("not accepted", judge(rcpt(paid(WALLET), transfer(WALLET)), chain=1)[1])


class Refusals(unittest.TestCase):
    def test_refused_with_short(self):
        v, info = judge(rcpt(refused(WALLET, A.R_SHORT), short(WALLET, 700_000)))
        self.assertEqual(v, "refused")
        self.assertEqual((info["reason"], info["shortBy"], info["shortEmitted"]), (A.R_SHORT, 700_000, True))

    def test_refused_by_an_unregistered_address_is_not_a_refusal(self):
        self.assertEqual(judge(rcpt(refused(STRANGER, A.R_SHORT)))[0], "rejected")

    def test_amber_top_up_when_the_pool_covers_it(self):
        st = A.classify({"reason": A.R_SHORT, "shortBy": 700_000}, PRICE,
                        {"cap": 20e6, "spent": 5e6, "pool": 2e6, "frozen": False, "paused": False})
        self.assertEqual((st["state"], st["why"], st["retryAfterSec"]), ("amber", "top-up", A.TOPUP_RETRY_SEC))
        self.assertIn("budget on its way, retry in ~5 s", st["message"])

    def test_amber_from_another_chain_when_the_pool_is_empty(self):
        st = A.classify({"reason": A.R_SHORT, "shortBy": PRICE}, PRICE,
                        {"cap": 20_000_000, "spent": 17_000_000, "pool": 0, "frozen": False, "paused": False})
        self.assertEqual((st["state"], st["retryAfterSec"]), ("amber", A.DONOR_RETRY_SEC))

    def test_red_cap_reached(self):
        st = A.classify({"reason": A.R_SHORT, "shortBy": 10_000_000}, 10_000_000,
                        {"cap": 20_000_000, "spent": 11_000_000, "pool": 8_000_000, "frozen": False, "paused": False})
        self.assertEqual((st["state"], st["why"]), ("red", "cap reached"))
        self.assertIn("$9.00 can still leave today", st["message"])

    def test_exactly_the_remaining_budget_is_still_amber(self):
        st = A.classify({"reason": A.R_SHORT, "shortBy": 9_000_000}, 9_000_000,
                        {"cap": 20_000_000, "spent": 11_000_000, "pool": 9_000_000, "frozen": False, "paused": False})
        self.assertEqual(st["state"], "amber")

    def test_red_for_stop_payee_per_call_cap_and_paused(self):
        ctx = {"cap": 20_000_000, "spent": 0, "pool": 20_000_000, "frozen": False, "paused": False}
        self.assertEqual(A.classify({"reason": A.R_FROZEN}, PRICE, ctx)["why"], "stopped")
        self.assertEqual(A.classify({"reason": A.R_SHORT}, PRICE, dict(ctx, frozen=True))["why"], "stopped")
        self.assertEqual(A.classify({"reason": A.R_PAYEE}, PRICE, ctx)["why"], "payee")
        self.assertEqual(A.classify({"reason": A.R_CAP}, PRICE, ctx)["why"], "per-call cap")
        self.assertEqual(A.classify({"reason": A.R_SHORT}, PRICE, dict(ctx, paused=True))["why"], "coordinator paused")


class FakeRpc:
    def __init__(self, receipts, calls=None):
        self.receipts, self.calls = receipts, calls or {}

    def receipt(self, tx):
        return self.receipts.get(tx)

    def head(self):
        return 16

    def call(self, method, params):
        if method == "eth_getBlockByNumber":
            return {"timestamp": hex(NOW)}
        raise AssertionError(method)

    def eth_call(self, to, data):
        return self.calls[(to.lower(), data[:10])]


class Service(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(dir=TMP)
        dep = {"coordinator": "0x" + "f1" * 20,
               "base": {"chainId": 84532, "token": TOKEN, "wallet": WALLET},
               "unichain": {"chainId": 1301, "token": TOKEN_U, "wallet": WALLET_U}}
        self.tx_ok, self.tx_ref = "0x" + "71" * 32, "0x" + "72" * 32
        self.rx = {}
        rc = dep["coordinator"]
        calls = {(WALLET, "0xa0c383e8"): "0x" + E.word(9_000_000) + E.word(6_000_000),
                 (WALLET_U, "0xa0c383e8"): "0x" + E.word(2_000_000) + E.word(1_000_000),
                 (rc, "0x32d07896"): "0x" + E.word(20_000_000), (rc, "0x2f9f5d82"): "0x" + E.word(0),
                 (rc, "0x054f7d9c"): "0x" + E.word(0), (E.SYSTEM, "0x9b6c56ec"): "0x" + E.word(0)}
        self.dep = dep
        self.mk = lambda: A.Service(dep, PAYEE, PRICE, 3600, os.path.join(self.d, "state.json"),
                                    {84532: FakeRpc(self.rx), 1301: FakeRpc(self.rx, calls)}, FakeRpc({}, calls))
        self.svc = self.mk()
        self.svc.rpcs[84532].calls = calls

    def tearDown(self):
        shutil.rmtree(self.d)

    def pay_header(self, q, tx):
        return f"84532:{tx}:{q['callId']}"

    def settle(self, res, q, tx, claim=None):
        return self.svc.settle(res, self.pay_header(q, tx), q["claim"] if claim is None else claim)

    def test_pay_then_replay_then_restart(self):
        q = self.svc.quote("/v1/snapshot?n=1", 1)
        self.rx[self.tx_ok] = rcpt(paid(WALLET, cid=q["callId"]), transfer(WALLET), tx=self.tx_ok)
        code, body = self.settle("/v1/snapshot?n=1", q, self.tx_ok)
        self.assertEqual(code, 200, body)
        self.assertEqual(len(body["data"]["rows"]), 1)
        code, body = self.settle("/v1/snapshot?n=1", q, self.tx_ok)
        self.assertEqual(code, 409, body)
        # a restarted API reads the used set from disk
        code, _ = self.mk().settle("/v1/snapshot?n=1", self.pay_header(q, self.tx_ok), q["claim"])
        self.assertEqual(code, 409)

    def test_an_onlooker_without_the_claim_cannot_redeem_the_agents_payment(self):
        q = self.svc.quote("/v1/snapshot?n=1", 1)
        self.rx[self.tx_ok] = rcpt(paid(WALLET, cid=q["callId"]), transfer(WALLET), tx=self.tx_ok)
        for wrong in ("", "00" * 16, q["claim"][:-1] + ("0" if q["claim"][-1] != "0" else "1")):
            code, body = self.settle("/v1/snapshot?n=1", q, self.tx_ok, claim=wrong)
            self.assertEqual(code, 402, body)
            self.assertIn("Claim", body["reason"])
        self.assertEqual(self.settle("/v1/snapshot?n=1", q, self.tx_ok)[0], 200)  # the agent still can

    def test_a_quote_is_bound_to_its_resource(self):
        q = self.svc.quote("/v1/snapshot?n=1", 1)
        self.rx[self.tx_ok] = rcpt(paid(WALLET, cid=q["callId"]), transfer(WALLET), tx=self.tx_ok)
        code, body = self.settle("/v1/snapshot?n=9", q, self.tx_ok)
        self.assertEqual(code, 402)
        self.assertIn("another resource", body["reason"])

    def test_refused_pay_gets_amber_or_red_and_keeps_the_quote_open(self):
        q = self.svc.quote("/v1/snapshot?n=3", 3)
        self.rx[self.tx_ref] = rcpt(refused(WALLET, A.R_SHORT, cid=q["callId"]), short(WALLET, 3_000_000), tx=self.tx_ref)
        code, body = self.settle("/v1/snapshot?n=3", q, self.tx_ref)
        # cap 20, spent 6 + 1 = 7, pool 0: the budget exists but must come from another chain
        self.assertEqual((code, body["state"], body["retryAfterSec"]), (402, "amber", A.DONOR_RETRY_SEC), body)
        self.assertNotIn(q["callId"], self.svc.used)
        q2 = self.svc.quote("/v1/snapshot?n=14", 14)
        self.rx[self.tx_ref] = rcpt(refused(WALLET, A.R_SHORT, cid=q2["callId"]), short(WALLET, 11_000_000),
                                    tx=self.tx_ref)
        code, body = self.settle("/v1/snapshot?n=14", q2, self.tx_ref)
        self.assertEqual((body["state"], body["why"]), ("red", "cap reached"), body)

    def test_malformed_header(self):
        self.assertEqual(self.svc.settle("/v1/snapshot?n=1", "nonsense")[0], 400)


class Agent(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(dir=TMP)
        os.environ["DEMO_AGENT_LOG"] = os.path.join(self.d, "agent.jsonl")
        self.q = {"callId": CID, "claim": "c1a1m", "price": PRICE, "priceUsd": "$1.00", "payee": PAYEE,
                  "chains": [{"chain": "base", "chainId": 84532}]}

    def tearDown(self):
        shutil.rmtree(self.d)

    def go(self, answers, wait_min=0, max_usd=10.0, pay_fails=False):
        answers, pays, slept = list(answers), [], []

        def get(url, headers=None):
            if headers is None:
                return 402, self.q
            self.assertEqual(headers["X-Payment-Claim"], "c1a1m")
            return answers.pop(0)

        def pay(chain, payee, amount, cid):
            if pay_fails:
                raise RuntimeError("forge died")
            pays.append((chain, payee, amount, cid))
            return "0x" + "%064x" % len(pays)

        a = type("A", (), {"api": "http://x", "resource": "/v1/snapshot?n=1", "chain": "base", "max_usd": max_usd,
                           "expect_payee": PAYEE, "wait_min": wait_min})
        code = G.run(a, get=get, pay=pay, sleep=slept.append, now=lambda: NOW + sum(slept))
        return code, pays, slept

    def test_402_pay_data(self):
        code, pays, _ = self.go([(200, {"data": {"rows": [1]}, "paid": {}})])
        self.assertEqual((code, pays), (0, [("base", PAYEE, PRICE, CID)]))

    def test_amber_then_served(self):
        amber = (402, {"state": "amber", "retryAfterSec": 5, "message": "budget on its way, retry in ~5 s"})
        code, pays, slept = self.go([amber, (200, {"data": {"rows": [1]}})], wait_min=1)
        self.assertEqual((code, len(pays), slept), (0, 2, [5.0]))
        self.assertEqual(pays[0][3], pays[1][3])  # the same quote, paid again after a refusal

    def test_amber_without_time_left_and_red(self):
        self.assertEqual(self.go([(402, {"state": "amber", "retryAfterSec": 310})], wait_min=1)[0], 10)
        self.assertEqual(self.go([(402, {"state": "red", "why": "cap reached"})])[0], 11)

    def test_never_pays_above_max_or_twice_after_a_forge_failure(self):
        code, pays, _ = self.go([], max_usd=0.5)
        self.assertEqual((code, pays), (12, []))
        code, pays, _ = self.go([], pay_fails=True)
        self.assertEqual(code, 4)


class Constants(unittest.TestCase):
    def test_topics_and_selectors_match_cast(self):
        cast = os.environ.get("CAST", os.path.expanduser("~/.foundry/bin/cast"))
        if not os.path.exists(cast):
            self.skipTest("cast not installed")
        for topic, sig in E.SIGS.items():
            self.assertEqual(subprocess.run([cast, "keccak", sig], capture_output=True, text=True).stdout.strip(), topic)
        for sig, sel in E.SEL.items():
            self.assertEqual(subprocess.run([cast, "sig", sig], capture_output=True, text=True).stdout.strip(), sel)


if __name__ == "__main__":
    unittest.main(verbosity=1)
