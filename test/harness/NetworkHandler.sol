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
/// and lets the fuzzer deliver in order, reorder, drop, duplicate and delay them, and orphan a
/// wallet transaction (a reorg: its state is rolled back but its events already escaped to the
/// reactive side and stay in the queue). It also keeps the STOP ghosts used by invariant (b).
contract NetworkHandler is Test {
    uint8 public constant N = 3;
    uint256 public constant CAP = 20e6; // $20, 6 decimals
    uint256 public constant FLOOR = 2e6;
    uint256 public constant LOW = 1e6;
    uint256 public constant PER_CALL = 10e6;
    uint256 public constant MAX_QUEUE = 400;

    address public constant OWNER = address(0xA11CE);
    address public constant AGENT = address(0xA6E47);
    address public constant PAYEE = address(0xBEEF);
    address public constant BRIDGE = address(0xB21D6E);
    uint8 internal constant FROM_CONSOLE = 255;

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

    Msg[] internal q;
    Msg[] internal late; // held back by the network, released much later
    Msg[64] internal history; // recently delivered, for late redelivery (replay)
    uint256 internal hcount;

    bool public immutable chaosOn;
    uint64 public immutable startDay;
    uint256 internal callSeq;

    // ---- ghosts
    uint256 public ghostMaxCap;
    uint256 public violations;
    string public firstViolation;
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
    uint256 public stops;
    uint256 public unstops;
    uint256 public capChanges;
    uint256 public withdraws;
    uint256 public daysCrossed;
    uint256 public outages;
    uint256 public delayed;
    uint256 public partitions;
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
        BudgetCore.Params memory p = BudgetCore.Params({
            nChains: N,
            cap: CAP,
            keepFloor: FLOOR,
            confirmWait: 60,
            grantTimeout: 300,
            reclaimTimeout: 300,
            verifyTimeout: 120,
            pregrantWindow: 2 hours,
            wantTtl: 600
        });
        core = mutant == 0 ? new BudgetCoreHarness(p, address(this)) : new MutantCore(p, address(this), mutant);
        console = new OwnerConsole(OWNER);
        ghostMaxCap = CAP;
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
        if (q.length > 0) _deliverAt(0);
    }

    /// Deliver a batch of 1-16 messages in order (the network is usually faster than the agents).
    function deliverBatch(uint256 s) public {
        uint256 k = 1 + (s % 16);
        for (uint256 i; i < k && q.length > 0; i++) {
            _deliverAt(0);
        }
    }

    function deliverAny(uint256 s) public {
        if (q.length > 0) _deliverAt(s % q.length);
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
        _run(address(core), address(this), abi.encodeCall(BudgetCoreHarness.onTick, ()));
    }

    function duplicate(uint256 s) public {
        if (q.length == 0 || q.length >= MAX_QUEUE) return;
        Msg memory m = q[s % q.length];
        q.push(m);
        duplicated++;
    }

    /// Faults and owner actions; disabled in the liveness model.
    function chaos(uint256 s) external {
        if (!chaosOn) return;
        uint256 op = s % 15;
        uint256 r = s >> 8;
        if (op == 0) {
            if (q.length > 0) {
                _removeAt(r % q.length);
                dropped++;
            }
        } else if (op == 1) {
            duplicate(r);
        } else if (op == 2) {
            _orphan(r);
        } else if (op == 3) {
            if (r % 2 == 0) _pressStop(uint8((r >> 1) % N));
        } else if (op == 4 || op == 12) {
            // the owner lifts STOP only when the dashboard (Lasna) shows it frozen
            if (core.frozen()) {
                _run(address(console), OWNER, abi.encodeCall(OwnerConsole.unstop, (core.epoch())));
                unstops++;
            }
        } else if (op == 5) {
            uint256[3] memory caps = [uint256(12e6), 20e6, 30e6];
            uint256 nc = caps[r % 3];
            if (nc > ghostMaxCap) ghostMaxCap = nc;
            _run(address(console), OWNER, abi.encodeCall(OwnerConsole.setCap, (nc)));
            capChanges++;
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
            if (q.length > 0 && late.length < 64) {
                uint256 i = r % q.length;
                for (uint256 k; k < q.length; k++) {
                    uint256 j = (r + k) % q.length;
                    if (q[j].toWallet && bytes4(q[j].data) == SpendWallet.applyGrant.selector) {
                        i = j;
                        break;
                    }
                }
                late.push(q[i]);
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
                if (q.length >= MAX_QUEUE) break;
                q.push(m);
                late[i] = late[late.length - 1];
                late.pop();
            }
        } else if (op == 14) {
            // a destination chain is unreachable for 1-30 min (proxy down, congestion, payer in
            // debt): every callback to it is held back, then released out of order
            uint8 c = uint8(r % N);
            partitionUntil[c] = uint64(block.timestamp + _bound(r >> 8, 60, 1800));
            partitions++;
        } else {
            // late redelivery of something already delivered
            if (hcount > 0 && q.length < MAX_QUEUE) {
                uint256 n = hcount < 64 ? hcount : 64;
                q.push(history[r % n]);
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
            uint256 guard;
            while (q.length > 0 && guard++ < 500) {
                _deliverAt(0);
            }
            vm.warp(block.timestamp + 61);
            tick();
        }
        uint256 g2;
        while (q.length > 0 && g2++ < 500) {
            _deliverAt(0);
        }
    }

    function queueLength() external view returns (uint256) {
        return q.length;
    }

    /// Debug view: the selector (to wallet) or topic0 (to core) of queued message i.
    function queueAt(uint256 i) external view returns (bool toWallet, uint8 chain, bytes32 tag) {
        Msg memory m = q[i];
        if (m.toWallet) return (true, m.chain, bytes32(bytes4(m.data)));
        (bytes32[] memory topics,) = abi.decode(m.data, (bytes32[], bytes));
        return (false, m.chain, topics[0]);
    }

    // ============================================================ internals

    function _pressStop(uint8 c) internal {
        (bool ok,) = _run(address(wallets[c]), OWNER, abi.encodeCall(SpendWallet.pressStop, ()));
        if (ok) {
            uint64 mark = uint64(block.timestamp);
            if (mark <= gPressMark[c]) mark = gPressMark[c] + 1;
            gPressMark[c] = mark;
            gFrozen[c] = true;
        }
        stops++;
    }

    /// A reorg on wallet c's chain: the callback transaction ran, its events escaped to the
    /// reactive side, then its block was orphaned. Its state is rolled back. With probability 1/2
    /// the message is re-included later (stays queued), else it is lost.
    function _orphan(uint256 r) internal {
        if (q.length == 0) return;
        uint256 start = r % q.length;
        for (uint256 k; k < q.length; k++) {
            uint256 i = (start + k) % q.length;
            if (!q[i].toWallet) continue;
            Msg memory m = q[i];
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            vm.prank(BRIDGE);
            (bool ok,) = address(wallets[m.chain]).call(m.data);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            vm.revertToStateAndDelete(snap);
            if (ok) _route(logs, true);
            if ((r >> 16) & 1 == 0) _removeAt(i);
            orphaned++;
            return;
        }
    }

    function _deliverAt(uint256 i) internal {
        Msg memory m = q[i];
        _removeAt(i);
        delivered++;
        history[hcount % 64] = m;
        hcount++;
        if (m.toWallet) {
            if (bytes4(m.data) == SpendWallet.applyGrant.selector) {
                (uint256 gid,,, uint64 ge) = abi.decode(_tail(m.data), (uint256, uint64, uint256, uint64));
                if (ge < gEpoch[m.chain] && !gFrozen[m.chain] && !wallets[m.chain].seen(gid)) freshStaleUnfrozen++;
            }
            (bool ok,) = _run(address(wallets[m.chain]), BRIDGE, m.data);
            if (ok) _ghostOnWallet(m.chain, m.data);
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
        if (q.length >= MAX_QUEUE) return; // a full network queue loses messages
        q.push(Msg(toWallet, c, data));
        if (q.length > maxQueue) maxQueue = q.length;
    }

    function _removeAt(uint256 i) internal {
        for (uint256 k = i; k + 1 < q.length; k++) {
            q[k] = q[k + 1];
        }
        q.pop();
    }

    function _feedCore(uint8 c, bytes memory enc) internal {
        (bytes32[] memory topics, bytes memory data) = abi.decode(enc, (bytes32[], bytes));
        bytes32 t0 = topics[0];
        bytes memory cd;
        if (c == FROM_CONSOLE) {
            if (t0 == IConsoleEvents.CapSet.selector) {
                (uint64 nonce, uint256 nc) = abi.decode(data, (uint64, uint256));
                cd = abi.encodeCall(BudgetCoreHarness.onCapSet, (nonce, nc));
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
        if (cd.length > 0) _run(address(core), address(this), cd);
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
                if (gFrozen[c]) _violate("paid while STOP in effect");
                gOutSinceRoll[c] += delta;
                if (gOutSinceRoll[c] > gGrantSinceRoll[c]) _violate("paid from an older epoch's allowance");
            }
            if (wallets[c].liveUnspent() + gOutSinceRoll[c] > gGrantSinceRoll[c]) {
                _violate("older epoch's allowance still spendable");
            }
        }
    }

    function _violate(string memory why) internal {
        if (violations == 0) firstViolation = why;
        violations++;
    }

    function _tail(bytes memory cd) internal pure returns (bytes memory out) {
        out = new bytes(cd.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = cd[i + 4];
        }
    }
}
