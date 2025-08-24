// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYuzuIssuerDefinitions} from "../interfaces/proto/IYuzuIssuerDefinitions.sol";

abstract contract YuzuIssuer is ContextUpgradeable, IYuzuIssuerDefinitions {
    struct YuzuIssuerStorage {
        uint256 _supplyCap;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.issuer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuIssuerStorageLocation =
        0x542408f99cbd5a3e32919127cd9d8984eb4635c3ab0f9f17273c636c42e08d00;

    function __YuzuIssuer_init(uint256 _supplyCap) internal onlyInitializing {
        __YuzuIssuer_init_unchained(_supplyCap);
    }

    function __YuzuIssuer_init_unchained(uint256 _supplyCap)
        internal
        onlyInitializing
    {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        $._supplyCap = _supplyCap;
    }

    /// @dev See {IERC4626}
    function asset() public view virtual returns (address);
    function convertToShares(uint256 assets) public view virtual returns (uint256 shares);
    function convertToAssets(uint256 shares) public view virtual returns (uint256 assets);
    function previewDeposit(uint256 assets) public view virtual returns (uint256 tokens);
    function previewMint(uint256 tokens) public view virtual returns (uint256 assets);
    function previewWithdraw(uint256 assets) public view virtual returns (uint256 tokens);
    function previewRedeem(uint256 tokens) public view virtual returns (uint256 assets);

    /// @dev See {IERC20}
    function __yuzu_totalSupply() internal virtual view returns (uint256);
    function __yuzu_balanceOf(address account) internal view virtual returns (uint256);
    function __yuzu_mint(address account, uint256 amount) internal virtual;
    function __yuzu_burn(address account, uint256 amount) internal virtual;

    function __yuzu_spendAllowance(address owner, address spender, uint256 amount) internal virtual;

    function treasury() public view virtual returns (address) {
        return address(this);
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view virtual returns (uint256) {
        return convertToAssets(__yuzu_totalSupply());
    }

    /// @notice See {IERC4626-maxDeposit}
    function maxDeposit(address receiver) public view virtual returns (uint256) {
        return convertToAssets(maxMint(receiver));
    }

    /// @notice See {IERC4626-maxMint}
    function maxMint(address) public view virtual returns (uint256) {
        return _getRemainingMintAllowance();
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address _owner) public view virtual returns (uint256) {
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        uint256 ownerTokens = __yuzu_balanceOf(_owner);
        return Math.min(previewRedeem(ownerTokens), liquidityBuffer);
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address _owner) public view virtual returns (uint256) {
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        uint256 ownerTokens = __yuzu_balanceOf(_owner);
        return Math.min(convertToShares(liquidityBuffer), ownerTokens);
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

    function cap() public view returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        return $._supplyCap;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 tokens) internal virtual {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, treasury(), assets);
        __yuzu_mint(receiver, tokens);
        emit Deposit(caller, receiver, assets, tokens);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 tokens)
        internal
        virtual
    {
        if (caller != owner) {
            __yuzu_spendAllowance(owner, caller, tokens);
        }
        __yuzu_burn(owner, tokens);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, tokens);
    }

    function _getRemainingMintAllowance() internal view virtual returns (uint256) {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 supplyCap = $._supplyCap;
        uint256 totalSupply = __yuzu_totalSupply();
        if (totalSupply >= supplyCap) {
            return 0;
        }
        return supplyCap - totalSupply;
    }

    function _getLiquidityBufferSize() internal view virtual returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _getYuzuIssuerStorage() private pure returns (YuzuIssuerStorage storage $) {
        assembly {
            $.slot := YuzuIssuerStorageLocation
        }
    }

    function _setSupplyCap(uint256 newCap) internal {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldCap = $._supplyCap;
        $._supplyCap = newCap;
        emit UpdatedSupplyCap(oldCap, newCap);
    }
}
