# Infinite Money Dopamine (IMD)

IMD is a fixed-supply ERC-20. Its constructor mints the entire supply to `msg.sender` once.

| Parameter | Value |
| --- | --- |
| Deployable contract | `src/IMD.sol:IMD` |
| Name | `Infinite Money Dopamine` |
| Symbol | `IMD` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`, encoded as `0x`) |
| Constructor ETH value | `0` |
| Initial recipient | Immediate deploying address |

## Behavior and assumptions

The requested custom behavior is the token's identity and one-time issuance. Transfers use the
unmodified OpenZeppelin ERC-20 implementation: amounts arrive whole, with no fees, burns, rebasing,
wallet limits, or transfer hooks. Zero-value and self-transfers are supported. Transfers to the
zero address and approvals for the zero spender revert. Insufficient balances or allowances
revert atomically, including restoration of any allowance updated by a failed `transferFrom`.

Finite allowances decrease when spent; an allowance of `type(uint256).max` remains unchanged.
`approve` replaces the existing allowance. Minting and transfers emit `Transfer`; approvals emit
`Approval`. OpenZeppelin v5 does not emit an additional `Approval` when `transferFrom` consumes
an allowance. Errors follow ERC-6093.

There is no owner, external mint or burn function, pause, blacklist, seizure, upgrade, initialization,
or rescue mechanism. The supply remains fixed for the lifetime of each deployment. The deployer
has no privileges over other holders and can spend only its own tokens or approved allowances.
Transfers make no external calls. The contract uses no oracle, randomness, signatures, or external
protocol. It is not a proxy and must be deployed directly.

## Build and test

Foundry and Solidity **0.8.26** are required. The verifier provides the compiler; on a fresh developer
machine Foundry may download that pinned compiler once. No compiler binary is included here.

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies are ordinary vendored files under `lib/`: OpenZeppelin Contracts v5.1.0
(the ERC-20 dependency subset) and forge-std v1.9.6 (test sources). Each dependency includes its
upstream license and `PROVENANCE.md` with the source archive and SHA-256. No package installation,
submodules, or network access is needed to build once the pinned compiler is available.

`foundry.toml` pins the compiler, Cancun EVM target, optimizer (200 runs), and `bytecode_hash = "none"`.
FFI is disabled and the filesystem permission list is empty. Tests use fresh local deployments,
no forks, and no environment-variable reads or writes. Unit and fuzz tests cover deployment,
events, transfers, allowances, rejection and rollback cases, attempted privileged calls, and
forbidden runtime opcodes. Stateful invariants compare balances and allowances against an
independent ledger across randomized transfers and approvals, and sum all balances to the fixed
supply. Default settings are 256 runs per fuzz test and 128 runs of up to 64 calls per invariant.

The factory/distributor/pool-address test checks exact ERC-20 movements using local actors. It
does not execute Uniswap swaps. The supplied protected integration harness requires the network's
launch infrastructure and environment; full pool initialization, seeding, and swaps belong to the
independent launch checks. That harness is not part of this standalone project's local test suite.

## Deployment and operations

Deploy `IMD` directly with the creation bytecode, no appended constructor arguments, and no ETH.
For example, a Solidity factory constructs it with `new IMD()` or `new IMD{salt: salt}()`; the
factory itself receives all `10^27` units. An EOA deployment receives the supply at that EOA.
The factory's caller or transaction origin is never substituted for the immediate deployer.

The deployment operator can inspect the ABI and creation bytecode without broadcasting:

```sh
forge inspect src/IMD.sol:IMD abi
forge inspect src/IMD.sol:IMD bytecode
```

The operator is responsible for selecting the chain and confirming Cancun compatibility, securing
the deploying account, verifying the source and pinned compiler settings on an explorer, and
checking the deployed name, symbol, decimals, total supply, initial balance, and mint event before
distribution. For CREATE2, the factory address, salt, and exact creation bytecode determine the
token address. None of these deployment choices is hardcoded in the token.

For IdentityMD, the launch factory owns distribution, the swarm allocation, pool setup and seeding,
and forwarding the remainder. The token imposes no address exemptions or launch restrictions.
No chain addresses, pool configuration, requester economics, or application contracts were provided
for this task. The network's deployer must supply those parameters and its launch manifest; this
project does not invent them. The 60% pool allocation in the local transfer test is illustrative only.

Holders are responsible for key custody, recipient selection, and spending approvals. Prefer
bounded approvals; when replacing an existing nonzero allowance, revoke it first and confirm the
revocation before granting a new allowance to reduce the standard ERC-20 approval race. Unlimited
approvals authorize the spender to use future balances too. Tokens sent to an address that cannot
transfer them, including the token contract itself, cannot be rescued. Ordinary ETH payments
revert; forcibly delivered ETH cannot be recovered. There are no administrative maintenance calls.

Local tests are not an independent security audit. Independent adversarial review and the network's
launch integration checks remain release responsibilities. Slither and Mythril have not been run.
This assignment does not broadcast transactions or access wallet keys.
