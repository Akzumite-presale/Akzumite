// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract AkzumitePresale is Ownable, ReentrancyGuard {
    using Address for address;

    IERC20 public immutable akzumiteToken = IERC20(0x8e29bf81cd0e0645d7565db2311bf3bfbc3cdfde); // AKZ token address
    uint256 public constant TOTAL_SUPPLY = 2100000000 * 10 ** 18; // 2.1 billion total supply with 18 decimals
    uint256 public constant TOTAL_PRESALE_PERCENTAGE = 10; // 10% of total tokens for presale
    uint256 public constant START_PRICE_USDT = 0.9 * 10 ** 18; // Starting price in USDT (0.9 USDT per token)
    uint256 public constant STAGE_INCREMENT_PERCENTAGE = 10; // 10% price increase per stage
    uint256 public constant FIRST_STAGE_DURATION = 25 days;
    uint256 public constant OTHER_STAGE_DURATION = 10 days;
    uint256 public presaleStartTime;
    uint256 public totalTokensForPresale;
    uint256 public tokensPerStage;
    uint256 public currentStage = 0;
    uint256 public tokensSold = 0;

    uint256 public maxTokensPerWallet = 50000 * 10 ** 18; // Limit per wallet (50,000 tokens)
    uint256 public bnbPriceForCurrentStage; // BNB price equivalent for the current stage
    bool public saleActive = true; // Emergency stop
    uint256 public referralBonusPercentage = 5; // 5% referral bonus
    uint256 public vestingBonusPercentage = 3; // 3% bonus for choosing vesting
    mapping(address => bool) public whitelist;
    mapping(uint256 => uint256) public stagePricesUSDT; // Price in USDT per stage
    mapping(uint256 => uint256) public stageEndTimes;
    mapping(address => uint256) public tokensPurchased; // Track tokens per wallet

    event TokensPurchased(address indexed buyer, uint256 amount, uint256 cost, address referrer);
    event StageAdvanced(uint256 newStage, uint256 newPrice, uint256 newEndTime);
    event FundsWithdrawn(uint256 amount, address indexed owner);
    event BNBPriceUpdated(uint256 newPrice);
    event SaleStatusUpdated(bool status);
    event ReferralRewarded(address referrer, uint256 rewardAmount);

    constructor() {
        // Set total tokens for presale based on 10% of the total supply
        totalTokensForPresale = (TOTAL_SUPPLY * TOTAL_PRESALE_PERCENTAGE) / 100;
        tokensPerStage = totalTokensForPresale / 10;

        // Calculate stage prices based on the initial price in USDT
        stagePricesUSDT[0] = START_PRICE_USDT;
        for (uint256 i = 1; i < 10; i++) {
            stagePricesUSDT[i] = stagePricesUSDT[i - 1] + (stagePricesUSDT[i - 1] * STAGE_INCREMENT_PERCENTAGE) / 100;
        }
        
        // Set stage end times
        presaleStartTime = block.timestamp;
        stageEndTimes[0] = presaleStartTime + FIRST_STAGE_DURATION;
        for (uint256 i = 1; i < 10; i++) {
            stageEndTimes[i] = stageEndTimes[i - 1] + OTHER_STAGE_DURATION;
        }
    }

    // Function to update the BNB price equivalent for the current stage, called by the owner
    function updateBNBPriceForCurrentStage(uint256 _bnbPrice) external onlyOwner {
        require(_bnbPrice > 0, "Price must be greater than 0");
        require(
            _bnbPrice >= (bnbPriceForCurrentStage * 80) / 100 &&
            _bnbPrice <= (bnbPriceForCurrentStage * 120) / 100,
            "Price deviation too high"
        );
        bnbPriceForCurrentStage = _bnbPrice;
        emit BNBPriceUpdated(bnbPriceForCurrentStage);
    }

    // Function to set referral bonus percentage
    function setReferralBonusPercentage(uint256 _percentage) external onlyOwner {
        referralBonusPercentage = _percentage;
    }

    // Tiered bonus based on the amount purchased
    function calculateTieredBonus(uint256 _amount) public view returns (uint256) {
        if (_amount >= 100000 * 10 ** 18) return (_amount * 15) / 100; // 15% bonus for large buyers
        if (_amount >= 50000 * 10 ** 18) return (_amount * 10) / 100; // 10% bonus for medium buyers
        return (_amount * 5) / 100; // 5% bonus for smaller buyers
    }

    // Buy tokens with an optional referrer address
    function buyTokens(uint256 _amount, address referrer, bool vesting) external payable nonReentrant {
        require(saleActive, "Sale is paused");
        require(block.timestamp < stageEndTimes[9], "Presale has ended");
        require(_amount > 0, "Must purchase a positive amount of tokens");

        uint256 costInBNB = (_amount * bnbPriceForCurrentStage) / (10 ** 18);
        require(msg.value >= costInBNB, "Insufficient BNB for purchase");
        require(tokensSold + _amount <= tokensPerStage * (currentStage + 1), "Not enough tokens in current stage");

        tokensSold += _amount;
        tokensPurchased[msg.sender] += _amount;

        // Calculate tiered and referral bonuses
        uint256 totalBonus = calculateTieredBonus(_amount);
        if (vesting) totalBonus += (_amount * vestingBonusPercentage) / 100;

        // Transfer tokens including bonuses to buyer
        require(akzumiteToken.transfer(msg.sender, _amount + totalBonus), "Token transfer failed");
        emit TokensPurchased(msg.sender, _amount, costInBNB, referrer);

        // Apply referral bonus if referrer is valid and different from the buyer
        if (referrer != address(0) && referrer != msg.sender) {
            uint256 referralBonus = (_amount * referralBonusPercentage) / 100;
            require(akzumiteToken.transfer(referrer, referralBonus), "Referral transfer failed");
            emit ReferralRewarded(referrer, referralBonus);
        }

        if (tokensSold >= tokensPerStage * (currentStage + 1) || block.timestamp > stageEndTimes[currentStage]) {
            advanceStage();
        }

        // Refund any excess BNB
        if (msg.value > costInBNB) {
            payable(msg.sender).transfer(msg.value - costInBNB);
        }
    }

    function advanceStage() internal {
        if (currentStage < 9) {
            currentStage++;
            emit StageAdvanced(currentStage, stagePricesUSDT[currentStage], stageEndTimes[currentStage]);
        }
    }

    // Allow owner to withdraw BNB funds after each stage
    function withdrawFunds() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        payable(owner()).transfer(balance);
        emit FundsWithdrawn(balance, owner());
    }

    // Emergency stop for sale
    function toggleSaleStatus() external onlyOwner {
        saleActive = !saleActive;
        emit SaleStatusUpdated(saleActive);
    }
}
