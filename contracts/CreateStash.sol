pragma solidity ^0.4.15;

import "./lib/Ownable.sol";
import "./lib/ERC20.sol";

import "./stash/MultiSigWalletFactory.sol";
import "./stash/MultiSigWallet.sol";

import "./tokenPoll/TokenPollFactory.sol";
import "./tokenPoll/TokenPoll.sol";

// Voting is quadratic
contract CreateStash is Ownable {

  // State
  uint tokenPollFee;
  ERC20 feeToken;
  TokenPollFactory tpFact;
  MultiSigWalletFactory walletFact; 

  // Setters
  function setTokenPollFee(uint fee) public onlyOwner { tokenPollFee = fee; }
  function setFeeToken(address t) public onlyOwner { feeToken = ERC20(t); }

  // Constructor
  function CreateStash (address _tpFact, address _walletFact, address _feeToken, uint _fee) {
    setFeeToken(_feeToken);
    setTokenPollFee(_fee);
    tpFact = TokenPollFactory(tpFact);
    walletFact = MultiSigWalletFactory(_walletFact);
  }

  // Functions
  function createStash() returns (address) {
    require(feeToken.transferFrom(msg.sender, this, tokenPollFee));

    address[] memory walletOwners = new address[](1);
    walletOwners[0] = this;

    // Create stash/tokenpoll
    MultiSigWallet w = MultiSigWallet(walletFact.create(walletOwners, 1));
    TokenPoll tp = TokenPoll(tpFact.createTokenPoll(w));

    // Transfer owner
    w.addOwner(tp);
    w.removeOwner(this);    
    tp.transferOwnership(msg.sender);

    return tp;
  }

  function withdraw(address token, address to, uint amount) public onlyOwner { require(ERC20(token).transfer(to, amount)); }
}
