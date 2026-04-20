# Primelta-Dev Periphery + DEX Deployment — 2026-04-21

Authoritative cross-repo record: [`primedelta-monorepo/dclex-blockchain/deployments/PRIMELTA_DEV_DEPLOYMENT_2026-04-21.md`](../../dclex-blockchain/deployments/PRIMELTA_DEV_DEPLOYMENT_2026-04-21.md).

## V3 Infra (DeployV3Production.s.sol)
| Contract | Address |
|---|---|
| WDEL | `0x1bb6d126516554f935cf8c0e9c70280088a5ce60` |
| DclexV3Factory | `0x2eb2bbaaf8d16e8ba07bd40d141a7e25c6dd9945` |
| V3 SwapRouter | `0x4ee108458a4d97daa2f8ef90a73942ac7b3a9209` |
| V3 Quoter | `0x1c3f3a797b80315fad4db7d1a58f3aa934118e03` |
| DclexPositionManager | `0x8fcac40e1302273cac387696ebdaff39fdfa172a` |

## Router + Pools (DeployDclexRouterWithPools.s.sol)
| Contract | Address |
|---|---|
| DclexRouter | `0x1d1aee6d5dc35f3c15e2d11083d0e59c026b64c4` |
| FIOracle | `0x9dbcf50e357172d490ee5e428d75129a6224a2e9` |
| 44 DclexPools | deployed via `BatchPoolDeployer`, paired with canonical dUSD `0x1A71DF49...ee` |

`Router.usdc()` = `0x1A71DF49ea92867bda910b948Da588383a0450Ee` (canonical dUSD) — verified post-deploy.

## DEX — AMM test tokens (DeployAMMStocks.s.sol)
| Symbol | Stock | V3 Pool |
|---|---|---|
| AMMT1 | `0x7944ae74CC109A300FB375001b825caf7870B4b7` | `0x56d0eb7b55EF8c3ff6cA9fc294Aee3577d449A84` |
| AMMT2 | `0x972561188FF2C3DBebe4E60D158dee9623b8048A` | `0x3e115653046d7303081611e50724f728E7a1f48F` |
| WDEL | `0x1bb6d126516554f935cf8c0e9c70280088a5ce60` | `0x78E469Dc15Fb83188142b1A1aec3B83CDe35a28A` |

## Script change this round
`DeployAMMStocks.s.sol` used `IERC20Mintable(_usdc).mint(helper, amount)` which was fine against USDCMock but is a non-existent function on the real `Stablecoin` contract. Swapped for `Factory.forceMintStablecoin("dUSD", helper, amount)` — goes through the factory-admin path (Admin has `DEFAULT_ADMIN_ROLE` on Factory so the call passes).

## Gotchas still current
1. Admin needs `MASTER_ADMIN_ROLE` on DID before running `DeployDclexRouterWithPools.s.sol` (granted by MasterAdmin post-DeployProduction).
2. Don't use `--slow` with 140-tx router+pools script on Besu (hangs). Without `--slow`, completes in ~3 min.
3. `WDEL.mint` is chainId==31337-only — `DeployAMMStocks` skips wDEL liquidity seed on other chains (fix: [dclex-periphery#7](https://github.com/dclex-platform/dclex-periphery/pull/7)).
