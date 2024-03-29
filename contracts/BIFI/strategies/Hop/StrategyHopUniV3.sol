// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../../interfaces/common/ISolidlyRouter.sol";
import "../../utils/UniswapV3Utils.sol";
import "./StrategyHop.sol";

contract StrategyHopUniV3 is StrategyHop {
    using SafeERC20 for IERC20;

    // Routes
    bytes public outputToNativePath;
    bytes public outputToDepositPath;

    function initialize(
        address _want,
        address _rewardPool,
        address _stableRouter,
        address[] calldata _outputToNativeRoute,
        uint24[] calldata _outputToNativeFees,
        address[] calldata _outputToDepositRoute,
        uint24[] calldata _outputToDepositFees,
        CommonAddresses calldata _commonAddresses
    ) public initializer {
        __StrategyHop_init(_want, _rewardPool, _stableRouter, _commonAddresses);

        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        depositToken = _outputToDepositRoute[_outputToDepositRoute.length - 1];
        depositIndex = IStableRouter(stableRouter).getTokenIndex(depositToken);

        outputToNativePath = UniswapV3Utils.routeToPath(_outputToNativeRoute, _outputToNativeFees);
        outputToDepositPath = UniswapV3Utils.routeToPath(_outputToDepositRoute, _outputToDepositFees);

        _giveAllowances();
    }

    function _swapToNative(uint256 totalFee) internal virtual override {
        uint256 toNative = IERC20(output).balanceOf(address(this)) * totalFee / DIVISOR;
        UniswapV3Utils.swap(unirouter, outputToNativePath, toNative);
    }

    function _swapToDeposit() internal virtual override {
        uint256 toDeposit = IERC20(output).balanceOf(address(this));
        UniswapV3Utils.swap(unirouter, outputToDepositPath, toDeposit);
    }

    function _getAmountOut(uint256) internal view virtual override returns (uint256) {
        return 0;
    }

    function outputToNative() external view virtual override returns (address[] memory) {
        return UniswapV3Utils.pathToRoute(outputToNativePath);
    }

    function outputToDeposit() external view virtual override returns (address[] memory) {
        return UniswapV3Utils.pathToRoute(outputToDepositPath);
    }
}
