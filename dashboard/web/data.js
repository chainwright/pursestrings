// Pursestrings replay data: every number here is copied from the 09.11.2026 live series (real testnet txs).
// Sources, all committed in this repo (dashboard/test_dashboard.py checks the hashes against them):
//   live/series_2026-11-09.jsonl            18 loop traces (origin / Lasna react / callbacks, block timestamps)
//   live/series_2026-11-09_phase4_before.txt snapshot 08:16:31 UTC  (state "open")
//   live/series_2026-11-09_close.txt         snapshot 09:15:25 UTC  (state "paused")
//   live/series_2026-11-09_phase1.txt        snapshot 05:34:38 UTC  (+ GrantApplied#4 -> state "amber" at 05:36:40)
//   broadcast/Loop.s.sol/84532/run-*.json    the 12 Base payments (token Transfer out of the wallet)
//   live/checker_2026-11-09.log              "Over: $0.00", spent $17.00 in 12 transfers (Base), $0.00 (Unichain)
//   live/SERIES_2026-11-09.md                path stats (median/max/n)
//   deployments/latest.json                  chains rendered (N = 2)
window.PS = (function () {
  const deployments = {
    chains: [
      { key: "base", name: "Base Sepolia", short: "Base", chainId: 84532,
        explorer: "https://sepolia.basescan.org/tx/" },
      { key: "unichain", name: "Unichain Sepolia", short: "Unichain", chainId: 1301,
        explorer: "https://sepolia.uniscan.xyz/tx/" }
    ],
    lasna: { name: "Lasna", chainId: 5318007, explorer: "https://lasna.reactscan.net/tx/" }
  };

  const CAP = 20;

  // The 12 payments of 09.11 = Transfer(wallet -> payee) receipts on Base. Unichain made none.
  const payments = [
    { chain: "base", usd: 1, tx: "0xbaca9c2b9ef4934c93e6a27a7c655a491afe12bf51bec7ed09e45ceaceb3a272", block: 56404020, utc: "05:37:52" },
    { chain: "base", usd: 1, tx: "0xb227122bee45067938a3b75964978fc0cee09447ed711be6d000094c159d73bc", block: 56405596, utc: "05:43:08" },
    { chain: "base", usd: 2, tx: "0x875c078d13a0520921cc1adf7bce7c8f9d0cc2a2d5b643d3bd0a305fe273afd0", block: 56406542, utc: "05:46:17" },
    { chain: "base", usd: 2, tx: "0xbade57d6583ae4de0884d97f7534d532f1ba91b0efeea4e5c0f78fff3e595190", block: 56407501, utc: "05:49:29" },
    { chain: "base", usd: 2, tx: "0xe44dac6764f046ece7e0c307a43593ee0d208245ad6cd2bbd1c8b5d86e993784", block: 56407967, utc: "05:51:02" },
    { chain: "base", usd: 2, tx: "0xef34c53129a5c1966275a8429b852aff493b81e4679b59656ed90a76f7ccf2da", block: 56408445, utc: "05:52:37" },
    { chain: "base", usd: 2, tx: "0x6a8f115cb141ef68124717b9af493a3e333578a23a0f0b502c271a72ffcd2b62", block: 56419875, utc: "06:30:43" },
    { chain: "base", usd: 1, tx: "0x1a2585149be0759c20562d433d3fe94805c96dfa82e3119569b830f421f0d38f", block: 56429436, utc: "07:02:36" },
    { chain: "base", usd: 1, tx: "0xb04c2fedecfb55761d4913131781cef37edee6b415e93340d0a961722497ffc8", block: 56430713, utc: "07:06:51" },
    { chain: "base", usd: 1, tx: "0x6baef963e546cb632c061b0d3a22b27576a4bfd34019aefe4c35c82a06dd854d", block: 56440097, utc: "07:38:08" },
    { chain: "base", usd: 1, tx: "0xa65bc8075d23057fc1387b0e75ec501335c2799e86ac5ac5ae3e7928fdc8115f", block: 56441301, utc: "07:42:09" },
    { chain: "base", usd: 1, tx: "0xc561c9b888d4130f4a2a13a36f99189dc1f1333bcf73ec9f2c6bb98c43f6f3dd", block: 56450686, utc: "08:13:26" }
  ];

  // Loop receipts (all 18). ts = origin block timestamp (unix). steps = [label, chainKey, tx, offset s].
  const L = "lasna";
  const loops = [
    { id: "T1", path: "top-up", kind: "refusal", chain: "unichain", ts: 1794202504, utc: "05:35:04", actual: "2 s",
      what: "pay refused (Short) on Unichain → Lasna react → GrantApplied#4 on Unichain",
      steps: [["origin", "unichain", "0x0d05a7a064289e9b0f220117fd74c41434b7535c63204e7242b5712dd0ffcfc8", 0], ["react", L, "0x652bbc0c140fd2ce76dd6da05b4ca88b53c95bb592bdd2ba2487a9631ce62341", -1], ["GrantApplied#4", "unichain", "0x4f2e0500bf4b9f9ae4650113ec8b3fe86cbc0f1bb465fe3679728258a0ea8332", 2]] },
    { id: "T2", path: "top-up", kind: "refusal", chain: "base", ts: 1794202600, utc: "05:36:40", actual: "1 s",
      what: "pay refused (Short) on Base → Lasna react → GrantApplied#5 on Base",
      steps: [["origin", "base", "0xe7629c982f59b7f4e7401b7ede1391e2c6f244d181d8911bf95f7ade7deeb163", 0], ["react", L, "0x0c12f2abf867f4f12519ebdfeace2c2357e0ed2f6df093956ac51541cf42fe7a", -1], ["GrantApplied#5", "base", "0x923a57c6b9edc7df74c9144e6698dc6fd6535d029c875d383a937b9f2360f62c", 1]] },
    { id: "T3", path: "top-up", kind: "refusal", chain: "unichain", ts: 1794202892, utc: "05:41:32", actual: "3 s",
      what: "pay refused (Short) on Unichain → Lasna react → GrantApplied#6 on Unichain",
      steps: [["origin", "unichain", "0x0cf040dcb3f493a26a8300fe7e903d2625bddb2f4c5f925319fd8d4f29c8d83b", 0], ["react", L, "0xb13a093728954040976b56db14304ebfebd19a6db891aa79776ab47e24f4f4b4", 0], ["GrantApplied#6", "unichain", "0xf74b7fb6d3428850abfab70daa0ea07b0ffccb96e4086fb8c93190c1b7c53d6e", 3]] },
    { id: "T4", path: "top-up", kind: "refill ahead", chain: "base", ts: 1794202988, utc: "05:43:08", actual: "2 s",
      what: "paid, running low on Base → Lasna react → GrantApplied#7 on Base",
      steps: [["origin", "base", "0xb227122bee45067938a3b75964978fc0cee09447ed711be6d000094c159d73bc", 0], ["react", L, "0xb7938fd67c7cbb4a087eadcefba6dbadcdebb3fd42af861f6cf17c3f5750a3e0", 0], ["GrantApplied#7", "base", "0xd0d824ca7236259b22b9a92eadd526e32fcadad93951642e9543f75423af357c", 2]] },
    { id: "T5", path: "top-up", kind: "refusal", chain: "unichain", ts: 1794203082, utc: "05:44:42", actual: "2 s",
      what: "pay refused (Short) on Unichain → Lasna react → GrantApplied#8 on Unichain",
      steps: [["origin", "unichain", "0xc62d6727fb592ce82d079b09da442cf0e185838d5a2044411b058c352e797991", 0], ["react", L, "0x09b2507933f3ad98385474c3dfcc1ff4c47c508911bf5aba70e57b22b71f88f7", -1], ["GrantApplied#8", "unichain", "0x2e1fadfb6c038066ae4ad1074f78af1f9f44eaf6e5ebfce506c549ccd5250bdc", 2]] },
    { id: "T6", path: "top-up", kind: "refill ahead", chain: "base", ts: 1794203177, utc: "05:46:17", actual: "1 s",
      what: "paid, running low on Base → Lasna react → GrantApplied#9 on Base",
      steps: [["origin", "base", "0x875c078d13a0520921cc1adf7bce7c8f9d0cc2a2d5b643d3bd0a305fe273afd0", 0], ["react", L, "0xdca230c407867a7a8a7758cabf68e8c3d56b434e0863a04b495c42c3080fa699", -1], ["GrantApplied#9", "base", "0x010b24605ac2f94943768dcd186c3252de59dcfd960fe683be66321ed32025d3", 1]] },
    { id: "T7", path: "top-up", kind: "refusal", chain: "unichain", ts: 1794203270, utc: "05:47:50", actual: "2 s",
      what: "pay refused (Short) on Unichain → Lasna react → GrantApplied#10 on Unichain",
      steps: [["origin", "unichain", "0xe14d6306e6c8b862182196248423e7eece58166f493af2931daf0095715c3be2", 0], ["react", L, "0xf5a909cf09c84d0c6c6916ce52aee6989bbaa6789a8183edcf1215144b09ac35", -1], ["GrantApplied#10", "unichain", "0x1905a5d27b9908b9188df1a87f6cadbbb549e4cd5e188973656fe8628d55364b", 2]] },
    { id: "T8", path: "top-up", kind: "refill ahead", chain: "base", ts: 1794203369, utc: "05:49:29", actual: "1 s",
      what: "paid, running low on Base → Lasna react → GrantApplied#11 on Base",
      steps: [["origin", "base", "0xbade57d6583ae4de0884d97f7534d532f1ba91b0efeea4e5c0f78fff3e595190", 0], ["react", L, "0x8e347e9c36e197e9c077a31ea54bd9fa819697971c1c22c379b29859c5053752", -1], ["GrantApplied#11", "base", "0x446be8cc2abe9431c52708d23d9a337f9e293d750d10e083c4c0b6a74c606d8e", 1]] },
    { id: "T9", path: "top-up", kind: "refill ahead", chain: "base", ts: 1794203462, utc: "05:51:02", actual: "2 s",
      what: "paid, running low on Base → Lasna react → GrantApplied#12 on Base",
      steps: [["origin", "base", "0xe44dac6764f046ece7e0c307a43593ee0d208245ad6cd2bbd1c8b5d86e993784", 0], ["react", L, "0x25bde94f69869e9f823211a490dec1abd5160261b045662cb83b8d751d3caf90", 0], ["GrantApplied#12", "base", "0xf7498560d85f7c89c7a689203e0edc766056333b57f4826f8c1380e99304f02c", 2]] },
    { id: "T10", path: "top-up", kind: "refill ahead", chain: "base", ts: 1794203557, utc: "05:52:37", actual: "2 s",
      what: "paid, running low on Base → Lasna react → GrantApplied#13 on Base",
      steps: [["origin", "base", "0xef34c53129a5c1966275a8429b852aff493b81e4679b59656ed90a76f7ccf2da", 0], ["react", L, "0xd80d23ef4da52bb0e72feddaa4fe75a98a3864ce6d477e4915b2c7d0af4db773", 0], ["GrantApplied#13", "base", "0x468046106d1635fb80856367fea8180ba4fa14a9ce9ad2ab2e5ab520c1b8d053", 2]] },
    { id: "D1", path: "chain-to-chain", kind: "donor", chain: "base", ts: 1794205843, utc: "06:30:43", actual: "31 min 13 s",
      what: "paid, running low on Base → Lasna → Unichain gives up $2 (+3 s) → L2 finality wait → GrantApplied#15 on Base",
      steps: [["origin", "base", "0x6a8f115cb141ef68124717b9af493a3e333578a23a0f0b502c271a72ffcd2b62", 0], ["react", L, "0x4549903286455dda6be4ec54e7b9e9465534b5859ef5089004f1ff313fd314bb", 0], ["reclaim", "unichain", "0xe3ddec4724171323ee70f7e7662b6ddba34e5e85e3e4626a9a00df174f081d39", 3], ["react", L, "0xfa5c7b2d46f83f90fcd59926b194475eadd2f314fa0ad1045e718e8fedac1a8f", 1871], ["GrantApplied#15", "base", "0xfb1d78dbc1da727b6b5c44d20fa277b8bbff4412c828015e04b6fcd690eeeca5", 1873]] },
    { id: "D2", path: "chain-to-chain", kind: "donor", chain: "base", ts: 1794208011, utc: "07:06:51", actual: "30 min 22 s",
      what: "paid, running low on Base → Lasna → Unichain gives up $2 (+3 s) → L2 finality wait → GrantApplied#17 on Base",
      steps: [["origin", "base", "0xb04c2fedecfb55761d4913131781cef37edee6b415e93340d0a961722497ffc8", 0], ["react", L, "0x0831f73fb6ada84a0bf92591db3a8660cff7177c92ab9ce6dec05b144a6c42e3", -1], ["reclaim", "unichain", "0x881c191bb847729c2af12b8c9fcdcfc9438d8b37b39c0138f1c504321e7ffd68", 3], ["react", L, "0x1ec1c71b01fe2473295b25379e9911622c4c5316279d806abbe9c4eba15a1043", 1820], ["GrantApplied#17", "base", "0x972547ab826b115d1f423a208d418db09f4a51b86c5d76454d6e07d2e6e0cf08", 1822]] },
    { id: "D3", path: "chain-to-chain", kind: "donor", chain: "base", ts: 1794210129, utc: "07:42:09", actual: "30 min 24 s",
      what: "paid, running low on Base → Lasna → Unichain gives up $2 (+2 s) → L2 finality wait → GrantApplied#19 on Base",
      steps: [["origin", "base", "0xa65bc8075d23057fc1387b0e75ec501335c2799e86ac5ac5ae3e7928fdc8115f", 0], ["react", L, "0x4fef3320912a3bd57627ca180908c85afc91ded61e0171c713591f51afb2e33e", -1], ["reclaim", "unichain", "0xd0ebca72923de17abcbea762094c2214253f03ed6514b3ead12ff4212911c39d", 2], ["react", L, "0x2053774518ee1bf3112953014d18fe0271467e25a91419216347dcedf7291fdf", 1822], ["GrantApplied#19", "base", "0x7498a5840b527f3329d9e1b56050032135989b7e567872ea99daaac5698ebe60", 1824]] },
    { id: "S1", path: "STOP", kind: "stop", chain: "unichain", ts: 1794212217, utc: "08:16:57", actual: "2 s",
      what: "STOP pressed on Unichain → Lasna react → EpochAck(3, frozen) on Base, on Unichain",
      steps: [["press", "unichain", "0xe9369699aa0a99cb4fa367abb198e34b1f03a6fc5aa2cffe831a5db58685cc11", 0], ["react", L, "0x3272fa208ab0873127825af7f76bb8846ee76f16a5bc29a5392991e6085d7611", -1], ["EpochAck(3, frozen)", "base", "0xccb4b6c17a445aab82da36938a670973ad1b0b390a67c8da3b88c034816cd916", 1], ["EpochAck(3, frozen)", "unichain", "0xf1361f5804b4c54ff4c8b25af0c251a7cd1cbe829d196e2062b436988e8222eb", 2]] },
    { id: "S2", path: "STOP", kind: "stop", chain: "base", ts: 1794212369, utc: "08:19:29", actual: "3 s",
      what: "STOP pressed on Base → Lasna react → EpochAck(5, frozen) on Base, on Unichain",
      steps: [["press", "base", "0x9a41353d38e611b3ea6e4739e784844088304162ac6c6d0e4e9d5e4fa8e7cbda", 0], ["react", L, "0x23bab0c180052f0133313842320b5d6d23d86c547b812a921c3d3aab269c44fc", 0], ["EpochAck(5, frozen)", "base", "0x54e8194c99f1f7589004c2c4eaf5176bce43c60bce12009604fbc5c768205026", 2], ["EpochAck(5, frozen)", "unichain", "0x821d90dc68b6143b8581202205bf2c55fbb3de66fc9704249278d36b69b93eea", 3]] },
    { id: "S3", path: "STOP", kind: "stop", chain: "unichain", ts: 1794212526, utc: "08:22:06", actual: "2 s",
      what: "STOP pressed on Unichain → Lasna react → EpochAck(7, frozen) on Base, on Unichain",
      steps: [["press", "unichain", "0xab9f3f09f09ac73086df25f9f284f6a623afdfb5e2a797b786de4209c79f6136", 0], ["react", L, "0x5ae517808c39544cff36972c6442e0927bdc4e347292de4aecb36f2f5e7f3f59", -1], ["EpochAck(7, frozen)", "base", "0xfe976e10ee2dd2dc556eef72863b9708e517b41ae98d8ee465cea21893c79b22", 1], ["EpochAck(7, frozen)", "unichain", "0xd0b300592598edebfbb078463364d7ab8795abc2985c4a32368c685a34c470ab", 2]] },
    { id: "S4", path: "STOP", kind: "stop", chain: "base", ts: 1794212678, utc: "08:24:38", actual: "2 s",
      what: "STOP pressed on Base → Lasna react → EpochAck(9, frozen) on Base, on Unichain",
      steps: [["press", "base", "0x7ce9e24a5798861adc057e85aeb553c141e25787458ae30e11ea6c31c431987f", 0], ["react", L, "0x5486044db3c8845f1e4577069a7d58bbf1815ab8c7939388612e987f53965f43", -1], ["EpochAck(9, frozen)", "base", "0x13a3468488b6e9bacc912d740b4b9bc0940ef839fc48a2fb118d7d4ff7da10d0", 1], ["EpochAck(9, frozen)", "unichain", "0x804af799e9b91874b170ca8232a61a34a17ef2e4e0304527fb310b3f1dc95f50", 2]] },
    { id: "S5", path: "STOP", kind: "stop", chain: "unichain", ts: 1794212832, utc: "08:27:12", actual: "2 s",
      what: "STOP pressed on Unichain → Lasna react → EpochAck(11, frozen) on Base, on Unichain",
      steps: [["press", "unichain", "0x3cd19fccd43d7c64b9c6491298e3f1b0a1b451a7dcd5fc54499776ba12670a5e", 0], ["react", L, "0x974605a92b077610b69e2da2af7cafaec2619b836531605fdde6645c8d065203", -1], ["EpochAck(11, frozen)", "base", "0xa419a9e355dd9ff2ea3c1069a464ff7796d272d89556afb13c07f06c1c449eea", 2], ["EpochAck(11, frozen)", "unichain", "0x3fda132d6cfd69a9ddf1736179059aa5845592ffd96f284b16e38903e88b22cb", 2]] }
  ];

  // Path stats (SERIES_2026-11-09.md, "Result per path"). Small n, so median and max, not percentiles.
  const stats = [
    { label: "top-up", value: "median 2 s · max 3 s", n: 10 },
    { label: "chain-to-chain", value: "median 30.4 min · max 31.2 min", n: 3 },
    { label: "STOP", value: "median 2 s · max 3 s", n: 5 }
  ];

  // Checker (live/checker_2026-11-09.log): read at head ~10:03 UTC, day still running.
  const checker = { over: 0, spent: 17, cap: 20, readAt: "10:03 UTC", partial: true,
    perChain: { base: { out: 17, n: 12 }, unichain: { out: 0, n: 0 } } };

  // Static states. Each one is a recorded snapshot, except "red", which is labelled as an illustration.
  // money = vault + agent-wallet tokens on that chain (it never leaves the chain).
  const states = {
    open: {
      label: "open", stamp: "snapshot 08:16:31 UTC · before the first STOP", asOf: 1794212191,
      reserve: 0, epoch: 2, paused: false, coordinatorReserves: "1.28 lREACT",
      chains: {
        base: { loop: 1, money: 2, vault: 1, wallet: 1, plate: "open" },
        unichain: { loop: 2, money: 10, vault: 8, wallet: 2, plate: "open" }
      },
      spentUpTo: 12, headline: { label: "CAN STILL LEAVE TODAY", usd: 3 }
    },
    amber: {
      label: "amber", stamp: "recorded 05:36:40 UTC · loop T2", asOf: 1794202600,
      reserve: 18, epoch: 2, paused: false, coordinatorReserves: "2.92 lREACT",
      chains: {
        base: { loop: 0, money: 19, vault: 17.67, wallet: 1.33, plate: "amber", coin: 1 },
        unichain: { loop: 2, money: 10, vault: 6.67, wallet: 3.33, plate: "open" } // after GrantApplied#4 ($2) at 05:35:06
      },
      spentUpTo: 0, headline: { label: "CAN STILL LEAVE TODAY", usd: 20 }
    },
    red: {
      label: "red", illustration: true,
      stamp: "illustration · numbers from 08:16:31 UTC; this $5.00 ask was not made on 09.11",
      asOf: 1794212191, reserve: 0, epoch: 2, paused: false, coordinatorReserves: "1.28 lREACT",
      chains: {
        base: { loop: 1, money: 2, vault: 1, wallet: 1, plate: "red", coin: 5 },
        unichain: { loop: 2, money: 10, vault: 8, wallet: 2, plate: "open" }
      },
      spentUpTo: 12, headline: { label: "CAN STILL LEAVE TODAY", usd: 3, note: "a $5.00 call is more than can still leave → 402" }
    },
    frozen: {
      label: "frozen", stamp: "recorded 08:16:59 UTC · after STOP S1, epoch 3", asOf: 1794212219,
      reserve: 0, epoch: 3, paused: false, coordinatorReserves: "1.28 lREACT",
      chains: {
        base: { loop: 0, knot: 1, money: 2, vault: 2, wallet: 0, plate: "frozen" },
        unichain: { loop: 0, knot: 2, money: 10, vault: 10, wallet: 0, plate: "frozen" }
      },
      spentUpTo: 12, headline: { label: "MOST STILL POSSIBLE DURING FREEZE", usd: 0, sub: "$3.00 left in today's budget · frozen" }
    },
    paused: {
      label: "paused", stamp: "snapshot 09:15:25 UTC · close of the series", asOf: 1794215725,
      reserve: 3, epoch: 12, paused: true, coordinatorReserves: "0 lREACT · debt 0.0142",
      chains: {
        base: { loop: 0, money: 2, vault: 2, wallet: 0, plate: "open" },
        unichain: { loop: 0, money: 10, vault: 10, wallet: 0, plate: "open" }
      },
      spentUpTo: 12, headline: { label: "CAN STILL LEAVE TODAY · AFTER RESUME", usd: 3,
        sub: "$3.00 waits on the spool · right now $0.00 can move" }
    }
  };

  // Replays: offsets are the recorded block-timestamp differences (1 s resolution).
  // Lasna's clock reads ~1 s behind the L2s (SERIES anomaly 5); its react is printed with the origin.
  const replays = {
    stop: {
      from: "open", loop: "S1", t0utc: "08:16:57",
      events: [
        { t: 0, do: "press", chain: "unichain", step: 0 },  // same tx freezes Unichain (SpendWallet.pressStop)
        { t: 0, do: "print", step: 1 },
        { t: 1, do: "ack", chain: "base", step: 2 },      // EpochAck(3, frozen) on Base
        { t: 2, do: "ack", chain: "unichain", step: 3 },  // EpochAck(3, frozen) on Unichain
        { t: 2, do: "end" }
      ]
    },
    topup: {
      from: "amber", loop: "T2", t0utc: "05:36:40",
      events: [
        { t: 0, do: "short", chain: "base", step: 0 },
        // Lasna react (printed with the origin; Lasna clock reads 1 s behind). The $2 outline leaves the spool here
        // and is in flight until GrantApplied, i.e. for exactly the recorded react -> callback interval.
        { t: 0, do: "react", step: 1, travel: { chain: "base", usd: 2, until: 1 } },
        { t: 1, do: "grant", chain: "base", usd: 2, step: 2 }, // GrantApplied#5, $2.00 from the Lasna reserve
        { t: 1.5, do: "skip", to: 71.6, label: "70 s skipped · agent retried 05:37:52" },
        { t: 72, do: "paid", chain: "base", usd: 1, tx: payments[0].tx },
        { t: 72, do: "end" }
      ]
    }
  };

  return { deployments, CAP, payments, loops, stats, checker, states, replays };
})();
