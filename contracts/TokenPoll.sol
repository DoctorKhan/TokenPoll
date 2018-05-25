pragma solidity ^0.4.15;

import "./Ownable.sol";
import "./ERC20.sol";


contract Escrow {
  function submitTransaction(address destination, uint value, bytes data) public returns (uint transactionId);
  address public erc20;
}

// https://www.stellar.org/developers/guides/issuing-assets.html
// https://www.stellar.org/blog/tokens-on-stellar/

// todo change initalizier to owner
// todo safe math

// Voting is quadratic
contract TokenPoll is Ownable {

  enum State { Uninitialized      // Waits token poll is parameterized
             , Initialized        // Waits until vote allocation. Can't have InRound/Voting before votes are allocated
             , VoteAllocation     // Token balances should be frozen and users allocate votes during this period.

             , InRound            // Voting period. Follows VoteAllocation & NextRoundApproved
             , PostRoundDecision
             , NextRoundApproved

             // End states
             , Refund            // Users can withdraw remaining balance
             , Finished          // End of polls

             , UnknownState
             }

  event Vote(address indexed voter, bool vote);

  // =====
  // State
  // =====  

  // Round variables
  bool refundFlag;                   // keep track of state
  bool nextRoundApprovedFlag;        // "
  bool initializedFlag;              // if contract is initialized with parameters
  uint public currentRound;
  uint public allocStartTime;        // Start/end of voting allocation
  uint public allocEndTime;          // "

  // Fund variables
  ERC20 public stableCoin;           // Location of funds
  address public escrow;             // Initiate escrow to send funds to ICO wallet
  uint public totalRefund;           // Total size of refund

  // Voting variables
  ERC20 public icoCoin;              // Voting power is based on token ownership count
  mapping (address => uint) public userTokenBalance; // user -> token balance
  uint public userCount;             // Used for keeping track of quorum
  uint public totalTokenCount;       // Count of all tokens registered for vote
  uint public totalVotePower;        // Total voting power of users
  mapping (address => mapping (uint => bool)) public voteChoice;
  uint public yesVotes;
  uint public noVotes;
  int public quadraticYesVotes;
  int public quadraticNoVotes;

  // =========
  // Blah
  // =========

  function getVoteChoice(address user, uint _roundNum) view returns (bool) { return voteChoice[user][_roundNum]; }

  function getHasVoted(address user, uint _roundNum) view returns (bool) { return voteChoice[user][_roundNum] != 0; }

  modifier validVoter() {
    require(userTokenBalance[msg.sender] != 0);
    _;
  }

  // ======================
  // Constructor & fallback
  // ======================

  constructor() public Ownable() {}

  function () public { require(false); return; }

  // =============
  // ICO Functions
  // =============

  // This is used b/c order of creating contracts:
  //    1 tokenPollAddr = TokenPoll() 
  //    2 escrowAddr    = Escrow(tokenPollAddr)
  //    3                 TokenPoll.initialize(escrowAddress)
  function initialize(address _icoToken, address _stableCoin, address _escrow, uint _allocStartTime, uint _allocEndTime, uint _dailyLimit) public inState(State.Uninitialized) onlyOwner {
    require(_allocStartTime > now);

    initializedFlag = true;
    icoCoin = ERC20(_icoToken);
    stableCoin = ERC20(_stableCoin);
    allocStartTime = _allocStartTime;
    allocEndTime = _allocEndTime;
    escrow = _escrow;
    escrowChangeDailyLimit(_dailyLimit);
  }

  // ===============
  // Voter Functions
  // ===============

  // Users
  function allocVotes() public inState(State.VoteAllocation){
    require(userTokenBalance[msg.sender] == 0);  // user has not allocated before

    uint userTokens = icoCoin.balanceOf(msg.sender);

    // State changes
    userTokenBalance[msg.sender] = userTokens;
    totalVotePower  += getUserVotePower(msg.sender);
    totalTokenCount += userTokens;
    userCount       += 1;
  }

  // todo fix this fn
  // Return (start time, end time) of this or upcoming round
  function getThisOrUpcomingRoundStartEnd () returns (uint, uint) {
    return (0,3);
  }

  function clearVoteTransition () private { nextRoundApprovedFlag = false; }
  function setVoteTransition () private { nextRoundApprovedFlag = true; }
  
  // todo, make sure it is impossible to postpone a next round indefinetly
  // todo vote window, vote params (qorem),
  function castVote(bool vote) public inState(State.InRound) validVoter() {
    require(!getHasVoted[msg.sender][currentRound]);

    voteChoice[msg.sender][currentRound] = vote;

    if (vote) {
      yesVotes += 1;
      quadraticYesVotes += getUserVotePower(msg.sender);
    }
    else {
      noVotes += 1;
      quadraticNoVotes += getUserVotePower(msg.sender);
    }

    Vote(msg.sender, vote);
  }

  /*  
      function allocVotes() public inState(State.VoteAllocation)
      function castVote(bool vote) public 
      function userRefund() public inState(State.Refund) 
      function startRefund() public inState(State.VoteFailed) 
  */

  function trasitionFromState_NextRoundApproved () public inState(State.NextRoundApproved) {
    uint (start, end) = getThisOrUpcomingRoundStartEnd();
    require(start < now < end);
    clearVoteTransition();
  }

  // todo - at what point can they start withdrawing?
  // todo - keep or add wallet?
  function transitionFromState_PostRoundDecision () public inState(State.PostRoundDecision) {
    bool notEnoughVotes = quadraticYesVotes < quadraticNoVotes;

    if (notEnoughVotes) {
      address erc20 = address(Escrow(escrow).erc20);
      totalRefund = ERC20(erc20).balanceOf(escrow);
      escrowChangeDailyLimit(totalRefund);
      escrowTransferTokens(address(this), totalRefund);
      refundFlag = true;
    }
    else {
      setVoteTransition();
      currentRound = 1 + currentRound;
      quadraticYesVotes = 0;
      quadraticNoVotes = 0;
      noVotes = 0;
      yesVotes = 0;
    }
  }

  function userRefund() public inState(State.Refund) {
    address user = msg.sender;
    uint userTokenCount = userTokenBalance[user];

    // Get tokens then clear. Reentrant safe
    require(userTokenCount != 0);
    userTokenBalance[user] = 0;

    // refund
    uint refundSize = totalRefund * userTokenCount / totalTokenCount;
    ERC20(address(Escrow(escrow).erc20)).transfer(user, refundSize); // todo is there a better way
  }

  // Call through escrow -- "erc20.transfer(to, amount)"
  function escrowChangeDailyLimit(uint newLimit) private {
    bytes memory data = new bytes(4 + 32);
    uint i = 0;
    for (; i < 4; i++)  data[i] = bytes4(0xcea08621)[i];
    for (; i < 36; i++) data[i] = bytes32(newLimit)[i];

    // change daily limit
    Escrow(escrow).submitTransaction(escrow, 0, data);    
  }

// todo must check if transaction failed or not
  // Call through escrow -- "erc20.transfer(to, amount)"
  function escrowTransferTokens(address _to, uint _amount) private {
    bytes memory data = new bytes(4 + 20 + 32);
    uint i = 0;
    for (; i < 4; i++)  data[i] = bytes4(0x06b091f9)[i];
    for (; i < 24; i++) data[i] = bytes20(_to)[i];
    for (; i < 56; i++) data[i] = bytes32(_amount)[i];

    // change daily limit
    Escrow(escrow).submitTransaction(escrow, 0, data);    
  }

  // =======
  // Getters
  // =======

  function getState() public view returns (State) {
    if (!initializedFlag)      return State.Uninitialized;
    if (now < allocStartTime)  return State.Initialized;

    if (allocStartTime < now 
        && now < allocEndTime) return State.VoteAllocation;

    if (refundFlag)            return State.Refund;
    if (now > allocEndTime)    return State.InRound
    if (nextRoundApprovedFlag) return State.PostRoundDecision;

    if ()                      return NextRoundApproved;

    if (endOfRounds)           return State.Finished;

    else State.UnknownState;
  }

  function getUserVotePower(address user) public view returns (uint) {
    return sqrt(userTokenBalance[user]);
  }

  // y = floor(sqrt(x))
  function sqrt(uint x) public pure returns (uint) {
    uint z = (x + 1) / 2;
    uint y = x;
    
    while (z < y) {
      y = z;
      z = (x / z + z) / 2;
    }
    
    return y;
  }
  
  // ================
  // Modifiers
  // ================

  // modifier onlyOwner() ...

  modifier inState(State s) {
    require(getState() == s);
    _;
  }

  modifier fromAddress(address _escrow) {
    require(escrow == _escrow);
    _;
  }

}
