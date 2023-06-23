// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/IMasterChef.sol";
import "../../utils/StringUtils.sol";
import "./StrategyCore.sol";

abstract contract StrategyConfig is StrategyCore {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using MathUpgradeable for uint256;

    // Tokens used
    address public lpToken0;
    address public lpToken1;
    address[] public rewards;

    // Third party contracts
    address public chef;
    uint256 public poolId;
    address public unirouter;

    string public pendingRewardsFunctionName;

    // Routes
    mapping(address => mapping(address => address[])) public routes;
    mapping(address => uint256) public minToSwap;

    function initialize(
        address _want,
        uint256 _poolId,
        address _chef,
        address _unirouter,
        address[] calldata _outputToNativeRoute,
        address[] calldata _outputToLp0Route,
        address[] calldata _outputToLp1Route,
        CommonAddresses calldata _commonAddresses
    ) public initializer {
        __StratManager_init(_commonAddresses);
        want = IERC20Upgradeable(_want);
        poolId = _poolId;
        chef = _chef;
        unirouter = _unirouter;

        output = IERC20Upgradeable(_outputToNativeRoute[0]);
        native = IERC20Upgradeable(_outputToNativeRoute[_outputToNativeRoute.length - 1]);
        routes[address(output)][address(native)] = _outputToNativeRoute;

        // setup lp routing
        lpToken0 = IUniswapV2Pair(address(want)).token0();
        require(_outputToLp0Route[0] == address(output), "outputToLp0Route[0] != output");
        require(
            _outputToLp0Route[_outputToLp0Route.length - 1] == lpToken0,
            "outputToLp0Route[last] != lpToken0"
        );
        routes[address(output)][lpToken0] = _outputToLp0Route;

        lpToken1 = IUniswapV2Pair(address(want)).token1();
        require(_outputToLp1Route[0] == address(output), "outputToLp1Route[0] != output");
        require(
            _outputToLp1Route[_outputToLp1Route.length - 1] == lpToken1,
            "outputToLp1Route[last] != lpToken1"
        );
        routes[address(output)][lpToken1] = _outputToLp1Route;

        _giveAllowances();
    }

    /**
     * @dev Helper function to deposit to the underlying platform.
     * @param amount The amount to deposit.
     */
    function _depositUnderlying(uint256 amount) internal override {
        IMasterChef(chef).deposit(poolId, amount);
    }

    /**
     * @dev Helper function to withdraw from the underlying platform.
     * @param amount The amount to withdraw.
     */
    function _withdrawUnderlying(uint256 amount) internal override {
        IMasterChef(chef).withdraw(poolId, amount);
    }

    /**
     * @dev It calculates the invested balance of 'want' in the underlying platform.
     * @return balanceOfPool The invested balance of the wanted asset.
     */
    function balanceOfPool() public override view returns (uint256) {
        (uint256 _amount,) = IMasterChef(chef).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev It claims rewards from the underlying platform and converts any extra rewards back into
     * the output token.
     */
    function _getRewards() internal override {
        IMasterChef(chef).deposit(poolId, 0);
        uint256 rewardLength = rewards.length;
        for (uint256 i; i < rewardLength;) {
            _swap(rewards[i], address(output), IERC20Upgradeable(rewards[i]).balanceOf(address(this)));
            unchecked { ++i; }
        }
    }

    /**
     * @dev It converts the output to the want asset, in this case it swaps half for each LP token
     * and adds liquidity.
     */
    function _convertToWant() internal override {
        _swap(address(output), lpToken0, IERC20Upgradeable(output).balanceOf(address(this)) / 2);
        _swap(address(output), lpToken1, IERC20Upgradeable(output).balanceOf(address(this)));

        uint256 lp0Bal = IERC20Upgradeable(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20Upgradeable(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(
            lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), block.timestamp
        );
    }

    /**
     * @dev It swaps from one token to another.
     * @param _fromToken The token to swap from.
     * @param _toToken The token to swap to.
     * @param _amount Amount of token to swap.
     */
    function _swap(
        address _fromToken,
        address _toToken,
        uint256 _amount
    ) internal {
        if (_fromToken == _toToken) {
            return;
        }

        if (_amount > minToSwap[_fromToken]) {
            address[] memory path = routes[_fromToken][_toToken];
            require(path[0] != address(0), "path not set");
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                _amount, 0, path, address(this), block.timestamp
            );
        }
    }

    /**
     * @dev It estimated the amount received from making a swap.
     * @param _fromToken The token to swap from.
     * @param _toToken The token to swap to.
     * @param _amountIn The amount of fromToken to be used in the swap.
     */
    function _getAmountOut(
        address _fromToken,
        address _toToken,
        uint256 _amountIn
    ) internal view returns (uint256 amount) {
        uint256[] memory amountOut = IUniswapRouterETH(unirouter).getAmountsOut(
            _amountIn,
            routes[_fromToken][_toToken]
        );
        amount = amountOut[amountOut.length - 1];
    }

    /**
     * @dev It calculates the output reward available to the strategy by calling the pending
     * rewards function on the underlying platform.
     * @return rewardsAvailable The amount of output rewards not yet harvested.
     */
    function rewardsAvailable() public override view returns (uint256) {
        string memory signature = StringUtils.concat(pendingRewardsFunctionName, "(uint256,address)");
        bytes memory result = AddressUpgradeable.functionStaticCall(
            chef,
            abi.encodeWithSignature(
                signature,
                poolId,
                address(this)
            )
        );
        return abi.decode(result, (uint256));
    }

    /**
     * @dev It withdraws from the underlying platform without caring about rewards.
     */
    function _emergencyWithdraw() internal override {
        IMasterChef(chef).emergencyWithdraw(poolId);
    }

    /**
     * @dev It gives allowances to the required addresses.
     */
    function _giveAllowances() internal override {
        IERC20Upgradeable(want).safeApprove(chef, type(uint).max);
        IERC20Upgradeable(output).safeApprove(unirouter, type(uint).max);

        IERC20Upgradeable(lpToken0).safeApprove(unirouter, 0);
        IERC20Upgradeable(lpToken0).safeApprove(unirouter, type(uint).max);

        IERC20Upgradeable(lpToken1).safeApprove(unirouter, 0);
        IERC20Upgradeable(lpToken1).safeApprove(unirouter, type(uint).max);

        for (uint i; i < rewards.length;) {
            IERC20Upgradeable(rewards[i]).safeApprove(unirouter, 0);
            IERC20Upgradeable(rewards[i]).safeApprove(unirouter, type(uint).max);
            unchecked { ++i; }
        }
    }

    /**
     * @dev It revokes allowances from the previously approved addresses.
     */
    function _removeAllowances() internal override {
        IERC20Upgradeable(want).safeApprove(chef, 0);
        IERC20Upgradeable(output).safeApprove(unirouter, 0);
        IERC20Upgradeable(lpToken0).safeApprove(unirouter, 0);
        IERC20Upgradeable(lpToken1).safeApprove(unirouter, 0);

        for (uint i; i < rewards.length;) {
            IERC20Upgradeable(rewards[i]).safeApprove(unirouter, 0);
            unchecked { ++i; }
        }
    }

    /**
     * @dev Helper function to view the token route for swapping between output and native.
     * @return outputToNativeRoute The token route between output to native.
     */
    function outputToNative() external view returns (address[] memory) {
        return routes[address(output)][address(native)];
    }

    /**
     * @dev Helper function to view the token route for swapping between output and lpToken0.
     * @return outputToLp0Route The token route between output to lpToken0.
     */
    function outputToLp0() external view returns (address[] memory) {
        return routes[address(output)][lpToken0];
    }

    /**
     * @dev Helper function to view the token route for swapping between output and lpToken1.
     * @return outputToLp1Route The token route between output to lpToken1.
     */
    function outputToLp1() external view returns (address[] memory) {
        return routes[address(output)][lpToken1];
    }

    /**
     * @dev It sets the name of the pending rewards function in the underlying platform so the
     * total amount of rewards can be fetched.
     * @param _pendingRewardsFunctionName The name of the pending rewards function.
     */
    function setPendingRewardsFunctionName(
        string calldata _pendingRewardsFunctionName
    ) external atLeastRole(STRATEGIST) {
        pendingRewardsFunctionName = _pendingRewardsFunctionName;
    }

    /**
     * @dev It notifies the strategy that there is an extra token to compound back into the output.
     * @param _route The route for the extra reward token.
     */
    function addReward(address[] calldata _route) external atLeastRole(ADMIN) {
        address fromToken = _route[0];
        address toToken = _route[_route.length - 1];
        require(fromToken != address(want), "want is not a reward");
        require(toToken == address(output), "dest token is not output");

        rewards.push(fromToken);
        routes[fromToken][toToken] = _route;

        IERC20Upgradeable(fromToken).safeApprove(unirouter, 0);
        IERC20Upgradeable(fromToken).safeApprove(unirouter, type(uint).max);
    }

    /**
     * @dev It removes the extra reward previously added by the owner.
     */
    function removeReward() external atLeastRole(STRATEGIST) {
        address token = rewards[rewards.length - 1];
        if (token != lpToken0 || token != lpToken1) {
            IERC20Upgradeable(token).safeApprove(unirouter, 0);
        }
        rewards.pop();
    }
}
