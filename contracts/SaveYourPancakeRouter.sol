pragma solidity =0.6.6;

// SPDX-License-Identifier: UNLICENSED
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/PancakeLibrary.sol";
import "./interfaces/IWETH.sol";

contract SaveYourPancakeRouter is Ownable {
    using SafeMath for uint256;
    event SwapFeeUpdated(uint8 swapFee);
    event FeeReceiverUpdated(address feeReceiver);

    uint256 public constant FEE_DENOMINATOR = 10000;
    address public immutable WETH;
    bytes internal pancakeInitCodeV1;
    bytes internal pancakeInitCodeV2;
    address public pancakeFactoryV1;
    address public pancakeFactoryV2;
    IERC20 public saveYourAssetsToken;
    uint256 public balanceThreshold;
    address public feeReceiver;
    uint8 public swapFee;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "SaveYourPancake: deadline for trade passed");
        _;
    }

    constructor(
        address _WETH,
        uint8 _swapFee,
        address _feeReceiver,
        uint256 _balanceThreshold,
        IERC20 _saveYourAssetsToken,
        address _pancakeFactoryV1,
        address _pancakeFactoryV2,
        bytes memory _pancakeInitCodeV1,
        bytes memory _pancakeInitCodeV2
    ) public {
        WETH = _WETH;
        swapFee = _swapFee;
        feeReceiver = _feeReceiver;
        saveYourAssetsToken = _saveYourAssetsToken;
        balanceThreshold = _balanceThreshold;
        pancakeFactoryV1 = _pancakeFactoryV1;
        pancakeFactoryV2 = _pancakeFactoryV2;
        pancakeInitCodeV1 = _pancakeInitCodeV1;
        pancakeInitCodeV2 = _pancakeInitCodeV2;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        address factory,
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = PancakeLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? _pairFor(factory, output, path[i + 2]) : _to;
            IPancakePair(_pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactNativeForTokens(
        address factory,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable ensure(deadline) returns (uint256[] memory amounts) {
        require(path[0] == WETH, "SaveYourPancakeRouter: INVALID_PATH");
        (uint256 swapAmount, uint256 feeAmount) = _calculateFee(msg.value);
        amounts = _getAmountsOut(factory, swapAmount, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "SaveYourPancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH).deposit{value: amounts[0].add(feeAmount)}();
        assert(IWETH(WETH).transfer(_pairFor(factory, path[0], path[1]), amounts[0]));
        assert(IWETH(WETH).transfer(feeReceiver, feeAmount));
        _swap(factory, amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0].add(feeAmount)) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0].add(feeAmount));
    }

    function swapExactTokensForNativ(
        address factory,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "SaveYourPancakeRouter: INVALID_PATH");
        amounts = _getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "SaveYourPancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        TransferHelper.safeTransferFrom(path[0], msg.sender, _pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(factory, amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);

        (uint256 swapAmount, uint256 feeAmount) = _calculateFee(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, swapAmount);
        TransferHelper.safeTransferETH(feeReceiver, feeAmount);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(
        address factory,
        address[] memory path,
        address _to
    ) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = PancakeLibrary.sortTokens(input, output);
            IPancakePair pair = IPancakePair(_pairFor(factory, input, output));
            uint256 amountInput;
            uint256 amountOutput;
            {
                // scope to avoid stack too deep errors
                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                (uint256 reserveInput, uint256 reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
                amountOutput = _getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            address to = i < path.length - 2 ? _pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForNativeSupportingFeeOnTransferTokens(
        address factory,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        require(path[path.length - 1] == WETH, "SaveYourPancake: BNB has to be the last path item");
        TransferHelper.safeTransferFrom(path[0], msg.sender, _pairFor(factory, path[0], path[1]), amountIn);
        _swapSupportingFeeOnTransferTokens(factory, path, address(this));
        uint256 amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, "SaveYourPancake: slippage setting to low");
        IWETH(WETH).withdraw(amountOut);
        (uint256 withdrawAmount, uint256 feeAmount) = _calculateFee(amountOut);
        TransferHelper.safeTransferETH(to, withdrawAmount);
        TransferHelper.safeTransferETH(feeReceiver, feeAmount);
    }

    function swapExactTokensForTokens(
        address factory,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        (uint256 swapAmount, uint256 feeAmount) = _calculateFee(amountIn);
        amounts = _getAmountsOut(factory, swapAmount, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "SaveYourPancake: INSUFFICIENT_OUTPUT_AMOUNT");
        TransferHelper.safeTransferFrom(path[0], msg.sender, _pairFor(factory, path[0], path[1]), amounts[0]);
        TransferHelper.safeTransferFrom(path[0], msg.sender, feeReceiver, feeAmount);
        _swap(factory, amounts, path, to);
    }

    function swapExactTokensForNative(
        address factory,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "SaveYourPancake: INVALID_PATH");
        amounts = _getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "SaveYourPancake: INSUFFICIENT_OUTPUT_AMOUNT");
        TransferHelper.safeTransferFrom(path[0], msg.sender, _pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(factory, amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        (uint256 swapAmount, uint256 feeAmount) = _calculateFee(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, swapAmount);
        TransferHelper.safeTransferETH(feeReceiver, feeAmount);
    }

    function _calculateFee(uint256 amount) internal view returns (uint256 swapAmount, uint256 feeAmount) {
        if (saveYourAssetsToken.balanceOf(msg.sender) > balanceThreshold) {
            feeAmount = 0;
            swapAmount = amount;
        } else {
            feeAmount = amount.mul(swapFee).div(FEE_DENOMINATOR);
            swapAmount = amount.sub(feeAmount);
        }
    }

    function getUserFee(address user) public view returns (uint256) {
        saveYourAssetsToken.balanceOf(user) > balanceThreshold ? 0 : swapFee;
    }

    function updateSwapFee(uint8 newSwapFee) external onlyOwner {
        swapFee = newSwapFee;
        emit SwapFeeUpdated(newSwapFee);
    }

    function updateFeeReceiver(address newFeeReceiver) external onlyOwner {
        feeReceiver = newFeeReceiver;
        emit FeeReceiverUpdated(newFeeReceiver);
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal view returns (uint256 amountOut) {
        require(amountIn > 0, "SaveYourPancake: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "SaveYourPancake: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn.mul((9975 - getUserFee(msg.sender)));
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(10000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function _getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal view returns (uint256 amountIn) {
        require(amountOut > 0, "SaveYourPancake: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "SaveYourPancake: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn.mul(amountOut).mul(10000);
        uint256 denominator = reserveOut.sub(amountOut).mul(9975 - getUserFee(msg.sender));
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function _getAmountsOut(
        address factory,
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "SaveYourPancake: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = _getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = _getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function _getAmountsIn(
        address factory,
        uint256 amountOut,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "SaveYourPancake: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = _getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = _getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }

    // fetches and sorts the reserves for a pair
    function _getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = PancakeLibrary.sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(_pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function _pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (address pair) {
        (address token0, address token1) = PancakeLibrary.sortTokens(tokenA, tokenB);
        bytes memory initcode = factory == pancakeFactoryV1 ? pancakeInitCodeV1 : pancakeInitCodeV2;
        pair = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff",
                        factory,
                        keccak256(abi.encodePacked(token0, token1)),
                        initcode // init code hash
                    )
                )
            )
        );
    }
}
