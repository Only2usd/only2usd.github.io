// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEntropyV2 {
    function getFeeV2(uint32 gasLimit) external view returns (uint128 feeAmount);
    function requestV2(uint32 gasLimit) external payable returns (uint64 assignedSequenceNumber);
}

abstract contract EntropyConsumer {
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        address entropy = getEntropy();
        require(entropy != address(0), "entropy not set");
        require(msg.sender == entropy, "only entropy");
        entropyCallback(sequence, provider, randomNumber);
    }
    function getEntropy() internal view virtual returns (address);
    function entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) internal virtual;
}

contract Only2USD is EntropyConsumer {
    string  public constant RULES = "1 ticket = 2.00 USDC. Tickets last until they win. Max 25 active tickets per wallet. Every Sunday 17:00 UTC one ticket wins 33% of the pool; the winning ticket is burned, 67% rolls over. Up to 7% of the prize goes to the developer (can only be lowered). Rules never change.";
    uint256 public constant TICKET_PRICE = 2_000_000;
    uint256 public constant MAX_TICKETS_PER_WALLET = 25;
    uint256 public constant PAYOUT_BPS = 3300;
    uint256 public constant MAX_DEV_FEE_BPS = 700;
    uint256 public constant DRAW_INTERVAL = 7 days;
    uint32  public constant CALLBACK_GAS_LIMIT = 250_000;

    IERC20 public immutable usdc;
    IEntropyV2 public immutable entropy;

    address public owner;
    address public feeRecipient;
    uint256 public devFeeBps = MAX_DEV_FEE_BPS;

    address[] public tickets;
    mapping(address => uint256) public activeTickets;
    mapping(address => uint256) public claimable;

    uint256 public pool;
    uint256 public totalClaimable;
    uint256 public nextDrawTime;
    uint256 public drawCount;

    bool    public drawPending;
    uint64  public pendingSequence;
    uint256 public pendingTicketCount;

    bool private locked;

    event TicketsBought(address indexed buyer, uint256 count, uint256 firstIndex);
    event Sponsor(address indexed from, uint256 amount);
    event DrawRequested(uint256 indexed drawId, uint64 sequence, uint256 ticketCount, uint256 poolBefore);
    event DrawResult(uint256 indexed drawId, address indexed winner, uint256 ticketIndex, uint256 winnerAmount, uint256 devAmount, bytes32 randomNumber);
    event DrawSkipped(uint256 indexed drawId, uint256 nextDrawTime);
    event Claimed(address indexed to, uint256 amount);
    event DevFeeLowered(uint256 oldBps, uint256 newBps);
    event FeeRecipientChanged(address oldRecipient, address newRecipient);
    event OwnershipTransferred(address oldOwner, address newOwner);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier nonReentrant() { require(!locked, "reentrancy"); locked = true; _; locked = false; }

    constructor(address _usdc, address _entropy, address _feeRecipient) {
        require(_usdc != address(0) && _entropy != address(0) && _feeRecipient != address(0), "zero address");
        usdc = IERC20(_usdc);
        entropy = IEntropyV2(_entropy);
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        uint256 firstSunday17 = 3 days + 17 hours;
        nextDrawTime = firstSunday17 + ((block.timestamp - firstSunday17) / DRAW_INTERVAL + 1) * DRAW_INTERVAL;
    }

    function ticketCount() external view returns (uint256) { return tickets.length; }
    function drawFee() external view returns (uint256) { return entropy.getFeeV2(CALLBACK_GAS_LIMIT); }
    function currentPrize() external view returns (uint256 winnerAmount, uint256 devAmount) {
        uint256 payout = (pool * PAYOUT_BPS) / 10_000;
        devAmount = (payout * devFeeBps) / 10_000;
        winnerAmount = payout - devAmount;
    }

    function getTickets(uint256 from, uint256 to) external view returns (address[] memory out) {
        if (to > tickets.length) to = tickets.length;
        require(from <= to, "bad range");
        out = new address[](to - from);
        for (uint256 i = from; i < to; i++) out[i - from] = tickets[i];
    }

    function buyTickets(uint256 count) external nonReentrant {
        require(count > 0, "count=0");
        require(activeTickets[msg.sender] + count <= MAX_TICKETS_PER_WALLET, "max 25 tickets per wallet");
        uint256 cost = count * TICKET_PRICE;
        require(usdc.transferFrom(msg.sender, address(this), cost), "USDC transfer failed");
        pool += cost;
        activeTickets[msg.sender] += count;
        uint256 firstIndex = tickets.length;
        for (uint256 i = 0; i < count; i++) tickets.push(msg.sender);
        emit TicketsBought(msg.sender, count, firstIndex);
    }

    function sponsor(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(usdc.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
        pool += amount;
        emit Sponsor(msg.sender, amount);
    }

    function sweepToPool() external {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 accounted = pool + totalClaimable;
        require(bal > accounted, "nothing to sweep");
        uint256 extra = bal - accounted;
        pool += extra;
        emit Sponsor(address(0), extra);
    }

    function draw() external payable nonReentrant {
        require(block.timestamp >= nextDrawTime, "too early");
        require(!drawPending, "draw pending");
        drawCount += 1;
        if (tickets.length == 0 || pool == 0) {
            _advanceWeek();
            emit DrawSkipped(drawCount, nextDrawTime);
            return;
        }
        uint256 fee = entropy.getFeeV2(CALLBACK_GAS_LIMIT);
        require(address(this).balance >= fee, "insufficient ETH for entropy fee");
        drawPending = true;
        pendingTicketCount = tickets.length;
        pendingSequence = entropy.requestV2{value: fee}(CALLBACK_GAS_LIMIT);
        emit DrawRequested(drawCount, pendingSequence, pendingTicketCount, pool);
    }

    function entropyCallback(uint64 sequence, address, bytes32 randomNumber) internal override {
        if (!drawPending || sequence != pendingSequence) return;
        drawPending = false;
        uint256 n = pendingTicketCount;
        if (n == 0 || pool == 0) {
            _advanceWeek();
            emit DrawSkipped(drawCount, nextDrawTime);
            return;
        }
        uint256 idx = uint256(randomNumber) % n;
        address winner = tickets[idx];
        uint256 last = tickets.length - 1;
        if (idx != last) tickets[idx] = tickets[last];
        tickets.pop();
        activeTickets[winner] -= 1;
        uint256 payout = (pool * PAYOUT_BPS) / 10_000;
        uint256 devAmount = (payout * devFeeBps) / 10_000;
        uint256 winnerAmount = payout - devAmount;
        pool -= payout;
        _payOrCredit(winner, winnerAmount);
        if (devAmount > 0) _payOrCredit(feeRecipient, devAmount);
        _advanceWeek();
        emit DrawResult(drawCount, winner, idx, winnerAmount, devAmount, randomNumber);
    }

    function _payOrCredit(address to, uint256 amount) internal {
        bool ok;
        try usdc.transfer(to, amount) returns (bool r) { ok = r; } catch { ok = false; }
        if (!ok) {
            claimable[to] += amount;
            totalClaimable += amount;
        }
    }

    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "nothing to claim");
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        require(usdc.transfer(msg.sender, amount), "USDC transfer failed");
        emit Claimed(msg.sender, amount);
    }

    function _advanceWeek() internal {
        do { nextDrawTime += DRAW_INTERVAL; } while (nextDrawTime <= block.timestamp);
    }

    function lowerDevFee(uint256 newBps) external onlyOwner {
        require(newBps < devFeeBps, "can only lower");
        emit DevFeeLowered(devFeeBps, newBps);
        devFeeBps = newBps;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "zero address");
        emit FeeRecipientChanged(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        (bool ok, ) = owner.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {}

    function getEntropy() internal view override returns (address) { return address(entropy); }
}
