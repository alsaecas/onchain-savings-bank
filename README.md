# SavingsBankPro

A Remix-first, production-style Solidity project that evolves a classroom “CryptoBank” into a realistic on-chain savings product.

Users can create multiple labeled savings plans, lock funds until a chosen unlock date, and optionally withdraw early with a configurable penalty that goes to a treasury address.

This repo is intentionally **Solidity-only** to keep it lightweight and perfect for Remix workflows.

---

## Why this exists

The original CryptoBank exercise demonstrates core Solidity mechanics.
SavingsBankPro adds real product logic and operational safety patterns that resemble real-world DeFi/fintech building blocks:

- Multiple savings plans per user
- Time locks
- Early-withdraw penalties
- Per-user total balance cap
- Reentrancy protection
- Pause/unpause operations
- Clear events and errors

---

## Contract

- `SavingsBankPro.sol`

---

## Features

### User Features
- Create multiple savings plans (goals)
  - Each plan has:
    - `balance`
    - `unlockTime`
    - optional `label`
- Deposit ETH into a specific plan
- Withdraw ETH from a plan
  - If withdrawing before `unlockTime`, a penalty is applied
  - Penalty is transferred to `treasury`

### Risk & Ops
- Global per-user cap across all plans: `maxBalancePerUser`
- Configurable penalty: `earlyWithdrawPenaltyBps`
  - BPS = basis points (100 = 1%)
  - Hard-capped at 20% to prevent abusive configuration
- Emergency pause:
  - Blocks plan creation, deposits, and withdrawals

---

## How it works (high-level)

1. User creates a plan with a future unlock timestamp.
2. User deposits ETH into that plan.
3. User can withdraw anytime:
   - After unlockTime: no penalty
   - Before unlockTime: penalty is charged and routed to treasury

---

## Quickstart (Remix)

1. Open Remix.
2. Create a new file:
   - `SavingsBankPro.sol`
3. Paste the contract code.
4. Compile with:
   - Solidity `0.8.24`
5. Deploy:
   - Provide constructor params:
     - `maxBalancePerUser_` (example: `5000000000000000000` for 5 ETH)
     - `treasury_` (an address you control)
     - `earlyWithdrawPenaltyBps_` (example: `300` for 3%)

---

## Example Usage

### 1) Create a plan
Call:
- `createPlan(unlockTime, label)`

Example:
- unlockTime = current time + 30 days
- label = "Emergency Fund"

### 2) Deposit
Call:
- `depositToPlan(planId)` with ETH value

### 3) Withdraw
Call:
- `withdrawFromPlan(planId, amount)`

---

## Design Notes

- Uses Checks-Effects-Interactions pattern.
- Uses a minimal `ReentrancyGuard`, `Pausable`, and `Ownable` built in-file to remain Remix-friendly.
- Disallows direct ETH transfers via `receive()` to ensure all ETH is properly accounted to a plan.

---

## Security Considerations

This is a portfolio project and not audited. If you extend it:

- Add unit tests (Foundry/Hardhat)
- Consider limiting penalty changes with a timelock
- Consider adding a guardian role for emergency pause
- Add invariant tests:
  - `sum(plan balances) == userTotalBalance`
  - `contract balance >= sum(all users balances)` (when no external flows)

---

## Roadmap Ideas

Easy upgrades that still fit Remix or a simple repo:
- Plan targets and milestone events
- Group savings plans (multiple contributors)
- Daily/weekly withdrawal limits
- ERC20 version of the savings logic

---

## License

LGPL-3.0-only

