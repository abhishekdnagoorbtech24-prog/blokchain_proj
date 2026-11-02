// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 v) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// Chainlink AggregatorV3-compatible subset (swap in real feeds on Sepolia/mainnet)
interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// Minimal 6-decimal stablecoin for local testing (stands in for USDC / EURC)
contract MockStable {
    string public name; string public symbol; uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) external returns (bool) { _mv(msg.sender, to, v); return true; }
    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        require(allowance[f][msg.sender] >= v, "allowance"); allowance[f][msg.sender] -= v; _mv(f, t, v); return true;
    }
    function _mv(address f, address t, uint256 v) internal { require(balanceOf[f] >= v, "balance"); balanceOf[f] -= v; balanceOf[t] += v; }
}

/// Mock oracle with 8 decimals (same shape as a Chainlink USD feed)
contract MockFeed is IPriceFeed {
    int256 public price; uint256 public updatedAt;
    constructor(int256 p) { price = p; updatedAt = block.timestamp; }
    function set(int256 p) external { price = p; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (1, price, 0, updatedAt, 1); }
}

/// Escrow + atomic FX settlement for SME cross-border supplier payments
contract StablePaySettlement {
    enum Status { None, Pending, Settled, Cancelled }
    struct Payment {
        address payer; address supplier; address tokenIn; address tokenOut;
        uint256 amountIn; uint256 minOut; uint256 amountOut; bytes32 invoiceRef; Status status;
    }

    address public owner;
    uint256 public feeBps = 50;               // 0.50% platform fee (vs 5-7% bank fees)
    uint256 public maxOracleAge = 1 hours;    // stale-price guard
    uint256 public nextId; uint256 public feesCollected;
    bool public paused; bool private _lock;
    mapping(address => bool) public kyc;                 // KYC/AML allow-list
    mapping(address => IPriceFeed) public usdFeed;       // token => X/USD feed (8 dec)
    mapping(uint256 => Payment) public payments;

    event PaymentCreated(uint256 indexed id, address indexed payer, address indexed supplier, uint256 amountIn, bytes32 invoiceRef);
    event PaymentSettled(uint256 indexed id, uint256 amountOut, uint256 fee, int256 rateIn, int256 rateOut);
    event PaymentCancelled(uint256 indexed id);
    event KycSet(address indexed user, bool ok);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier whenNotPaused() { require(!paused, "paused"); _; }
    modifier nonReentrant() { require(!_lock, "reentrancy"); _lock = true; _; _lock = false; }

    constructor() { owner = msg.sender; }

    function setKyc(address u, bool ok) external onlyOwner { kyc[u] = ok; emit KycSet(u, ok); }
    function setFeed(address token, address feed) external onlyOwner { usdFeed[token] = IPriceFeed(feed); }
    function setFeeBps(uint256 b) external onlyOwner { require(b <= 200, "fee too high"); feeBps = b; }
    function setPaused(bool p) external onlyOwner { paused = p; }

    /// Liquidity provider / treasury funds the settlement-currency pool
    function fundLiquidity(address token, uint256 amt) external { require(IERC20(token).transferFrom(msg.sender, address(this), amt), "fund"); }

    /// Live FX quote: how much tokenOut the supplier receives for amountIn of tokenIn (after fee)
    function quote(address tIn, address tOut, uint256 amountIn) public view returns (uint256 out, uint256 fee, int256 rIn, int256 rOut) {
        rIn = _price(tIn); rOut = _price(tOut);
        uint256 gross = (amountIn * uint256(rIn)) / uint256(rOut);
        fee = (gross * feeBps) / 10_000;
        out = gross - fee;
    }

    function _price(address token) internal view returns (int256 p) {
        IPriceFeed f = usdFeed[token]; require(address(f) != address(0), "no feed");
        uint256 ts; (, p, , ts, ) = f.latestRoundData();
        require(p > 0, "bad price"); require(block.timestamp - ts <= maxOracleAge, "stale oracle");
    }

    /// Step 1: payer locks stablecoin in escrow
    function createPayment(address supplier, address tIn, address tOut, uint256 amountIn, uint256 minOut, bytes32 ref)
        external whenNotPaused nonReentrant returns (uint256 id)
    {
        require(kyc[msg.sender], "payer not KYC"); require(kyc[supplier], "supplier not KYC");
        require(amountIn > 0, "zero amount");
        require(IERC20(tIn).transferFrom(msg.sender, address(this), amountIn), "escrow lock");
        id = ++nextId;
        payments[id] = Payment(msg.sender, supplier, tIn, tOut, amountIn, minOut, 0, ref, Status.Pending);
        emit PaymentCreated(id, msg.sender, supplier, amountIn, ref);
    }

    /// Step 2: atomic FX swap + release; all-or-nothing in one transaction
    function settle(uint256 id) external whenNotPaused nonReentrant {
        Payment storage p = payments[id];
        require(p.status == Status.Pending, "not pending");
        require(msg.sender == p.payer || msg.sender == owner, "not authorised");
        (uint256 out, uint256 fee, int256 rIn, int256 rOut) = quote(p.tokenIn, p.tokenOut, p.amountIn);
        require(out >= p.minOut, "slippage");
        require(IERC20(p.tokenOut).balanceOf(address(this)) >= out, "no liquidity");
        p.status = Status.Settled; p.amountOut = out; feesCollected += fee;
        require(IERC20(p.tokenOut).transfer(p.supplier, out), "payout");
        emit PaymentSettled(id, out, fee, rIn, rOut);
    }

    /// Payer can reclaim escrowed funds while payment is still pending
    function cancel(uint256 id) external nonReentrant {
        Payment storage p = payments[id];
        require(p.status == Status.Pending, "not pending"); require(msg.sender == p.payer, "not payer");
        p.status = Status.Cancelled;
        require(IERC20(p.tokenIn).transfer(p.payer, p.amountIn), "refund");
        emit PaymentCancelled(id);
    }
}
