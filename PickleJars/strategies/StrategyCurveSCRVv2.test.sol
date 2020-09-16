pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./hevm.sol";
import "./user.sol";
import "./test-approx.sol";

import "../interfaces/strategy.sol";
import "../interfaces/curve.sol";
import "../interfaces/uniswapv2.sol";

import "../pickle-jar.sol";
import "../controller.sol";
import "../strategies/strategy-curve-scrv-v2.sol";

contract DSTestApprox is DSTest {
    function assertEqApprox(uint256 a, uint256 b) internal {
        uint256 max = a > b ? a : b;
        uint256 min = a < b ? a : b;

        if (max / min != 1) {
            emit log_bytes32("Error: Wrong `a-uint` value!");
            emit log_named_uint("  Expected", b);
            emit log_named_uint("    Actual", a);
            fail();
        }
    }
}

contract StrategyCurveSCRVv2Test is DSTestApprox {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address pickle = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;
    address burn = 0x000000000000000000000000000000000000dEaD;

    address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address curve = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address scrv = 0xC25a3A3b969415c80451098fa907EC722572917F;
    address crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address snx = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address susd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;

    address governance;
    address strategist;
    address rewards;

    PickleJar pickleJar;
    Controller controller;
    StrategyCurveSCRVv2 strategy;

    Hevm hevm;
    UniswapRouterV2 univ2 = UniswapRouterV2(
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    );

    uint256 startTime = block.timestamp;

    function setUp() public {
        governance = address(this);
        strategist = address(this);
        rewards = address(this);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        controller = new Controller(governance, strategist, rewards);

        strategy = new StrategyCurveSCRVv2(
            governance,
            strategist,
            address(controller)
        );

        pickleJar = new PickleJar(
            strategy.want(),
            governance,
            address(controller)
        );

        controller.setJar(strategy.want(), address(pickleJar));
        controller.approveStrategy(strategy.want(), address(strategy));
        controller.setStrategy(strategy.want(), address(strategy));

        hevm.warp(startTime);
    }

    function _swap(
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        address[] memory path;

        if (_from == eth) {
            path = new address[](2);
            path[0] = weth;
            path[1] = _to;

            univ2.swapExactETHForTokens{value: _amount}(
                0,
                path,
                address(this),
                now + 60
            );
        } else {
            path = new address[](3);
            path[0] = _from;
            path[1] = weth;
            path[2] = _to;

            IERC20(_from).safeApprove(address(univ2), 0);
            IERC20(_from).safeApprove(address(univ2), _amount);

            univ2.swapExactTokensForTokens(
                _amount,
                0,
                path,
                address(this),
                now + 60
            );
        }
    }

    function _getDAI(uint256 _amount) internal {
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = dai;

        uint256[] memory ins = univ2.getAmountsIn(_amount, path);
        uint256 ethAmount = ins[0];

        univ2.swapETHForExactTokens{value: ethAmount}(
            _amount,
            path,
            address(this),
            now + 60
        );
    }

    function _getSCRV(uint256 daiAmount) internal {
        _getDAI(daiAmount);
        uint256[4] memory liquidity;
        liquidity[0] = IERC20(dai).balanceOf(address(this));
        IERC20(dai).approve(curve, liquidity[0]);
        ICurveFi(curve).add_liquidity(liquidity, 0);
    }

    // **** Tests ***

    function test_get_earn_harvest_rewards() public {
        User user = new User();

        // Deposit sCRV, and earn
        _getSCRV(10000000 ether); // 1 million DAI
        uint256 _scrv = IERC20(scrv).balanceOf(address(this));
        IERC20(scrv).approve(address(pickleJar), _scrv);
        pickleJar.deposit(_scrv);
        pickleJar.earn();
        (address to, ) = strategy.getMostPremiumStablecoin();

        // Fast forward one week
        hevm.warp(block.timestamp + 1 weeks);

        // Call the getReward function
        (, uint256 callerRewards, uint256 picklesToBurn) = strategy
            .getExpectedRewards();

        // Call the harvest function
        uint256 _before = pickleJar.balance();
        uint256 _userBefore = IERC20(to).balanceOf(address(user));
        uint256 _picklesBefore = IERC20(pickle).balanceOf(burn);
        uint256 _rewardsBefore = IERC20(scrv).balanceOf(rewards);
        user.execute(address(strategy), 0, "harvest()", "");
        uint256 _after = pickleJar.balance();
        uint256 _userAfter = IERC20(to).balanceOf(address(user));
        uint256 _picklesAfter = IERC20(pickle).balanceOf(burn);
        uint256 _rewardsAfter = IERC20(scrv).balanceOf(rewards);

        uint256 earned = _after.sub(_before).mul(1000).div(970);
        uint256 earnedRewards = earned.mul(3).div(100); // 3%
        uint256 actualRewardsEarned = _rewardsAfter.sub(_rewardsBefore);

        // Allow errors up to 18 decimal places
        actualRewardsEarned = actualRewardsEarned.div(1e18).mul(1e18);
        earnedRewards = earnedRewards.div(1e18).mul(1e18);

        // 3 % performance fee is given
        assertEq(earnedRewards, actualRewardsEarned);

        // Caller is given some stablecoin as gas compensation
        assertEqApprox(callerRewards, _userAfter.sub(_userBefore));

        // Pickles are burned
        // Slight variation
        assertEq(_picklesAfter.sub(_picklesBefore).div(picklesToBurn), 1);
    }
}
