/*
 * @title String & slice utility library for Solidity contracts.
 * @author Daniel Bennett <dbennett18@protonmail.com>
 *
 * @dev This is a solitidy contract that facilitates betting for the 2018
        world cup. The contract on does not act as a counter party 
        to any bets placed and thus users bet on a decision pool for a match
        (win, lose, draw), and based on the results of users will be credited winnings
        proportional to their contributions to the winning pool.
    */


pragma solidity ^0.4.4;

import "./Ownable.sol";
import "./usingOraclize.sol";
import "./strings.sol";

contract WorldCupBroker is Ownable, usingOraclize {

    using strings for *;

    struct Bet {
        bool    cancelled;
        bool    claimed;
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
        bool   inverted; // inverted if the secondary api has the home team and away teams inverted
        string name;
        mapping(uint => Bet) bets;
    }

    event MatchCreated(uint8);

    event MatchUpdated(uint8);

    event MatchFailedPayoutRelease(uint8);

    event BetPlaced(
        uint8   matchId,
        uint8   outcome,
        uint    betId,
        uint    amount,
        address better
    );

    event BetClaimed(
        uint8   matchId,
        uint    betId
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
    uint public constant MAX_NUM_PAYOUT_ATTEMPTS = 3; // after 3 consecutive failed payout attempts, lock the match
    uint public constant PAYOUT_ATTEMPT_INTERVAL = 10 minutes; // try every 10 minutes to release payout
    uint public  commission_rate = 7;
    uint public  minimum_bet = 0.01 ether;
    uint private commissions = 0;
    uint public  primaryGasLimit = 225000;
    uint public  secondaryGasLimit = 250000;
    

    Match[] matches;
    mapping(bytes32 => uint8) oraclizeIds;
    mapping(uint8 => uint8) payoutAttempts;
    mapping(uint8 => bool) firstStepVerified;
    mapping(uint8 => uint8) pendingWinner;

     /*
     * @dev Ensures a matchId points to a legitimate match
     * @param _matchId the uint to check if it points to a valid match.
     */
    modifier validMatch(uint8 _matchId) {
        require(_matchId < uint8(matches.length));
        _;
    }

    /*
     * @dev the validBet modifier does as it's name implies and ensures that a bet
     * is valid before proceeding with any methods called on the contract
     * that would require access to such a bet
     * @param _matchId the uint to check if it points to a valid match.
     * @param _betId the uint to check if it points to a valid bet for a match.
     */
    modifier validBet(uint8 _matchId, uint _betId) {
        // short circuit to save gas
        require(_matchId < uint8(matches.length) && _betId < matches[_matchId].numBets);
        _;
    }

    /*
     * @dev Adds a new match to the smart contract and schedules an oraclize query call
     *      to determine the winner of a match within 3 hours. Additionally emits an event
     *      signifying a match was created.
     * @param _name      the unique identifier of the match, should be of format Stage:Team A vs Team B
     * @param _fixture   the fixtureId for the football-data.org endpoint
     * @param _secondary the fixtureId for the sportsmonk.com endpoint
     * @param _inverted  should be set to true if the teams are inverted on either of the API 
     *                   that is if the hometeam and localteam are swapped
     * @param _teamA     index of the homeTeam from the TEAMS array
     * @param _teamB     index of the awayTeam from the TEAMS array
     * @param _start     the unix timestamp for when the match is scheduled to begin
     * @return `uint`     the Id of the match in the matches array
     */ 
    function addMatch(string _name, string _fixture, string _secondary, bool _invert, uint8 _teamA, uint8 _teamB, uint _start) public onlyOwner returns (uint8) {
        // Check that there's at least 15 minutes until the match starts
        require(_teamA < 32 && _teamB < 32 && _teamA != _teamB && (_start - 15 minutes) >= now);
        Match memory newMatch = Match({
            locked: false, 
            cancelled: false, 
            teamA: _teamA,
            teamB: _teamB, 
            winner: 0,
            fixtureId: _fixture, // The primary fixtureId that will be used to query the football-data API
            secondaryFixtureId: _secondary, // The secondary fixtureID used to query sports monk
            inverted: _invert,
            start: _start, 
            closeBettingTime: _start - 3 minutes, // betting closes 3 minutes before a match starts
            totalTeamABets: 0, 
            totalTeamBBets: 0, 
            totalDrawBets: 0, 
            numBets: 0,
            name: _name
        });
        uint8 matchId = uint8(matches.push(newMatch)) - 1;
        // concatinate oraclize query
        string memory url = strConcat(
            "[URL] json(https://soccer.sportmonks.com/api/v2.0/fixtures/",
            newMatch.secondaryFixtureId,
            "?api_token=${[decrypt] BNxYykO2hsQ7iA7yRuDLSu1km6jFZwN5X87TY1BSmU30llRn8uWkJjHgx+YGytA1tmbRjb20CW0gIzcFmvq3yLZnitsvW28SPjlf+s9MK7hU+uRXqwhoW6dmWqKsBrCigrggFwMBRk4kA16jugtIr+enXHjOnAKSxd1dO4YXTCYvZc3T1pFA9PVyFFnd}).data.scores[localteam_score,visitorteam_score]");
        // store the oraclize query id for later use
        // use hours to over estimate the amount of time it would take to safely get a correct result
        // 90 minutes of regulation play time + potential 30 minutes of extra time + 15 minutes break
        // + potential 10 minutes of stoppage time + potential 10 minutes of penalties
        // + 25 minutes of time for any APIs to correct and ensure their information is correct
        bytes32 oraclizeId = oraclize_query((_start + (3 hours)), "nested", url, primaryGasLimit);
        oraclizeIds[oraclizeId] = matchId;
        emit MatchCreated(matchId);
        return matchId;
    }

    function cancelMatch(uint8 _matchId) public onlyOwner validMatch(_matchId) returns (bool) {
        Match storage mtch = matches[_matchId];
        require(!mtch.cancelled && now < mtch.closeBettingTime);
        mtch.cancelled = true;
        mtch.locked = true;
        emit MatchUpdated(_matchId);
        return true;
    }

    /*
     * @dev returns the number of matches on the contract
     */ 
    function getNumMatches() public view returns (uint) {
        return matches.length;
    }

    
    /*
     * @dev Returns some of the properties of a match. Functionality had to be seperated
     *      into 2 function calls to prevent stack too deep errors
     * @param _matchId   the index of that match in the matches array
     * @return `string`  the match name
     * @return `string`  the fixutre Id of the match for the football-data endpoint
     * @return `string`  the fixture Id fo the match for the sports monk endpoint
     * @return `uint8`   the index of the home team
     * @return `uint8`   the index of the away team
     * @return `uint8`   the winner of the match
     * @return `uint`    the unix timestamp for the match start time
     * @return `bool`    Match cancelled boolean
     * @return `bool`    Match locked boolean which is set to true if the match is payed out or bets are returned
     */ 
    function getMatch(uint8 _matchId) public view validMatch(_matchId) returns (string, string, string, bool, uint8, uint8, uint8, uint, bool, bool) {
        Match memory mtch = matches[_matchId];
        return (
            mtch.name,
            mtch.fixtureId, 
            mtch.secondaryFixtureId,
            mtch.inverted,
            mtch.teamA, 
            mtch.teamB,
            mtch.winner, 
            mtch.start,
            mtch.cancelled,
            mtch.locked
        );
    }

    /*
     * @dev Returns remaining of the properties of a match. Functionality had to be seperated
     *      into 2 function calls to prevent stack too deep errors
     * @param _matchId   the index of that match in the matches array
     * @return `uint`  timestamp for when betting for the match closes
     * @return `uint`  total size of the home team bet pool
     * @return `uint`  total size of the away team bet pool
     * @return `uint`  total size of the draw bet pool
     * @return `uint`  the total number of bets
     * @return `uint8` the number of payout attempts for the match
     */ 
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

    /*
     * @dev Adds a new bet to a match with the outcome passed where there are 3 possible outcomes
     *      homeTeam wins(1), awayTeam wins(2), draw(3). While it is possible for some matches
     *      to end in a draw, not all matches will have the possibility of ending in a draw
     *      this functionality will be added in front end code to prevent betting on invalid decisions.
     *      Emits a BetPlaced event.
     * @param _matchId   the index of the match in matches that the bet is for
     * @param _outcome   the possible outcome for the match that this bet is betting on 
     * @return `uint`    the Id of the bet in a match's bet array
     */ 
    function placeBet(uint8 _matchId, uint8 _outcome) public payable validMatch(_matchId) returns (uint) {
        Match storage mtch = matches[_matchId];
        // A bet must be a valid option, 1, 2, or 3, and cannot be less that the minimum bet amount
        require(
            !mtch.locked &&
            !mtch.cancelled &&
            now < mtch.closeBettingTime &&
            _outcome > 0 && 
            _outcome < 4 && 
            msg.value >= minimum_bet
        );
        Bet memory bet = Bet(false, false, msg.value, _outcome, msg.sender);
        uint betId = mtch.numBets;
        mtch.bets[betId] = bet;
        mtch.numBets++;
        if (_outcome == 1) {
            mtch.totalTeamABets += msg.value;
            // a bit of safe math checking here
            assert(mtch.totalTeamABets >= msg.value);
        } else if (_outcome == 2) {
            mtch.totalTeamBBets += msg.value;
            assert(mtch.totalTeamBBets >= msg.value);
        } else {
            mtch.totalDrawBets += msg.value;
            assert(mtch.totalDrawBets >= msg.value);
        }
        // emit bet placed event
        emit BetPlaced(_matchId, _outcome, betId, msg.value, msg.sender);
        return (betId);
    }

    /*
     * @dev Returns the properties of a bet for a match
     * @param _matchId   the index of that match in the matches array
     * @param _betId     the index of that bet in the match bets array
     * @return `address` the address that placed the bet and thus it's owner
     * @return `uint`    the amount that was bet
     * @return `uint`    the option that was bet on
     * @return `bool`    wether or not the bet had been cancelled
     */ 
    function getBet(uint8 _matchId, uint _betId) public view validBet(_matchId, _betId) returns (address, uint, uint, bool, bool) {
        Bet memory bet = matches[_matchId].bets[_betId];
        // Don't return matchId and betId since you had to know them in the first place
        return (bet.better, bet.amount, bet.option, bet.cancelled, bet.claimed);
    } 

    /*
     * @dev Cancel's a bet and returns the amount - commission fee. Emits a BetCancelled event
     * @param _matchId   the index of that match in the matches array
     * @param _betId     the index of that bet in the match bets array
     */ 
    function cancelBet(uint8 _matchId, uint _betId) public validBet(_matchId, _betId) {
        Match memory mtch = matches[_matchId];
        require(!mtch.locked && now < mtch.closeBettingTime);
        Bet storage bet = matches[_matchId].bets[_betId];
        // only the person who made this bet can cancel it
        require(!bet.cancelled && !bet.claimed && bet.better == msg.sender );
        // stop re-entry just in case of malicious attack to withdraw all contract eth
        bet.cancelled = true;
        uint commission = bet.amount / 100 * commission_rate;
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

    /*
     * @dev Betters can claim there winnings using this method or reclaim their bet
     *      if the match was cancelled
     * @param _matchId   the index of the match in the matches array
     * @param _betId     the bet being claimed
     */ 
    function claimBet(uint8 _matchId, uint8 _betId) public validBet(_matchId, _betId) {
        Match storage mtch = matches[_matchId];
        Bet storage bet = mtch.bets[_betId];
        // ensures the match has been locked (payout either done or bets returned)
        // dead man's switch to prevent bets from ever getting locked in the contrat
        // from insufficient funds during an oracalize query
        // if the match isn't locked or cancelled, then you can claim your bet after
        // the world cup is over (noon July 16)
        require((mtch.locked || now >= 1531742400) &&
            !bet.claimed &&
            !bet.cancelled &&
            msg.sender == bet.better
        );
        bet.claimed = true;
        if (mtch.winner == 0) {
            // If the match is locked with no winner set
            // then either it was cancelled or a winner couldn't be determined
            // transfer better back their bet amount
            bet.better.transfer(bet.amount);
        } else {
            if (bet.option != mtch.winner) {
                return;
            }
            uint totalPool;
            uint winPool;
            if (mtch.winner == 1) {
                totalPool = mtch.totalTeamBBets + mtch.totalDrawBets;
                // once again do some safe math
                assert(totalPool >= mtch.totalTeamBBets);
                winPool = mtch.totalTeamABets;
            } else if (mtch.winner == 2) {
                totalPool = mtch.totalTeamABets + mtch.totalDrawBets;
                assert(totalPool >= mtch.totalTeamABets);
                winPool = mtch.totalTeamBBets;
            } else {
                totalPool = mtch.totalTeamABets + mtch.totalTeamBBets;
                assert(totalPool >= mtch.totalTeamABets);
                winPool = mtch.totalDrawBets;
            }
            uint winnings = totalPool * bet.amount / winPool;
            // calculate commissions percentage
            uint commission = winnings / 100 * commission_rate;
            commissions += commission;
            assert(commissions >= commission);
            // return original bet amount + winnings - commission
            bet.better.transfer(winnings + bet.amount - commission);
        }
        emit BetClaimed(_matchId, _betId);
    }

    /*
     * @dev Change the commission fee for the contract. The fee can never exceed 7%
     * @param _newCommission  the new fee rate to be charged in wei
     */ 
    function changeFees(uint8 _newCommission) public onlyOwner {
        // Max commission is 7%, but it can be FREE!!
        require(_newCommission <= 7);
        commission_rate = _newCommission;
    }

    /*
     * @dev Withdraw a portion of the commission from the commission pool.
     * @param _amount  the amount of commission to be withdrawn
     */ 
    function withdrawCommissions(uint _amount) public onlyOwner {
        require(_amount <= commissions);
        commissions -= _amount;
        owner.transfer(_amount);
    }

    /*
     * @dev Destroy the contract but only after the world cup is over for a month
     */ 
    function withdrawBalance() public onlyOwner {
        // World cup is over for a full month withdraw the full balance of the contract
        // and destroy it to free space on the blockchain
        require(now >= 1534291200); // This is 12am August 15, 2018
        selfdestruct(owner);
    }

    
    /*
     * @dev Change the minimum bet amount. Just in case the price of eth skyrockets or drops.
     * @param _newMin   the new minimum bet amount
     */ 
    function changeMiniumBet(uint _newMin) public onlyOwner {
        minimum_bet = _newMin;
    }

    /*
     * @dev sets the gas price to be used for oraclize quries in the contract
     * @param _price          the price of each gas
     */ 
    function setGasPrice(uint _price) public onlyOwner {
        require(_price >= 20000000000 wei);
        oraclize_setCustomGasPrice(_price);
    }


     /*
     * @dev Oraclize query callback to determine the winner of the match.
     * @param _myid    the id for the oraclize query that is being returned
     * @param _result  the result of the query
     */ 
    function __callback(bytes32 _myid, string _result) public {
        // only oraclize can call this method
        if (msg.sender != oraclize_cbAddress()) revert();
        uint8 matchId = oraclizeIds[_myid];
        Match storage mtch = matches[matchId];
        require(!mtch.locked && !mtch.cancelled);
        bool firstVerification = firstStepVerified[matchId];
        // If there is no result or the result is null we want to do the following
        if (bytes(_result).length == 0 || (keccak256(_result) == keccak256("[null, null]"))) {
            // If max number of attempts has been reached then return all bets
            if (++payoutAttempts[matchId] >= MAX_NUM_PAYOUT_ATTEMPTS) {
                mtch.locked = true;
                emit MatchFailedPayoutRelease(matchId);
            } else {
                emit MatchUpdated(matchId);
                string memory url;
                string memory querytype;
                uint limit;
                // if the contract has already verified the sportsmonks api
                // use football-data.org as a secondary source of truth
                if (firstVerification) {
                    url = strConcat(
                        "json(https://api.football-data.org/v1/fixtures/", 
                        matches[matchId].fixtureId,
                        ").fixture.result.[goalsHomeTeam,goalsAwayTeam]");
                    querytype = "URL";
                    limit = secondaryGasLimit;
                } else {                
                    url = strConcat(
                        "[URL] json(https://soccer.sportmonks.com/api/v2.0/fixtures/",
                        matches[matchId].secondaryFixtureId,
                        "?api_token=${[decrypt] BNxYykO2hsQ7iA7yRuDLSu1km6jFZwN5X87TY1BSmU30llRn8uWkJjHgx+YGytA1tmbRjb20CW0gIzcFmvq3yLZnitsvW28SPjlf+s9MK7hU+uRXqwhoW6dmWqKsBrCigrggFwMBRk4kA16jugtIr+enXHjOnAKSxd1dO4YXTCYvZc3T1pFA9PVyFFnd}).data.scores[localteam_score,visitorteam_score]");
                    querytype = "nested";
                    // use primary gas limit since that query won't payout winners on callback
                    limit = primaryGasLimit;
                }
                bytes32 oraclizeId = oraclize_query(PAYOUT_ATTEMPT_INTERVAL, querytype, url, limit);
                oraclizeIds[oraclizeId] = matchId;
            }
        } else {
            payoutAttempts[matchId] = 0;
            // eg. result = "[2, 4]"
            strings.slice memory s = _result.toSlice();
            // remove the braces from the result
            s = s.beyond("[".toSlice());
            s = s.until("]".toSlice());
            // split the string to get the two string encoded ints
            strings.slice memory x = s.split(", ".toSlice());
            // parse them to int to get the scores
            uint homeScore = parseInt(s.toString()); 
            uint awayScore = parseInt(x.toString());
            uint8 matchResult;
            // determine the winner
            if (homeScore > awayScore) {
                matchResult = 1;
            } else if (homeScore < awayScore) {
                matchResult = 2;
            } else {
                matchResult = 3;
            }
            // if this is the query to sportsmonks
            if (!firstVerification) {
                // set pending winner and call the second source of truth
                pendingWinner[matchId] = matchResult;
                firstStepVerified[matchId] = true;
                url = strConcat(
                    "json(https://api.football-data.org/v1/fixtures/", 
                    matches[matchId].fixtureId,
                    ").fixture.result.[goalsHomeTeam,goalsAwayTeam]");
                oraclizeId = oraclize_query("nested", url, secondaryGasLimit);
                oraclizeIds[oraclizeId] = matchId;
            } else {
                mtch.locked = true;
                // if one of the APIs has the teams inverted then flip the result
                if (matches[matchId].inverted) {
                    if (matchResult == 1) {
                        matchResult = 2;
                    } else if (matchResult == 2) {
                        matchResult = 1;
                    }
                }
                // if the both APIs confirm the same winner then payout the winners
                if (pendingWinner[matchId] == matchResult) {
                    mtch.winner = matchResult;
                    emit MatchUpdated(matchId);
                } else {
                    // else don't set a winner because a source of truth couldn't be verified
                    // this way users can still reclaim their original bet amount
                    emit MatchFailedPayoutRelease(matchId);
                }
            }
        }
    }
    
    function() public payable {}
}