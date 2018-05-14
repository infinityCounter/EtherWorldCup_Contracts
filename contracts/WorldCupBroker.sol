pragma solidity ^0.4.4;

import "./Ownable.sol";
import "./usingOraclize.sol";
import "./strings.sol";

contract WorldCupBroker is Ownable, usingOraclize {

    using strings for *;

    struct Bet {
        bool    cancelled;
        uint    amount;
        uint8   option; // 1 - teamA, 2 - teamB, 3 - Draw
        address better;
    }
    
    struct Match {
        bool   locked; // match will be locked after payout or all bets returned
        bool   cancelled;
        uint8  teamA;
        uint8  teamB;
        uint8  winner; // 0 - not set, 1 - teamA, 2 - teamB, 3- Draw, 4 - no winner
        uint   start;
        uint   closeBettingTime; // since this the close delay is constant 
        // this will always be the same, save gas for betters and just set the close time once
        uint   totalTeamABets;
        uint   totalTeamBBets;
        uint   totalDrawBets;
        uint   numBets;
        string fixtureId;
        string name;
        mapping(uint => Bet) bets;
    }

    event MatchCreated(
        uint8 matchId
    );

    event MatchCancelled(
        uint8 matchId
    );

    event MatchOver(
        uint8 matchId, 
        uint8 result
    );

    event MatchFailedAttemptedPayoutRelease(
        uint8 matchId,
        uint8 numAttempts
    );

    event MatchFailedPayoutRelease(
        uint8 matchId
    );

    event BetPlaced(
        uint8   matchId,
        uint8   outcome,
        uint    betId,
        uint    amount,
        address better
    );

    event BetCancelled(
        uint8   matchId,
        uint    betId
    );
    
    uint8 public constant NUM_TEAMS = 32;

    string[NUM_TEAMS] public TEAMS = [
        "Russia", 
        "Saudi Arabia", 
        "Egypt", 
        "Uruguay", 
        "Morocco", 
        "Iran", 
        "Portugal", 
        "Spain", 
        "France", 
        "Australia", 
        "Argentina", 
        "Iceland", 
        "Peru", 
        "Denmark", 
        "Croatia", 
        "Nigeria", 
        "Costa Rica", 
        "Serbia", 
        "Germany", 
        "Mexico", 
        "Brazil", 
        "Switzerland", 
        "Sweden", 
        "South Korea", 
        "Belgium", 
        "Panama", 
        "Tunisia", 
        "England", 
        "Poland", 
        "Senegal", 
        "Colombia", 
        "Japan"
    ];
    uint public constant COMMISSION_RATE = 7;
    // need to address if this could be used to drain contract of eth
    // by cancelling bets and it costs more to return the money than the amount of money
    uint public CANCEL_FEE = 10;
    uint public MINIMUM_BET = 0.01 ether;
    uint public MAX_NUM_PAYOUT_ATTEMPTS = 4; // after 4 attemps a refund will be given
    //*
    uint public constant WITHDRAW_BALANCE_TIMESTAMP = 1531742400;
    uint public constant PAYOUT_ATTEMPT_INTERVAL = 30 minutes; // try every 15 minutes to release payout
    uint public constant BETTING_CLOSE_DELAY = 3 minutes;
    uint public constant MATCH_ENDING_QUERY_DELAY = 3 hours;
    uint public constant MATCH_ADD_TIME_REQUIREMENT = 15 minutes;
    /*/
    uint public constant WITHDRAW_BALANCE_TIMESTAMP = 1526083200;
    uint public constant PAYOUT_ATTEMPT_INTERVAL = 2 minutes; // try every 2 minutes to release payout
    uint public constant BETTING_CLOSE_DELAY = 3 minutes;
    uint public constant MATCH_ENDING_QUERY_DELAY = 5 minutes;
    uint public constant MATCH_ADD_TIME_REQUIREMENT = 1 minutes;
    //*/
    uint private commissions = 0;

    Match[] matches;
    mapping(bytes32 => uint8) oraclizeIds;
    mapping(uint8 => uint8) payoutAttempts;

    modifier validMatch(uint8 _matchId) {
        require(_matchId < uint8(matches.length), "Invalid Match");
        _;
    }

    modifier validBet(uint8 _matchId, uint _betId) {
        // short circuit to save gas
        require(_matchId < uint8(matches.length), "Invalid Match");
        require(_betId < matches[_matchId].numBets, "Invalid Bet");
        _;
    }   

    function addMatch(string _name, uint _fixtureId, uint8 _teamA, uint8 _teamB, uint _start) public onlyOwner returns (uint8) {
        // Check that there's at least 15 minutes until the match starts
        require(_teamA < NUM_TEAMS && _teamB < NUM_TEAMS && _teamA != _teamB, "Team A and B Id must be less than 32 and greater than 0, and cannot be the same");
        require((_start - MATCH_ADD_TIME_REQUIREMENT) >= now, "Game cannot be added with less than 15 minutes left to start time");
        Match memory newMatch = Match({
            locked: false, 
            cancelled: false, 
            teamA: _teamA,
            teamB: _teamB, 
            fixtureId: uint2str(_fixtureId),
            winner: 0, 
            start: _start, 
            closeBettingTime: _start - BETTING_CLOSE_DELAY, 
            totalTeamABets: 0, 
            totalTeamBBets: 0, 
            totalDrawBets: 0, 
            numBets: 0,
            name: _name
        });
        // only ower can call this addMatch method so uint8 is fine
        uint8 matchId = uint8(matches.push(newMatch)) - 1;
        // This query should return false if the match isn't finished yet, otherwise 
        // there should be goal values set for both teams
        string memory url = strConcat(
            "json(https://api.football-data.org/v1/fixtures/", 
            newMatch.fixtureId,
            ").fixture.result.[goalsHomeTeam,goalsAwayTeam]");
        bytes32 oraclizeId = oraclize_query(_start + MATCH_ENDING_QUERY_DELAY, "URL", url);
        oraclizeIds[oraclizeId] = matchId;
        emit MatchCreated(matchId);
        return matchId;
    }

    function getNumMatches() public view returns (uint8) {
        return uint8(matches.length);
    }

    function getMatch(uint8 _matchId) public view validMatch(_matchId) returns (string, string, uint8, uint8, uint8, uint, bool, bool) {
        Match memory mtch = matches[_matchId];
        return (
            mtch.name,
            mtch.fixtureId, 
            mtch.teamA, 
            mtch.teamB,
            mtch.winner, 
            mtch.start,
            mtch.cancelled,
            mtch.locked
        );
    }

    function getMatchBettingDetails(uint8 _matchId) public view validMatch(_matchId) returns (uint, uint, uint, uint, uint, uint8) {
        Match memory mtch = matches[_matchId];
        return (
            mtch.closeBettingTime,
            mtch.totalTeamABets, 
            mtch.totalTeamBBets, 
            mtch.totalDrawBets,
            mtch.numBets,
            payoutAttempts[_matchId]
        );
    }

    function cancelMatch(uint8 _matchId) public onlyOwner validMatch(_matchId) returns (bool) {
        Match storage mtch = matches[_matchId];
        require(!mtch.cancelled, "Match is already cancelled");
        require(now < mtch.closeBettingTime, "Cannot cancel match after betting has been closed");
        _returnAllBets(mtch);
        mtch.cancelled = true;
        emit MatchCancelled(_matchId);
        return true;
    }

    function getBet(uint8 _matchId, uint _betId) public view validBet(_matchId, _betId) returns (address, uint, uint, bool) {
        Bet memory bet = matches[_matchId].bets[_betId];
        // Don't return matchId and betId since you had to know them in the first place
        return (bet.better, bet.amount, bet.option, bet.cancelled);
    } 

    function placeBet(uint8 _matchId, uint8 _outcome) public payable validMatch(_matchId) returns (uint) {
        Match storage mtch = matches[_matchId];
        require(
            now < mtch.closeBettingTime &&
            !mtch.locked &&
            !mtch.cancelled &&
            _outcome > 0 && 
            _outcome < 4 && 
            msg.value >= MINIMUM_BET,
            "Attempt to place invalid bet. Either invalid outcome or value of bet too small, or betting is already closed."
        );
        Bet memory bet = Bet(false, msg.value, _outcome, msg.sender);
        uint betId = mtch.numBets;
        mtch.bets[betId] = bet;
        mtch.numBets++;
        if (_outcome == 1) {
            mtch.totalTeamABets += msg.value;
        } else if (_outcome == 2) {
            mtch.totalTeamBBets += msg.value;
        } else {
            mtch.totalDrawBets += msg.value;
        }
        emit BetPlaced(_matchId, _outcome, betId, msg.value, msg.sender);
        return (betId);
    }

    function cancelBet(uint8 _matchId, uint _betId) public validBet(_matchId, _betId) {
        Match memory mtch = matches[_matchId];
        require(!mtch.locked, "Match has already been payed out, cannot cancel bet");
        require(now < mtch.closeBettingTime, "Betting for match is closed, cannot cancel bet");
        Bet storage bet = matches[_matchId].bets[_betId];
        // only the person who made this bet can cancel it
        require(!bet.cancelled && bet.better == msg.sender, "Only the address that placed a bet may cancel it");
        uint commission = bet.amount / 100 * CANCEL_FEE;
        // stop re-entry just in case of malicious attack to withdraw all contract eth
        bet.cancelled = true;
        commissions += commission;
        if (bet.option == 1) {
            matches[_matchId].totalTeamABets -= bet.amount;
        } else if (bet.option == 2) {
            matches[_matchId].totalTeamBBets -= bet.amount;
        } else if (bet.option == 3) {
            matches[_matchId].totalDrawBets -= bet.amount;
        }
        bet.better.transfer(bet.amount - commission);
        emit BetCancelled(_matchId, _betId);
    }

    function _returnAllBets(Match storage _mtch) internal {
        require(!_mtch.locked, "Match already payed out, cannot return bets");
        _mtch.locked = true;
        for(uint count = 0; count < _mtch.numBets; count++) {
            Bet memory bet = _mtch.bets[count];
            if (!bet.cancelled) {
                bet.better.transfer(bet.amount);
            }    
        }
    }

    function _returnAllBets(uint8 _matchId) internal {
        Match storage mtch = matches[_matchId];
        require(!mtch.locked, "Match already payed out, cannot return bets");
        mtch.locked = true;
        for(uint count = 0; count < mtch.numBets; count++) {
            Bet memory bet = mtch.bets[count];
            if (!bet.cancelled) {
                bet.better.transfer(bet.amount);
            }    
        }
    }

    function _payoutWinners(uint8 _matchId, uint8 _outcome) internal validMatch(_matchId) {
        Match storage mtch = matches[_matchId];
        require(!mtch.locked && _outcome > 0 && _outcome < 4);
        mtch.locked = true;
        mtch.winner = _outcome;
        uint totalPool;
        uint winPool;
        if (_outcome == 1) {
            totalPool = mtch.totalTeamBBets + mtch.totalDrawBets;
            winPool = mtch.totalTeamABets;
        } else if (_outcome == 2) {
            totalPool = mtch.totalTeamABets + mtch.totalDrawBets;
            winPool = mtch.totalTeamBBets;
        } else {
            totalPool = mtch.totalTeamABets + mtch.totalTeamBBets;
            winPool = mtch.totalDrawBets;
        }
        for (uint count = 0; count < mtch.numBets; count++) {
            Bet memory bet = mtch.bets[count];
            if (bet.option != _outcome) {
                continue;
            }
            // check this logic that it isn't truncating numbers
            uint winnings = totalPool * bet.amount / winPool;
            uint commission = winnings / 100 * COMMISSION_RATE;
            commissions += commission;
            winnings -= commission;
            // return original bet amount + (winnings - % commission)
            bet.better.transfer(winnings + bet.amount);
        }
    }

    function getCommissions() public view onlyOwner returns (uint) {
        return commissions;
    }

    function withdrawCommissions(uint _amount) public onlyOwner {
        require(_amount < commissions);
        commissions -= _amount;
        owner.transfer(_amount);
    }

    function withdrawCommissions() public onlyOwner {
        uint amount = commissions;
        commissions = 0;
        owner.transfer(amount);
    }

    function getBalance() public view returns (uint) {
        return address(this).balance;
    }

    function withdrawBalance() public onlyOwner {
        // World cup is over for a full day now so check if there are any matches that have yet to be
        // payed out for (should never happen)
        // return those bets
        require(now >= WITHDRAW_BALANCE_TIMESTAMP);
        for (uint8 count = 0; count < matches.length; count++) {
            if (!matches[count].locked) {
                _returnAllBets(count);
            }
        }
        // World cup should be over so withdraw the balance of the smart contract
        address cntr = address(this);
        owner.transfer(cntr.balance);
        commissions = 0;
    }

    function getMinimumBet() public view returns (uint) {
        return MINIMUM_BET;
    }

    function changeMiniumBet(uint newMin) public onlyOwner {
        MINIMUM_BET = newMin;
    }

    function __callback(bytes32 myid, string result) public {
        if (msg.sender != oraclize_cbAddress()) revert();
        uint8 matchId = oraclizeIds[myid];
        // The sha3 hash of false, as in failed to get the finished match
        if (bytes(result).length == 0 || (keccak256(result) == keccak256("[null, null]"))) {
            uint8 attempts = ++payoutAttempts[matchId];
            // If max number of attempts has been reached then return all bets
            if (attempts >= MAX_NUM_PAYOUT_ATTEMPTS) {
                _returnAllBets(matchId);
                emit MatchFailedPayoutRelease(matchId);
            } else {
                string memory url = strConcat(
                    "json(https://api.football-data.org/v1/fixtures/", 
                    matches[matchId].fixtureId,
                    ").fixture.result.[goalsHomeTeam,goalsAwayTeam]");
                bytes32 oraclizeId = oraclize_query(PAYOUT_ATTEMPT_INTERVAL, "URL", url);
                oraclizeIds[oraclizeId] = matchId;
                emit MatchFailedAttemptedPayoutRelease(matchId, attempts);
            }
        } else {
            // eg. result = [2, 4]
            strings.slice memory s = result.toSlice();
            s = s.beyond("[".toSlice());
            s = s.until("]".toSlice());
            strings.slice memory x = s.split(", ".toSlice());
            uint homeScore = parseInt(x.toString());
            uint awayScore = parseInt(s.toString());
            uint8 matchResult;
            if (homeScore > awayScore) {
                matchResult = 1;
            } else if (homeScore < awayScore) {
                matchResult = 2;
            } else {
                matchResult = 3;
            }
            _payoutWinners(matchId, matchResult);
            emit MatchOver(matchId, matchResult);
        }
    }
    
    function() public payable {}
}