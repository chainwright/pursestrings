// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {BudgetCore} from "../../src/BudgetCore.sol";
import {SpendWallet} from "../../src/SpendWallet.sol";
import {Vault} from "../../src/Vault.sol";
import {OwnerConsole} from "../../src/OwnerConsole.sol";
import {IERC20Min, IWalletEvents, IConsoleEvents} from "../../src/interfaces/IPursestrings.sol";
import {BudgetCoreHarness} from "./BudgetCoreHarness.sol";
import {MutantCore, MutantWallet} from "../mutants/Mutants.sol";
import {MockToken} from "../mocks/MockToken.sol";

/// The network model. It owns one in-memory queue of messages in both directions:
///   core -> wallet : callback payloads (Intent events of the core)
///   wallet/console -> core : origin events, as raw logs
/// and lets the fuzzer deliver in order, reorder, drop, duplicate and delay them, and reorg a
/// wallet transaction. A reorg runs the transaction on a competing branch: its events escape to
/// the reactive side at once, the branch stays alive for `window` seconds (0 = instant orphan),
/// and while it is alive a re-read (verify) sent to that chain may be served from it. Then the
/// branch is abandoned; the transaction is re-included later or lost. The model keeps
/// window < the chain's confirmation wait: that is the assumption the design rests on.
///
/// Ghosts, kept from the test's own record of what the owner did and what the network delivered,
/// never from the contracts under test:
///   - the owner's cap for each day (invariant a);
///   - when STOP is in effect on each chain and which grants belong to its epoch (invariant b);
///   - the owner's intent (stopped or not), checked after the network heals (invariant s).
contract NetworkHandler is Test {
    uint8 public constant N = 3;
    uint256 public constant CAP = 20e6; // $20, 6 decimals
    uint256 public constant FLOOR = 2e6;
    uint256 public constant LOW = 1e6;
    uint256 public constant PER_CALL = 10e6;
    uint256 public constant MAX_QUEUE = 400;
    /// After the network heals: rounds of (deliver everything, 5 min pass, Cron tick, every agent
    /// retries). 40 rounds = 3h20m, above the longest retry backoff (300 s x 32 = 2h40m).
    uint256 public constant HEAL_ROUNDS = 40;
    uint256 public constant HEAL_STEP = 300;

    address public constant OWNER = address(0xA11CE);
    address public constant AGENT = address(0xA6E47);
    address public constant PAYEE = address(0xBEEF);
    address public constant BRIDGE = address(0xB21D6E);
    uint8 public constant FROM_CONSOLE = 255;

    BudgetCoreHarness public core;
    OwnerConsole public console;
    SpendWallet[3] public wallets;
    Vault[3] public vaults;
    MockToken[3] public tokens;

    struct Msg {
        bool toWallet;
        uint8 chain;
        bytes data; // toWallet: calldata. toCore: abi.encode(bytes32[] topics, bytes data)
    }

    /// A transaction on a competing branch of `chain`, alive until `until`.
    struct Branch {
        uint8 chain;
        uint64 at;
        uint64 until;
        bytes data;
    }

    /// The queue is qs[qh .. qs.length): a deque, so in-order delivery from the front is O(1)
    /// (a mutant that floods the network must not make the model itself quadratic).
    Msg[] internal qs;
    uint256 internal qh;
    Msg[] internal late; // held back by the network, released much later
    Msg[64] internal history; // recently delivered, for late redelivery (replay)
    uint256 internal hcount;
    Branch[] internal branches;

    bool public immutable chaosOn;
    uint64 public immutable startDay;
    uint256 internal callSeq;

    // ---- ghost: the owner's cap per day
    mapping(uint64 => uint256) public ownerCapOfNonce; // what the owner set, by console nonce
    uint64 public ownerCapIssued;
    uint64 public gCapNonce; // newest owner cap message delivered to the coordinator
    uint256 public gCfgCap; // the owner's cap in that message
    mapping(uint64 => uint256) public gDayCap; // the owner's cap for day d (0 = day not open)

    // ---- ghost: owner intent for STOP (sequence numbers of owner actions)
    uint256 internal ownerSeq;
    uint256 public gLastPressSeq;
    uint8 public gLastPressChain;
    uint256 public gLastUnstopSeq;

    // ---- ghost: STOP in effect per chain (invariant b)
    uint256 public violations;
    string public firstViolation;
    uint256 public stopViolations;
    string public firstStopViolation;
    bool[3] public gFrozen;
    uint64[3] public gEpoch;
    uint64[3] public gPressMark;
    uint64[3] public gPressAcked;
    uint256[3] public gGrantSinceRoll;
    uint256[3] public gOutSinceRoll;
    uint256[3] public gOutSeen;
    mapping(uint256 => bool) internal gCounted;
    uint256[3] public lastNeed; // last refused amount per chain (liveness test)
    uint64[3] public partitionUntil;

    // ---- coverage counters
    uint256 public paysOk;
    uint256 public paysRefused;
    uint256 public delivered;
    uint256 public dropped;
    uint256 public duplicated;
    uint256 public orphaned;
    uint256 public delayedReorgs;
    uint256 public branchReads;
    uint256 public stops;
    uint256 public unstops;
    uint256 public capChanges;
    uint256 public withdraws;
    uint256 public daysCrossed;
    uint256 public outages;
    uint256 public delayed;
    uint256 public partitions;
    uint256 public heals;
    uint256 public healsWhileStopped;
    uint256 public staleGrants; // grants delivered with an epoch older than the wallet's
    uint256 public staleGrantsUnfrozen; // ... while the wallet was not frozen
    uint256 public freshStaleUnfrozen; // ... and not yet seen/tombstoned: the only rule-6 path
    uint256 public replayed;
    uint256 public grantsSent;
    uint256 public reclaimsSent;
    uint256 public cancelsSent;
    uint256 public credits;
    uint256 public voidsSeen;
    uint256 public maxQueue;

    constructor(uint256 mutant, bool chaos_) {
        chaosOn = chaos_;
        startDay = uint64(block.timestamp / 1 days);
        // Model time is compressed: waits of 1-3 min per chain (production: 16-30 min, see
        // TestnetConfig). What the model keeps is the relation the design rests on: every reorg
        // window is shorter than its chain's wait.
        uint64[] memory waits = new uint64[](N);
        waits[0] = 60;
        waits[1] = 90;
        waits[2] = 180;
        BudgetCore.Params memory p = BudgetCore.Params({
            nChains: N,
            cap: CAP,
            keepFloor: FLOOR,
            confirmWaits: waits,
            grantTimeout: 300,
            reclaimTimeout: 300,
            verifyTimeout: 120,
            pregrantWindow: 2 hours,
            wantTtl: 600,
            heartbeat: 1800
        });
        core = mutant == 0 ? new BudgetCoreHarness(p, address(this)) : new MutantCore(p, address(this), mutant);
        console = new OwnerConsole(OWNER);
        gCfgCap = CAP;
        for (uint8 c; c < N; c++) {
            MockToken t = new MockToken();
            Vault v = new Vault(IERC20Min(address(t)), OWNER);
            SpendWallet w = mutant == 0
                ? new SpendWallet(IERC20Min(address(t)), v, BRIDGE, OWNER, AGENT, PER_CALL, FLOOR, LOW)
                : new MutantWallet(IERC20Min(address(t)), v, BRIDGE, OWNER, AGENT, PER_CALL, FLOOR, LOW, mutant);
            vm.startPrank(OWNER);
            v.bind(address(w));
            w.setPayee(PAYEE, true);
            vm.stopPrank();
            t.mint(address(v), 100 * CAP);
            t.watch(address(w), address(v));
            tokens[c] = t;
            vaults[c] = v;
            wallets[c] = w;
        }
    }

    // =========================================================== fuzz actions

    function pay(uint256 cSeed, uint256 amtSeed) public {
        uint8 c = uint8(cSeed % N);
        payExact(c, _bound(amtSeed, CAP / 40, CAP / 4));
    }

    function payExact(uint8 c, uint256 amt) public returns (bool paid) {
        (bool ok, bytes memory ret) =
            _run(address(wallets[c]), AGENT, abi.encodeCall(SpendWallet.pay, (PAYEE, amt, bytes32(++callSeq))));
        paid = ok && abi.decode(ret, (bool));
        if (paid) {
            paysOk++;
            lastNeed[c] = 0;
        } else {
            paysRefused++;
            if (!wallets[c].frozen()) lastNeed[c] = amt;
        }
        _checkStops();
    }

    function deliverNext() public {
        if (_qlen() > 0) _deliverAt(0);
    }

    /// Deliver a batch of 1-16 messages in order (the network is usually faster than the agents).
    function deliverBatch(uint256 s) public {
        uint256 k = 1 + (s % 16);
        for (uint256 i; i < k && _qlen() > 0; i++) {
            _deliverAt(0);
        }
    }

    function deliverAny(uint256 s) public {
        if (_qlen() > 0) _deliverAt(s % _qlen());
    }

    /// Normal time: 1-60 s per step.
    function warp(uint256 s) public {
        _advance(_bound(s, 1, 60));
    }

    /// An outage or a quiet stretch: 1-26 hours pass with nothing delivered; usually crosses a day.
    function outage(uint256 s) public {
        _advance(_bound(s, 1 hours, 26 hours));
        outages++;
    }

    function _advance(uint256 dt) internal {
        uint256 before = block.timestamp / 1 days;
        vm.warp(block.timestamp + dt);
        daysCrossed += block.timestamp / 1 days - before;
    }

    function tick() public {
        _runCore(abi.encodeCall(BudgetCoreHarness.onTick, ()), 0);
    }

    function duplicate(uint256 s) public {
        if (_qlen() == 0 || _qlen() >= MAX_QUEUE) return;
        Msg memory m = qs[qh + s % _qlen()];
        qs.push(m);
        duplicated++;
    }

    /// Now and then the network heals and stays healthy for a few hours; then the owner-level STOP
    /// property is checked (invariant s). Rare, because it is long.
    function heal(uint256 s) external {
        if (!chaosOn || s % 8 != 0) return;
        healAndSettle();
    }

    /// Faults and owner actions; disabled in the liveness model.
    function chaos(uint256 s) external {
        if (!chaosOn) return;
        uint256 op = s % 15;
        uint256 r = s >> 8;
        if (op == 0) {
            if (_qlen() > 0) {
                _removeAt(r % _qlen());
                dropped++;
            }
        } else if (op == 1) {
            duplicate(r);
        } else if (op == 2) {
            _reorg(r);
        } else if (op == 3) {
            if (r % 2 == 0) _pressStop(uint8((r >> 1) % N));
        } else if (op == 4 || op == 12) {
            // the owner lifts STOP only when the dashboard (Lasna) shows it frozen, naming the
            // epoch the dashboard shows
            if (core.frozen()) _ownerUnstop(core.epoch());
        } else if (op == 5) {
            uint256[3] memory caps = [uint256(12e6), 20e6, 30e6];
            _ownerSetCap(caps[r % 3]);
        } else if (op == 6) {
            if (r % 4 != 0) return;
            uint8 c = uint8((r >> 2) % N);
            uint256 bal = tokens[c].balanceOf(address(vaults[c]));
            _run(address(vaults[c]), OWNER, abi.encodeCall(Vault.withdraw, (OWNER, bal)));
            withdraws++;
        } else if (op == 7) {
            uint8 c = uint8(r % N);
            tokens[c].mint(address(vaults[c]), 100 * CAP);
        } else if (op == 8) {
            outage(r);
        } else if (op == 9 || op == 13) {
            // hold a message back (long delay); prefers an in-flight grant, the message whose
            // late arrival the epoch and cancel rules exist for
            if (_qlen() > 0 && late.length < 64) {
                uint256 i = r % _qlen();
                for (uint256 k; k < _qlen(); k++) {
                    uint256 j = (r + k) % _qlen();
                    if (qs[qh + j].toWallet && bytes4(qs[qh + j].data) == SpendWallet.applyGrant.selector) {
                        i = j;
                        break;
                    }
                }
                late.push(qs[qh + i]);
                _removeAt(i);
                delayed++;
            }
        } else if (op == 10) {
            // release up to 8 held-back messages in random order (skipping chains still cut off),
            // possibly long after STOP/unstop or a day change
            for (uint256 k; k < 8 && late.length > 0; k++) {
                uint256 i = uint256(keccak256(abi.encode(r, k))) % late.length;
                Msg memory m = late[i];
                if (m.toWallet && block.timestamp < partitionUntil[m.chain]) continue;
                if (_qlen() >= MAX_QUEUE) break;
                qs.push(m);
                late[i] = late[late.length - 1];
                late.pop();
            }
        } else if (op == 14) {
            // a destination chain is unreachable for 1-30 min (proxy down, congestion, payer in
            // debt): every callback created meanwhile is held back
            uint8 c = uint8(r % N);
            partitionUntil[c] = uint64(block.timestamp + _bound(r >> 8, 60, 1800));
            partitions++;
        } else {
            // late redelivery of something already delivered
            if (hcount > 0 && _qlen() < MAX_QUEUE) {
                uint256 n = hcount < 64 ? hcount : 64;
                qs.push(history[r % n]);
                replayed++;
            }
        }
    }

    // ===================================================== liveness helpers

    /// Deliver everything in order, let confirmation waits pass, tick, repeat.
    function settle() external {
        settleFor(30);
    }

    function settleFor(uint256 rounds) public {
        for (uint256 round; round < rounds; round++) {
            deliverAll();
            vm.warp(block.timestamp + 61);
            tick();
        }
        deliverAll();
    }

    function deliverAll() public {
        uint256 guard;
        while (_qlen() > 0 && guard++ < 1000) {
            _deliverAt(0);
        }
    }

    /// The network heals: held messages are released, partitions end, competing branches are
    /// abandoned, and nothing is dropped any more. For HEAL_ROUNDS rounds everything queued is
    /// delivered in order, 5 minutes pass, Cron ticks, and every agent retries a small payment,
    /// except the agent on the chain where the owner last pressed STOP, which stays idle (the
    /// runaway agent is usually elsewhere; a lost press must not depend on that agent).
    /// Then the owner-level STOP property is checked:
    ///   - every wallet is at the coordinator's epoch (no payment can use an older epoch);
    ///   - if the owner's last action was a STOP (pressed after the last unstop was issued), the
    ///     coordinator is frozen, every chain is frozen, and no payment succeeds on any chain.
    function healAndSettle() public {
        heals++;
        for (uint256 i; i < late.length; i++) {
            qs.push(late[i]);
        }
        delete late;
        for (uint8 c; c < N; c++) {
            partitionUntil[c] = 0;
        }
        delete branches;
        for (uint256 round; round < HEAL_ROUNDS; round++) {
            deliverAll();
            vm.warp(block.timestamp + HEAL_STEP);
            tick();
            for (uint8 c; c < N; c++) {
                if (ownerStopped() && c == gLastPressChain) continue;
                payExact(c, CAP / 40);
            }
        }
        deliverAll();
        _checkOwnerStop();
    }

    function queueLength() external view returns (uint256) {
        return _qlen();
    }

    /// Debug view: the selector (to wallet) or topic0 (to core) of queued message i.
    function queueAt(uint256 i) external view returns (bool toWallet, uint8 chain, bytes32 tag) {
        return _tagOf(qs[qh + i]);
    }

    function ownerStopped() public view returns (bool) {
        return gLastPressSeq > gLastUnstopSeq;
    }

    // ================================================ directed-test controls
    // `tag` is the selector (to a wallet) or topic0 (to the core); chain 255 is the console.

    function ownerPressStop(uint8 c) external {
        _pressStop(c);
    }

    function ownerUnstop(uint64 e) external {
        _ownerUnstop(e);
    }

    function ownerSetCap(uint256 nc) external {
        _ownerSetCap(nc);
    }

    function count(bool toWallet, bytes32 tag, uint8 chain) external view returns (uint256 n) {
        for (uint256 i; i < _qlen(); i++) {
            if (_matches(qs[qh + i], toWallet, tag, chain)) n++;
        }
    }

    function deliverFirst(bool toWallet, bytes32 tag, uint8 chain) external {
        _deliverAt(_find(toWallet, tag, chain));
    }

    function dropFirst(bool toWallet, bytes32 tag, uint8 chain) external {
        _removeAt(_find(toWallet, tag, chain));
        dropped++;
    }

    function dropAll(bool toWallet, bytes32 tag, uint8 chain) external {
        for (uint256 i = _qlen(); i > 0; i--) {
            if (_matches(qs[qh + i - 1], toWallet, tag, chain)) _removeAt(i - 1);
        }
    }

    function holdFirst(bool toWallet, bytes32 tag, uint8 chain) external {
        uint256 i = _find(toWallet, tag, chain);
        late.push(qs[qh + i]);
        _removeAt(i);
    }

    function releaseHeld() external {
        for (uint256 i; i < late.length; i++) {
            qs.push(late[i]);
        }
        delete late;
    }

    function duplicateFirst(bool toWallet, bytes32 tag, uint8 chain) external {
        qs.push(qs[qh + _find(toWallet, tag, chain)]);
    }

    /// Reorg the first matching callback on a branch that lives `window` seconds (any window,
    /// also deeper than the wait, so a test can show what the assumption protects).
    function reorgFirst(bytes32 tag, uint8 chain, uint64 window, bool lost) external {
        _reorgAt(_find(true, tag, chain), window, lost);
    }

    /// Deliver the first matching verify, served from the live competing branch of its chain.
    function deliverOnBranch(uint8 chain) external {
        uint256 i = _find(true, bytes32(SpendWallet.verify.selector), chain);
        Msg memory m = qs[qh + i];
        _removeAt(i);
        require(_branchAlive(chain), "no live branch");
        _deliver(m, true);
    }

    function ownerWithdrawVault(uint8 c) external {
        uint256 bal = tokens[c].balanceOf(address(vaults[c]));
        _run(address(vaults[c]), OWNER, abi.encodeCall(Vault.withdraw, (OWNER, bal)));
        withdraws++;
    }

    /// Redeliver a matching message from the delivery history (nth = 0: the newest).
    function replay(bool toWallet, bytes32 tag, uint8 chain, uint256 nth) external {
        uint256 n = hcount < 64 ? hcount : 64;
        for (uint256 k; k < n; k++) {
            Msg memory m = history[(hcount - 1 - k) % 64];
            if (_matches(m, toWallet, tag, chain)) {
                if (nth == 0) {
                    qs.push(m);
                    return;
                }
                nth--;
            }
        }
        revert("not in history");
    }

    /// The first safety rule that does not hold right now, or "" (used by the directed tests).
    /// (a) is checked first, so a message starting with "(a) paid out" means a real overspend.
    function safetyFailure() external view returns (string memory) {
        uint64 last = uint64(block.timestamp / 1 days) + 1;
        for (uint64 d = startDay; d <= last; d++) {
            if (_outflow(d) > gDayCap[d]) return "(a) paid out more than the owner's cap for the day";
        }
        for (uint64 d = startDay; d <= last; d++) {
            if (core.capOfDay(d) != gDayCap[d]) return "(a) day cap differs from the owner's configured cap";
        }
        if (violations > 0) return firstViolation;
        if (stopViolations > 0) return firstStopViolation;
        uint64 t = uint64(block.timestamp / 1 days);
        for (uint64 d = t; d <= t + 1; d++) {
            for (uint8 c; c < N; c++) {
                (uint128 allowance,) = wallets[c].buckets(d);
                if (allowance > core.heldOf(d, c)) return "(e) wallet allowance above coordinator's held";
            }
        }
        for (uint8 c; c < N; c++) {
            if (wallets[c].liveUnspent() > tokens[c].balanceOf(address(wallets[c]))) {
                return "allowance > balance";
            }
        }
        return "";
    }

    function outflowOfDay(uint64 d) external view returns (uint256) {
        return _outflow(d);
    }

    // ============================================================ internals

    function _outflow(uint64 d) internal view returns (uint256 out) {
        for (uint256 c; c < N; c++) {
            out += tokens[c].outflow(address(wallets[c]), d);
        }
    }

    function _pressStop(uint8 c) internal {
        (bool ok,) = _run(address(wallets[c]), OWNER, abi.encodeCall(SpendWallet.pressStop, ()));
        if (ok) {
            uint64 mark = uint64(block.timestamp);
            if (mark <= gPressMark[c]) mark = gPressMark[c] + 1;
            gPressMark[c] = mark;
            gFrozen[c] = true;
            gLastPressSeq = ++ownerSeq;
            gLastPressChain = c;
        }
        stops++;
    }

    function _ownerUnstop(uint64 e) internal {
        (bool ok,) = _run(address(console), OWNER, abi.encodeCall(OwnerConsole.unstop, (e)));
        if (ok) gLastUnstopSeq = ++ownerSeq;
        unstops++;
    }

    function _ownerSetCap(uint256 nc) internal {
        (bool ok,) = _run(address(console), OWNER, abi.encodeCall(OwnerConsole.setCap, (nc)));
        if (ok) ownerCapOfNonce[++ownerCapIssued] = nc;
        capChanges++;
    }

    /// A reorg on some wallet's chain, shallower than that chain's confirmation wait.
    function _reorg(uint256 r) internal {
        if (_qlen() == 0) return;
        uint256 start = r % _qlen();
        for (uint256 k; k < _qlen(); k++) {
            uint256 i = (start + k) % _qlen();
            if (!qs[qh + i].toWallet) continue;
            uint64 window = uint64((r >> 24) % _wait(qs[qh + i].chain));
            _reorgAt(i, window, (r >> 16) & 1 == 0);
            return;
        }
    }

    /// The callback transaction runs on a branch: its events escape to the reactive side at once,
    /// its state never becomes canonical. The branch stays readable for `window` seconds. The
    /// message is then re-included later (stays queued) or lost.
    function _reorgAt(uint256 i, uint64 window, bool lost) internal {
        Msg memory m = qs[qh + i];
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(BRIDGE);
        (bool ok,) = address(wallets[m.chain]).call(m.data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.revertToStateAndDelete(snap);
        if (ok) {
            _route(logs, true);
            if (window > 0) {
                _pruneBranches();
                if (branches.length < 16) {
                    branches.push(Branch(m.chain, uint64(block.timestamp), uint64(block.timestamp + window), m.data));
                }
                delayedReorgs++;
            }
        }
        if (lost) _removeAt(i);
        orphaned++;
    }

    function _branchAlive(uint8 c) internal view returns (bool) {
        for (uint256 i; i < branches.length; i++) {
            if (branches[i].chain == c && block.timestamp < branches[i].until) return true;
        }
        return false;
    }

    function _pruneBranches() internal {
        for (uint256 i = branches.length; i > 0; i--) {
            if (block.timestamp >= branches[i - 1].until) {
                branches[i - 1] = branches[branches.length - 1];
                branches.pop();
            }
        }
    }

    /// Run a callback on the live competing branch of its chain: the branch's own transactions
    /// (at their original times) on top of the current state, then this one. Only this call's
    /// events escape; then the branch is dropped again.
    function _runOnBranch(Msg memory m) internal {
        uint256 nowTs = block.timestamp;
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        for (uint256 i; i < branches.length; i++) {
            Branch memory b = branches[i];
            if (b.chain != m.chain || nowTs >= b.until) continue;
            vm.warp(b.at);
            vm.prank(BRIDGE);
            (bool okB,) = address(wallets[m.chain]).call(b.data);
            okB;
        }
        vm.warp(nowTs);
        vm.getRecordedLogs(); // the branch's own events already escaped when it was created
        vm.prank(BRIDGE);
        (bool ok,) = address(wallets[m.chain]).call(m.data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.revertToStateAndDelete(snap);
        vm.warp(nowTs);
        if (ok) _route(logs, true);
        branchReads++;
    }

    function _deliverAt(uint256 i) internal {
        Msg memory m = qs[qh + i];
        _removeAt(i);
        bool onBranch = chaosOn && m.toWallet && bytes4(m.data) == SpendWallet.verify.selector && _branchAlive(m.chain)
            && uint256(keccak256(abi.encode(delivered, block.timestamp))) % 2 == 0;
        _deliver(m, onBranch);
    }

    function _deliver(Msg memory m, bool onBranch) internal {
        delivered++;
        history[hcount % 64] = m;
        hcount++;
        if (m.toWallet) {
            if (onBranch) {
                _runOnBranch(m);
            } else {
                if (bytes4(m.data) == SpendWallet.applyGrant.selector) {
                    (uint256 gid,,, uint64 ge) = abi.decode(_tail(m.data), (uint256, uint64, uint256, uint64));
                    if (ge < gEpoch[m.chain] && !gFrozen[m.chain] && !wallets[m.chain].seen(gid)) {
                        freshStaleUnfrozen++;
                    }
                }
                (bool ok,) = _run(address(wallets[m.chain]), BRIDGE, m.data);
                if (ok) _ghostOnWallet(m.chain, m.data);
            }
        } else {
            _feedCore(m.chain, m.data);
        }
        _checkStops();
    }

    function _run(address target, address sender, bytes memory cd) internal returns (bool ok, bytes memory ret) {
        vm.recordLogs();
        vm.prank(sender);
        (ok, ret) = target.call(cd);
        _route(vm.getRecordedLogs(), false);
    }

    /// A call into the coordinator. Also keeps the owner-cap ghost: a day's cap is the owner's cap
    /// from the newest cap message delivered when the day opened, raised by any newer, higher
    /// owner cap delivered while the day is open (today or tomorrow).
    function _runCore(bytes memory cd, uint64 capNonce) internal {
        uint64 t = uint64(block.timestamp / 1 days);
        bool open0 = core.isOpen(t);
        bool open1 = core.isOpen(t + 1);
        (bool ok,) = _run(address(core), address(this), cd);
        if (!ok) return;
        if (capNonce > gCapNonce) {
            gCapNonce = capNonce;
            gCfgCap = ownerCapOfNonce[capNonce];
            if (open0 && gCfgCap > gDayCap[t]) gDayCap[t] = gCfgCap;
            if (open1 && gCfgCap > gDayCap[t + 1]) gDayCap[t + 1] = gCfgCap;
        }
        if (!open0 && core.isOpen(t)) gDayCap[t] = gCfgCap;
        if (!open1 && core.isOpen(t + 1)) gDayCap[t + 1] = gCfgCap;
    }

    function _route(Vm.Log[] memory logs, bool walletOnly) internal {
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            bytes32 t0 = l.topics[0];
            if (l.emitter == address(core)) {
                if (walletOnly) continue;
                if (t0 == BudgetCoreHarness.Intent.selector) {
                    _push(true, uint8(uint256(l.topics[1])), abi.decode(l.data, (bytes)));
                } else if (t0 == BudgetCore.GrantSent.selector) {
                    grantsSent++;
                } else if (t0 == BudgetCore.ReclaimSent.selector) {
                    reclaimsSent++;
                } else if (t0 == BudgetCore.CancelSent.selector) {
                    cancelsSent++;
                } else if (t0 == BudgetCore.Credited.selector) {
                    credits++;
                }
                continue;
            }
            if (l.emitter == address(console)) {
                if (!walletOnly) _push(false, FROM_CONSOLE, abi.encode(l.topics, l.data));
                continue;
            }
            for (uint8 c; c < N; c++) {
                if (l.emitter == address(wallets[c])) {
                    if (_subscribed(t0)) _push(false, c, abi.encode(l.topics, l.data));
                    if (t0 == IWalletEvents.GrantNotApplied.selector) voidsSeen++;
                    break;
                }
            }
        }
    }

    function _subscribed(bytes32 t0) internal pure returns (bool) {
        return t0 == IWalletEvents.Short.selector || t0 == IWalletEvents.LowWater.selector
            || t0 == IWalletEvents.GrantApplied.selector || t0 == IWalletEvents.GrantNotApplied.selector
            || t0 == IWalletEvents.Reclaimed.selector || t0 == IWalletEvents.CancelAck.selector
            || t0 == IWalletEvents.Rolled.selector || t0 == IWalletEvents.EpochAck.selector
            || t0 == IWalletEvents.StopPressed.selector || t0 == IWalletEvents.Verified.selector;
    }

    function _push(bool toWallet, uint8 c, bytes memory data) internal {
        if (toWallet && block.timestamp < partitionUntil[c] && late.length < 64) {
            late.push(Msg(toWallet, c, data));
            return;
        }
        if (_qlen() >= MAX_QUEUE) return; // a full network queue loses messages
        qs.push(Msg(toWallet, c, data));
        if (_qlen() > maxQueue) maxQueue = _qlen();
    }

    /// Remove entry i, keeping the order of the rest (shifts the i entries before it).
    function _removeAt(uint256 i) internal {
        for (uint256 k = i; k > 0; k--) {
            qs[qh + k] = qs[qh + k - 1];
        }
        delete qs[qh];
        qh++;
    }

    function _qlen() internal view returns (uint256) {
        return qs.length - qh;
    }

    function _tagOf(Msg memory m) internal pure returns (bool, uint8, bytes32) {
        if (m.toWallet) return (true, m.chain, bytes32(bytes4(m.data)));
        (bytes32[] memory topics,) = abi.decode(m.data, (bytes32[], bytes));
        return (false, m.chain, topics[0]);
    }

    function _matches(Msg memory m, bool toWallet, bytes32 tag, uint8 chain) internal pure returns (bool) {
        (bool w, uint8 c, bytes32 t) = _tagOf(m);
        return w == toWallet && c == chain && t == tag;
    }

    function _find(bool toWallet, bytes32 tag, uint8 chain) internal view returns (uint256) {
        for (uint256 i; i < _qlen(); i++) {
            if (_matches(qs[qh + i], toWallet, tag, chain)) return i;
        }
        revert("no such message queued");
    }

    function _wait(uint8 c) internal view returns (uint64) {
        return core.confirmWaitOf(c);
    }

    function _feedCore(uint8 c, bytes memory enc) internal {
        (bytes32[] memory topics, bytes memory data) = abi.decode(enc, (bytes32[], bytes));
        bytes32 t0 = topics[0];
        bytes memory cd;
        uint64 capNonce;
        if (c == FROM_CONSOLE) {
            if (t0 == IConsoleEvents.CapSet.selector) {
                (uint64 nonce, uint256 nc) = abi.decode(data, (uint64, uint256));
                cd = abi.encodeCall(BudgetCoreHarness.onCapSet, (nonce, nc));
                capNonce = nonce;
            } else if (t0 == IConsoleEvents.Unstop.selector) {
                (uint64 nonce, uint64 e) = abi.decode(data, (uint64, uint64));
                cd = abi.encodeCall(BudgetCoreHarness.onUnstop, (nonce, e));
            }
        } else if (t0 == IWalletEvents.Short.selector) {
            (uint64 day, uint256 shortBy,) = abi.decode(data, (uint64, uint256, uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onShort, (c, day, shortBy));
        } else if (t0 == IWalletEvents.LowWater.selector) {
            (uint64 day,,) = abi.decode(data, (uint64, uint256, uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onLowWater, (c, day));
        } else if (t0 == IWalletEvents.GrantApplied.selector) {
            cd = abi.encodeCall(BudgetCoreHarness.onGrantApplied, (c, uint256(topics[1])));
        } else if (t0 == IWalletEvents.GrantNotApplied.selector) {
            (, uint64 ts) = abi.decode(data, (uint8, uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onGrantNotApplied, (c, uint256(topics[1]), ts));
        } else if (t0 == IWalletEvents.Reclaimed.selector) {
            (, uint256 amount, uint64 ts) = abi.decode(data, (uint64, uint256, uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onReclaimed, (c, uint256(topics[1]), amount, ts));
        } else if (t0 == IWalletEvents.CancelAck.selector) {
            (bool applied, uint64 ts) = abi.decode(data, (bool, uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onCancelAck, (c, uint256(topics[2]), applied, ts));
        } else if (t0 == IWalletEvents.Rolled.selector) {
            (uint64 day, uint256 r0, uint256 r1, uint64 ts) = abi.decode(data, (uint64, uint256, uint256, uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onRolled, (c, uint64(uint256(topics[1])), day, r0, r1, ts));
        } else if (t0 == IWalletEvents.EpochAck.selector) {
            (, uint64 ts) = abi.decode(data, (bool, uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onEpochAck, (c, uint64(uint256(topics[1])), ts));
        } else if (t0 == IWalletEvents.StopPressed.selector) {
            uint64 mark = abi.decode(data, (uint64));
            cd = abi.encodeCall(BudgetCoreHarness.onStopPressed, (c, mark));
        } else if (t0 == IWalletEvents.Verified.selector) {
            BudgetCore.Echo memory v = abi.decode(data, (BudgetCore.Echo));
            cd = abi.encodeCall(BudgetCoreHarness.onVerified, (c, v));
        }
        if (cd.length > 0) _runCore(cd, capNonce);
    }

    // ------------------------------------------------------- STOP ghosts

    /// Mirrors, independently of the wallet's storage, when STOP has taken effect on a chain and
    /// which grants belong to the wallet's current epoch.
    function _ghostOnWallet(uint8 c, bytes memory cd) internal {
        bytes4 sel = bytes4(cd);
        bytes memory args = _tail(cd);
        if (sel == SpendWallet.applyGrant.selector) {
            (uint256 id,, uint256 amount, uint64 e) = abi.decode(args, (uint256, uint64, uint256, uint64));
            if (e < gEpoch[c]) {
                staleGrants++;
                if (!gFrozen[c]) staleGrantsUnfrozen++;
            }
            if (e > gEpoch[c]) _gRoll(c, e);
            if (e == gEpoch[c] && !gFrozen[c] && !gCounted[id]) {
                gCounted[id] = true;
                gGrantSinceRoll[c] += amount;
            }
        } else if (sel == SpendWallet.applyEpoch.selector) {
            (uint64 e, bool fz, uint64 ps) = abi.decode(args, (uint64, bool, uint64));
            if (e < gEpoch[c]) return;
            if (ps > gPressAcked[c]) gPressAcked[c] = ps;
            if (e > gEpoch[c]) _gRoll(c, e);
            gFrozen[c] = fz || gPressMark[c] > gPressAcked[c];
        }
    }

    function _gRoll(uint8 c, uint64 e) internal {
        gEpoch[c] = e;
        gGrantSinceRoll[c] = 0;
        gOutSinceRoll[c] = 0;
        gFrozen[c] = gPressMark[c] > gPressAcked[c];
    }

    /// Invariant (b), checked after every action:
    ///  - from real token outflows: nothing leaves a wallet while STOP is in effect on its chain,
    ///    and after the wallet enters a new epoch it pays out no more than that epoch's grants;
    ///  - stricter: after an epoch change no older-epoch allowance is even spendable
    ///    (unspent + paid since the change <= grants of the new epoch).
    function _checkStops() internal {
        for (uint8 c; c < N; c++) {
            uint256 tot = tokens[c].outflowTotal(address(wallets[c]));
            uint256 delta = tot - gOutSeen[c];
            if (delta > 0) {
                gOutSeen[c] = tot;
                if (gFrozen[c]) _violate("(b) paid while STOP in effect");
                gOutSinceRoll[c] += delta;
                if (gOutSinceRoll[c] > gGrantSinceRoll[c]) _violate("(b) paid from an older epoch's allowance");
            }
            if (wallets[c].liveUnspent() + gOutSinceRoll[c] > gGrantSinceRoll[c]) {
                _violate("(b) older epoch's allowance still spendable");
            }
        }
    }

    /// Invariant (s), checked at the end of healAndSettle().
    function _checkOwnerStop() internal {
        if (ownerStopped()) healsWhileStopped++;
        uint64 e = core.epoch();
        for (uint8 c; c < N; c++) {
            if (wallets[c].epoch() != e) {
                _violateStop("(s) a wallet is still on an older epoch after the network healed");
            }
        }
        if (!ownerStopped()) return;
        if (!core.frozen()) _violateStop("(s) the owner's STOP was lifted by an unstop issued before it");
        for (uint8 c; c < N; c++) {
            if (!wallets[c].frozen()) _violateStop("(s) the owner's STOP did not reach every chain in time");
        }
        for (uint8 c; c < N; c++) {
            if (payExact(c, CAP / 40)) _violateStop("(s) paid after STOP had time to reach every chain");
        }
    }

    function _violate(string memory why) internal {
        if (violations == 0) firstViolation = why;
        violations++;
    }

    function _violateStop(string memory why) internal {
        if (stopViolations == 0) firstStopViolation = why;
        stopViolations++;
    }

    function _tail(bytes memory cd) internal pure returns (bytes memory out) {
        out = new bytes(cd.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = cd[i + 4];
        }
    }
}
