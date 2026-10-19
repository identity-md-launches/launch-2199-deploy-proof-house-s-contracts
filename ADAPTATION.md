# Proof House launch adaptation

The manifest now has seven entries, in this order: ArtStorage, ArtHouse, KeyProof,
ArtifactsFactory, ArtifactsSource, BrokerPass, SubmissionReviews. ArtifactsPiece left
the launch in the mainnet revision below (EIP-7825), and ArtifactsFactory and
ArtifactsSource take it through a one-shot owner setter instead of a constructor
argument; every other constructor argument is unchanged. No token, pool, proxy,
upgrade mechanism or deployment transaction was added. The specified owner remains an explicit constructor argument wherever the
project has ownership. Ownership remains two-step, without renunciation.

The brief explicitly says that the owner configures everything after deployment.
That requirement takes precedence over the background recipe's generic instruction
to move all configuration into constructors. Artist approval, publication, VRF
configuration, wiring and sale opening therefore remain owner actions. No missing
operational value was replaced with a fabricated production address or identifier.

## Mainnet revision 2: the launch transaction and EIP-7825

This section records the changes of this revision relative to the accepted tree
(commit d379142). The sections below it are the earlier rounds' notes, kept as history.

### 180a7e1d59e1 — the 8-contract launch exceeds EIP-7825's per-transaction gas cap: reproduced and fixed

Full id: `180a7e1d59e12e6b95c6128645a5b9badf44dc0bd123c8ea45343cd28e7776fc`.

Reproduced. The supplied proof, copied unchanged to `test/scratch/`, failed on the
starting tree exactly as reported: the eight CREATE2s alone took 19,419,813 gas of
execution and 20,853,017 gas with the intrinsic cost of 90,308 bytes of calldata,
against the cap of 16,777,216 (2^24) that Ethereum mainnet enforces on every
transaction since Fusaka. The protected harness deploys the whole manifest in one call,
as `ProjectFactory.launchContracts` does, so no gas price or ceiling could have included
that launch. The deposit cost of the runtime code (200 gas a byte for ≈86 KB) is the
bulk and cannot be optimised away: about 19 KB of code had to leave the launch.

What changed, and why this shape:

- `launch.json`: ArtifactsPiece (24,132 bytes of runtime, the largest contract by far,
  and only ever a template that claims copy) is no longer deployed by the launch.
  ArtifactsFactory and ArtifactsSource are constructed with `($owner, $contract:ArtHouse)`.
  The remaining seven contracts are deployed in the same order as before.
- `launch.piece.json` (new, same shape as the existing `launch.burner.json`): the
  curator deploys `ArtifactsPiece($contract:KeyProof)` right after the launch, with the
  KeyProof the launch deployed, and checks its runtime against a build of this commit
  before connecting it. The piece's own code is unchanged byte for byte.
- `src/ArtifactsFactory.sol`, `src/ArtifactsSource.sol`: `pieceImplementation` is a
  storage variable set once by `setPieceImplementation(address)` (owner only, refuses a
  second call and an address without code, emits `PieceImplementationSet`), the same
  set-once pattern the ledger already uses for the broker pass and the buyback burner.
  `setSaleOpen(true)` and `setAuction` refuse to open while it is unset, so no sale can
  start whose claim or settlement would have nothing to copy. What a claim copies can
  never change once set: the connection is not upgradeable.
- `script/Deploy.s.sol`, `test/Fixture.sol`: the two-argument constructors, then the
  owner's `setPieceImplementation` step, so every existing test runs the launch order.
- `test/LaunchDeployment.t.sol`: the CREATE2 rehearsal deploys the seven manifest
  contracts, then performs the curator's step (deploy the piece with the launched
  KeyProof, set it once on both, a second set and a non-owner's set refused).
- `test/LaunchGasCap.t.sol` (new): the proof's own one-transaction loop over the seven
  manifest contracts, asserting execution plus intrinsic calldata cost stays under the
  cap with 1,000,000 gas kept for the factory's bookkeeping, then the curator's step.

Measured with this commit (`forge test --match-path test/LaunchGasCap.t.sol -vv`):

| | execution | total with calldata |
|---|---|---|
| 8 contracts, starting tree | 19,419,813 | 20,853,017 |
| 7 contracts, this tree | 14,150,696 | 15,201,436 (1,575,780 under the cap) |

The reviewer's proof (`Proof_180a7e1d59e1.t.sol`) hard-codes the previous manifest: it
deploys ArtifactsPiece as the fourth contract and passes it to three-argument factory and
source constructors. On this tree it still deploys all eight (the extra constructor word
is ignored) and still measures ≈19.5M, because it measures a set the launch no longer
deploys; it cannot pass with any fix that changes the manifest, which is the only kind
that reaches the cap. `test/LaunchGasCap.t.sol` is the same loop over the manifest as it
is now, and is the check this tree is held to. The finding is answered "disputed" for that
reason alone; its substance is accepted and fixed.

Why not the reviewer's first suggestion: creating the ArtCollection template lazily in
`createCollection` moves ArtCollection's creation code from ArtHouse's init code into
ArtHouse's runtime, which the launch deposits at the same 200 gas a byte, so it saves
only the one CREATE and nothing of substance. Moving the metadata rendering out of the
piece (≈9.8 KB, measured by compiling the piece without `tokenURI`) would have saved
about 2.1M gas, short of the 4.1M needed, while changing the piece's code and adding a
renderer dependency to every piece; taking the whole template out of the launch saves
≈5.3M, keeps the piece byte-identical to the reviewed code, and follows the pattern the
project already uses for the burner. The ArtCollection template stays in ArtHouse's
constructor as before.

Trust consequence, stated plainly: the piece implementation is no longer attested by the
launch; the curator deploys it and the requester compares its runtime with their own
build of this commit (as they do for every launched contract) before `setPieceImplementation`.
Buyers can read `pieceImplementation()` on the factory and the source and compare it the
same way. A wrong address cannot be corrected: a second call reverts.

### a0cc401d2e36 — resale key posted after SELLER_WINDOW (the imported audit): already fixed in the accepted tree

Reproduced on the tree as it arrived in the previous round and fixed there (the
`TooLate` deadline in `postEscrowKey`, `test/EscrowDeadline.t.sol`, see the next section).
The supplied proof `Proof_a0cc401d2e36.t.sol` passes on the starting tree of this
revision and on its result. Nothing further changed for it.

### Advisory findings

- `5f41a376` (setSaleOpen without the ledger registered): reproduced on the starting
  tree (`setSaleOpen(true)` succeeded with `canRecordSale(factory) == false`, after which
  every buy reverted `NotSaleModule` while the holders window ran out). Fixed:
  `setSaleOpen(true)` now reverts `NotRegistered` unless `house.canRecordSale(address(this))`,
  before `saleOpenedAt` is written, exactly as `ArtifactsSource.setAuction` does.
  Tested in `test/PieceImplementation.t.sol`.
- `7b2e2f48` (reviewsOf panics on `start + count` overflow): reproduced
  (`reviewsOf(0, 1, type(uint256).max)` panicked 0x11). Fixed: the page length is
  clamped from the list length before any addition, so the idiom returns the tail.
  Tested in `test/PieceImplementation.t.sol`.
- `2c64d841` (VRF_CALLBACK_GAS_MIN below one draw's cost): the project's own fork test
  needs 300k and the reviewer measured 216,317 for a first draw, so 150,000 admitted a
  limit at which every callback fails. Fixed: `VRF_CALLBACK_GAS_MIN = 250_000`; the
  existing bound tests (149,999 refused, 500,000 accepted) still hold, and README's
  figures are updated. No test sets a value between the old and new minimum.
- `23c8ec1c` (token leg of the holders window is a balance at the instant of the call):
  not changed. The token leg was documented as a soft gate when the gate was designed:
  IMD is freely transferable, so no instantaneous balance check can bind, and a
  checkpointed token or a registration pre-window would change the brief's design.
  Seats and members (ownership of a seat, membership in the gate contract) carry the
  priority guarantee; the per-wallet and per-phase caps still apply to any wallet.
- `2a619fed` (allowanceOf ignores saleOpen and the window): not changed; it is the
  phase and wallet cap only, as its NatSpec says, and a front end checks `saleOpen`
  and the gate views beside it. No contract logic depends on it.
- `19bd0394` (a Chainlink answer inside a started fallback window leaves the fallback
  views set): not changed. `_fallbackLive` is false once `requestEdition` is set, so the
  stale `fallbackBlock`/`fallbackInFlight` values affect no draw; clearing them inside
  `rawFulfillRandomWords` is cosmetic and was left alone to keep the draw code the
  reviewed one.

### Verification for this revision

`forge build` (project configuration unchanged), `forge test` with
`FOUNDRY_FUZZ_SEED=0xd866aa7377ecb437719b479dd53badc82fc76d051a9db942f07bd62360986989`;
the supplied proofs run from `test/scratch/`. Results are in the final notes of the run.

## Current mainnet adaptation: resale posting deadline

This section records the changes in this assignment relative to the supplied,
previously reviewed tree. The review rounds below are retained historical notes;
their changes, sizes and test counts are not changes or results from this run.

### a0cc401d2e36 — late escrow key posting: reproduced and fixed

Full finding id:
`a0cc401d2e36398a456f5b5fd8bc801aa04d750f3210a0c7cc636ee7185f4659`.

The supplied proof was copied unchanged to `test/scratch/` and run before editing
production code. It failed with `next call did not revert as expected`: after
`paidAt + SELLER_WINDOW + 1`, cancellation succeeded on a snapshot, and after
restoring that snapshot a seller's valid Schnorr proof still posted a key. This
reproduces the overlapping posting/cancellation permissions. No imported finding
was left unreproduced.

Changes in this assignment:

- `src/ArtifactsPiece.sol`: one deadline check in `postEscrowKey`, after the
  existing seller/buyer/key-posted checks and before proof verification or state
  changes. At `block.timestamp >= paidAt + SELLER_WINDOW` it reverts with the new
  `TooLate()` error. NatSpec states the deadline and refund/retry path. This is
  the only production source change; it applies to both edition and THE SOURCE
  runtime copies. Storage layout, constructors, deposits, royalties, cancellation,
  refunds, release and token supply are unchanged.
- `test/EscrowDeadline.t.sol`: regressions on both an edition claimed through
  ArtifactsFactory and THE SOURCE created by auction settlement. Tests cover the
  last valid second, the exact deadline, one second after it, fuzzed later times,
  rejected deposits and unchanged escrow state, full buyer withdrawal, and a fresh
  posting window after either seller refund/relisting or buyer cancellation.
  They use valid seller proofs and confirm a timely key still releases normally.
- `test/invariants/PieceEscrowInvariant.t.sol`: the handler's expected-success
  condition now requires a post to be strictly inside the seller's window.
- `test/NothingStuck.t.sol`: the release-timeout test previously posted after
  60 hours, contrary to the corrected deadline. It now posts after 23 hours and
  still checks rejection at key-time + 71 hours and release at + 72 hours.
- `test/LaunchDeployment.t.sol`: runs the existing eight-contract CREATE2,
  constructor-isolation, ownership and opcode/size checks on chain id 1 instead
  of Sepolia, matching this launch.
- `README.md`: documents the strict posting deadline and refund/retry path,
  including the public-calldata limitation below; identifies the exception to
  adopting the prior review unchanged and updates the piece's compiled size.
- `ADAPTATION.md`: records this reproduction, patch, verification and its limits.

The deadline makes successful key posting and buyer cancellation mutually
exclusive in the same escrow state. It cannot conceal calldata already broadcast:
a pending post delayed across the deadline, or an expired post sent despite the
guard, can still expose the wrapped key. Seller clients must respect the deadline
with inclusion margin and use refund/retry with a fresh viewing key after expiry.
No claim is made that a revert restores key secrecy. Changing cancellation into
a multi-step protocol would be a broader redesign than the requested minimal fix.

`launch.json`, the eight constructors, ownership rules, build configuration and
dependencies remain unchanged. No live transaction is part of this worker task;
the deployment service uses the supplied manifest and the owner configures the
applications afterwards.

### Bytecode comparison for this assignment

With the same configured solc 0.8.26 optimizer settings, ArtifactsPiece's runtime
is **24,132 bytes** (baseline 24,385), leaving **444 bytes** below EIP-170. Its
creation code is 24,320 bytes before its single address argument. The size decrease
comes from the compiler's output for the deadline/error addition; no separate
optimization or build-setting change was made.

Saved pre-edit compiler artifacts were compared against the patched artifacts:
the other seven launch contracts' creation bytecode and runtime templates, and
the ArtCollection template, are byte-for-byte unchanged. Immutable dependency
addresses in deployed runtimes must still be resolved from this build's actual
deployment addresses. The existing manifest and its backward references handle
that; the changed piece bytecode can change CREATE2 address predictions.

### Verification for this assignment

Foundry 1.8.3 and solc 0.8.26, with the repository's unchanged configuration.
Every test invocation used the requested fuzz seed:
`0xd866aa7377ecb437719b479dd53badc82fc76d051a9db942f07bd62360986989`.

- Supplied proof before the fix: **1 failed**, with the expected late-post
  acceptance described above. After the fix: **1 passed**. The proof was run
  unchanged from scratch and then kept there as a non-test text file, so it is
  excluded from the delivered suite count.
- Focused regression run: **13 passed**, comprising the supplied proof and the
  12 new regression tests (six each for editions and THE SOURCE). Both new fuzz
  tests ran 64 cases.
- `forge build`: **passed**, with existing compiler/lint warnings, including the
  unused parameter in `test/invariants/ArtHouseInvariant.t.sol`.
- `FOUNDRY_FUZZ_SEED=0xd866aa7377ecb437719b479dd53badc82fc76d051a9db942f07bd62360986989 forge test`:
  **271 passed, 0 failed, 2 skipped**, across 36 suites. This includes the escrow
  invariant handler (96 runs, depth 60), the updated release-timeout regression,
  and the deployment checks on chain id 1.
- The skipped entries are the existing `BurnerForkTest.setUp` and
  `VrfForkTest.setUp`, whose `FORK_URL` guards skipped them. No live-fork results
  are claimed for this assignment.
- Manifest ABI inspection passed: eight nonpayable constructors, supported
  static arguments, correct argument counts, backward-only references, no
  unresolved library links, and bounded creation/runtime code. The existing
  deployment tests also pass with code-less dependencies, explicit ownership,
  and protected-style opcode scans of the actual deployed runtimes.
- Baseline bytecode comparison and `git diff --check` passed. The manifest,
  protected build files and dependencies have no diff.

No new dependencies, live deployments, signing, explorer verification, Slither
or Mythril runs were needed or performed.

## Historical review round 4: the independent review of the accepted launch

The accepted work was reopened with two reproducible findings and seven advisory
ones. Each was reproduced before anything changed; the answers are in
`.imd-responses.json`. Three source changes resulted, all behaviour-preserving
outside the reported paths, and no manifest, constructor, configuration or
dependency changed.

### 07f1616add6c — fallback draw on a request Chainlink still holds: fixed

The supplied proof failed on the accepted tree: at purchase + `FALLBACK_BLOCKS` a
buyer re-requested their draw and started the fallback on the fresh request in
the same block, so once the fallback block's hash was public they could let the
coordinator answer the fresh request instead and keep whichever edition they
liked.

- `src/ArtifactsFactory.sol::startFallbackDraw`: refuses (`RequestTooRecent`)
  while the coordinator still holds the request and it is younger than
  `VRF_RETRY_BLOCKS`, the same `_stillHeld` test `rerequestRandomness` uses. After
  that Chainlink has dropped the request (24 h) and cannot answer it; a request
  it answered with a failed callback is no longer held and may fall back at once.
- `src/ArtifactsFactory.sol::rawFulfillRandomWords`: refuses (`FallbackPending`)
  an answer to a request whose started fallback block is behind us, since its
  hash is public from then on; `finishFallbackDraw` assigns it. An answer before
  the target block still stands, as before.

`test/NothingStuck.t.sol::test_fallbackDraw_countsFromThePurchase` asserted the
reported behaviour (a fallback started on a request under a day old that the
coordinator still held). It now expects `RequestTooRecent` until that request is
`VRF_RETRY_BLOCKS` old, and a new test shows the fallback starting at once when
the coordinator answered the young request but the callback failed. Regressions:
`test/ReviewRound4.t.sol` (`test_noFallbackOnARequestChainlinkMayStillAnswer`,
`test_noChainlinkAnswerOnceTheFallbackHashIsPublic`,
`testFuzz_theFallbackResultStandsAgainstAnyLateWord`).

### 20ca2ef1fdca — code-less gate address reverts every gated buy or bid: fixed

The supplied proof failed on the accepted tree in all three cases. Solidity's
`try/catch` only catches the callee's revert; a code-less token returns no data,
the ABI decode fails in the caller, and `holdsToken`, every `buy`/`buyMany` in the
window (members included) and every `buyWithSeat`/`ArtifactsSource.bid` with
code-less seats reverted with no data. The factory's gate cannot be changed once
the sale has opened, so the only exit was `endSale`.

- `src/base/HolderGate.sol`: `holdsToken`, `holdsSeat` and `_ownsSeat` read
  `balanceOf`/`ownerOf` through a private `_readWord` (raw static call, 32 bytes
  copied, success only with exactly 32 bytes returned), the pattern `isMember`
  already used. No code, a revert, or a malformed answer counts as not held, as
  the contract's NatSpec promised; `_ownsSeat` also requires the word to equal the
  account with no bits above the address. `_setGate` still accepts a code-less
  address (the proof's setup depends on it); the promise is kept at read time.

Regressions in `test/ReviewRound4.t.sol`: code-less token with a member buying
and a non-holder refused `NotEligible`; code-less seats; a dirty `ownerOf` word; a
real seat contract unchanged; THE SOURCE's window with code-less seats and token;
a fuzz that the gate views never revert for any addresses.

### 07bde3893de7 (advisory) — dead fallback draw strands the re-request: fixed

Reproduced by test: once a started draw's hash left BLOCKHASH and the EIP-2935
history unread, `finishFallbackDraw` reverted `FallbackMissed`, `rerequestRandomness`
reverted `FallbackPending` for ever, and `startFallbackDraw` reverted
`ChainlinkAnswering` while Chainlink answered anyone else, so the paid edition
waited until Chainlink had been silent for three days.

- `src/ArtifactsFactory.sol::rerequestRandomness`: refuses only a live draw
  (`_fallbackLive(requestId)`) and clears the dead draw's `fallbackBlock` (and
  `fallbackInFlight` when it is this request) as it re-requests.

A live draw (hash still readable) still cannot be re-requested away by anyone
(`test_aLiveFallbackDrawStillCannotBeRerequested` and the existing NothingStuck
test); `test_aDeadFallbackDrawCanBeRerequested` covers the fix. This gives a buyer
who let a draw die the same re-roll the review's informational finding
03cc5b5b2e8c already describes for restarting it, without the three-day wait; the
keeper finishing each draw within ~27 hours remains the fairness guarantee and
the README now says so.

### Advisory findings left as they are

- ec83ecd2060869 (revoking THE SOURCE strands a live auction until re-approval or
  the void after `SETTLE_GRACE`): an owner power, already exercised by
  `test_anAuctionNobodyCanCloseGivesTheBidBack`; the README trust list now states
  it. Both suggested fixes change agreed behaviour.
- 6cc4015d311c2f (public burner swap sandwichable): the documented, bounded
  behaviour of a contract this launch does not deploy; to weigh when the burner
  is reviewed before `setBuybackBurner`.
- 03cc5b5b2e8c33 (a dead draw may be restarted): acknowledged in the NatSpec and
  README; the keeper's liveness is the guarantee.
- 313dd464f0a1d5 (point-in-time `balanceOf`), edce6803362756 (`allowanceOf` ignores
  the gate and the sale flag; it cannot know a caller's seat), 6c384346670965
  (`sealCollection` over an unbounded piece count): documented semantics or
  informational, each a redesign the brief does not ask for.

`README.md` was updated for the fallback rules, the gate's code-less behaviour and
the module-revocation trust assumption. Runtime sizes after this round:
ArtifactsFactory 15,732 bytes (was 15,702), ArtifactsSource 8,323 (was 8,365); the
other seven launched runtimes are byte-for-byte unchanged, and every launched
runtime and the generated ERC-721s still pass the opcode and size scans in
`test/LaunchDeployment.t.sol`.

Verification for this round (Foundry 1.8.3, solc 0.8.26, the repository's
configuration, fuzz seed `0x9c11807f812cb2361b4137f8ffa9aa8f637b5257d865e6236bfc291828760e1e`):
`forge build` passes; `forge test` reports **244 passed, 0 failed, 2 skipped**
(the two fork suites, which need `FORK_URL`), 30 suites, 262 test functions
listed; both supplied proofs pass when run from `test/scratch/`; nine of the
eleven new `ReviewRound4` tests fail on the previous source and the two that
assert unchanged behaviour pass there.

## Reproduced findings and their disposition (round 1, the imported audit)

### b0f3f99d54ac — generated ERC-721 proxies: fixed

Both tests in the supplied `Proof_b0f3f99d54ac.t.sol` failed on the original code:
the generated plain collection and claimed edition contained DELEGATECALL. Both
pass after the change.

- `src/ArtHouse.sol`: `createCollection` uses `Clones.copyCode`.
- `src/ArtifactsFactory.sol`: `_claim` uses `Clones.copyCode`.
- `src/libs/Clones.sol`: removed the EIP-1167 deployment function; retained the
  existing full-copy implementation already used by THE SOURCE.
- `src/ArtCollection.sol`, `src/ArtifactsPiece.sol`, `src/ArtifactsFactory.sol`
  and `README.md`: descriptions now match the independent runtime copies.

This removes the forbidden proxy capability from production code. Each piece
still has its own ERC-721 storage, escrow, keys and withdrawals, and the copied
runtime retains the implementation's immutable KeyProof address. ArtifactsPiece's
storage declarations and layout were not changed. Creation and initialization
remain atomic within collection creation, claim or settlement.

The tradeoff is gas: an edition's 24,385-byte runtime alone costs 4,877,000 gas in
code deposit, before creation overhead and initialization. Claim batches must fit
the target chain's transaction gas limit. No new batch restriction or economic
parameter was introduced. THE SOURCE already used this deployment mechanism.

Tests: the supplied two-test proof, plus
`test/LaunchAudit.t.sol::test_plainCollectionIsIndependentRuntime`,
`test_claimedEditionsAreIndependentRuntimesAndStorage`, and the source settlement
test compare runtime copies, check independent ownership/storage, and scan the
generated code with the protected check's exact PUSH-skipping algorithm.

### 5fab1872a919 — owner configuration after deployment: retained as requested

The reported initial state reproduces: ArtStorage has no house, the ledger has no
BrokerPass or registered modules, sales are closed, and pass claims are closed.
Uploading before `setHouse` fails with `NotHouse`; it succeeds once the owner wires
the storage. `test/LaunchDeployment.t.sol` verifies this sequence after deploying
the eight contracts in one CREATE2 batch.

This is not an unintended permission or behavior defect under the approved brief.
Moving circular dependencies into constructors, removing ArtStorage from the
manifest, or inventing the owner's VRF subscription and burner would change the
requested launch. No such change was made. Each of the eight existing constructors
is nonpayable, uses supported static arguments, and succeeds without dependency
code. The factories receive no administrative privileges.

### 76d2a83f2f13 — unauthenticated copy initialization: fixed

On the original code, an attacker initialized an independent copy naming the real
ArtifactsFactory, ArtifactsSource or ArtHouse as controller. The new tests expecting
rejection failed before the fix.

- `src/ArtifactsPiece.sol`: after the existing one-time guard, require the caller
  to equal `controller_` and that controller to have code; otherwise revert with
  `NotController`.
- `src/ArtCollection.sol`: the analogous check uses the existing `NotHouse` error.

The launched templates remain locked. Legitimate controllers initialize copies
in the same transaction that creates them. Caller and code checks happen only
during this later application operation, not in the eight launch constructors.
No new initializer is required from the deployment service or owner.

Tests cover impersonating each real controller, EOA controllers, repeat
initialization, and legitimate collection, edition and source creation. The proof
fixtures in `test/NothingStuck.t.sol` and `test/audit/KeyReuseLeak.t.sol` now install
the full runtime at their fixed test addresses and initialize as their controller;
`test/Adversarial.t.sol` likewise uses a full copy and its stub controller. Their
cryptographic and reveal assertions remain intact.

The existing adversarial test that explicitly asserted the old EIP-1167 bytecode
was changed to require the full implementation runtime, as the launch policy now
requires. Its template lock, controller, house, ERC interface and token-existence
assertions were retained.

Public NFT code and names can still be copied. Authenticity continues to require
the project's canonical registries; this fix prevents the supplied implementation
from being initialized by an attacker while naming a different, real controller.

### ab923af3c52f — broken BrokerPass blocks sales: fixed

Before the change, an EOA configured as BrokerPass made edition purchases and
THE SOURCE settlement with an unapproved nonzero broker revert. A reverting pass
also made `isEligibleBroker` revert.

`src/ArtHouse.sol::isEligibleBroker` now performs a static call with a named
100,000-gas limit, copies at most 32 bytes, and requires a successful, exactly
32-byte result. Reverts, missing code, malformed data and exhausted gas count as
no pass. Zero brokers remain ineligible, approved brokers still qualify without
consulting the pass, and valid pass holders still qualify. The unearned primary
broker share follows the existing buyback rule.

This deliberately preserves the one-shot setter: a bad pass address still cannot
be corrected and will not grant pass-based eligibility. It no longer blocks
otherwise valid sales. `README.md` documents the call bound and this limitation.

Tests cover edition purchases, source settlement, plain ETH and IMD mints,
explicitly approved brokers, zero brokers, failed/short/oversized/gas-exhausting
responses, and valid zero/nonzero balances. The existing BrokerPass tests continue
to exercise real pass-holder primary and resale commissions.

### b93e09f36b44 — dynamic member result bypasses the gate: fixed

Calling the mock ERC-20's `name()` with the wallet appended reproduced the dynamic
ABI offset being counted as points. Both the edition and source window regression
tests failed on the original code; a fuzz test also produced an oversized-answer
counterexample with the required seed.

`src/base/HolderGate.sol::isMember` now requires `returndatasize() == 32` instead of
`>= 32`, preserving the existing gas bound and bounded copy. This changes both
ArtifactsFactory and ArtifactsSource. Malformed/dynamic/multi-word answers count
as no membership. Tests cover both sale windows, the existing token/public paths,
and fuzzed return lengths, scores and thresholds. The original tests retain
coverage of valid points, seat holders and hostile membership contracts.

The owner must still select a semantically correct points function. A single-word
boolean and integer cannot be distinguished by their ABI encoding; the fix does
not claim to infer the intended semantics of an arbitrary selector.

### a85c2484bf00 — constructor-created ArtCollection template: retained and checked

This observation reproduces: ArtHouse creates a ninth contract, its locked
ArtCollection template, in addition to the eight manifest entries. It is now a
source of independent runtime copies, not a DELEGATECALL target. The launch
reference explicitly says its floor does not establish that a constructor creates
no other contract; it does not require removing this existing implementation
detail. Removing it would change the requested constructor/collection design.

`test/LaunchDeployment.t.sol` asserts that the template exists outside the eight
addresses, is locked, is below EIP-170, and passes the same opcode scan as the
manifest runtimes. The existing README launch table already discloses its creation.

### 015b0e5b53ba — curator powers: retained and documented

These are intended powers, not authorization bypasses. The new regression test
reproduces closing a primary sale while claims and transfers remain possible, and
changing THE SOURCE's split after a 10 ETH bid so settlement credits 8.5 ETH to the
house and none to the artist. Existing tests cover artist revocation, module
revocation/fallback withdrawals, retries, claims and late key posting.

The expanded README trust assumptions explicitly retain: primary sale closure and
ending; splits read at settlement; artist revocation without taking its payout;
module revocation routing resale shares into piece-level pull balances; owner
VRF retries and claims on behalf of buyers; and curator key delivery into an empty
key slot without a fake-key proof. No holder freeze, seizure or upgrade path was
introduced. NFT supplies and mint-on-purchase/pass-claim behavior remain unchanged.

All seven reports' underlying observations reproduced. The three retained reports
above are documented design/policy observations whose suggested redesigns are not
required by the explicit brief; they are not claimed to be fixed defects.

## Additional change required by the protected deployment scan

With the copy-deployment changes, solc emitted the event topic
`keccak256("WrappedKeyPosted(uint256)")` in ArtifactsFactory's unreachable constant
tail. That hash includes `0xf4`. The protected scan skips PUSH operands but does
not distinguish a constant-data tail, so it rejected the runtime even though no
DELEGATECALL instruction was executable there.

`src/ArtifactsFactory.sol::_postWrappedKey` now shares the two branches' event
emission and computes the same topic from the signature bytes in memory before
`log2`. The event name, indexed edition, empty data, emitter, timing and number of
events are unchanged. `test_keyPostEventUnchangedBeforeAndAfterClaim` checks both
branches and the delivered keys. The full protected-style scan then passes without
altering any build configuration or weakening the check.

## Delivered test and documentation changes

- `test/LaunchAudit.t.sol`: reproductions and regressions for the four fixes, the
  event encoding, and the retained curator powers.
- `test/LaunchDeployment.t.sol`: all eight CREATE2 deployments in manifest order
  on chain id 11155111, address prediction, explicit ownership, no renunciation,
  isolation with code-less dependencies, runtime/initialization size bounds,
  opcode scans, the extra template, and the owner's wiring sequence.
- The three existing test files listed above were adapted for full copies,
  authenticated initialization and the replacement of the forbidden proxy assertion.
- `README.md`: copy deployment, its gas cost, current piece size, the broker call
  limit, membership result shape, authenticity and owner trust assumptions.
- `ADAPTATION.md`: this change record.

Existing build configuration, dependencies and deployment manifest were not
modified. No new project dependency is needed. KeyProof, ArtStorage, BrokerPass,
SubmissionReviews, ImdBuybackBurner and the ownership base source are unchanged.

## Verification

Toolchain: Foundry 1.5.1 and solc 0.8.26, using the repository's unchanged via-IR,
optimizer (200), Cancun and metadata configuration. The locally supplied compiler
binary was selected by path; its version matches `foundry.toml`.

Fuzz seed:
`0x9c11807f812cb2361b4137f8ffa9aa8f637b5257d865e6236bfc291828760e1e`.

The 12 initial regression tests and the two supplied proxy proof tests failed on
the original implementation. After the fixes, all 19 focused checks passed (17
delivered checks plus the two supplied proof checks run in scratch).

Final verification:

- `forge build`: passed. The compiler reported warnings, including the existing
  unused parameter in `test/invariants/ArtHouseInvariant.t.sol`; no build errors.
- `forge test` with the seed above: **245 passed, 0 failed, 2 skipped**, across 29
  suites. This includes the project's unit, fuzz and four invariant suites and
  the 17 new regression/deployment tests, with scratch proofs excluded.
- The two skipped entries are `BurnerForkTest.setUp` and `VrfForkTest.setUp`:
  their existing `FORK_URL` guards skipped them because no RPC URL was configured.
  The five live-fork test methods in those suites were not executed; no live-chain
  verification is claimed.
- Manifest ABI inspection confirms eight nonpayable constructors with supported
  static arguments, backward-only contract references and no library link slots.
- All eight deployed application runtimes, the ArtCollection template and the
  generated ERC-721s pass the protected-style opcode and runtime-size checks.
- `git diff --check`: passed; protected build/dependency files and `launch.json`
  have no changes.

Runtime sizes from the configured compiler (bytes):

| Contract | Runtime | Creation code before arguments |
| --- | ---: | ---: |
| ArtStorage | 2,128 | 2,320 |
| ArtHouse | 15,979 | 21,182 |
| KeyProof | 3,151 | 3,177 |
| ArtifactsPiece | 24,385 | 24,573 |
| ArtifactsFactory | 15,732 (round 4; 15,702 before) | 16,086 |
| ArtifactsSource | 8,323 (round 4; 8,365 before) | 8,650 |
| BrokerPass | 6,753 | 7,343 |
| SubmissionReviews | 5,286 | 5,650 |
| ArtCollection template/copies | 4,735 | 4,779 |

No live deployment, signing, explorer verification, Slither or Mythril run was
performed. Local constructor tests do not establish that external IMD, seat or
VRF services are available on the launch chain. External integrations and their
owner-selected configuration remain part of the existing deployment handoff.
