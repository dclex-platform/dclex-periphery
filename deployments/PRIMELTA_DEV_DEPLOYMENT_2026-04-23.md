# Primelta-Dev V3 Periphery + Router Redeploy — 2026-04-23

Cross-repo record: [`primedelta-monorepo/dclex-blockchain/deployments/PRIMELTA_DEV_DEPLOYMENT_2026-04-23.md`](../../dclex-blockchain/deployments/PRIMELTA_DEV_DEPLOYMENT_2026-04-23.md).

Partial redeploy replacing the V3 stack + Router after a `POOL_INIT_CODE_HASH` drift made every V3 op fail with a `0x` revert. Core contracts from 2026-04-21 (Factory, DID, dUSD, Vault, 44 DclexPools) are unchanged; all seeded DclexPool liquidity and the `protocolFeeRate=15%` setting were preserved by re-registering the existing pool addresses on the new Router.

## Root cause
`lib/v3-periphery/contracts/libraries/PoolAddress.sol::POOL_INIT_CODE_HASH` was a stale literal. The value differs between compiler pipelines — the standalone `UniswapV3Pool` artifact (no `--via-ir`) hashes to `0x2076fc70…`, but the `--via-ir` bytecode that the factory actually deploys hashes to `0x54488334146a9568201119ab62bd8fcc957d3c9a15289c14f66505c87d5e6b89`. The periphery (SwapRouter/Quoter/NonfungiblePositionManager) was computing pool addresses against the wrong hash, landing at empty addresses, so `slot0()` reverted and every swap/quote/mint fell over silently.

## Mitigation landed in `lib/v3-periphery`
- **`PoolAddress.sol`** — hash updated to the `--via-ir` value with a comment explaining the pipeline dependence (do NOT read from `out/` JSON).
- **`test/PoolInitCodeHash.t.sol`** — guard test comparing `keccak256(type(UniswapV3Pool).creationCode)` against the constant. Fails CI loudly if v3-core / solc / optimizer settings shift again.
- `RedeployV3PoolsAndRouter.s.sol` asserts `PoolAddress.computeAddress(factory, key) == actualPoolAddr` for every pool it creates so an on-chain deploy can't silently land a mismatch.

## New addresses
| Contract | Address | Note |
|---|---|---|
| DclexV3Factory | `0xcF1c2099b16E36Dc50DdC357D995fB36D515d772` | unaffected by hash bug (uses CREATE2 directly), but redeployed as part of the fresh V3 stack |
| V3 SwapRouter | `0x49B67797A04DaC9523998893aC019d6aF69fC936` | rebuilt with corrected PoolAddress |
| V3 Quoter | `0xd23ad7d69d892f2ccABFF2E78cb2e46751B49295` | rebuilt with corrected PoolAddress |
| DclexPositionManager | `0x3f4C141153B1994bcb72D22d37a8073f58981Ad6` | rebuilt with corrected PoolAddress |
| DclexRouter | `0x63D09D33b3f0DaCA5C1d85392B53D0cdCBCFEb4e` | wired to new SwapRouter + Quoter |
| WDEL/dUSD V3 pool | `0x41810C6ea4dD96B18324Dcb792e0a8428b857534` | created on new Factory, initialized at $10/DEL |
| AMMT1/dUSD V3 pool | `0x8a702eAF3133fF8c810e11992E4876eAe2a09208` | created on new Factory, initialized at $10 |
| AMMT2/dUSD V3 pool | `0x931b3305C2118f2fbD2BaEd624dc1B8687DAD915` | created on new Factory, initialized at $20 |

## Unchanged from 2026-04-21
| Contract | Address |
|---|---|
| Factory | `0xb39CA4095bf1E2e617df5aD898e058A58939C50F` |
| DigitalIdentity | `0xAb8C84125E0380736f0e1cC9f73A249c82417cA1` |
| dUSD (Stablecoin) | `0x1A71DF49ea92867bda910b948Da588383a0450Ee` |
| Vault | `0xb0E19D426c737dAe9deE8dAeB95C6d2491882204` |
| FIOracle | `0x9dbcf50e357172d490ee5e428d75129a6224a2e9` |
| WDEL | `0x1bb6D126516554F935cF8C0E9C70280088A5CE60` |
| AMMT1 stock | `0x7944ae74CC109A300FB375001b825caf7870B4b7` |
| AMMT2 stock | `0x972561188FF2C3DBebe4E60D158dee9623b8048A` |
| 44 canonical DclexPools | preserved — re-registered on new Router via `setCustomPool` |

## Router state (post-deploy)
- `Router.usdc()` = `0x1A71DF49ea92867bda910b948Da588383a0450Ee` (dUSD) ✓
- `Router.v3SwapRouter()` = `0x49B67797A04DaC9523998893aC019d6aF69fC936` ✓
- `Router.v3Quoter()` = `0xd23ad7d69d892f2ccABFF2E78cb2e46751B49295` ✓
- `Router.owner()` = `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` (admin) ✓
- `Router.allStockTokens().length` = 47 (44 custom + 3 AMM) ✓

## Services to roll
- **Frontend (DEX)**: `primedelta-dex` — updated `.github/workflows/build-and-deploy-dex-dev.yaml` with new SwapRouter / PositionManager / Quoter. Push to `main` to trigger build.
- **Backend / Tasks / Admin**: `primedelta-gitops/apps/dev/primedelta-{backend,tasks,admin}/values.yaml` — updated `UNISWAP_V3_FACTORY_ADDRESS` + `UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_ADDRESS`.

## Scripts added
- `script/RedeployV3Peripheral.s.sol` — rebuilds SwapRouter + Quoter + PositionManager against an existing Factory/WDEL when only the periphery hash needs fixing.
- `script/RedeployV3PoolsAndRouter.s.sol` — creates 3 V3 AMM pools on the new Factory, mints DIDs, deploys a fresh DclexRouter, copies 44 custom-pool mappings from the old Router, registers the 3 new AMM pools, transfers ownership.

## Gotcha captured
Don't trust `out/UniswapV3Pool.sol/UniswapV3Pool.json::bytecode.object` — it can be stale from a pre-`--via-ir` build. Ground truth is `keccak256(type(UniswapV3Pool).creationCode)` measured at runtime by `PoolInitCodeHashTest`, against the same compiler pipeline that actually deploys the pools.
