// https://github.com/iearn-finance/contracts/blob/master/contracts/strategies/StrategyCurveYCRVVoter.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.6.2;

import "../lib/erc20.sol";
import "../lib/safe-math.sol";

import "../interfaces/jar.sol";
import "../interfaces/curve.sol";
import "../interfaces/onesplit.sol";
import "../interfaces/controller.sol";

contract StrategyCurveSCRVv1 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // sCRV
    address public constant want = 0xC25a3A3b969415c80451098fa907EC722572917F;

    // susdv2 pool
    address public constant curve = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;

    // tokens we're farming
    address public constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant snx = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;

    // curve dao
    address public constant gauge = 0xA90996896660DEcC6E997655E065b23788857849;
    address public constant mintr = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;

    // stablecoins
    address public constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant susd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;

    // pickle token
    address public constant pickle = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;

    // burn address
    address public constant burn = 0x000000000000000000000000000000000000dEaD;

    // dex
    address public onesplit = 0xC586BeF4a0992C495Cf22e1aeEE4E446CECDee0E;
    uint256 public parts = 2; // onesplit parts

    // Fees ~4.93% in total
    // - 2.94%  performance fee
    // - 1.5%   used to burn pickles
    // - 0.5%   gas compensation fee (for caller)

    // 3% of 98% = 2.94% of original 100%
    uint256 public performanceFee = 300;
    uint256 public constant performanceMax = 10000;

    uint256 public burnFee = 150;
    uint256 public constant burnMax = 10000;

    uint256 public callerFee = 50;
    uint256 public constant callerMax = 10000;

    uint256 public withdrawalFee = 50;
    uint256 public constant withdrawalMax = 10000;

    address public governance;
    address public controller;
    address public strategist;

    constructor(
        address _governance,
        address _strategist,
        address _controller
    ) public {
        governance = _governance;
        strategist = _strategist;
        controller = _controller;
    }

    // **** Views ****

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        return ICurveGauge(gauge).balanceOf(address(this));
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function getName() external pure returns (string memory) {
        return "StrategyCurveSCRVv1";
    }

    function getMostPremiumStablecoin() public view returns (address, uint256) {
        uint256[] memory balances = new uint256[](4);
        balances[0] = ICurveFi(curve).balances(0); // DAI
        balances[1] = ICurveFi(curve).balances(1).mul(10**12); // USDC
        balances[2] = ICurveFi(curve).balances(2).mul(10**12); // USDT
        balances[3] = ICurveFi(curve).balances(3); // sUSD

        // DAI
        if (
            balances[0] < balances[1] &&
            balances[0] < balances[2] &&
            balances[0] < balances[3]
        ) {
            return (dai, 0);
        }

        // USDC
        if (
            balances[1] < balances[0] &&
            balances[1] < balances[2] &&
            balances[1] < balances[3]
        ) {
            return (usdc, 1);
        }

        // USDT
        if (
            balances[2] < balances[0] &&
            balances[2] < balances[1] &&
            balances[2] < balances[3]
        ) {
            return (usdt, 2);
        }

        // SUSD
        if (
            balances[3] < balances[0] &&
            balances[3] < balances[1] &&
            balances[3] < balances[2]
        ) {
            return (susd, 3);
        }

        // If they're somehow equal, we just want DAI
        return (dai, 0);
    }

    // Manually change this function to view on the abi
    // This is due to 'gauge'.claimable_token function
    // Which fucks everything up
    function getExpectedRewards()
        public
        returns (
            address, // stablecoin address
            uint256, // caller rewards
            uint256 // amount of pickle to burn
        )
    {
        // stablecoin we want to convert to
        (address to, ) = getMostPremiumStablecoin();

        // Return amounts
        uint256 _to;
        uint256 _pickleBurn;
        uint256 _retAmount;

        // CRV
        uint256 _crv = ICurveGauge(gauge).claimable_tokens(address(this));
        if (_crv > 0) {
            (_retAmount, ) = OneSplitAudit(onesplit).getExpectedReturn(
                crv,
                to,
                _crv,
                parts,
                0
            );
            _to = _to.add(_retAmount);
        }

        // SNX
        uint256 _snx = ICurveGauge(gauge).claimable_reward(address(this));
        if (_snx > 0) {
            (_retAmount, ) = OneSplitAudit(onesplit).getExpectedReturn(
                snx,
                to,
                _snx,
                parts,
                0
            );
            _to = _to.add(_retAmount);
        }

        if (_to > 0) {
            (_pickleBurn, ) = OneSplitAudit(onesplit).getExpectedReturn(
                to,
                pickle,
                _to.mul(burnFee).div(burnMax),
                parts,
                0
            );
        }

        return (
            to,
            _to.mul(callerFee).div(callerMax), // Caller rewards
            _pickleBurn // BURN Pickle amount
        );
    }

    // **** Setters ****

    function setStrategist(address _strategist) external {
        require(msg.sender == governance, "!governance");
        strategist = _strategist;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external {
        require(msg.sender == governance, "!governance");
        withdrawalFee = _withdrawalFee;
    }

    function setPerformanceFee(uint256 _performanceFee) external {
        require(msg.sender == governance, "!governance");
        performanceFee = _performanceFee;
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function setController(address _controller) external {
        require(msg.sender == governance, "!governance");
        controller = _controller;
    }

    function setOneSplit(address _onesplit) public {
        require(msg.sender == governance, "!governance");
        onesplit = _onesplit;
    }

    function setParts(uint256 _parts) public {
        require(msg.sender == governance, "!governance");
        parts = _parts;
    }

    // **** State Mutations ****

    function deposit() public {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeApprove(gauge, 0);
            IERC20(want).approve(gauge, _want);
            ICurveGauge(gauge).deposit(_want);
        }
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        require(crv != address(_asset), "crv");
        require(snx != address(_asset), "snx");
        require(dai != address(_asset), "dai");
        require(usdc != address(_asset), "usdc");
        require(usdt != address(_asset), "usdt");
        require(susd != address(_asset), "susd");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a jar withdrawal
    function withdraw(uint256 _amount) external {
        require(msg.sender == controller, "!controller");
        uint256 _balance = IERC20(want).balanceOf(address(this));
        if (_balance < _amount) {
            _amount = _withdrawSome(_amount.sub(_balance));
            _amount = _amount.add(_balance);
        }

        uint256 _fee = _amount.mul(withdrawalFee).div(withdrawalMax);

        IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
        address _jar = IController(controller).jars(address(want));
        require(_jar != address(0), "!jar"); // additional protection so we don't burn the funds

        IERC20(want).safeTransfer(_jar, _amount.sub(_fee));
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        _withdrawAll();

        balance = IERC20(want).balanceOf(address(this));

        address _jar = IController(controller).jars(address(want));
        require(_jar != address(0), "!jar"); // additional protection so we don't burn the funds
        IERC20(want).safeTransfer(_jar, balance);
    }

    function _withdrawAll() internal {
        ICurveGauge(gauge).withdraw(
            ICurveGauge(gauge).balanceOf(address(this))
        );
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        ICurveGauge(gauge).withdraw(_amount);
        return _amount;
    }

    function brine() public {
        harvest();
    }

    function harvest() public {
        // Anyone can harvest it at any given time.
        // I understand the possibility of being frontrun
        // But ETH is a dark forest, and I wanna see how this plays out
        // i.e. will be be heavily frontrunned?
        //      if so, a new strategy will be deployed.

        // stablecoin we want to convert to
        (address to, uint256 toIndex) = getMostPremiumStablecoin();

        // Collects crv tokens
        // Don't bother voting in v1
        ICurveMintr(mintr).mint(gauge);
        uint256 _crv = IERC20(crv).balanceOf(address(this));
        if (_crv > 0) {
            _swap(crv, to, _crv);
        }

        // Collects SNX tokens
        ICurveGauge(gauge).claim_rewards(address(this));
        uint256 _snx = IERC20(snx).balanceOf(address(this));
        if (_snx > 0) {
            _swap(snx, to, _snx);
        }

        // Adds liquidity to curve.fi's susd pool
        // to get back want (scrv)
        uint256 _to = IERC20(to).balanceOf(address(this));
        if (_to > 0) {
            // Fees (in stablecoin)
            // 0.5% sent to msg.sender to refund gas
            uint256 _callerFee = _to.mul(callerFee).div(callerMax);
            IERC20(to).safeTransfer(msg.sender, _callerFee);

            // 1.5% used to buy and BURN pickles
            uint256 _burnFee = _to.mul(burnFee).div(burnMax);
            _swap(to, pickle, _burnFee);
            IERC20(pickle).transfer(
                burn,
                IERC20(pickle).balanceOf(address(this))
            );

            // Supply to curve to get sCRV
            _to = _to.sub(_callerFee).sub(_burnFee);
            IERC20(to).safeApprove(curve, 0);
            IERC20(to).safeApprove(curve, _to);
            uint256[4] memory liquidity;
            liquidity[toIndex] = _to;
            ICurveFi(curve).add_liquidity(liquidity, 0);
        }

        // We want to get back sCRV
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            // Fees (in sCRV)
            // 3% performance fee
            // This 3% comes AFTER deducing 2%
            // So in reality its actually around 2.94%
            // 0.98 * 0.03 = 0.0294
            IERC20(want).safeTransfer(
                IController(controller).rewards(),
                _want.mul(performanceFee).div(performanceMax)
            );

            deposit();
        }
    }

    function _swap(
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        // Onesplit params
        uint256 expected;
        uint256[] memory distribution;

        IERC20(_from).safeApprove(onesplit, 0);
        IERC20(_from).safeApprove(onesplit, _amount);

        (expected, distribution) = OneSplitAudit(onesplit).getExpectedReturn(
            _from,
            _to,
            _amount,
            parts,
            0
        );
        OneSplitAudit(onesplit).swap(
            _from,
            _to,
            _amount,
            parts,
            distribution,
            0
        );
    }
}
