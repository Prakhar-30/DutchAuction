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
