# Only 2 USD

A weekly on-chain draw on Base. One ticket costs 2 USDC. Tickets never expire: each one stays in every weekly draw until it wins.

Website: https://only2usd.com

## Rules (fixed in the contract)

- 1 ticket = 2.00 USDC, bought through the contract’s `buyTickets` function. USDC on Base only.
- Maximum 25 active tickets per wallet.
- Every Sunday at 17:00 UTC one ticket wins 33% of the pool. The winning ticket is burned; the remaining 67% stays in the pool.
- The winner is chosen with a random number from Pyth Entropy, delivered on-chain after the draw is requested.
- Up to 7% of each payout goes to the developer. The contract allows this share to be lowered, never raised.
- Anyone may add USDC to the pool with `sponsor`. Sponsors get no tickets.
- The owner cannot withdraw USDC from the pool. There is no such function.
- Rules never change. A different game would be a new contract, not a change to this one.

## Contract

| Network | Address | Status |
|---|---|---|
| Base Sepolia (testnet) | `0x9041e577b2239a0757Bf15c699146881317b39c4` | testing |
| Base (mainnet) | — | not deployed yet |

Source: [`Only2USD.sol`](./Only2USD.sol). Verified source on Basescan matches this file.

## Verify a draw yourself

1. Open the contract on Basescan and go to **Events**.
2. Find the `DrawRequested` event for the week: it records the number of tickets that were in play when the draw was requested.
3. Find the `DrawResult` event: it records the winner, the ticket index, the amounts paid and the random number used.
4. `ticketIndex` equals `randomNumber mod ticketCount`. Anyone can check that calculation.

## This repository

- `index.html` — the website. A static page that talks to the contract through the visitor’s wallet. No backend.
- `Only2USD.sol` — the contract source.

## Disclaimer

This is a game of chance with a negative expected return. Most tickets never win. Play only with money you can afford to lose. You must be 18 or older, and online lotteries are restricted or illegal in some jurisdictions; it is your responsibility to know whether you may take part where you live.
