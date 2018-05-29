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
        string secondaryFixtureId;
        bool   inverted;
        string name;
        mapping(uint => Bet) bets;
    }

    event MatchCreated(uint8);

    event MatchUpdated(uint8);

    event MatchFailedAttemptedPayoutRelease(uint8);

    event MatchFailedPayoutRelease(uint8);

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
    
    string[32] public TEAMS = [
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
    uint public constant MAX_NUM_PAYOUT_ATTEMPTS = 4; // after 4 attemps a refund will be given
    /*
    uint public constant PAYOUT_ATTEMPT_INTERVAL = 10 minutes; // try every 15 minutes to release payout
    /*/
    uint public constant PAYOUT_ATTEMPT_INTERVAL = 2 minutes; // try every 2 minutes to release payout
    //*/
    uint public  commission_rate = 7;
    uint public  minimum_bet = 0.01 ether;
    uint private commissions = 0;
    

    Match[] matches;
    mapping(bytes32 => uint8) oraclizeIds;
    mapping(uint8 => uint8) payoutAttempts;
    mapping(uint8 => bool) firstStepVerified;
    mapping(uint8 => uint8) pendingWinner;

    modifier validMatch(uint8 _matchId) {
        require(_matchId < uint8(matches.length));
        _;
    }

    modifier validBet(uint8 _matchId, uint _betId) {
        // short circuit to save gas
        require(_matchId < uint8(matches.length) && _betId < matches[_matchId].numBets);
        _;
    }   

    function addMatch(string _name, string _fixture, string _secondary, bool _invert, uint8 _teamA, uint8 _teamB, uint _start) public onlyOwner returns (uint8) {
        // Check that there's at least 15 minutes until the match starts
        require(_teamA < 32 && _teamB < 32 && _teamA != _teamB && (_start - 15 minutes) >= now);
        Match memory newMatch = Match({
            locked: false, 
            cancelled: false, 
            teamA: _teamA,
            teamB: _teamB, 
            winner: 0,
            fixtureId: _fixture,
            secondaryFixtureId: _secondary,
            inverted: _invert,
            start: _start, 
            closeBettingTime: _start - 3 minutes, 
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
        bytes32 oraclizeId = oraclize_query((_start + 3 hours), "URL", url);
        oraclizeIds[oraclizeId] = matchId;
        emit MatchCreated(matchId);
        return matchId;
    }

    function getMatch(uint8 _matchId) public view validMatch(_matchId) returns (string, string, string, uint8, uint8, uint8, uint, bool, bool) {
        Match memory mtch = matches[_matchId];
        return (
            mtch.name,
            mtch.fixtureId, 
            mtch.secondaryFixtureId,
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
        require(!mtch.cancelled && now < mtch.closeBettingTime);
        mtch.cancelled = true;
        _returnAllBets(_matchId);
        emit MatchUpdated(_matchId);
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
            _outcome > 0 && 
            _outcome < 4 && 
            msg.value >= minimum_bet,
            "Attempt to place invalid bet. Either invalid outcome or value of bet too small, or betting is already closed."
        );
        Bet memory bet = Bet(false, msg.value, _outcome, msg.sender);
        uint betId = mtch.numBets;
        mtch.bets[betId] = bet;
        mtch.numBets++;
        if (_outcome == 1) {
            mtch.totalTeamABets += msg.value;
            assert(mtch.totalTeamABets >= msg.value);
        } else if (_outcome == 2) {
            mtch.totalTeamBBets += msg.value;
            assert(mtch.totalTeamBBets >= msg.value);
        } else {
            mtch.totalDrawBets += msg.value;
            assert(mtch.totalDrawBets >= msg.value);
        }
        emit BetPlaced(_matchId, _outcome, betId, msg.value, msg.sender);
        return (betId);
    }

    function cancelBet(uint8 _matchId, uint _betId) public validBet(_matchId, _betId) {
        Match memory mtch = matches[_matchId];
        require(!mtch.locked && now < mtch.closeBettingTime);
        Bet storage bet = matches[_matchId].bets[_betId];
        // only the person who made this bet can cancel it
        require(!bet.cancelled && bet.better == msg.sender);
        uint commission = bet.amount / 100 * commission_rate;
        // stop re-entry just in case of malicious attack to withdraw all contract eth
        bet.cancelled = true;
        commissions += commission;
        assert(commissions >= commission);
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

    function _returnAllBets(uint8 _matchId) internal {
        Match storage mtch = matches[_matchId];
        require(!mtch.locked);
        mtch.locked = true;
        for(uint count = 0; count < mtch.numBets; count++) {
            Bet memory bet = mtch.bets[count];
            if (!bet.cancelled) {
                if (bet.option == 1) {
                    mtch.totalTeamABets -= bet.amount;
                } else if (bet.option == 2) {
                    mtch.totalTeamBBets -= bet.amount;
                } else {
                    mtch.totalDrawBets -= bet.amount;
                }
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
            assert(totalPool >= mtch.totalTeamBBets);
            winPool = mtch.totalTeamABets;
        } else if (_outcome == 2) {
            totalPool = mtch.totalTeamABets + mtch.totalDrawBets;
            assert(totalPool >= mtch.totalTeamABets);
            winPool = mtch.totalTeamBBets;
        } else {
            totalPool = mtch.totalTeamABets + mtch.totalTeamBBets;
            assert(totalPool >= mtch.totalTeamABets);
            winPool = mtch.totalDrawBets;
        }
        for (uint count = 0; count < mtch.numBets; count++) {
            Bet memory bet = mtch.bets[count];
            if (bet.option != _outcome || bet.cancelled) {
                continue;
            }
            uint winnings = totalPool * bet.amount / winPool;
            uint commission = winnings / 100 * commission_rate;
            commissions += commission;
            assert(commissions >= commission);
            winnings -= commission;
            // return original bet amount + (winnings - % commission)
            bet.better.transfer(winnings + bet.amount);
        }
    }

    function changeFees(uint8 _newCommission) public onlyOwner {
        // Max commission is 7%, but it can be FREE!!
        require(_newCommission <= 7);
        commission_rate = _newCommission;
    }

    function withdrawCommissions(uint _amount) public onlyOwner {
        require(_amount <= commissions);
        commissions -= _amount;
        owner.transfer(_amount);
    }

    function withdrawBalance() public onlyOwner {
        // World cup is over for a full day now so check if there are any matches that have yet to be
        // payed out for (should never happen)
        // return those bets
        require(now >= 1527617726);
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

    function changeMiniumBet(uint newMin) public onlyOwner {
        minimum_bet = newMin;
    }

    function __callback(bytes32 myid, string result) public {
        if (msg.sender != oraclize_cbAddress()) revert();
        uint8 matchId = oraclizeIds[myid];
        bool firstVerification = firstStepVerified[matchId];
        // The sha3 hash of false, as in failed to get the finished match
        if (bytes(result).length == 0 || (keccak256(result) == keccak256("[null, null]"))) {
            // If max number of attempts has been reached then return all bets
            if (++payoutAttempts[matchId] >= MAX_NUM_PAYOUT_ATTEMPTS) {
                _returnAllBets(matchId);
                emit MatchFailedPayoutRelease(matchId);
            } else {
                string memory url;
                string memory querytype;
                if (!firstVerification) {
                    url = strConcat(
                        "json(https://api.football-data.org/v1/fixtures/", 
                        matches[matchId].fixtureId,
                        ").fixture.result.[goalsHomeTeam,goalsAwayTeam]");
                    querytype = "URL";
                } else {                
                    url = strConcat(
                        "[URL] json(https://soccer.sportmonks.com/api/v2.0/fixtures/",
                        matches[matchId].secondaryFixtureId,
                        "?api_token=${[decrypt] BNbN1dspbpPJ1GdXsbe2jjeBTJ3G0hDaRLG0cXkYnusCTckisOiojns4pqC7zy0Se/bBHe/DlJ9mLXFXacFuhnSSC5jroMm3uyUBOjr4qb33tnBYZ41YnrlWf9Kj3GjbozewJ3IhwmplO6P8sXdWFprhtWhNVUsZD8GiNMLNHnqMXCK//SiQZAR3SthJ}).data.scores[localteam_score,visitorteam_score]");
                    querytype = "nested";
                }
                bytes32 oraclizeId = oraclize_query(PAYOUT_ATTEMPT_INTERVAL, querytype, url);
                oraclizeIds[oraclizeId] = matchId;
                emit MatchFailedAttemptedPayoutRelease(matchId);
            }
        } else {
            payoutAttempts[matchId] = 0;
            // eg. result = [2, 4]
            strings.slice memory s = result.toSlice();
            s = s.beyond("[".toSlice());
            s = s.until("]".toSlice());
            strings.slice memory x = s.split(", ".toSlice());
            uint homeScore = parseInt(s.toString()); 
            uint awayScore = parseInt(x.toString());
            uint8 matchResult;
            if (homeScore > awayScore) {
                matchResult = 1;
            } else if (homeScore < awayScore) {
                matchResult = 2;
            } else {
                matchResult = 3;
            }
            if (!firstVerification) {
                url = strConcat(
                    "[URL] json(https://soccer.sportmonks.com/api/v2.0/fixtures/",
                    matches[matchId].secondaryFixtureId,
                    "?api_token=${[decrypt] BNbN1dspbpPJ1GdXsbe2jjeBTJ3G0hDaRLG0cXkYnusCTckisOiojns4pqC7zy0Se/bBHe/DlJ9mLXFXacFuhnSSC5jroMm3uyUBOjr4qb33tnBYZ41YnrlWf9Kj3GjbozewJ3IhwmplO6P8sXdWFprhtWhNVUsZD8GiNMLNHnqMXCK//SiQZAR3SthJ}).data.scores[localteam_score,visitorteam_score]");
                oraclizeId = oraclize_query("nested", url);
                oraclizeIds[oraclizeId] = matchId;
                pendingWinner[matchId] = matchResult;
                firstStepVerified[matchId] = true;
            } else {
                if (matches[matchId].inverted) {
                    if (matchResult == 1) {
                        matchResult = 2;
                    } else if (matchResult == 2) {
                        matchResult = 1;
                    }
                }
                if (pendingWinner[matchId] == matchResult) {
                    _payoutWinners(matchId, matchResult);
                    emit MatchUpdated(matchId);
                } else {
                    _returnAllBets(matchId);
                    emit MatchFailedPayoutRelease(matchId);
                }
            }
        }
    }
    
    function() public payable {}
}