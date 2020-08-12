/**
▓▓▌ ▓▓ ▐▓▓ ▓▓▓▓▓▓▓▓▓▓▌▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▄
▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▌▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
  ▓▓▓▓▓▓    ▓▓▓▓▓▓▓▀    ▐▓▓▓▓▓▓    ▐▓▓▓▓▓   ▓▓▓▓▓▓     ▓▓▓▓▓   ▐▓▓▓▓▓▌   ▐▓▓▓▓▓▓
  ▓▓▓▓▓▓▄▄▓▓▓▓▓▓▓▀      ▐▓▓▓▓▓▓▄▄▄▄         ▓▓▓▓▓▓▄▄▄▄         ▐▓▓▓▓▓▌   ▐▓▓▓▓▓▓
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▀        ▐▓▓▓▓▓▓▓▓▓▓         ▓▓▓▓▓▓▓▓▓▓▌        ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
  ▓▓▓▓▓▓▀▀▓▓▓▓▓▓▄       ▐▓▓▓▓▓▓▀▀▀▀         ▓▓▓▓▓▓▀▀▀▀         ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▀
  ▓▓▓▓▓▓   ▀▓▓▓▓▓▓▄     ▐▓▓▓▓▓▓     ▓▓▓▓▓   ▓▓▓▓▓▓     ▓▓▓▓▓   ▐▓▓▓▓▓▌
▓▓▓▓▓▓▓▓▓▓ █▓▓▓▓▓▓▓▓▓ ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  ▓▓▓▓▓▓▓▓▓▓
▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓ ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  ▓▓▓▓▓▓▓▓▓▓

                           Trust math, not hardware.
*/

pragma solidity 0.5.17;

import "./BondedECDSAKeep.sol";
import "./KeepBonding.sol";
import "./api/IBondedECDSAKeepFactory.sol";
import "./CloneFactory.sol";
import "./KeepFactoryBeaconConsumer.sol";

import "@keep-network/sortition-pools/contracts/api/IStaking.sol";
import "@keep-network/sortition-pools/contracts/api/IBonding.sol";
import "@keep-network/sortition-pools/contracts/BondedSortitionPool.sol";
import "@keep-network/sortition-pools/contracts/BondedSortitionPoolFactory.sol";

import {
    AuthorityDelegator,
    TokenStaking
} from "@keep-network/keep-core/contracts/TokenStaking.sol";
import "@keep-network/keep-core/contracts/utils/AddressArrayUtils.sol";

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

/// @title Bonded ECDSA Keep Factory
/// @notice Contract creating bonded ECDSA keeps.
/// @dev We avoid redeployment of bonded ECDSA keep contract by using the clone factory.
/// Proxy delegates calls to sortition pool and therefore does not affect contract's
/// state. This means that we only need to deploy the bonded ECDSA keep contract
/// once. The factory provides clean state for every new bonded ECDSA keep clone.
contract BondedECDSAKeepFactory is
    IBondedECDSAKeepFactory,
    CloneFactory,
    AuthorityDelegator,
    KeepFactoryBeaconConsumer
{
    using AddressArrayUtils for address[];
    using SafeMath for uint256;

    // Notification that a new sortition pool has been created.
    event SortitionPoolCreated(
        address indexed application,
        address sortitionPool
    );

    // Notification that a new keep has been created.
    event BondedECDSAKeepCreated(
        address indexed keepAddress,
        address[] members,
        address indexed owner,
        address indexed application,
        uint256 honestThreshold
    );

    // Holds the address of the bonded ECDSA keep contract that will be used as a
    // master contract for cloning.
    address public masterBondedECDSAKeepAddress;

    // Keeps created by this factory.
    address[] public keeps;

    // Maps keep opened timestamp to each keep address
    mapping(address => uint256) keepOpenedTimestamp;

    // Mapping of pools with registered member candidates for each application.
    mapping(address => address) candidatesPools; // application -> candidates pool

    BondedSortitionPoolFactory sortitionPoolFactory;
    TokenStaking tokenStaking;
    KeepBonding keepBonding;

    // Sortition pool is created with a minimum bond of 20 ETH to avoid
    // small operators joining and griefing future selections before the
    // minimum bond is set to the right value by the application.
    //
    // Anyone can create a sortition pool for an application with the default
    // minimum bond value but the application can change this value later, at
    // any point.
    uint256 public constant minimumBond = 20e18; // 20 ETH

    // Signer candidates in bonded sortition pool are weighted by their eligible
    // stake divided by a constant divisor. The divisor is set to 1 KEEP so that
    // all KEEPs in eligible stake matter when calculating operator's eligible
    // weight for signer selection.
    uint256 public constant poolStakeWeightDivisor = 1e18;

    constructor(
        address _masterBondedECDSAKeepAddress,
        address _sortitionPoolFactory,
        address _tokenStaking,
        address _keepBonding,
        address _randomBeacon
    ) public KeepFactoryBeaconConsumer(_randomBeacon) {
        masterBondedECDSAKeepAddress = _masterBondedECDSAKeepAddress;
        sortitionPoolFactory = BondedSortitionPoolFactory(
            _sortitionPoolFactory
        );
        tokenStaking = TokenStaking(_tokenStaking);
        keepBonding = KeepBonding(_keepBonding);
    }

    /// @notice Creates new sortition pool for the application.
    /// @dev Emits an event after sortition pool creation.
    /// @param _application Address of the application.
    /// @return Address of the created sortition pool contract.
    function createSortitionPool(address _application)
        external
        returns (address)
    {
        require(
            candidatesPools[_application] == address(0),
            "Sortition pool already exists"
        );

        address sortitionPoolAddress = sortitionPoolFactory.createSortitionPool(
            IStaking(address(tokenStaking)),
            IBonding(address(keepBonding)),
            tokenStaking.minimumStake(),
            minimumBond,
            poolStakeWeightDivisor
        );

        candidatesPools[_application] = sortitionPoolAddress;

        emit SortitionPoolCreated(_application, sortitionPoolAddress);

        return candidatesPools[_application];
    }

    /// @notice Sets the minimum bondable value required from the operator to
    /// join the sortition pool of the given application. It is up to the
    /// application to specify a reasonable minimum bond for operators trying to
    /// join the pool to prevent griefing by operators joining without enough
    /// bondable value.
    /// @param _minimumBondableValue The minimum bond value the application
    /// requires from a single keep.
    /// @param _groupSize Number of signers in the keep.
    /// @param _honestThreshold Minimum number of honest keep signers.
    function setMinimumBondableValue(
        uint256 _minimumBondableValue,
        uint256 _groupSize,
        uint256 _honestThreshold
    ) external {
        uint256 memberBond = bondPerMember(_minimumBondableValue, _groupSize);
        BondedSortitionPool(getSortitionPool(msg.sender))
            .setMinimumBondableValue(memberBond);
    }

    /// @notice Register caller as a candidate to be selected as keep member
    /// for the provided customer application.
    /// @dev If caller is already registered it returns without any changes.
    /// @param _application Address of the application.
    function registerMemberCandidate(address _application) external {
        BondedSortitionPool candidatesPool = BondedSortitionPool(
            getSortitionPool(_application)
        );

        address operator = msg.sender;
        if (!candidatesPool.isOperatorInPool(operator)) {
            candidatesPool.joinPool(operator);
        }
    }

    /// @notice Checks if operator's details in the member candidates pool are
    /// up to date for the given application. If not update operator status
    /// function should be called by the one who is monitoring the status.
    /// @param _operator Operator's address.
    /// @param _application Customer application address.
    function isOperatorUpToDate(address _operator, address _application)
        external
        view
        returns (bool)
    {
        BondedSortitionPool candidatesPool = getSortitionPoolForOperator(
            _operator,
            _application
        );

        return candidatesPool.isOperatorUpToDate(_operator);
    }

    /// @notice Invokes update of operator's details in the member candidates pool
    /// for the given application
    /// @param _operator Operator's address.
    /// @param _application Customer application address.
    function updateOperatorStatus(address _operator, address _application)
        external
    {
        BondedSortitionPool candidatesPool = getSortitionPoolForOperator(
            _operator,
            _application
        );

        candidatesPool.updateOperatorStatus(_operator);
    }

    /// @notice Opens a new ECDSA keep.
    /// @dev Selects a list of signers for the keep based on provided parameters.
    /// A caller of this function is expected to be an application for which
    /// member candidates were registered in a pool.
    /// @param _groupSize Number of signers in the keep.
    /// @param _honestThreshold Minimum number of honest keep signers.
    /// @param _owner Address of the keep owner.
    /// @param _bond Value of ETH bond required from the keep in wei.
    /// @param _stakeLockDuration Stake lock duration in seconds.
    /// @return Created keep address.
    function openKeep(
        uint256 _groupSize,
        uint256 _honestThreshold,
        address _owner,
        uint256 _bond,
        uint256 _stakeLockDuration
    ) external payable returns (address keepAddress) {
        require(_groupSize > 0, "Minimum signing group size is 1");
        require(_groupSize <= 16, "Maximum signing group size is 16");
        require(
            _honestThreshold > 0,
            "Honest threshold must be greater than 0"
        );
        require(
            _honestThreshold <= _groupSize,
            "Honest threshold must be less or equal the group size"
        );

        address application = msg.sender;
        address pool = candidatesPools[application];
        require(pool != address(0), "No signer pool for this application");

        uint256 memberBond = bondPerMember(_bond, _groupSize);
        require(memberBond > 0, "Bond per member must be greater than zero");

        require(
            msg.value >= openKeepFeeEstimate(),
            "Insufficient payment for opening a new keep"
        );

        uint256 minimumStake = tokenStaking.minimumStake();

        address[] memory members = BondedSortitionPool(pool).selectSetGroup(
            _groupSize,
            bytes32(groupSelectionSeed),
            minimumStake,
            memberBond
        );

        newGroupSelectionSeed();

        keepAddress = createClone(masterBondedECDSAKeepAddress);
        BondedECDSAKeep keep = BondedECDSAKeep(keepAddress);

        // keepOpenedTimestamp value for newly created keep is required to be set
        // before calling `keep.initialize` function as it is used to determine
        // token staking delegation authority recognition in `__isRecognized`
        // function.
        /* solium-disable-next-line security/no-block-members*/
        keepOpenedTimestamp[address(keep)] = block.timestamp;

        keep.initialize(
            _owner,
            members,
            _honestThreshold,
            minimumStake,
            _stakeLockDuration,
            address(tokenStaking),
            address(keepBonding),
            address(this)
        );

        for (uint256 i = 0; i < _groupSize; i++) {
            keepBonding.createBond(
                members[i],
                keepAddress,
                uint256(keepAddress),
                memberBond,
                pool
            );
        }

        keeps.push(address(keep));

        emit BondedECDSAKeepCreated(
            keepAddress,
            members,
            _owner,
            application,
            _honestThreshold
        );
    }

    /// @notice Gets how many keeps have been opened by this contract.
    /// @dev    Checks the size of the keeps array.
    /// @return The number of keeps opened so far.
    function getKeepCount() external view returns (uint256) {
        return keeps.length;
    }

    /// @notice Gets a specific keep address at a given index.
    /// @return The address of the keep at the given index.
    function getKeepAtIndex(uint256 index) external view returns (address) {
        require(index < keeps.length, "Out of bounds.");
        return keeps[index];
    }

    /// @notice Gets the opened timestamp of the given keep.
    /// @return Timestamp the given keep was opened at or 0 if this keep
    /// was not created by this factory.
    function getKeepOpenedTimestamp(address _keep)
        external
        view
        returns (uint256)
    {
        return keepOpenedTimestamp[_keep];
    }

    /// @notice Verifies if delegates authority recipient is valid address recognized
    /// by the factory for token staking authority delegation.
    /// @param _delegatedAuthorityRecipient Address of the delegated authority
    /// recipient.
    /// @return True if provided address is recognized delegated token staking
    /// authority for this factory contract.
    function __isRecognized(address _delegatedAuthorityRecipient)
        external
        returns (bool)
    {
        return keepOpenedTimestamp[_delegatedAuthorityRecipient] > 0;
    }

    /// @notice Gets the sortition pool address for the given application.
    /// @dev Reverts if sortition does not exist for the application.
    /// @param _application Address of the application.
    /// @return Address of the sortition pool contract.
    function getSortitionPool(address _application)
        public
        view
        returns (address)
    {
        require(
            candidatesPools[_application] != address(0),
            "No pool found for the application"
        );

        return candidatesPools[_application];
    }

    /// @notice Checks if operator is registered as a candidate for the given
    /// customer application.
    /// @param _operator Operator's address.
    /// @param _application Customer application address.
    /// @return True if operator is already registered in the candidates pool,
    /// false otherwise.
    function isOperatorRegistered(address _operator, address _application)
        public
        view
        returns (bool)
    {
        if (candidatesPools[_application] == address(0)) {
            return false;
        }

        BondedSortitionPool candidatesPool = BondedSortitionPool(
            candidatesPools[_application]
        );

        return candidatesPool.isOperatorRegistered(_operator);
    }

    /// @notice Checks if given operator is eligible for the given application.
    /// @param _operator Operator's address.
    /// @param _application Customer application address.
    function isOperatorEligible(address _operator, address _application)
        public
        view
        returns (bool)
    {
        if (candidatesPools[_application] == address(0)) {
            return false;
        }

        BondedSortitionPool candidatesPool = BondedSortitionPool(
            candidatesPools[_application]
        );

        return candidatesPool.isOperatorEligible(_operator);
    }

    /// @notice Gets a fee estimate for opening a new keep.
    /// @return Uint256 estimate.
    function openKeepFeeEstimate() public view returns (uint256) {
        return newEntryFeeEstimate();
    }

    /// @notice Checks if the specified account has enough active stake to become
    /// network operator and that this contract has been authorized for potential
    /// slashing.
    ///
    /// Having the required minimum of active stake makes the operator eligible
    /// to join the network. If the active stake is not currently undelegating,
    /// operator is also eligible for work selection.
    ///
    /// @param _operator operator's address
    /// @return True if has enough active stake to participate in the network,
    /// false otherwise.
    function hasMinimumStake(address _operator) public view returns (bool) {
        return tokenStaking.hasMinimumStake(_operator, address(this));
    }

    /// @notice Checks if the factory has the authorization to operate on stake
    /// represented by the provided operator.
    ///
    /// @param _operator operator's address
    /// @return True if the factory has access to the staked token balance of
    /// the provided operator and can slash that stake. False otherwise.
    function isOperatorAuthorized(address _operator)
        public
        view
        returns (bool)
    {
        return tokenStaking.isAuthorizedForOperator(_operator, address(this));
    }

    /// @notice Gets the stake balance of the specified operator.
    /// @param _operator The operator to query the balance of.
    /// @return An uint256 representing the amount staked by the passed operator.
    function balanceOf(address _operator) public view returns (uint256) {
        return tokenStaking.balanceOf(_operator);
    }

    /// @notice Gets the total weight of operators
    /// in the sortition pool for the given application.
    /// @dev Reverts if sortition does not exits for the application.
    /// @param _application Address of the application.
    /// @return The sum of all registered operators' weights in the pool.
    /// Reverts if sortition pool for the application does not exist.
    function getSortitionPoolWeight(address _application)
        public
        view
        returns (uint256)
    {
        return
            BondedSortitionPool(getSortitionPool(_application)).totalWeight();
    }

    /// @notice Calculates bond requirement per member performing the necessary
    /// rounding.
    /// @param _keepBond The bond required from a keep.
    /// @param _groupSize Number of signers in the keep.
    /// @return Bond value required from each keep member.
    function bondPerMember(uint256 _keepBond, uint256 _groupSize)
        internal
        pure
        returns (uint256)
    {
        // In Solidity, division rounds towards zero (down) and dividing
        // '_bond' by '_groupSize' can leave a remainder. Even though, a remainder
        // is very small, we want to avoid this from happening and memberBond is
        // rounded up by: `(bond + groupSize - 1 ) / groupSize`
        // Ex. (100 + 3 - 1) / 3 = 34
        return (_keepBond.add(_groupSize).sub(1)).div(_groupSize);
    }

    /// @notice Gets bonded sortition pool of specific application for the
    /// operator.
    /// @dev Reverts if the operator is not registered for the application.
    /// @param _operator Operator's address.
    /// @param _application Customer application address.
    /// @return Bonded sortition pool.
    function getSortitionPoolForOperator(
        address _operator,
        address _application
    ) internal view returns (BondedSortitionPool) {
        require(
            isOperatorRegistered(_operator, _application),
            "Operator not registered for the application"
        );

        return BondedSortitionPool(candidatesPools[_application]);
    }
}
