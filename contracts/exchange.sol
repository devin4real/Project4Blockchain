// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;


import './token.sol';
import "hardhat/console.sol";


contract TokenExchange is Ownable {
    string public exchange_name = 'StanDex';

    // TODO: paste token contract address here
    // e.g. tokenAddr = 0x5FbDB2315678afecb367f032d93F642f64180aa3
    address tokenAddr = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    Token public token = Token(tokenAddr);                                

    // Liquidity pool for the exchange
    uint private token_reserves = 0;
    uint private eth_reserves = 0;

    // Fee Pools
    uint private token_fee_reserves = 0;
    uint private eth_fee_reserves = 0;

    // Liquidity pool shares
    mapping(address => uint) private lps;

    // For Extra Credit only: to loop through the keys of the lps mapping
    address[] private lp_providers;      

    // Total Pool Shares
    uint private total_shares = 0;

    // liquidity rewards
    uint private swap_fee_numerator = 3;                
    uint private swap_fee_denominator = 100;

    // Constant: x * y = k
    uint private k;

    uint private multiplier = 10**5;

    // Extra Credit: O(1) per-share fee accumulators and reward checkpoints
    uint private constant REWARD_PRECISION = 10**24;
    uint private acc_eth_fee_per_share = 0;
    uint private acc_token_fee_per_share = 0;
    mapping(address => uint) private eth_reward_debt;
    mapping(address => uint) private token_reward_debt;
    mapping(address => uint) private pending_eth_rewards_scaled;
    mapping(address => uint) private pending_token_rewards_scaled;

    // Reentrancy guard
    uint private unlocked = 1;

    event LiquidityAdded(address indexed provider, uint ethAmount, uint tokenAmount, uint sharesMinted);
    event LiquidityRemoved(address indexed provider, uint ethAmount, uint tokenAmount, uint ethRewards, uint tokenRewards, uint sharesBurned);
    event SwappedETHForTokens(address indexed trader, uint ethIn, uint ethFee, uint tokensOut);
    event SwappedTokensForETH(address indexed trader, uint tokensIn, uint tokenFee, uint ethOut);

    modifier nonReentrant() {
        require(unlocked == 1, "ReentrancyGuard: reentrant call");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    modifier poolInitialized() {
        require(eth_reserves > 0 && token_reserves > 0, "Pool is not initialized");
        _;
    }

    constructor() {}
    

    // Function createPool: Initializes a liquidity pool between your Token and ETH.
    // ETH will be sent to pool in this transaction as msg.value
    // amountTokens specifies the amount of tokens to transfer from the liquidity provider.
    // Sets up the initial exchange rate for the pool by setting amount of token and amount of ETH.
    function createPool(uint amountTokens)
        external
        payable
        onlyOwner
    {
        // This function is already implemented for you; no changes needed.

        // require pool does not yet exist:
        require (token_reserves == 0, "Token reserves was not 0");
        require (eth_reserves == 0, "ETH reserves was not 0.");

        // require nonzero values were sent
        require (msg.value > 0, "Need eth to create pool.");
        uint tokenSupply = token.balanceOf(msg.sender);
        require(amountTokens <= tokenSupply, "Not have enough tokens to create the pool");
        require (amountTokens > 0, "Need tokens to create pool.");

        token.transferFrom(msg.sender, address(this), amountTokens);
        token_reserves = token.balanceOf(address(this));
        eth_reserves = msg.value;
        k = token_reserves * eth_reserves;

        // Pool shares set to a large value to minimize round-off errors
        total_shares = 10**5;
        // Pool creator has some low amount of shares to allow autograder to run
        lps[msg.sender] = 100;
    }

    // For use for ExtraCredit ONLY
    // Function removeLP: removes a liquidity provider from the list.
    // This function also removes the gap left over from simply running "delete".
    function removeLP(uint index) private {
        require(index < lp_providers.length, "specified index is larger than the number of lps");
        lp_providers[index] = lp_providers[lp_providers.length - 1];
        lp_providers.pop();
    }

    // Function getSwapFee: Returns the current swap fee ratio to the client.
    function getSwapFee() public view returns (uint, uint) {
        return (swap_fee_numerator, swap_fee_denominator);
    }

    // Function getReserves
    function getReserves() public view returns (uint, uint) {
        return (eth_reserves, token_reserves);
    }

    // ============================================================
    //                    FUNCTIONS TO IMPLEMENT
    // ============================================================
    
    /* ========================= Liquidity Provider Functions =========================  */ 

    // Function addLiquidity: Adds liquidity given a supply of ETH (sent to the contract as msg.value).
    // Fails if the current exchange rate is outside [min_exchange_rate, max_exchange_rate] (scaled by multiplier).
    function addLiquidity(uint max_exchange_rate, uint min_exchange_rate) 
        external 
        payable
        nonReentrant
        poolInitialized
    {
        require(msg.value > 0, "Must provide ETH to add liquidity");
        require(min_exchange_rate <= max_exchange_rate, "Invalid slippage bounds");

        uint current_exchange_rate = (token_reserves * 10**18 * multiplier) / eth_reserves;
        require(
            current_exchange_rate >= min_exchange_rate && current_exchange_rate <= max_exchange_rate,
            "Slippage limit exceeded"
        );

        // Ceiling division ensures provider does not under-deposit tokens on fractional rates
        uint tokens_needed = (msg.value * token_reserves + eth_reserves - 1) / eth_reserves;
        require(tokens_needed > 0, "ETH amount too small");
        require(token.balanceOf(msg.sender) >= tokens_needed, "Insufficient token balance");
        require(token.allowance(msg.sender, address(this)) >= tokens_needed, "Insufficient token allowance");

        uint shares_added = (msg.value * total_shares) / eth_reserves;
        require(shares_added > 0, "Liquidity amount too small");

        // Snapshot accrued rewards before changing share balance
        _updateRewards(msg.sender);

        lps[msg.sender] += shares_added;
        total_shares += shares_added;
        eth_reward_debt[msg.sender] = lps[msg.sender] * acc_eth_fee_per_share;
        token_reward_debt[msg.sender] = lps[msg.sender] * acc_token_fee_per_share;

        eth_reserves += msg.value;
        token_reserves += tokens_needed;
        k = eth_reserves * token_reserves;

        require(token.transferFrom(msg.sender, address(this), tokens_needed), "Token transfer failed");

        emit LiquidityAdded(msg.sender, msg.value, tokens_needed, shares_added);
    }


    // Function removeLiquidity: Removes liquidity given the desired amount of ETH to remove.
    // Transfers proportional ETH and tokens plus all unclaimed LP fee rewards accrued by msg.sender.
    function removeLiquidity(uint amountETH, uint max_exchange_rate, uint min_exchange_rate)
        public 
        payable
        nonReentrant
        poolInitialized
    {
        require(msg.value == 0, "Do not send ETH when removing liquidity");
        require(amountETH > 0, "Amount must be greater than 0");
        require(lps[msg.sender] > 0, "No liquidity provided");
        require(min_exchange_rate <= max_exchange_rate, "Invalid slippage bounds");

        uint current_exchange_rate = (token_reserves * 10**18 * multiplier) / eth_reserves;
        require(
            current_exchange_rate >= min_exchange_rate && current_exchange_rate <= max_exchange_rate,
            "Slippage limit exceeded"
        );

        uint shares_to_burn = (amountETH * total_shares + eth_reserves - 1) / eth_reserves;
        require(shares_to_burn > 0, "Amount too small");
        require(shares_to_burn <= lps[msg.sender], "Insufficient liquidity shares");

        uint tokens_to_remove = (amountETH * token_reserves) / eth_reserves;
        require(eth_reserves > amountETH && token_reserves > tokens_to_remove, "Cannot drain pool reserves to 0");

        (uint eth_rewards, uint token_rewards) = _claimPendingRewards(msg.sender);

        lps[msg.sender] -= shares_to_burn;
        total_shares -= shares_to_burn;

        if (lps[msg.sender] == 0) {
            pending_eth_rewards_scaled[msg.sender] = 0;
            pending_token_rewards_scaled[msg.sender] = 0;
            eth_reward_debt[msg.sender] = 0;
            token_reward_debt[msg.sender] = 0;
        } else {
            eth_reward_debt[msg.sender] = lps[msg.sender] * acc_eth_fee_per_share;
            token_reward_debt[msg.sender] = lps[msg.sender] * acc_token_fee_per_share;
        }

        eth_reserves -= amountETH;
        token_reserves -= tokens_to_remove;
        k = eth_reserves * token_reserves;

        uint total_eth = amountETH + eth_rewards;
        uint total_tokens = tokens_to_remove + token_rewards;

        if (total_tokens > 0) {
            require(token.transfer(msg.sender, total_tokens), "Token transfer failed");
        }
        (bool sent, ) = payable(msg.sender).call{value: total_eth}("");
        require(sent, "ETH transfer failed");

        emit LiquidityRemoved(msg.sender, amountETH, tokens_to_remove, eth_rewards, token_rewards, shares_to_burn);
    }

    // Function removeAllLiquidity: Removes all liquidity that msg.sender is entitled to withdraw.
    function removeAllLiquidity(uint max_exchange_rate, uint min_exchange_rate)
        external
        payable
        nonReentrant
        poolInitialized
    {
        require(msg.value == 0, "Do not send ETH when removing liquidity");
        uint user_shares = lps[msg.sender];
        require(user_shares > 0, "No liquidity provided");
        require(min_exchange_rate <= max_exchange_rate, "Invalid slippage bounds");

        uint current_exchange_rate = (token_reserves * 10**18 * multiplier) / eth_reserves;
        require(
            current_exchange_rate >= min_exchange_rate && current_exchange_rate <= max_exchange_rate,
            "Slippage limit exceeded"
        );

        uint eth_to_remove = (user_shares * eth_reserves) / total_shares;
        uint tokens_to_remove = (user_shares * token_reserves) / total_shares;
        require(eth_reserves > eth_to_remove && token_reserves > tokens_to_remove, "Cannot drain pool reserves to 0");
        require(eth_to_remove > 0 || tokens_to_remove > 0, "Liquidity too small to remove");

        (uint eth_rewards, uint token_rewards) = _claimPendingRewards(msg.sender);

        lps[msg.sender] = 0;
        total_shares -= user_shares;
        pending_eth_rewards_scaled[msg.sender] = 0;
        pending_token_rewards_scaled[msg.sender] = 0;
        eth_reward_debt[msg.sender] = 0;
        token_reward_debt[msg.sender] = 0;

        eth_reserves -= eth_to_remove;
        token_reserves -= tokens_to_remove;
        k = eth_reserves * token_reserves;

        uint total_eth = eth_to_remove + eth_rewards;
        uint total_tokens = tokens_to_remove + token_rewards;

        if (total_tokens > 0) {
            require(token.transfer(msg.sender, total_tokens), "Token transfer failed");
        }
        if (total_eth > 0) {
            (bool sent, ) = payable(msg.sender).call{value: total_eth}("");
            require(sent, "ETH transfer failed");
        }

        emit LiquidityRemoved(msg.sender, eth_to_remove, tokens_to_remove, eth_rewards, token_rewards, user_shares);
    }

    /***  Define additional functions for liquidity fees here as needed ***/

    function _updateRewards(address lp) private {
        uint shares = lps[lp];
        if (shares > 0) {
            uint accumulatedEth = shares * acc_eth_fee_per_share;
            uint accumulatedToken = shares * acc_token_fee_per_share;
            if (accumulatedEth > eth_reward_debt[lp]) {
                pending_eth_rewards_scaled[lp] += accumulatedEth - eth_reward_debt[lp];
            }
            if (accumulatedToken > token_reward_debt[lp]) {
                pending_token_rewards_scaled[lp] += accumulatedToken - token_reward_debt[lp];
            }
        }
    }

    function _claimPendingRewards(address lp) private returns (uint eth_rewards, uint token_rewards) {
        _updateRewards(lp);
        eth_rewards = pending_eth_rewards_scaled[lp] / REWARD_PRECISION;
        token_rewards = pending_token_rewards_scaled[lp] / REWARD_PRECISION;
        if (eth_rewards > eth_fee_reserves) {
            eth_rewards = eth_fee_reserves;
        }
        if (token_rewards > token_fee_reserves) {
            token_rewards = token_fee_reserves;
        }
        pending_eth_rewards_scaled[lp] %= REWARD_PRECISION;
        pending_token_rewards_scaled[lp] %= REWARD_PRECISION;
        eth_fee_reserves -= eth_rewards;
        token_fee_reserves -= token_rewards;
    }

    function getLPShares(address lp) public view returns (uint, uint) {
        return (lps[lp], total_shares);
    }

    function getFeeReserves() public view returns (uint, uint) {
        return (eth_fee_reserves, token_fee_reserves);
    }

    function getPendingRewards(address lp) public view returns (uint, uint) {
        uint shares = lps[lp];
        uint totalEthScaled = pending_eth_rewards_scaled[lp];
        uint totalTokenScaled = pending_token_rewards_scaled[lp];
        if (shares > 0) {
            uint accumulatedEth = shares * acc_eth_fee_per_share;
            uint accumulatedToken = shares * acc_token_fee_per_share;
            if (accumulatedEth > eth_reward_debt[lp]) {
                totalEthScaled += accumulatedEth - eth_reward_debt[lp];
            }
            if (accumulatedToken > token_reward_debt[lp]) {
                totalTokenScaled += accumulatedToken - token_reward_debt[lp];
            }
        }
        return (totalEthScaled / REWARD_PRECISION, totalTokenScaled / REWARD_PRECISION);
    }


    /* ========================= Swap Functions =========================  */ 

    // Function swapTokensForETH: Swaps your token with ETH
    function swapTokensForETH(uint amountTokens, uint max_exchange_rate)
        external 
        payable
        nonReentrant
        poolInitialized
    {
        require(msg.value == 0, "Do not send ETH when swapping tokens for ETH");
        require(amountTokens > 0, "Must swap a positive amount of tokens");
        require(token.balanceOf(msg.sender) >= amountTokens, "Insufficient token balance");
        require(token.allowance(msg.sender, address(this)) >= amountTokens, "Insufficient token allowance");

        // Price of ETH in terms of tokens (scaled by multiplier)
        uint current_exchange_rate = (token_reserves * 10**18 * multiplier) / eth_reserves;
        require(current_exchange_rate <= max_exchange_rate, "Slippage limit exceeded");

        uint token_fee = (amountTokens * swap_fee_numerator) / swap_fee_denominator;
        uint tokens_after_fee = amountTokens - token_fee;
        require(tokens_after_fee > 0, "Swap amount too small after fee");

        uint new_token_reserves = token_reserves + tokens_after_fee;
        uint eth_out = (eth_reserves * tokens_after_fee) / new_token_reserves;
        require(eth_out > 0, "Output ETH amount is 0");
        require(eth_reserves >= eth_out + 1 ether, "Must leave at least 1 ETH in pool");

        token_fee_reserves += token_fee;
        if (token_fee > 0) {
            acc_token_fee_per_share += (token_fee * REWARD_PRECISION) / total_shares;
        }

        token_reserves = new_token_reserves;
        eth_reserves -= eth_out;

        require(token.transferFrom(msg.sender, address(this), amountTokens), "Token transfer failed");
        (bool sent, ) = payable(msg.sender).call{value: eth_out}("");
        require(sent, "ETH transfer failed");

        emit SwappedTokensForETH(msg.sender, amountTokens, token_fee, eth_out);
    }



    // Function swapETHForTokens: Swaps ETH for your tokens
    // ETH is sent to contract as msg.value
    function swapETHForTokens(uint max_exchange_rate)
        external
        payable 
        nonReentrant
        poolInitialized
    {
        require(msg.value > 0, "Must send ETH to swap");

        // Price of Token in terms of ETH (scaled by multiplier)
        uint current_exchange_rate = (eth_reserves * multiplier) / (token_reserves * 10**18);
        require(current_exchange_rate <= max_exchange_rate, "Slippage limit exceeded");

        uint eth_fee = (msg.value * swap_fee_numerator) / swap_fee_denominator;
        uint eth_after_fee = msg.value - eth_fee;
        require(eth_after_fee > 0, "Swap amount too small after fee");

        uint new_eth_reserves = eth_reserves + eth_after_fee;
        uint tokens_out = (token_reserves * eth_after_fee) / new_eth_reserves;
        require(tokens_out > 0, "Swap amount too small: 0 tokens output");
        require(token_reserves >= tokens_out + 1, "Must leave at least 1 token in pool");

        eth_fee_reserves += eth_fee;
        if (eth_fee > 0) {
            acc_eth_fee_per_share += (eth_fee * REWARD_PRECISION) / total_shares;
        }

        eth_reserves = new_eth_reserves;
        token_reserves -= tokens_out;

        require(token.transfer(msg.sender, tokens_out), "Token transfer failed");

        emit SwappedETHForTokens(msg.sender, msg.value, eth_fee, tokens_out);
    }
}