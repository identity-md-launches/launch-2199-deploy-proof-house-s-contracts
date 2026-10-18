# Proof House launch adaptation

The eight manifest entries, their order and constructor arguments are unchanged:
ArtStorage, ArtHouse, KeyProof, ArtifactsPiece, ArtifactsFactory, ArtifactsSource,
BrokerPass, SubmissionReviews. `launch.json` was read, not edited. No token, pool,
proxy, upgrade mechanism, deployment transaction or additional launch entry was
added. The specified owner remains an explicit constructor argument wherever the
project has ownership. Ownership remains two-step, without renunciation.

The brief explicitly says that the owner configures everything after deployment.
That requirement takes precedence over the background recipe's generic instruction
to move all configuration into constructors. Artist approval, publication, VRF
configuration, wiring and sale opening therefore remain owner actions. No missing
operational value was replaced with a fabricated production address or identifier.

## Review round 4: the independent review of the accepted launch

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
