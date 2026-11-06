#!/usr/bin/env python3
"""Source-patch mutants for script/mutants.sh.

Unlike the hook mutants (test/mutants/Mutants.sol, selected with MUTANT=<n>, seen only by the
tests built on the network model), a patch mutant edits a copy of the production source, so
every suite sees it: invariants, directed scenarios, Reactive glue, gas, the coverage walk.

    patch_mutants.py list               -> "<id>\t<description>" per mutant
    patch_mutants.py apply <id> <dir>   -> apply mutant <id> to the project copy in <dir>

Each patch must match its source text exactly once, or `apply` fails (so a stale patch can
never silently become a no-op "mutant" that trivially survives or is trivially killed).
Y* are the round-2 judge's mutants; Z* break the round-3 fixes.
"""
import pathlib
import sys

MUTANTS = [
    ("Y3", "core: re-read cursor never advances (bounded work doesn't carry over)",
     "src/BudgetCore.sol", "            _pCur = i;", "            _pCur = 0;"),
    ("Y4", "core: cancel cursor never advances (bounded work doesn't carry over)",
     "src/BudgetCore.sol", "            _gCur = i;", "            _gCur = 0;"),
    ("Y5", "wallet: return to the vault reverts on failure (freeze tied to the transfer)",
     "src/SpendWallet.sol",
     "        if (token.tryTransfer(address(vault), amount, gasleft() - FLUSH_KEEP)) stranded = 0;",
     "        token.safeTransfer(address(vault), amount);\n        stranded = 0;"),
    ("Y6", "core: every chain uses chain 0's (shortest) confirmation wait",
     "src/BudgetCore.sol",
     "        return v.ts >= v.appliedAt + _cp[c].confirmWait;",
     "        return v.ts >= v.appliedAt + _cp[0].confirmWait;"),
    ("Y8", "wallet: applies epoch messages older than its own epoch",
     "src/SpendWallet.sol", "        if (e < epoch) return;\n", ""),
    ("Y11", "wallet: forgets stranded tokens even when the return failed",
     "src/SpendWallet.sol",
     "        if (token.tryTransfer(address(vault), amount, gasleft() - FLUSH_KEEP)) stranded = 0;",
     "        token.tryTransfer(address(vault), amount, gasleft() - FLUSH_KEEP);\n        stranded = 0;"),
    ("Y12", "wallet: accepts a short delivery from the vault (fee-on-transfer guard off)",
     "src/SpendWallet.sol", "        if (got >= amount) return true;", "        if (true) return true;"),
    ("Y13", "front: drops the reactive-contract id check",
     "src/reactive/CallbackFront.sol", '        require(rvm == rc, "reactive contract");', "        rvm;"),
    ("Y14", "core: epoch ack trusted at head, without the re-read",
     "src/BudgetCore.sol",
     "        if (e > epochAcked[c]) _admit(K_EPOCH, c, e, 0, 0, 0, ts);",
     "        if (e > epochAcked[c]) epochAcked[c] = e;"),
    ("Z1", "core: no heartbeat (a lost STOP waits for the pressing chain's agent)",
     "src/BudgetCore.sol",
     "        if (heartbeat != 0 && nowTs >= _nextBeat && _canSendBackground()) _beat(nowTs);\n", ""),
    ("Z2", "wallet: a re-read doesn't re-announce an unacknowledged press",
     "src/SpendWallet.sol",
     "        _echoStop(); // the coordinator's periodic heartbeat is a verify: a lost press rides on it\n",
     ""),
    ("Z3", "core: no limit of one unanswered grant per chain",
     "src/BudgetCore.sol", "        return inflight[c] == 0;", "        return true;"),
    ("Z4", "core: a reclaim can time out while its return is pending",
     "src/BudgetCore.sol",
     "                        && pending[_key(K_RECLAIM, r.chain, _liveReclaims[i])].kind == 0\n", ""),
    ("W2", "core: heartbeat 3x slower than configured",
     "src/BudgetCore.sol", "        _beatDue[c] = nowTs + heartbeat;", "        _beatDue[c] = nowTs + 3 * heartbeat;"),
    ("W9", "config: production reclaim timeout = wait / 2",
     "src/reactive/TestnetConfig.sol",
     "        p.reclaimTimeout = uint32(wait) + 2 * p.verifyTimeout;",
     "        p.reclaimTimeout = uint32(wait) / 2;"),
    ("W10", "config: production want TTL 10 min",
     "src/reactive/TestnetConfig.sol", "        p.wantTtl = p.reclaimTimeout;", "        p.wantTtl = 10 minutes;"),
    ("W12", "config: production grant timeout 10 h",
     "src/reactive/TestnetConfig.sol", "        p.grantTimeout = 10 minutes;", "        p.grantTimeout = 10 hours;"),
    ("W15", "core: a reclaim is sized to the first short chain's want only (old sizing)",
     "src/BudgetCore.sol",
     "            if (w.amount != 0) owed += w.amount > chunk ? w.amount : chunk;",
     "            if (w.amount != 0 && owed == 0) owed = w.amount;"),
    ("W14", "core: no backoff reset when a chain shows it is alive",
     "src/BudgetCore.sol", "        epochTries[c] = 0;\n        uint256 id = _inflightId[c];", "        return;\n        uint256 id = _inflightId[c];"),
]


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "list":
        for m in MUTANTS:
            print(f"{m[0]}\t{m[1]}")
        return
    if len(sys.argv) == 4 and sys.argv[1] == "apply":
        mid, root = sys.argv[2], pathlib.Path(sys.argv[3])
        for m in MUTANTS:
            if m[0] == mid:
                path = root / m[2]
                src = path.read_text()
                if src.count(m[3]) != 1:
                    sys.exit(f"patch {mid}: expected 1 match in {m[2]}, found {src.count(m[3])}")
                path.write_text(src.replace(m[3], m[4]))
                return
        sys.exit(f"no patch mutant {mid}")
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
