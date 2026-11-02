# StablePay SME – prototype
Escrow + oracle-priced atomic FX settlement for SME stablecoin payments.
- `contracts/StablePay.sol` – settlement contract, MockStable (USDC/EURC), MockFeed (Chainlink-style)
- `npm i` then `node compile.js` then `node test/stablepay.test.js` (7 tests, in-memory chain)
- `dapp/StablePay_DApp.html` – open in a browser; runs the real contract on an in-page chain (no wallet needed)
- `deploy.js` – deploy to Sepolia; then use real Chainlink feeds via setFeed()
