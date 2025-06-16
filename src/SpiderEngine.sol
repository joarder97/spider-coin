// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SpiderCoin} from "./SpiderCoin.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SpiderEngine is ReentrancyGuard, AccessControl, EIP712, Ownable, Pausable {
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    error SpiderEngine__ZeroAddress();
    error SpiderEngine__NotEnoughBalance();
    error SpiderEngine__TransferFailed();
    error SpiderEngine__InvalidFee();

    // Role Definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant FEE_CONTROLLER_ROLE = keccak256("FEE_CONTROLLER_ROLE");

    // State Variables
    mapping(address => uint256) private s_userCollateralValue; // in USD
    mapping(bytes32 => bool) public processedRequests;

    uint256 private s_mintingFeePercentage;
    address private s_feeRecipient;

    SpiderCoin private immutable i_spiderCoin;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant PERCENTAGE_PRECISION = 10000;

    bytes32 private constant _MINT_TYPEHASH =
        keccak256("MintRequest(bytes32 requestId, address to, uint256 amount)");

    // Events
    event CollateralDeposited(address indexed user, uint256 valueInUsd);
    event SpiderCoinMinted(address indexed user, uint256 amount);
    event CollateralRedeemed(address indexed user, uint256 valueInUsd);
    event SpiderCoinBurned(address indexed user, uint256 amount);
    event FeeCollected(address indexed user, uint256 amount, string feeType);

    constructor(
        SpiderCoin _token,
        address _ethUsdFeed
    )
        ReentrancyGuard()
        AccessControl()
        EIP712("SpiderEngine", "1")
        Ownable(msg.sender)
    {
        i_spiderCoin = SpiderCoin(_token);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdFeed);

        s_feeRecipient = owner();
        s_mintingFeePercentage = 50; // 0.5%

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(FEE_CONTROLLER_ROLE, msg.sender);
    }

    function depositCollateralAndMint(
        uint256 _collateralAmount
    ) external nonReentrant whenNotPaused {
        if (_collateralAmount == 0) {
            revert SpiderEngine__NotEnoughBalance();
        }

        // In a real-world scenario, you would transfer the collateral (e.g., ETH) to this contract
        // For simplicity, we'll assume the collateral is already here.

        uint256 valueInUsd = getUsdValue(_collateralAmount);
        s_userCollateralValue[msg.sender] += valueInUsd;

        uint256 mintingFee = (valueInUsd * s_mintingFeePercentage) / PERCENTAGE_PRECISION;
        uint256 amountToMint = valueInUsd - mintingFee;

        i_spiderCoin.mint(msg.sender, amountToMint);

        emit CollateralDeposited(msg.sender, valueInUsd);
        emit SpiderCoinMinted(msg.sender, amountToMint);
        if (mintingFee > 0) {
            i_spiderCoin.mint(s_feeRecipient, mintingFee);
            emit FeeCollected(msg.sender, mintingFee, "MINT");
        }
    }

    function redeemCollateralAndBurn(
        uint256 _amountToBurn
    ) external nonReentrant whenNotPaused {
        if (_amountToBurn == 0) {
            revert SpiderEngine__NotEnoughBalance();
        }
        if (i_spiderCoin.balanceOf(msg.sender) < _amountToBurn) {
            revert SpiderEngine__NotEnoughBalance();
        }

        uint256 collateralValueToRedeem = _amountToBurn; // 1:1 with USD
        s_userCollateralValue[msg.sender] -= collateralValueToRedeem;

        i_spiderCoin.burnFrom(msg.sender, _amountToBurn);

        // In a real-world scenario, you would transfer the collateral back to the user
        // For example: payable(msg.sender).transfer(collateralAmount);

        emit SpiderCoinBurned(msg.sender, _amountToBurn);
        emit CollateralRedeemed(msg.sender, collateralValueToRedeem);
    }

    function setMintingFee(uint256 _feePercentage) external onlyRole(FEE_CONTROLLER_ROLE) {
        if (_feePercentage > 1000) { // Max 10%
            revert SpiderEngine__InvalidFee();
        }
        s_mintingFeePercentage = _feePercentage;
    }

    function getUsdValue(uint256 _ethAmount) public view returns (uint256) {
        (, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
        // The price is returned with 8 decimals, so we adjust it to 18
        return (uint256(price) * _ethAmount) / 1e8;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}