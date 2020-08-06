pragma solidity 0.5.17;

import "../../contracts/ECDSAKeepRewards.sol";

contract ECDSAKeepRewardsStub is ECDSAKeepRewards {
    constructor (
        address _keepToken,
        address factoryAddress,
        uint256 _initiated,
        uint256[] memory _intervalWeights
    ) public ECDSAKeepRewards(
            _keepToken,
            factoryAddress,
            _initiated,
            _intervalWeights
    ) {}

    // function eligibleForRewardA(address keep) public view returns (bool) {
    //     return eligibleForReward(fromAddress(keep));
    // }

    // function eligibleButTerminatedA(address keep) public view returns (bool) {
    //     return eligibleButTerminated(fromAddress(keep));
    // }

    // function receiveRewardA(address keep) public {
    //     return receiveReward(fromAddress(keep));
    // }

    // function reportTerminationA(address keep) public {
    //     return reportTermination(fromAddress(keep));
    // }

    function getUnallocatedRewards() public view returns (uint256) {
        return unallocatedRewards;
    }

    function _toAddress(bytes32 b) public pure returns (address) {
        return toAddress(b);
    }

    function _fromAddress(address a) public pure returns (bytes32) {
        return fromAddress(a);
    }

    function testRoundtrip(bytes32 b) public pure returns (bool) {
        return validAddressBytes(b);
    }

    function isClosed(bytes32 keep) public view returns (bool) {
        return _isClosed(keep);
    }

    function isTerminated(bytes32 keep) public view returns (bool) {
        return _isTerminated(keep);
    }

    function recognizedByFactory(bytes32 keep) public view returns (bool) {
        return _recognizedByFactory(keep);
    }
}
