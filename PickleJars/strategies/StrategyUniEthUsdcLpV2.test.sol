// hevm: flattened sources of src/tests/strategy-uni-eth-usdc-lp-v2.test.sol
pragma solidity >=0.4.23 >=0.6.0 <0.7.0 >=0.6.2 <0.7.0 >=0.6.7 <0.7.0;

////// src/tests/strategy-uni-eth-usdc-lp-v2.test.sol
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
import "../strategies/strategy-uni-eth-usdc-lp-v2.sol";

contract StrategyUniEthUsdcpV2Test is DSTestApprox {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address pickle = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;
    address burn = 0x000000000000000000000000000000000000dEaD;

    address want = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    address uni = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address rewardsFactory = 0x3032Ab3Fa8C01d786D29dAdE018d7f2017918e12;

    address governance;
    address strategist;
    address rewards;
    address timelock;

    PickleJar pickleJar;
    Controller controller;
    StrategyUniEthUsdcLpV2 strategy;

    Hevm hevm;
    UniswapRouterV2 univ2Router2 = UniswapRouterV2(
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    );

    uint256 startTime = block.timestamp;

    function setUp() public {
        governance = address(this);
        strategist = address(this);
        rewards = address(this);
        timelock = address(this);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        controller = new Controller(governance, strategist, rewards);

        strategy = new StrategyUniEthUsdcLpV2(
            governance,
            strategist,
            address(controller),
            timelock
        );

        pickleJar = new PickleJar(
            strategy.want(),
            governance,
            address(controller)
        );

        controller.setJar(strategy.want(), address(pickleJar));
        controller.approveStrategy(strategy.want(), address(strategy));
        controller.setStrategy(strategy.want(), address(strategy));

        // Set time
        hevm.warp(startTime);

        if (
            block.timestamp <
            IStakingRewardsFactory(rewardsFactory).stakingRewardsGenesis()
        ) {
            // Modify genesis time
            hevm.store(
                rewardsFactory,
                bytes32(uint256(2)), // genesisTime is at 0x2 location
                bytes32(block.timestamp - 1 hours)
            );

            // Gimmie tokens
            IStakingRewardsFactory(rewardsFactory).notifyRewardAmounts();
        }
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

            univ2Router2.swapExactETHForTokens{value: _amount}(
                0,
                path,
                address(this),
                now + 60
            );
        } else {
            if (_from == weth || _to == weth) {
                path = new address[](2);
                path[0] = _from;
                path[1] = _to;
            } else {
                path = new address[](3);
                path[0] = _from;
                path[1] = weth;
                path[2] = _to;
            }

            IERC20(_from).approve(address(univ2Router2), _amount);
            univ2Router2.swapExactTokensForTokens(
                _amount,
                0,
                path,
                address(this),
                now + 60
            );
        }
    }

    function _getUSDC(uint256 _amount) internal {
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = usdc;

        uint256[] memory ins = univ2Router2.getAmountsIn(_amount, path);
        uint256 ethAmount = ins[0];

        univ2Router2.swapETHForExactTokens{value: ethAmount}(
            _amount,
            path,
            address(this),
            now + 60
        );
    }

    function _getWant(uint256 ethAmount, uint256 usdcAmount) internal {
        _getUSDC(usdcAmount);

        uint256 _usdc = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).approve(address(univ2Router2), _usdc);

        univ2Router2.addLiquidityETH{value: ethAmount}(
            usdc,
            _usdc,
            0,
            0,
            address(this),
            now + 60
        );
    }

    // **** Tests ****

    function test_timelock() public {
        assertTrue(strategy.timelock() == timelock);
        strategy.setTimelock(address(1));
        assertTrue(strategy.timelock() == address(1));
    }

    function test_withdraw_release() public {
        _getWant(10 ether, 4000 * 10e6); // WANT w/ 10 ETH and 400 USDC
        uint256 _want = IERC20(want).balanceOf(address(this));
        IERC20(want).approve(address(pickleJar), _want);
        pickleJar.deposit(_want);
        pickleJar.earn();
        hevm.warp(block.timestamp + 1 weeks);
        strategy.harvest();

        // Checking withdraw
        uint256 _before = IERC20(want).balanceOf(address(pickleJar));
        controller.withdrawAll(want);
        uint256 _after = IERC20(want).balanceOf(address(pickleJar));
        assertTrue(_after > _before);
        _before = IERC20(want).balanceOf(address(this));
        pickleJar.withdrawAll();
        _after = IERC20(want).balanceOf(address(this));
        assertTrue(_after > _before);

        // Check if we gained interest
        assertTrue(_after > _want);
    }

    function test_get_earn_harvest_rewards() public {
        _getWant(10 ether, 4000 * 10e6); // WANT w/ 10 ETH and 400 USDC
        uint256 _want = IERC20(want).balanceOf(address(this));
        IERC20(want).approve(address(pickleJar), _want);
        pickleJar.deposit(_want);
        pickleJar.earn();
        hevm.warp(block.timestamp + 1 weeks);

        // Call the harvest function
        uint256 _before = pickleJar.balance();
        uint256 _picklesBefore = IERC20(pickle).balanceOf(burn);
        uint256 _rewardsBefore = IERC20(want).balanceOf(rewards);
        strategy.harvest();
        uint256 _after = pickleJar.balance();
        uint256 _picklesAfter = IERC20(pickle).balanceOf(burn);
        uint256 _rewardsAfter = IERC20(want).balanceOf(rewards);

        uint256 earned = _after.sub(_before).mul(1000).div(970);
        uint256 earnedRewards = earned.mul(3).div(100); // 3%
        uint256 actualRewardsEarned = _rewardsAfter.sub(_rewardsBefore);

        // Allow errors up to 18 decimal places
        actualRewardsEarned = actualRewardsEarned.div(1e18).mul(1e18);
        earnedRewards = earnedRewards.div(1e18).mul(1e18);

        // 3 % performance fee is given
        assertEq(earnedRewards, actualRewardsEarned);

        // Pickles are burned
        // Slight variation
        assertTrue(_picklesAfter > _picklesBefore);
    }
}

