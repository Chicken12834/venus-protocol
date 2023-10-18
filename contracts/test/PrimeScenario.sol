pragma solidity 0.8.13;

import "../Tokens/Prime/Prime.sol";

contract PrimeScenario is Prime {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wbnb,
        address _vbnb,
        uint256 _blocksPerYear,
        uint256 _stakingPeriod,
        uint256 _minimumStakedXVS,
        uint256 _maximumXVSCap
    ) Prime(_wbnb, _vbnb, _blocksPerYear, _stakingPeriod, _minimumStakedXVS, _maximumXVSCap) {}

    function calculateScore(uint256 xvs, uint256 capital) external view returns (uint256) {
        return Scores.calculateScore(xvs, capital, alphaNumerator, alphaDenominator);
    }

    function setPLP(address plp) external {
        primeLiquidityProvider = plp;
    }
}
