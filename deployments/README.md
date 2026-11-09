# Deployments

`latest.json` holds the addresses of the live testnet deployment of 07.11.2026 UTC (06.11 evening
CST), written by `script/Deploy.s.sol`. No secrets. `dryrun.json` (gitignored) is the local anvil
rehearsal's.

The creation hashes below were checked read-only on 09.11 UTC (08.11 evening CST; `cast receipt <hash> contractAddress`
returns the address). Use this table, not the contract names in forge's multi-chain record:
`broadcast/multi/Deploy.s.sol-latest/run.json` names the Unichain Sepolia contracts after the Base
Sepolia ones at the same addresses (it calls the Unichain front `OwnerConsole`), and it has the
Lasna CREATE with no hash and no receipt, because the public Lasna RPC refused forge's broadcast
(fee cap) and the same initcode was sent with `cast send --create` (see
`live/LIVE_RUN_2026-11-07.md`, step C).

Deployer and owner: `0xeE7F470E1C47431b033F8638E932a9ebfFB3cbfc`. Agent:
`0xf22aE6D4425cD74a4B1e04705ba71a4EAD6D2b14`.

| Chain | Contract | Address | Creation tx |
|---|---|---|---|
| Lasna (5318007) | PursestringsReactive (coordinator) | [`0x7B8111CDF7001721469c584Fa9613369F0E7aC1E`](https://lasna.reactscan.net/address/0x7B8111CDF7001721469c584Fa9613369F0E7aC1E) | [`0x2798f59845663e8ff42519707a15a3112ea0b6643381f941d06ff05d3992c0ad`](https://lasna.reactscan.net/tx/0x2798f59845663e8ff42519707a15a3112ea0b6643381f941d06ff05d3992c0ad) (4,593,296 gas at 110 gwei legacy = 0.505 lREACT; 23 Subscribe events) |
| Base Sepolia (84532) | OwnerConsole | `0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d` | [`0xa9b4e44964a4e78c1e8039608c2549c9cfc931e4c994c3c7feabe93b98eed9a6`](https://base-sepolia.blockscout.com/tx/0xa9b4e44964a4e78c1e8039608c2549c9cfc931e4c994c3c7feabe93b98eed9a6) |
| Base Sepolia | CallbackFront | `0xEDe676F068c225315a3973BCdefB40364C26567d` | [`0xf7fa34d322a16e9e836240b280d995728a140e3f0f7d9c5a2c0c5c7a0bfdc737`](https://base-sepolia.blockscout.com/tx/0xf7fa34d322a16e9e836240b280d995728a140e3f0f7d9c5a2c0c5c7a0bfdc737) |
| Base Sepolia | Vault | `0xb80D1f2176d721c77A08EA1450B8266293d675de` | [`0x61c461b7a9fe8f4d69ec9495e03daca08b773bd75ec2fc1a51008b69ad38aeea`](https://base-sepolia.blockscout.com/tx/0x61c461b7a9fe8f4d69ec9495e03daca08b773bd75ec2fc1a51008b69ad38aeea) |
| Base Sepolia | SpendWallet | `0x8e0c2ad73ef5e7Eb7630126195A37D74C3BD939e` | [`0x856f3b998435a08078d9efe15552380fa453dc7bc9c6c823a8c565a62d60238a`](https://base-sepolia.blockscout.com/tx/0x856f3b998435a08078d9efe15552380fa453dc7bc9c6c823a8c565a62d60238a) |
| Unichain Sepolia (1301) | CallbackFront | `0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d` | [`0x039787e1e8183ba0378004c7cf32e242ac11655a3a11b5bd249d964655a4dc27`](https://sepolia.uniscan.xyz/tx/0x039787e1e8183ba0378004c7cf32e242ac11655a3a11b5bd249d964655a4dc27) |
| Unichain Sepolia | Vault | `0xEDe676F068c225315a3973BCdefB40364C26567d` | [`0x8ed514dbfc9e70f106f773a488fc747b2d1e94ce1c3255bb3a274906764a560c`](https://sepolia.uniscan.xyz/tx/0x8ed514dbfc9e70f106f773a488fc747b2d1e94ce1c3255bb3a274906764a560c) |
| Unichain Sepolia | SpendWallet | `0xb80D1f2176d721c77A08EA1450B8266293d675de` | [`0x5f7c71b1d1f51f111115da7b929855a73c29170e3bf71ae71346e5ae4e87a60d`](https://sepolia.uniscan.xyz/tx/0x5f7c71b1d1f51f111115da7b929855a73c29170e3bf71ae71346e5ae4e87a60d) |

Base Sepolia binds: vault `0x1a0e7fcb…a6a0`, front `0x78ac826b…1948`, wallet payee `0xbcedfc99…14f6`.
Unichain Sepolia binds: `0xeb5f8ce8…65ba`, `0xb16aabd6…2aff`, `0x7812deb8…7df8` (full hashes in the
broadcast record).

Same addresses on both L2s are expected: the deployer's nonce sequence is the same on each chain,
and Base deploys one more contract (the console) first.

## Source verification (09.11.2026 UTC)

All eight contracts are verified on Sourcify with an **exact match** on both the creation and the
runtime bytecode, metadata hash included. `src/`, `lib/` (submodule commits), `foundry.toml` and
`remappings.txt` are unchanged since the deploy commit `0a2e273` (`git diff 0a2e273 HEAD -- src lib
foundry.toml remappings.txt` is empty), and each on-chain creation input starts byte for byte with
the creation bytecode `forge build` produces at HEAD. Settings: solc 0.8.29, optimizer on, 200 runs,
EVM `cancun`, no via-IR. Constructor arguments were taken from each creation tx's input (the bytes
after the creation bytecode), not from forge's multi-chain record, whose Unichain arguments are
mislabeled. Base Sepolia's and Unichain Sepolia's Blockscout pick the Sourcify match up and show
each contract as fully verified.

| Chain | Contract | Address | Verifier | Status |
|---|---|---|---|---|
| Lasna (5318007) | PursestringsReactive | `0x7B8111CDF7001721469c584Fa9613369F0E7aC1E` | Sourcify | [exact match](https://repo.sourcify.dev/5318007/0x7B8111CDF7001721469c584Fa9613369F0E7aC1E) |
| Base Sepolia (84532) | OwnerConsole | `0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d` | Sourcify (+ Blockscout) | [exact match](https://repo.sourcify.dev/84532/0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d), [Blockscout](https://base-sepolia.blockscout.com/address/0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d?tab=contract) |
| Base Sepolia | CallbackFront | `0xEDe676F068c225315a3973BCdefB40364C26567d` | Sourcify (+ Blockscout) | [exact match](https://repo.sourcify.dev/84532/0xEDe676F068c225315a3973BCdefB40364C26567d), [Blockscout](https://base-sepolia.blockscout.com/address/0xEDe676F068c225315a3973BCdefB40364C26567d?tab=contract) |
| Base Sepolia | Vault | `0xb80D1f2176d721c77A08EA1450B8266293d675de` | Sourcify (+ Blockscout) | [exact match](https://repo.sourcify.dev/84532/0xb80D1f2176d721c77A08EA1450B8266293d675de), [Blockscout](https://base-sepolia.blockscout.com/address/0xb80D1f2176d721c77A08EA1450B8266293d675de?tab=contract) |
| Base Sepolia | SpendWallet | `0x8e0c2ad73ef5e7Eb7630126195A37D74C3BD939e` | Sourcify (+ Blockscout) | [exact match](https://repo.sourcify.dev/84532/0x8e0c2ad73ef5e7Eb7630126195A37D74C3BD939e), [Blockscout](https://base-sepolia.blockscout.com/address/0x8e0c2ad73ef5e7Eb7630126195A37D74C3BD939e?tab=contract) |
| Unichain Sepolia (1301) | CallbackFront | `0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d` | Sourcify (+ Blockscout) | [exact match](https://repo.sourcify.dev/1301/0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d), [Blockscout](https://unichain-sepolia.blockscout.com/address/0x9C1E06984DC361226EB9db2f14A089f93b1Fe12d?tab=contract) |
| Unichain Sepolia | Vault | `0xEDe676F068c225315a3973BCdefB40364C26567d` | Sourcify (+ Blockscout) | [exact match](https://repo.sourcify.dev/1301/0xEDe676F068c225315a3973BCdefB40364C26567d), [Blockscout](https://unichain-sepolia.blockscout.com/address/0xEDe676F068c225315a3973BCdefB40364C26567d?tab=contract) |
| Unichain Sepolia | SpendWallet | `0xb80D1f2176d721c77A08EA1450B8266293d675de` | Sourcify (+ Blockscout) | [exact match](https://repo.sourcify.dev/1301/0xb80D1f2176d721c77A08EA1450B8266293d675de), [Blockscout](https://unichain-sepolia.blockscout.com/address/0xb80D1f2176d721c77A08EA1450B8266293d675de?tab=contract) |

Check any row: `curl -s https://sourcify.dev/server/v2/contract/<chainId>/<address>` returns
`"match":"exact_match"`. To reproduce a verification:
`forge verify-contract <address> <path>:<Contract> --chain <chainId> --verifier sourcify --constructor-args <hex> --compiler-version 0.8.29 --num-of-optimizations 200 --evm-version cancun --watch`.
The callback proxies (`0x476F…3585` on Base Sepolia, `0x775c…66C1` on Unichain Sepolia) and the
system contract `0x8888…8888` on Lasna belong to Reactive Network, not to this deployment.

## Loop transactions of 07.11 (smoke steps D and E)

| Step | Chain | Tx |
|---|---|---|
| fundReserves 3 lREACT (system contract `depositTo`) | Lasna | `0x07c4b39cd6ce1dae0e426aae7767475e350765a1e731705c0cd802fafec9db22` |
| fundReserves 0.002 ETH to the front | Base Sepolia | `0x52d43386b131733ca18b2e928635c90c7382dc1e878763a70c3d4475f3a3adcf` |
| fundReserves 0.002 ETH to the front | Unichain Sepolia | `0xde7cb6d2c3226198939184c7174ae60b8b4ce75413330a27789675d2e134e776` |
| fundVault $4 | Base Sepolia | `0x9266a1e55add1085f0c7c8ab8c96f7db8e84c426045cb1de975b0d09c4d73dd3` |
| fundVault $4 | Unichain Sepolia | `0x68ffbad85b963797227e2d146067ae17012f87e113fbbaf1fdb102aa862ded4d` |
| fundAgent 0.0005 ETH | Base Sepolia | `0x9de892c114f900cdf6dc536d4ddf2fc38326fdc447dcec174eb9b8b9a283554f` |
| fundAgent 0.0005 ETH | Unichain Sepolia | `0x899b5dabfe4b71512d4bea4a75784278d9723822b94204a7630b2bf69a9a2c9a` |
| top-up origin: `pay` $1 refused (Short) | Base Sepolia | `0xf1af94ab6c150801e0286e6df36dafeeab0f0c8a2d90671964623ba39069f63b` |
| its reactive tx (GrantSent #1) | Lasna | `0xe72a615502dd0aab162c94a9e6f7cd348b119709d1eeb27c85c301a6b44f76ff` |
| its answer: GrantApplied #1, 2 s after the origin | Base Sepolia | `0xe553555026eaeae975876be51773b5dec52ca7014f9eca7a23e3700b5045682c` |
| STOP origin: `pressStop` | Unichain Sepolia | `0x2422cae8cc5abc77f7ec104708ec6ea1e56a8f5b6c9b4ac09b52e1321a657d35` |
| its reactive tx (Frozen 1) | Lasna | `0xc1bb73a4b21fcbfe014c93c4eda1e04719f727b1ec2418b9af25625bcd34e900` |
| EpochAck(1, frozen), 2 s after the press | Base Sepolia | `0x324710ed5b61a18c07a520f1c4bf195d631008363165be9764eee6598218ef1c` |
| EpochAck(1, frozen) | Unichain Sepolia | `0x10ada01fbab0e7c25632d85bc1f8b3551f7a2792d70f5c0123d2d31d22462a6e` |
| unstop (epoch 1, console) | Base Sepolia | `0x81966d46a64f6a90715de770850ee0da04384317536d5eb8c9c3c79ad7879be2` |

Explorers: Lasna `https://lasna.reactscan.net/tx/<hash>`, Base Sepolia
`https://base-sepolia.blockscout.com/tx/<hash>`, Unichain Sepolia `https://sepolia.uniscan.xyz/tx/<hash>`.
