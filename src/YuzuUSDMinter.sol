// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IYuzuUSD.sol";

/**
 * @title YuzuUSDMinter
 */
contract YuzuUSDMinter is AccessControlDefaultAdminRules, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event MaxMintPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event MaxRedeemPerBlockUpdated(uint256 oldMax, uint256 newMax);

    error InvalidZeroAddress();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IYuzuUSD public immutable yzusd;
    address public immutable collateralToken;

    address public treasury;

    mapping(uint256 => uint256) public mintedPerBlock;
    mapping(uint256 => uint256) public redeemedPerBlock;
    uint256 public maxMintPerBlock;
    uint256 public maxRedeemPerBlock;

    modifier underMaxMintPerBlock(uint256 amount) {
        uint256 currentBlock = block.number;
        if (mintedPerBlock[currentBlock] + amount > maxMintPerBlock) {
            revert MaxMintPerBlockExceeded();
        }
        _;
    }

    modifier underMaxRedeemPerBlock(uint256 amount) {
        uint256 currentBlock = block.number;
        if (redeemedPerBlock[currentBlock] + amount > maxRedeemPerBlock) {
            revert MaxRedeemPerBlockExceeded();
        }
        _;
    }

    constructor(
        address _yzusd,
        address _collateralToken,
        address _treasury,
        uint256 _maxMintPerBlock,
        uint256 _maxRedeemPerBlock
    ) AccessControlDefaultAdminRules(0, msg.sender) {
        if (_yzusd == address(0)) revert InvalidZeroAddress();
        if (_collateralToken == address(0)) revert InvalidZeroAddress();
        if (_treasury == address(0)) revert InvalidZeroAddress();

        yzusd = IYuzuUSD(_yzusd);
        collateralToken = _collateralToken;

        _setTreasury(_treasury);
        _setMaxMintPerBlock(_maxMintPerBlock);
        _setMaxRedeemPerBlock(_maxRedeemPerBlock);

        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        _setTreasury(newTreasury);
    }

    function setMaxMintPerBlock(
        uint256 newMaxMintPerBlock
    ) external onlyRole(ADMIN_ROLE) {
        _setMaxMintPerBlock(newMaxMintPerBlock);
    }

    function setMaxRedeemPerBlock(
        uint256 newMaxRedeemPerBlock
    ) external onlyRole(ADMIN_ROLE) {
        _setMaxRedeemPerBlock(newMaxRedeemPerBlock);
    }

    function mint(
        address to,
        uint256 amount
    ) external nonReentrant underMaxMintPerBlock(amount) {
        mintedPerBlock[block.number] += amount;
        IERC20(collateralToken).safeTransferFrom(msg.sender, treasury, amount);
        yzusd.mint(to, amount);
    }

    function redeem(
        address to,
        uint256 amount
    ) external nonReentrant underMaxRedeemPerBlock(amount) {
        redeemedPerBlock[block.number] += amount;
        yzusd.burnFrom(msg.sender, amount);
        IERC20(collateralToken).safeTransfer(to, amount);
    }

    function _setTreasury(address newTreasury) internal {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function _setMaxMintPerBlock(uint256 newMaxMintPerBlock) internal {
        uint256 oldMaxMintPerBlock = maxMintPerBlock;
        maxMintPerBlock = newMaxMintPerBlock;
        emit MaxMintPerBlockUpdated(oldMaxMintPerBlock, newMaxMintPerBlock);
    }

    function _setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock) internal {
        uint256 oldMaxRedeemPerBlock = maxRedeemPerBlock;
        maxRedeemPerBlock = newMaxRedeemPerBlock;
        emit MaxRedeemPerBlockUpdated(
            oldMaxRedeemPerBlock,
            newMaxRedeemPerBlock
        );
    }
}
