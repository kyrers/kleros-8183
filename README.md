# Kleros x 8183 PoC

Proof of concept integrating [Kleros V2](https://github.com/kleros/kleros-v2) dispute resolution with [ERC-8183 (Agentic Commerce)](https://eips.ethereum.org/EIPS/eip-8183) as the job evaluator.

The 8183 escrow is consumed **untouched** from the reference implementation ([erc-8183/base-contracts](https://github.com/erc-8183/base-contracts)), pinned as a git submodule at [main commit](https://github.com/erc-8183/base-contracts/commit/142e669c1fd318486a4628395b629f033654dd06).

## Design

Kleros integrates as the job's **evaluator**, via the `KlerosEvaluator` contract. The lifecycle of a job:

1. The client creates and funds the job on the escrow, naming `KlerosEvaluator` as evaluator, then calls `acceptJob(jobId)`. The contract checks that it really is the job's evaluator, that the job is funded, and that `expiredAt` leaves enough room for a possible dispute. If any check fails, it rejects the job on the escrow, instantly refunding the client. `canAccept(jobId)` exposes the creation-time checks (evaluator, expiry) so the client can verify before funding. Jobs never accepted are ignored entirely, so naming this contract as evaluator without its consent has no effect.
2. The provider submits work on the escrow, committing a content hash, and registers the content reference and that same hash with the evaluator via `registerDeliverable`, so jurors can access and verify the actual work done, if a dispute arises.
3. To dispute, the client calls `challenge(jobId)` within `challengeWindow`, paying the arbitration fee, which is forwarded to the arbitrator (excess refunded). If the window passes silently instead, anyone can call `finalize(jobId)` and the contract calls `complete()` on the escrow.
4. The ruling comes back via `rule()`: acceptable → `complete()`; not acceptable → `reject()`; refuse to arbitrate → default path, `complete()`.

### Juror information

Jurors must have the relevant information in the case page. Three pieces make that possible:

- **Dispute template and data mappings** ([template/](template/)) contains a `dispute-template` and a `data-mappings` that are registered on Kleros' template registry by the constructor.
- **`KlerosEvaluatorView`** is a read-only aggregator returning everything the template needs in a single call as a named struct. One deployment serves every evaluator on the chain; its address goes into `data-mappings.json`. Struct returns are used deliberately here, so information can be decoded identically across the different kleros-sdk versions deployed. For a production version, this might not be needed, or a better alternative might be possible.
- **The dispute policy** ([template/policy.md](template/policy.md), pinned on IPFS) instructs jurors: verify the registered content hashes to the committed deliverable; judge it against the agreement; non-disclosure is a reject, never a refuse-to-arbitrate. This is, of course, a mock policy used for the PoC, but it contains useful information.

### Decisions & PoC limitations

- **Submitted work is assumed correct unless the client challenges.** The alternative, assuming incorrect, would require paying for arbitration on every job. Disputes should only exist on actual disagreement.
- **Only the client can challenge.** The optimistic default already favors the provider, so the client is the only party silence can hurt.
- **Refuse to arbitrate completes the job.** Jurors declining to rule falls back to the default outcome. Any default favors one side; this one is consistent with the optimistic design.
- **No arbitration fee return.** The client pays the arbitration fee and is not refunded, even if he wins.
- **Claims are ignored.** The escrow's claim system gets no policy in v1.
- **Rulings are binary.** `complete()` or `reject()` is all the current spec allows a ruling to enforce.
- **Evaluator fees exist.** Even if Kleros wants no evaluator fee, only the escrow's admin (a given marketplace) sets them. To integrate with marketplaces that force evaluator fees, the `KlerosEvaluator` contract owner can collect them via `collectEvaluatorFees`, otherwise fees would just be lost.
- **Provider committing on the escrow is not enough.** The escrow only emits the commitment hash in an event, which neither contracts nor the case page can read reliably, so `registerDeliverable` exists for the provider to be able to point jurors to the actual work delivered, and also to restate the hash committed to in the escrow contract. The escrow's event stays the authoritative commitment: a lying restatement just diverges from the provider's own escrow commitment, which the client can prove in the evidence tab and the jurors will punish with a reject, according to the PoC policy.
- **The template is immutable.** It is registered once at construction; changing it means redeploying the evaluator. A production integration might want governed template versioning.
- **Interfaces match the current mainnet/testnet deployments.** They lag some existing changes on the dev branches, but it means this PoC works on the deployed protocol today.
- **One evaluator instance per escrow.** Job ids are just counters, so one evaluator for multiple escrows would have conflicting job ids. If in the future, we have multiple evaluators integrating with multiple escrows, we should put the marketplace's identity in the template title, so the case title in the court can make it clear which marketplace a given dispute refers to.

## Testnet deployment

All contracts are deployed and verified on Arbitrum Sepolia, interacting with the Kleros v2 testnet and using the Agentic Commerce Court. The disputes have the following settings: 3 jurors per dispute, classic dispute kit, and arbitration cost of 0.00081 ETH.

| Contract | Address |
| --- | --- |
| ERC8183 escrow (proxy, their code untouched) | `0x3745128DcE892cD86B926E7F3f1cE50C5Fa2F736` |
| ERC8183 implementation | `0xA4009B2a06f24b5639Cf070Da9F8A9436A69Afcd` |
| KlerosEvaluator | `0xf26b4FA85507914Ae0d3C58ac0D3A30c9C493103` |
| KlerosEvaluatorView | `0xA36902CF1922732bAE257e1bdb3A4b942262c0e2` |
| Payment token (Circle testnet USDC) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Kleros KlerosCore | `0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479` |
| Kleros DisputeTemplateRegistry | `0xe763d31Cb096B4bc7294012B78FC7F148324ebcb` |

Earlier evaluator iterations exist on-chain (`0xD7E9…9600`, `0xd2AC…59BA`, `0x6026…fe37`, `0x8059…6554`). These were part of the tests and abandoned after a problem was found that required a new evaluator deployment.

## Demo

Every settlement path ran on the real testnet court, against real contracts, with a real AI juror staked on the Agentic Commerce Court.

- **Refusal with refund**: the evaluator refuses a job whose expiry is inside the margin and rejects it on the escrow with reason `"expiry inside margin"`, refunding the client in the same transaction.
- **Optimistic completion**: work submitted and disclosed, nobody challenges, permissionless `finalize` completes with reason `"no challenge within window"`; the provider is paid and the 2% evaluator fee accrues to the evaluator.
- **Disputed jobs** — three disputes under the same agreement:

| Case | Delivery | Honest verdict |
| --- | --- | --- |
| [83](https://v2-testnet.kleros.builders/#/cases/83/overview) | A page satisfying the agreement | Yes, accept |
| [84](https://v2-testnet.kleros.builders/#/cases/84/overview) | An "Under construction." page | No, reject |
| [85](https://v2-testnet.kleros.builders/#/cases/85/overview) | Nothing registered | No, reject (policy rule 1) |

Note that every ruled settlement carries its dispute id as the escrow's reason, so each job's final state permanently cites the dispute that decided it.

## Setup

Requires [Foundry](https://getfoundry.sh/).

```bash
git clone --recursive git@github.com:documes/kleros-8183.git
```

If already cloned without `--recursive`, fetch the submodules (including the escrow's own nested dependencies):

```bash
git submodule update --init --recursive
```

## Build & test

```bash
forge build
```

```bash
forge test
```

## Reproducing the demo

If the system is not deployed on the wanted chain, deploy the once-per-chain pieces first: `script/DeployEvaluatorView.s.sol`, then put the contract address in `template/data-mappings.json`. Then:

```bash
forge script script/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --private-key $DEPLOYER_PK --broadcast
```

deploys the escrow and the evaluator, registering the dispute template from `template/`. Optionally, verify with the same command plus `--resume --verify --verifier-url 'https://api.etherscan.io/v2/api?chainid=CHAIN_ID' --etherscan-api-key $KEY`.

The demo scenarios live in [script/test_scenarios/](script/test_scenarios/) and run with two funded wallets (client and provider, because the escrow forbids them being the same):

```bash
CLIENT_PK=0x... PROVIDER_PK=0x... forge script script/test_scenarios/RefuseAndRefund.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast
```

same for `OptimisticCompletion.s.sol` (call `finalize(jobId)` on the evaluator after the `challengeWindow`) and `DisputedJobs.s.sol` (pays 3 × 0.00081 ETH of arbitration fees).
