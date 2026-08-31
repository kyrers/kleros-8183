# Kleros ERC-8183 Evaluator Dispute Policy

Basic policy for the Kleros x ERC-8183 evaluator proof of concept. Disputes
under this policy concern one question: does the work a provider submitted
for an escrowed job satisfy the agreement?

## The facts of a case

Each dispute presents three facts, read directly from the blockchain:

- **The agreement**: the job description written on the escrow when the job
  was created. It is immutable from that moment.
- **The deliverable hash**: a commitment the provider placed on the escrow
  when submitting the work. It is immutable from that moment.
- **The registered content**: a reference (e.g. IPFS) to the delivered work,
  registered by the provider with the evaluator contract. It can be replaced
  until the dispute is created, and is frozen from that moment.

Parties may submit additional arguments and material as evidence through the
court.

## What the provider registers

The registered content is a single document; its keccak256 is the deliverable
hash committed on the escrow. It is either:

- **The delivered work itself**, when the work is a file: a page, a report, a
  dataset, an archive of source code.
- **A delivery note**, when the work is not a file (a deployed application, an
  on-chain transfer, service access): a document from which jurors can verify
  delivery using public material only: pointers such as a git commit, a
  transaction hash or a live URL, and snapshots pinning any live state at
  submission time.

Secrets (credentials, API keys) never belong in registered content, which is
public; working access is demonstrated through the evidence tab instead.
Registered content from which delivery cannot be verified counts as no
disclosure under rule 1.

## How to vote

1. Verify the commitment: the registered content must hash (keccak256) to
   the committed deliverable. If no content was registered, or the hash does
   not match, vote **No, reject**: work that was not disclosed, or was
   swapped after submission, cannot be accepted.
2. If the commitment checks out, judge the registered content against the
   agreement. Vote **Yes, accept** if it satisfies the agreement, and
   **No, reject** if it does not.
3. The challenger bears the burden of proof: if the evidence does not
   establish that the submission fails the agreement, vote **Yes, accept**.
4. Reserve **Refuse to Arbitrate** for malformed disputes. A provider's
   failure to disclose is covered by rule 1 and is a **No, reject**, never
   a Refuse to Arbitrate.
