// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ISimpleSwap } from "./interface/ISimpleSwap.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract SimpleSwap is ISimpleSwap, ReentrancyGuard, ERC20 {
    using Address for address;

    uint24 private constant FEE_RATIO = 0; // 3 => 0.3%, 0 => 0%

    address internal immutable _tokenA;
    address internal immutable _tokenB;

    uint256 internal _reserveA;
    uint256 internal _reserveB;

    //
    // CONSTRUCTOR
    //

    constructor(address tokenA, address tokenB) ERC20("SimpleSwap LP Token", "SLP") {
        require(tokenA != tokenB, "SimpleSwap: TOKENA_TOKENB_IDENTICAL_ADDRESS");
        require(tokenA.isContract(), "SimpleSwap: TOKENA_IS_NOT_CONTRACT");
        require(tokenB.isContract(), "SimpleSwap: TOKENB_IS_NOT_CONTRACT");

        (_tokenA, _tokenB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    //
    // EXTERNAL NON-VIEW
    //

    /// @inheritdoc ISimpleSwap
    function addLiquidity(
        uint256 amountAIn,
        uint256 amountBIn
    ) external override nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(amountAIn > 0 && amountBIn > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");

        uint256 reserveA = _reserveA;
        uint256 reserveB = _reserveB;

        if (reserveA == 0 && reserveB == 0) {
            amountA = amountAIn;
            amountB = amountBIn;
        } else {
            uint256 amountBRequired = _quote(amountAIn, reserveA, reserveB);
            if (amountBRequired <= amountBIn) {
                amountA = amountAIn;
                amountB = amountBRequired;
            } else {
                uint256 amountARequired = _quote(amountBIn, reserveB, reserveA);
                amountA = amountARequired;
                amountB = amountBIn;
            }
        }

        SafeERC20.safeTransferFrom(IERC20(_tokenA), msg.sender, address(this), amountA);
        SafeERC20.safeTransferFrom(IERC20(_tokenB), msg.sender, address(this), amountB);

        liquidity = _mintLpToken(msg.sender, reserveA, reserveB, amountA, amountB);

        _update();

        emit AddLiquidity(msg.sender, amountA, amountB, liquidity);
    }

    /// @inheritdoc ISimpleSwap
    function removeLiquidity(
        uint256 liquidity
    ) external override nonReentrant returns (uint256 amountA, uint256 amountB) {
        address msgSender = msg.sender;

        SafeERC20.safeTransferFrom(IERC20(address(this)), msgSender, address(this), liquidity);

        (amountA, amountB) = _burnLpToken();

        SafeERC20.safeTransfer(IERC20(_tokenA), msgSender, amountA);
        SafeERC20.safeTransfer(IERC20(_tokenB), msgSender, amountB);

        _update();

        emit RemoveLiquidity(msgSender, amountA, amountB, liquidity);
    }

    /// @inheritdoc ISimpleSwap
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external override nonReentrant returns (uint256 amountOut) {
        require(tokenIn == _tokenA || tokenIn == _tokenB, "SimpleSwap: INVALID_TOKEN_IN");
        require(tokenOut == _tokenA || tokenOut == _tokenB, "SimpleSwap: INVALID_TOKEN_OUT");
        require(tokenIn != tokenOut, "SimpleSwap: IDENTICAL_ADDRESS");
        require(amountIn > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");

        (uint256 reserveIn, uint256 reserveOut) = tokenIn == _tokenA ? (_reserveA, _reserveB) : (_reserveB, _reserveA);

        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut > 0, "SimpleSwap: INSUFFICIENT_OUTPUT_AMOUNT");

        if (tokenIn == _tokenA) {
            _reserveA += amountIn;
            _reserveB -= amountOut;
        } else {
            _reserveA -= amountOut;
            _reserveB += amountIn;
        }

        SafeERC20.safeTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn);
        SafeERC20.safeTransfer(IERC20(tokenOut), msg.sender, amountOut);

        _update();

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    //
    // EXTERNAL VIEW
    //

    /// @inheritdoc ISimpleSwap
    function getReserves() external view override returns (uint256 reserveA, uint256 reserveB) {
        reserveA = _reserveA;
        reserveB = _reserveB;
    }

    /// @inheritdoc ISimpleSwap
    function getTokenA() external view override returns (address tokenA) {
        tokenA = _tokenA;
    }

    /// @inheritdoc ISimpleSwap
    function getTokenB() external view override returns (address tokenB) {
        tokenB = _tokenB;
    }

    //
    // INTERNAL NON-VIEW
    //

    function _mintLpToken(
        address to,
        uint256 reserveA,
        uint256 reserveB,
        uint256 amountA,
        uint256 amountB
    ) internal returns (uint256 liquidity) {
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            liquidity = Math.sqrt(amountA * amountB);
        } else {
            liquidity = Math.min((amountA * totalSupply) / reserveA, (amountB * totalSupply) / reserveB);
        }

        require(liquidity > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_MINTED");

        _mint(to, liquidity);
    }

    function _burnLpToken() internal returns (uint256 amountA, uint256 amountB) {
        uint256 balanceA = IERC20(_tokenA).balanceOf(address(this));
        uint256 balanceB = IERC20(_tokenB).balanceOf(address(this));

        uint256 liquidity = balanceOf(address(this));
        uint256 totalSupply = totalSupply();

        amountA = (liquidity * (balanceA)) / totalSupply;
        amountB = (liquidity * (balanceB)) / totalSupply;
        require(amountA > 0 && amountB > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
    }

    //
    // INTERNAL VIEW
    //

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY");

        uint256 amountInWithFee = amountIn * (1000 - FEE_RATIO);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;

        amountOut = numerator / denominator;
        return amountOut;
    }

    function _update() internal {
        _reserveA = IERC20(_tokenA).balanceOf(address(this));
        _reserveB = IERC20(_tokenB).balanceOf(address(this));
    }

    function _quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY");

        amountB = (amountA * reserveB) / reserveA;
    }
}
