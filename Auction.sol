// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";


contract AuctionFactory is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;

    Counters.Counter private _auctionIds;
    mapping(uint256 => address) public auctions;
    mapping(address => bool) public approvedAuctions;

    uint256 public constant FEE_MULTIPLIER = 10000;
    uint256 public constant MIN_AUCTION_DURATION = 2 minutes;
    uint256 public constant MAX_AUCTION_DURATION = 7 minutes;

    event AuctionCreated(uint256 auctionId, address auctionAddress);
    event AuctionApproved(uint256 auctionId);

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Creates a new Dutch auction.
     * @param _startPrice Starting price of the auction.
     * @param _minimumPrice Minimum price of the auction.
     * @param _itemName Name of the item being auctioned.
     * @param _ipfsHash IPFS hash of additional item details.
     * @param _platformFee Platform fee percentage in basis points (e.g., 1000 for 10%).
     * @return The ID of the newly created auction.
     */
    function createAuction(
        uint256 _startPrice,
        uint256 _minimumPrice,
        string memory _itemName,
        string memory _ipfsHash,
        uint256 _platformFee
    ) external returns (uint256) {
        require(_platformFee >= 500 && _platformFee <= 1500, "Platform fee must be between 5% and 15%");
        require(_startPrice > _minimumPrice, "Start price must be greater than minimum price");

        _auctionIds.increment();
        uint256 newAuctionId = _auctionIds.current();

        // Generate discount steps for the Dutch auction
        DutchAuction.DiscountStep[] memory discountSteps = generateDiscountSteps(_startPrice, _minimumPrice);

        // Deploy a new Dutch auction contract
        DutchAuction newAuction = new DutchAuction(
            _startPrice,
            discountSteps,
            _minimumPrice,
            _itemName,
            _ipfsHash,
            msg.sender,
            payable(address(this)),
            _platformFee
        );

        // Store the address of the new auction and mark it as not approved initially
        auctions[newAuctionId] = address(newAuction);
        approvedAuctions[address(newAuction)] = false;

        emit AuctionCreated(newAuctionId, address(newAuction));

        return newAuctionId;
    }

    /**
     * @dev Generates random discount steps for the Dutch auction.
     * @param _startPrice Starting price of the auction.
     * @param _minimumPrice Minimum price of the auction.
     * @return An array of DiscountStep structs representing the auction's pricing steps.
     */
    function generateDiscountSteps(uint256 _startPrice, uint256 _minimumPrice) private view returns (DutchAuction.DiscountStep[] memory) {
        uint256 totalDuration = MIN_AUCTION_DURATION + (block.timestamp % (MAX_AUCTION_DURATION - MIN_AUCTION_DURATION));
        uint256 numSteps = 3 + (block.timestamp % 3); // 3 to 5 steps

        DutchAuction.DiscountStep[] memory steps = new DutchAuction.DiscountStep[](numSteps);
        uint256 remainingDuration = totalDuration;
        uint256 remainingDiscount = _startPrice - _minimumPrice;

        for (uint i = 0; i < numSteps; i++) {
            uint256 stepDuration;
            uint256 stepRate;

            if (i == numSteps - 1) {
                stepDuration = remainingDuration;
                stepRate = remainingDiscount / stepDuration;
            } else {
                stepDuration = remainingDuration / (numSteps - i);
                stepRate = (remainingDiscount / (numSteps - i)) / stepDuration;
            }

            steps[i] = DutchAuction.DiscountStep(stepRate, stepDuration);
            remainingDuration -= stepDuration;
            remainingDiscount -= stepRate * stepDuration;
        }

        return steps;
    }

    /**
     * @dev Approves an auction for activation.
     * @param auctionId ID of the auction to approve.
     */
    function approveAuction(uint256 auctionId) external onlyOwner {
        address auctionAddress = auctions[auctionId];
        require(auctionAddress != address(0), "Auction does not exist");
        approvedAuctions[auctionAddress] = true;
        emit AuctionApproved(auctionId);
    }

    /**
     * @dev Withdraws all accumulated fees to the owner's address.
     */
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        payable(owner()).transfer(balance);
    }

    receive() external payable {}
}








contract DutchAuction is ReentrancyGuard {
    struct DiscountStep {
        uint256 rate;  // wei per second
        uint256 duration;  // in seconds
    }

    uint256 private immutable startPrice;     // in wei
    uint256 private immutable minimumPrice;   // in wei
    uint256 private immutable startTime;      // Unix timestamp in seconds
    uint256 private immutable auctionDuration;  // in seconds
    uint256 private immutable actualPrice;    // in wei
    string public itemName;
    string public ipfsHash;
    address public immutable seller;
    address payable public immutable factory;  // Make factory address payable
    uint256 public immutable platformFee;  // in basis points (1/100 of a percent)
    uint256 public constant FEE_MULTIPLIER = 10000;

    DiscountStep[] public discountSteps;

    enum AuctionStatus { Pending, Active, Ended, Unsold }
    AuctionStatus public status;

    address public winner;
    uint256 public finalPrice;  // in wei
    int256 public totalProfit;  // in wei, can be negative

    event AuctionEnded(address winner, uint256 amount);
    event AuctionUnsold();
    event AuctionActivated(address auctionAddress);

    /**
     * @dev Constructor to initialize the Dutch auction.
     * @param _startPrice Starting price of the auction.
     * @param _discountSteps Array of DiscountStep structs defining pricing steps.
     * @param _minimumPrice Minimum price of the auction.
     * @param _itemName Name of the item being auctioned.
     * @param _ipfsHash IPFS hash of additional item details.
     * @param _seller Address of the auction seller.
     * @param _factory Address of the AuctionFactory contract.
     * @param _platformFee Platform fee percentage in basis points (e.g., 1000 for 10%).
     */
    constructor(
        uint256 _startPrice,
        DiscountStep[] memory _discountSteps,
        uint256 _minimumPrice,
        string memory _itemName,
        string memory _ipfsHash,
        address _seller,
        address payable _factory,
        uint256 _platformFee
    ) {
        require(_startPrice >= _minimumPrice, "Start price must be greater than or equal to minimum price");
        require(_discountSteps.length > 0, "No discount steps provided");
        
        startPrice = _startPrice;
        minimumPrice = _minimumPrice;
        itemName = _itemName;
        ipfsHash = _ipfsHash;
        seller = _seller;
        factory = _factory;
        platformFee = _platformFee;
        status = AuctionStatus.Pending;

        // Initialize auctionDuration and startTime
        uint256 totalDuration = 0;
        for (uint i = 0; i < _discountSteps.length; i++) {
            discountSteps.push(_discountSteps[i]);
            totalDuration += _discountSteps[i].duration;
        }
        auctionDuration = totalDuration;
        startTime = block.timestamp;

        // Initialize actualPrice with a pseudo-random number greater than minimumPrice
        actualPrice = _minimumPrice + (uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % (_startPrice - _minimumPrice));
    }

    /**
     * @dev Returns the current price of the auction based on elapsed time.
     * @return Current price of the auction in wei.
     */
    function getPrice() public view returns (uint256) {
        if (status != AuctionStatus.Active) {
            return 0; // Price is 0 if auction is not active
        }
        
        uint256 elapsedTime = block.timestamp - startTime;
        uint256 currentPrice = startPrice;
        uint256 stepStartTime = 0;

        for (uint i = 0; i < discountSteps.length; i++) {
            DiscountStep memory step = discountSteps[i];
            uint256 stepEndTime = stepStartTime + step.duration;

            if (elapsedTime < stepEndTime) {
                uint256 timeInStep = elapsedTime - stepStartTime;
                uint256 discount = step.rate * timeInStep;
                currentPrice = currentPrice > discount ? currentPrice - discount : minimumPrice;
                break;
            } else {
                uint256 discount = step.rate * step.duration;
                currentPrice = currentPrice > discount ? currentPrice - discount : minimumPrice;
            }

            stepStartTime = stepEndTime;
        }

        return currentPrice > minimumPrice ? currentPrice : minimumPrice;
    }

    /**
     * @dev Allows a bidder to purchase the item at the current auction price.
     */
    function buy() external payable nonReentrant {
        require(status == AuctionStatus.Active, "Auction not active");

        uint256 price = getPrice();
        require(price > 0, "Invalid price");
        require(msg.value >= price, "Insufficient value sent");

        status = AuctionStatus.Ended;
        winner = msg.sender;
        finalPrice = price;

        uint256 fee = (price * platformFee) / FEE_MULTIPLIER;
        uint256 sellerProceeds = price - fee;

        (bool feeSuccess, ) = factory.call{value: fee}("");
        require(feeSuccess, "Fee transfer failed");

        (bool sellerSuccess, ) = payable(seller).call{value: sellerProceeds}("");
        require(sellerSuccess, "Seller transfer failed");

        uint256 refund = msg.value - price;
        if (refund > 0) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: refund}("");
            require(refundSuccess, "Refund failed");
        }

        // Calculate total profit (can be negative)
        totalProfit = int256(finalPrice) - int256(actualPrice);

        emit AuctionEnded(msg.sender, price);
    }

    /**
     * @dev Returns the details of the auction.
     * @return currentPrice Current price of the auction.
     * @return _minimumPrice Minimum price of the auction.
     * @return _startTime Start time of the auction.
     * @return _duration Duration of the auction.
     * @return _itemName Name of the item being auctioned.
     * @return _status Current status of the auction.
     * @return _winner Address of the winning bidder.
     * @return _finalPrice Final price paid by the winning bidder.
     * @return _actualPrice The actual price of the item.
     * @return _totalProfit Total profit or loss from the auction.
     */
    function getAuctionInfo() external view returns (
        uint256 currentPrice,
        uint256 _minimumPrice,
        uint256 _startTime,
        uint256 _duration,
        string memory _itemName,
        AuctionStatus _status,
        address _winner,
        uint256 _finalPrice,
        uint256 _actualPrice,
        int256 _totalProfit
    ) {
        return (
            getPrice(),
            minimumPrice,
            startTime,
            auctionDuration,
            itemName,
            status,
            winner,
            finalPrice,
            actualPrice,
            totalProfit
        );
    }

    /**
     * @dev Activates the auction, making it available for bidding.
     */
    function activateAuction() external {
        require(AuctionFactory(factory).approvedAuctions(address(this)), "Auction not approved");
        require(status == AuctionStatus.Pending, "Auction already active or ended");

        status = AuctionStatus.Active;
        emit AuctionActivated(address(this));
    }

    /**
     * @dev Ends the auction without a sale if the auction duration has passed.
     */
    function endAuctionIfUnsold() external {
        require(status == AuctionStatus.Active, "Auction not active");

        uint256 elapsedTime = block.timestamp - startTime;
        if (elapsedTime >= auctionDuration) {
            status = AuctionStatus.Unsold;
            emit AuctionUnsold();
        }
    }
}
