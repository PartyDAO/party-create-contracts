# party-token-protocol

## Summary

This is a new protocol that helps users create new ERC-20 tokens and crowdfund liquidity for a launch. It consists of
the following contracts:

- PartyTokenLauncher
- PartyERC20
- PartyLPLocker
- PartyTokenAdminERC721

At a high level, this is the user behavior. The rest of the documentation will go into further details about each piece.

### Create

Someone starts a new ERC-20 token and a crowdfund with a specific amount of ETH as a goal.

### Crowdfund

People can join a crowdfund by contributing ETH and receiving tokens. They can also leave at any time for a refund.

### Finalize

If the crowdfund hits its goal, all ETH is used in a new UniV3 LP position which is locked forever. Tokens become
transferable at this time.

### LP Fees

The owner of a special `PartyTokenAdminERC721` can claim the LP fees from the locked position.

## PartyTokenLauncher

The `PartyTokenLauncher` contract is the main contract. It provides a clear structured way to create tokens, distribute
supply fairly, and establish liquidity pools on Uniswap V3. By incorporating crowdfunding mechanisms, it allows token
creators to raise the necessary funds while offering contributors a fair share of the tokens. In our first release, we
will do a simple fixed-price crowdfund that transitions into a symmetric full-range Uniswap V3 position where the
percentage of tokens allocated to the LP and to crowdfund contributors is equal.

### Creation

- Someone starts a new ERC-20 token and a crowdfund with a specific amount of ETH as a goal.
- The creator receives a `PartyTokenAdminERC721` for their new token, allowing them to change metadata or claim LP fees
  later if the crowdfund succeeds.
- The creator sets 3 amounts of tokens:
  - Amount for reserve (given to a specific address)
  - Amount for crowdfunders (given to contributors)
  - Amount for LP (paired with ETH at the end of the crowdfund)
- All fee amounts are set during creation. Our frontend UI will pass in the parameters for the 3 types of fees:
  withdrawal fees, success fee, and LP fee split.
- The creator can also choose to add a contribution limit (max-per-wallet) or an allow list (via merkle root) to limit
  contribution activity.

### Crowdfund

- Crowdfunds have no time duration. They last as long as they need until they hit their goal.

#### Joining

- People can contribute ETH to the crowdfund, bringing it closer to its goal. When they contribute, they receive ERC-20
  tokens in proportion to the amount of ETH they put in.
- The ERC-20 tokens are non-transferable during the crowdfund.

#### Leaving

- At any time during the crowdfund, users can leave for a refund. They do this by burning their tokens and getting back
  their ETH.
- PartyDAO charges a fee during withdrawals. It is a percentage of the ETH.

### Finalization

When a crowdfund successfully reaches its ETH goal, it is finalized and several things happen in the same transaction:

- When the crowdfund reaches its goal, all of the ETH raised in the crowdfund is paired with a specified amount of
  tokens in a new UniV3 LP position. This is a full-range UniV3 LP position. A percentage finalization fee is taken on
  the total amount of ETH raised before liquidity is added.
- The LP position is locked forever in our PartyLPLocker.
- In the same transaction, any reserve tokens are sent to the designated recipient.
- In the same transaction, the tokens become transferable.

## PartyLPLocker

The `PartyLPLocker` contract locks Uniswap V3 LP NFTs and manages fee collection for locked positions.

### Fee collection

- The owner of the `PartyTokenAdminERC721` can claim fees from the locked LP position.
- The owner of the Admin NFT receives 100% of the fees earned in their ERC-20 token.
- The owner of the Admin NFT splits the ETH fees with PartyDAO based on a percentage set when the crowdfund was created.

## PartyERC20

The `PartyERC20` is a custom ERC20 token used by the `PartyTokenLauncher` for launches.

- Inherits `ERC20PermitUpgradeable` and `ERC20VotesUpgradeable`.
- It is meant to be created using ERC-1167 minimal proxies by the `PartyTokenLauncher`.
- Is ownable. In practice, this will always be the `PartyTokenLauncher` until finalization, after which ownership will
  be revoked.
- The owner of the launch’s creator NFT from `PartyTokenAdminERC721` can set metadata for the token. Besides this, they
  have no other control over the token.

## PartyTokenAdminERC721

The `PartyTokenAdminERC721` contract is an ERC721 token representing the launch creator with metadata management and
minter permissions.

- The NFT is a big protocol-wide collection.
- The NFT has an attribute that represents whether the crowdfund was successful or not.
- It can have multiple minters, but for now, the only minter is `PartyTokenLauncher`.

## Defaults & Clarifications

Certain inputs in our protocol will be exposed to users who are creating ERC20 tokens. Other input parameters, however,
will be set by our frontend across all ERC20 tokens.

### Defaults

- Every token will have 1B supply.
- Users can only set the reserve percentage of their token. We will default the amount of tokens for contributors and
  the amount for the LP position to be equal.
- All fee amounts will be set by our frontend and will not be adjustable by users:
  - `finalizationFeeBps`: `100`
  - `withdrawalFeeBps`: `100`
  - `lockerFeeRecipients`: `[partyDaoMultisigAddress 5000]`
- There will be a frontend restriction to ensure `targetContribution` is at least 0.055 ETH
