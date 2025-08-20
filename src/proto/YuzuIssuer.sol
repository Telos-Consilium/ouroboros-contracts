// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYuzuIssuerDefinitions} from "../interfaces/proto/IYuzuIssuerDefinitions.sol";

abstract contract YuzuIssuer is ContextUpgradeable, IYuzuIssuerDefinitions {
    struct YuzuIssuerStorage {
        uint256 _maxDepositPerBlock;
        uint256 _maxWithdrawPerBlock;
        mapping(uint256 => uint256) _depositedPerBlock;
        mapping(uint256 => uint256) _withdrawnPerBlock;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.issuer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuIssuerStorageLocation =
        0x542408f99cbd5a3e32919127cd9d8984eb4635c3ab0f9f17273c636c42e08d00;

    // slither-disable-next-line pess-unprotected-initialize
    function __YuzuIssuer_init(uint256 _maxDepositPerBlock, uint256 _maxWithdrawPerBlock) internal onlyInitializing {
        __YuzuIssuer_init_unchained(_maxDepositPerBlock, _maxWithdrawPerBlock);
    }

    // slither-disable-next-line pess-unprotected-initialize
    function __YuzuIssuer_init_unchained(uint256 _maxDepositPerBlock, uint256 _maxWithdrawPerBlock)
        internal
        onlyInitializing
    {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        $._maxDepositPerBlock = _maxDepositPerBlock;
        $._maxWithdrawPerBlock = _maxWithdrawPerBlock;
    }

    /// @dev See {IERC4626}
    function asset() public view virtual returns (address);
    function previewDeposit(uint256 assets) public view virtual returns (uint256 tokens);
    function previewMint(uint256 tokens) public view virtual returns (uint256 assets);
    function previewWithdraw(uint256 assets) public view virtual returns (uint256 tokens);
    function previewRedeem(uint256 tokens) public view virtual returns (uint256 assets);

    /// @dev See {IERC20}
    function __yuzu_balanceOf(address account) public view virtual returns (uint256);
    function __yuzu_mint(address account, uint256 amount) internal virtual;
    function __yuzu_burn(address account, uint256 amount) internal virtual;

    function __yuzu_spendAllowance(address owner, address spender, uint256 amount) internal virtual;

    function treasury() public view virtual returns (address) {
        return address(this);
    }

    /// @notice See {IERC4626-convertToShares}
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        return previewDeposit(assets);
    }

    /// @notice See {IERC4626-convertToAssets}
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        return previewMint(shares);
    }

    /// @notice See {IERC4626-maxDeposit}
    function maxDeposit(address) public view virtual returns (uint256) {
        return _getRemainingDepositAllowance();
    }

    /// @notice See {IERC4626-maxMint}
    function maxMint(address receiver) public view virtual returns (uint256) {
        return previewDeposit(maxDeposit(receiver));
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address owner) public view virtual returns (uint256) {
        uint256 remainingAllowance = _getRemainingWithdrawAllowance();
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        uint256 ownerTokens = __yuzu_balanceOf(owner);
        return Math.min(ownerTokens, previewWithdraw(Math.min(liquidityBuffer, remainingAllowance)));
    }

    /// @notice See {IERC4626-deposit}
    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 tokens = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, tokens);

        return tokens;
    }

    /// @notice See {IERC4626-mint}
    function mint(uint256 tokens, address receiver) public virtual returns (uint256) {
        uint256 maxTokens = maxMint(receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }

        uint256 assets = previewMint(tokens);
        _deposit(_msgSender(), receiver, assets, tokens);

        return assets;
    }

    /// @notice See {IERC4626-withdraw}
    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 tokens = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, tokens);

        return tokens;
    }

    /// @notice See {IERC4626-redeem}
    function redeem(uint256 tokens, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxTokens = maxRedeem(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeem(owner, tokens, maxTokens);
        }

        uint256 assets = previewRedeem(tokens);
        _withdraw(_msgSender(), receiver, owner, assets, tokens);

        return assets;
    }

    function withdrawCollateral(uint256 assets, address receiver) public virtual {
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        if (assets > liquidityBuffer) {
            revert ExceededLiquidityBuffer(assets, liquidityBuffer);
        }
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit WithdrawnCollateral(receiver, assets);
    }

    function maxDepositPerBlock() public view returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        return $._maxDepositPerBlock;
    }

    function maxWithdrawPerBlock() public view returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        return $._maxWithdrawPerBlock;
    }

    function depositedPerBlock(uint256 blockNumber) public view returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        return $._depositedPerBlock[blockNumber];
    }

    function withdrawnPerBlock(uint256 blockNumber) public view returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        return $._withdrawnPerBlock[blockNumber];
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 tokens) internal virtual {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        $._depositedPerBlock[block.number] += assets;

        SafeERC20.safeTransferFrom(IERC20(asset()), caller, treasury(), assets);
        __yuzu_mint(receiver, tokens);

        emit Deposit(caller, receiver, assets, tokens);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 tokens)
        internal
        virtual
    {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        $._withdrawnPerBlock[block.number] += assets;

        if (caller != owner) {
            __yuzu_spendAllowance(owner, caller, tokens);
        }
        __yuzu_burn(owner, tokens);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, tokens);
    }

    function _getRemainingDepositAllowance() internal view virtual returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        if ($._depositedPerBlock[block.number] >= $._maxDepositPerBlock) {
            return 0;
        }
        return $._maxDepositPerBlock - $._depositedPerBlock[block.number];
    }

    function _getRemainingWithdrawAllowance() internal view virtual returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        if ($._withdrawnPerBlock[block.number] >= $._maxWithdrawPerBlock) {
            return 0;
        }
        return $._maxWithdrawPerBlock - $._withdrawnPerBlock[block.number];
    }

    function _getLiquidityBufferSize() internal view virtual returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _getYuzuIssuerStorage() private pure returns (YuzuIssuerStorage storage $) {
        assembly {
            $.slot := YuzuIssuerStorageLocation
        }
    }

    function _setMaxDepositPerBlock(uint256 newMax) internal {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldMax = $._maxDepositPerBlock;
        $._maxDepositPerBlock = newMax;
        emit UpdatedMaxDepositPerBlock(oldMax, newMax);
    }

    function _setMaxWithdrawPerBlock(uint256 newMax) internal {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldMax = $._maxWithdrawPerBlock;
        $._maxWithdrawPerBlock = newMax;
        emit UpdatedMaxWithdrawPerBlock(oldMax, newMax);
    }
}
