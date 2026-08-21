# Kleros x 8183 PoC

Proof of concept integrating [Kleros V2](https://github.com/kleros/kleros-v2) dispute resolution with [ERC-8183 (Agentic Commerce)](https://eips.ethereum.org/EIPS/eip-8183) as the job evaluator.

The 8183 escrow is consumed **untouched** from the reference implementation ([erc-8183/base-contracts](https://github.com/erc-8183/base-contracts)), pinned as a git submodule at [main commit](https://github.com/erc-8183/base-contracts/commit/142e669c1fd318486a4628395b629f033654dd06).

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
