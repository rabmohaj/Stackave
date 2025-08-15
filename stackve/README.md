# Stackave

A decentralized lending protocol built on Stacks, inspired by Aave v1. Stackave allows users to supply STX as liquidity, borrow against collateral, and earn interest on their deposits.

## Features

- **Supply & Earn**: Deposit STX to earn interest from borrowers
- **Collateralized Borrowing**: Borrow STX against your collateral deposits  
- **Dynamic Interest Rates**: Rates adjust automatically based on supply/demand
- **Liquidation Protection**: Unhealthy positions can be liquidated to maintain protocol solvency
- **Risk Management**: Configurable liquidation thresholds and safety parameters

## How It Works

### Interest Rate Model
Stackave uses a dual-slope interest rate model:
- **Base Rate**: 2% minimum borrowing rate
- **Slope 1**: Up to 80% utilization, rates increase by 10%
- **Slope 2**: Above 80% utilization, rates increase by 60%
- **Optimal Utilization**: 80% target utilization rate

### Core Functions

#### For Lenders
- `supply(amount)` - Deposit STX to earn interest
- `withdraw(amount)` - Withdraw your deposits plus accrued interest

#### For Borrowers  
- `deposit-collateral(amount)` - Deposit STX as collateral
- `borrow(amount)` - Borrow STX against your collateral (up to 75% LTV)
- `repay(amount)` - Repay borrowed STX plus interest
- `withdraw-collateral(amount)` - Withdraw excess collateral

#### For Liquidators
- `liquidate(borrower, repay-amount)` - Liquidate unhealthy positions for 10% bonus

### Risk Parameters

- **Liquidation Threshold**: 75% - positions become liquidatable when collateral falls below this ratio
- **Liquidation Bonus**: 10% - extra collateral awarded to liquidators
- **Reserve Factor**: 10% - portion of interest reserved for protocol treasury

## Usage Example

```clarity
;; Supply 1000 STX to earn interest
(contract-call? .stackave supply u1000000000) ;; 1000 STX (6 decimals)

;; Deposit 2000 STX as collateral
(contract-call? .stackave deposit-collateral u2000000000)

;; Borrow up to 75% of collateral (1500 STX max)
(contract-call? .stackave borrow u1000000000) ;; Borrow 1000 STX

;; Repay the loan
(contract-call? .stackave repay u1000000000)

;; Withdraw collateral
(contract-call? .stackave withdraw-collateral u2000000000)
```

## Read-Only Functions

Check protocol and user state without making transactions:

```clarity
;; Get current interest rates
(contract-call? .stackave get-current-borrow-rate)
(contract-call? .stackave get-current-supply-rate)

;; Check user balances
(contract-call? .stackave get-user-deposit-balance 'SP1ABC...)
(contract-call? .stackave get-user-borrow-balance 'SP1ABC...)
(contract-call? .stackave get-user-collateral-balance 'SP1ABC...)

;; Check position health
(contract-call? .stackave is-position-healthy 'SP1ABC...)

;; Get utilization rate
(contract-call? .stackave get-utilization-rate)
```

## Admin Functions

Protocol parameters can be adjusted by the contract owner:

```clarity
;; Update interest rate model
(contract-call? .stackave set-interest-rate-params base-rate slope1 slope2 optimal-util)

;; Update risk parameters  
(contract-call? .stackave set-risk-params liquidation-threshold liquidation-bonus reserve-factor)
```

## Deployment

1. Deploy the contract to Stacks using Clarinet or Stacks CLI
2. Call `initialize()` to set up initial state
3. Configure interest rate and risk parameters as needed

## Security Considerations

- All user funds are held in the contract's STX balance
- Interest accrues through scaled balance accounting
- Liquidations ensure protocol remains solvent
- Only contract owner can modify risk parameters
- No external oracles - uses STX as both collateral and borrowing asset

## Technical Details

- **Language**: Clarity smart contract language
- **Blockchain**: Stacks
- **Token**: STX (native Stacks token)
- **Decimals**: 6 (1 STX = 1,000,000 micro-STX)
- **Architecture**: Single-asset lending pool with over-collateralization
