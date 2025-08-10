// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

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

    function __YuzuIssuer_init(uint256 _maxDepositPerBlock, uint256 _withdrawnPerBlock) internal onlyInitializing {
        __YuzuIssuer_init_unchained(_maxDepositPerBlock, _withdrawnPerBlock);
    }

    function __YuzuIssuer_init_unchained(uint256 _maxDepositPerBlock, uint256 _withdrawnPerBlock)
        internal
        onlyInitializing
    {
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        $._maxDepositPerBlock = _maxDepositPerBlock;
        $._maxWithdrawPerBlock = _withdrawnPerBlock;
    }

    function asset() public view virtual returns (address);
    function previewDeposit(uint256 assets) public view virtual returns (uint256 tokens);
    function previewMint(uint256 tokens) public view virtual returns (uint256 assets);
    function previewWithdraw(uint256 assets) public view virtual returns (uint256 tokens);
    function previewRedeem(uint256 tokens) public view virtual returns (uint256 assets);

    function __yuzu_balanceOf(address account) public view virtual returns (uint256);
    function __yuzu_mint(address account, uint256 amount) internal virtual;
    function __yuzu_burn(address account, uint256 amount) internal virtual;
    function __yuzu_spendAllowance(address owner, address spender, uint256 amount) internal virtual;

    function treasury() public view virtual returns (address) {
        return address(this);
    }

    function maxDeposit(address) public view virtual returns (uint256) {
        return _getRemainingDepositAllowance();
    }

    function maxMint(address receiver) public view virtual returns (uint256) {
        uint256 _maxDeposit = maxDeposit(receiver);
        if (_maxDeposit == type(uint256).max) {
            return type(uint256).max;
        }
        return previewDeposit(_maxDeposit);
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        uint256 remainingAllowance = _getRemainingWithdrawAllowance();
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        uint256 ownerAssets = previewRedeem(__yuzu_balanceOf(owner));
        return Math.min(ownerAssets, Math.min(liquidityBuffer, remainingAllowance));
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        uint256 remainingAllowance = _getRemainingWithdrawAllowance();
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        uint256 ownerTokens = __yuzu_balanceOf(owner);
        return Math.min(ownerTokens, previewWithdraw(Math.min(liquidityBuffer, remainingAllowance)));
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 tokens = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, tokens);

        return tokens;
    }

    function mint(uint256 tokens, address receiver) public virtual returns (uint256) {
        uint256 maxTokens = maxMint(receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }

        uint256 assets = previewMint(tokens);
        _deposit(_msgSender(), receiver, assets, tokens);

        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 tokens = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, tokens);

        return tokens;
    }

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

        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the tokens are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
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

        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // tokens are burned and after the assets are transferred, which is a valid state.
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
