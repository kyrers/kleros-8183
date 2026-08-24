# Kleros x 8183 PoC

Proof of concept integrating [Kleros V2](https://github.com/kleros/kleros-v2) dispute resolution with [ERC-8183 (Agentic Commerce)](https://eips.ethereum.org/EIPS/eip-8183) as the job evaluator.

The 8183 escrow is consumed **untouched** from the reference implementation ([erc-8183/base-contracts](https://github.com/erc-8183/base-contracts)), pinned as a git submodule at [main commit](https://github.com/erc-8183/base-contracts/commit/142e669c1fd318486a4628395b629f033654dd06).

## Design

Kleros integrates as the job's **evaluator**, via the `KlerosEvaluator` contract. The lifecycle of a job:

1. The client creates and funds the job on the escrow, naming `KlerosEvaluator` as evaluator, then calls `acceptJob(jobId)`. The contract checks that it really is the job's evaluator, that the job is funded, and that `expiredAt` leaves enough room for a possible dispute. If any check fails, it rejects the job on the escrow, instantly refunding the client. `canAccept(jobId)` exposes the creation-time checks (evaluator, expiry) so the client can verify before funding. Jobs never accepted are ignored entirely, so naming this contract as evaluator without its consent has no effect.
2. The provider submits work. The client then has `challengeWindow` to dispute. If the window passes silently, anyone can call `finalize(jobId)` and the contract calls `complete()` on the escrow.
3. To dispute, the client calls `challenge(jobId)` within the window, paying the arbitration fee, which is forwarded to the arbitrator (excess refunded). Jurors decide whether the submission should be accepted.
4. The ruling comes back via `rule()`: acceptable → `complete()`; not acceptable → `reject()`; refuse to arbitrate → default path, `complete()`.

### Decisions & PoC limitations

- **Submitted work is assumed correct unless the client challenges.** The alternative, assuming incorrect, would require paying for arbitration on every job. Disputes should only exist on actual disagreement.
- **Only the client can challenge.** The optimistic default already favors the provider, so the client is the only party silence can hurt.
- **Refuse to arbitrate completes the job.** Jurors declining to rule falls back to the default outcome. Any default favors one side; this one is consistent with the optimistic design.
- **No arbitration fee return.** The client pays the arbitration fee and is not refunded, even if he wins.
- **Claims are ignored.** The escrow's claim system gets no policy in v1.
- **Rulings are binary.** `complete()` or `reject()` is all the current spec allows a ruling to enforce.

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
