// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract MinuteMarkets {
  enum Winner {
    UNSET,
    UP,
    DOWN,
    HOUSE,
    REFUND
  }

  enum Position {
    UP,
    DOWN
  }

  enum Status {
    OPEN,
    LIVE,
    RESOLVED,
    CANCELLED
  }

  struct Market {
    uint256 oldPrice;
    uint256 newPrice;
    Winner winner;
    uint256 upPool;
    uint256 downPool;
    uint256 winnerOdds;
    Status status;
    bool houseClaimed;
    uint256 openedAt;
    uint256 lockedAt;
    uint256 resolvedAt;
  }

  struct Bet {
    address addr;
    Position position;
    uint256 amount;
    uint256 marketId;
    bool claimed;
    bool cancelled;
  }

  address public admin;
  address public houseAddress;
  address public platformAddress;

  uint256 public platformFee;
  uint256 public minimumTradeAmount;
  uint256 public marketTimeSeconds;

  uint256 public currentMarketId;
  uint256 public nextBetId;

  uint256 public precisionFactor;

  mapping(uint256 => Market) public markets;
  mapping(uint256 => Bet) public bets;
  mapping(address => bool) public authorizedPriceSigners;
  mapping(address => bool) public authorizedAutomators;

  constructor (
    address _admin,
    address _houseAddress,
    address _platformAddress,
    uint256 _platformFee,
    uint256 _minimumTradeAmount,
    uint256 _marketTimeSeconds,
    uint256 _precisionFacor,
    address[] memory _authorizedPriceSigners,
    address[] memory _authorizedAutomators
  ) {
    admin = _admin;
    houseAddress = _houseAddress;
    platformAddress = _platformAddress;

    platformFee = _platformFee;
    minimumTradeAmount = _minimumTradeAmount;
    marketTimeSeconds = _marketTimeSeconds;

    currentMarketId = 1;
    nextBetId = 0;

    precisionFactor = _precisionFacor;

    for (uint256 i = 0; i < _authorizedPriceSigners.length; i++){
      authorizedPriceSigners[_authorizedPriceSigners[i]] = true;
    }
    for (uint256 i = 0; i < _authorizedAutomators.length; i++){
      authorizedAutomators[_authorizedAutomators[i]] = true;
    }
  }

  modifier onlyAdmin() {
    require(msg.sender == admin, "Only admin");
    _;
  }
  modifier onlyAuthorizedPriceSigner() {
    require(authorizedPriceSigners[msg.sender], "Only authorized price signer");
    _;
  }
  modifier onlyAuthorizedAutomator() {
    require(authorizedAutomators[msg.sender], "Only authorized automator");
    _;
  }

  function updateAdmin(address _newAdmin) public onlyAdmin {
    require(_newAdmin != address(0), "Invalid newAdmin");

    admin = _newAdmin;
  }

  function updateAddresses(
      address _houseAddress,
      address _platformAddress
  ) public onlyAdmin {
    houseAddress = _houseAddress;
    platformAddress = _platformAddress;
  }

  function updateFeeAndMinTradeAmount(
      uint256 _platformFee,
      uint256 _minimumTradeAmount
  ) public onlyAdmin {
    platformFee = _platformFee;
    minimumTradeAmount = _minimumTradeAmount;

  }

  function updateMarketTimeSeconds(
      uint256 _marketTimeSeconds
  ) public onlyAdmin {
    marketTimeSeconds = _marketTimeSeconds;
  }

  function addAuthorizedPriceSigner(address _signer)
      public
      onlyAdmin
  {
    authorizedPriceSigners[_signer] = true;
  }
  function removeAuthorizedPriceSigner(address _signer)
      public
      onlyAdmin
  {
    authorizedPriceSigners[_signer] = false;
  }

  function addAuthorizedAutomator(address _automator)
      public
      onlyAdmin
  {
    authorizedAutomators[_automator] = true;
  }
  function removeAuthorizedAutomator(address _automator)
      public
      onlyAdmin
  {
    authorizedAutomators[_automator] = false;
  }

  function newMarket(uint256 _prevMarketId) internal {
    currentMarketId++;

    require(_prevMarketId + 1 == currentMarketId);

    Market storage market = markets[currentMarketId];

    market.oldPrice = 0;
    market.newPrice = 0;
    market.winner = Winner.UNSET;
    market.upPool = 0;
    market.downPool = 0;
    market.winnerOdds = 0;
    market.status = Status.OPEN;
    market.houseClaimed = false;

    market.openedAt = block.timestamp;
    market.lockedAt = block.timestamp + marketTimeSeconds;
    market.resolvedAt = block.timestamp + (2 * marketTimeSeconds);
  }

  function liveMarket(uint256 _prevMarketId) internal {
    uint256 liveMarketId = _prevMarketId + 1;

    Market storage prevMarket = markets[_prevMarketId];
    Market storage market = markets[liveMarketId];

    market.status = Status.LIVE;
    market.oldPrice = prevMarket.newPrice;

    newMarket(liveMarketId);
  }

  function resolveMarket(
    uint256 _marketId,
    uint256 _newPrice
) public onlyAuthorizedPriceSigner {
    Market storage market = markets[_marketId];

    require(market.status == Status.LIVE, "Market is not LIVE");
    require(block.timestamp >= market.resolvedAt, "Market not ready to resolve");

    market.newPrice = _newPrice;

    uint256 totalPool = market.upPool + market.downPool;

    if (_newPrice > market.oldPrice && market.upPool > 0) {
        market.winner = Winner.UP;
        market.winnerOdds =
            (totalPool * precisionFactor) /
            market.upPool;
    } else if (_newPrice < market.oldPrice && market.downPool > 0) {
        market.winner = Winner.DOWN;
        market.winnerOdds =
            (totalPool * precisionFactor) /
            market.downPool;
    } else {
        market.winner = Winner.HOUSE;
        market.winnerOdds = 0;
    }

    market.status = Status.RESOLVED;

    liveMarket(_marketId);
  }

  function cancelMarket(uint256 _marketId)
    public
    onlyAuthorizedPriceSigner
  {
    Market storage market = markets[_marketId];

    require(market.status == Status.LIVE, "Market is not LIVE");
    require(block.timestamp >= market.resolvedAt, "Market not ready to cancel");

    market.winner = Winner.REFUND;
    market.winnerOdds = precisionFactor;
    market.status = Status.CANCELLED;

    liveMarket(_marketId);
  }

  function placeBet(Position _position)
    public
    payable
    returns (uint256 betId)
  {
    Market storage market = markets[currentMarketId];

    require(market.status == Status.OPEN, "Market is not OPEN");
    require(block.timestamp < market.lockedAt, "Market is locked");
    require(msg.value >= minimumTradeAmount, "Trade amount too small");

    if (_position == Position.UP) {
        market.upPool += msg.value;
    } else {
        market.downPool += msg.value;
    }

    betId = nextBetId;
    bets[betId] = Bet({
        addr: msg.sender,
        position: _position,
        amount: msg.value,
        marketId: currentMarketId,
        claimed: false,
        cancelled: false
    });

    nextBetId++;
  }

  function cancelBet(uint256 _betId) public {
    Bet storage bet = bets[_betId];
    Market storage market = markets[bet.marketId];

    require(market.status == Status.OPEN, "Market is not OPEN");
    require(!bet.cancelled, "Bet already cancelled");
    require(!bet.claimed, "Bet already claimed");
    require(msg.sender == bet.addr, "Not bet owner");

    if (bet.position == Position.UP) {
        market.upPool -= bet.amount;
    } else {
        market.downPool -= bet.amount;
    }

    bet.cancelled = true;

    payable(bet.addr).transfer(bet.amount);
  }

  function claimBet(uint256 _betId) public {
    Bet storage bet = bets[_betId];
    Market storage market = markets[bet.marketId];

    require(market.winner != Winner.HOUSE, "House won");
    require(!bet.claimed, "Bet already claimed");
    require(!bet.cancelled, "Bet already cancelled");
    require(msg.sender == bet.addr, "Not bet owner");
    require(
        market.status == Status.RESOLVED ||
        market.status == Status.CANCELLED,
        "Market not settled"
    );

    uint256 payout;

    if (market.winner == Winner.REFUND) {
        payout = bet.amount;
    } else {
        if (
            (bet.position == Position.UP && market.winner == Winner.UP) ||
            (bet.position == Position.DOWN && market.winner == Winner.DOWN)
        ) {
            uint256 gross =
                (bet.amount * market.winnerOdds) /
                precisionFactor;

            uint256 fee =
                (gross * platformFee) /
                precisionFactor;

            payout = gross - fee;

            payable(platformAddress).transfer(fee);
        } else {
            revert("Not a winner");
        }
    }

    bet.claimed = true;

    payable(bet.addr).transfer(payout);
  }

  function claimHouse(uint256 _marketId) public {
    Market storage market = markets[_marketId];

    require(!market.houseClaimed, "Already claimed");
    require(market.status == Status.RESOLVED, "Market not resolved");
    require(market.winner == Winner.HOUSE, "House did not win");

    market.houseClaimed = true;

    payable(houseAddress).transfer(
        market.upPool + market.downPool
    );
  }
}
