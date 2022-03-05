// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

library Math {
    function max(uint a, uint b) internal pure returns (uint) {
        return a >= b ? a : b;
    }
    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
}

interface erc20 {
    function totalSupply() external view returns (uint256);
    function transfer(address recipient, uint amount) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
}

interface ve {
    function token() external view returns (address);
    function balanceOfNFT(uint) external view returns (uint);
    function isApprovedOrOwner(address, uint) external view returns (bool);
    function ownerOf(uint) external view returns (address);
    function transferFrom(address, address, uint) external;
}

interface IBaseV1Factory {
    function isPair(address) external view returns (bool);
}

interface IBaseV1Core {
    function claimFees() external returns (uint, uint);
    function tokens() external returns (address, address);
}

interface IBribe {
    function notifyRewardAmount(address token, uint amount) external;
    function left(address token) external view returns (uint);
}

interface Voter {
    function attachTokenToGauge(uint _tokenId, address account) external;
    function detachTokenFromGauge(uint _tokenId, address account) external;
    function emitDeposit(uint _tokenId, address account, uint amount) external;
    function emitWithdraw(uint _tokenId, address account, uint amount) external;
    function distribute(address _gauge) external;
}

// Gauges are used to incentivize pools, they emit reward tokens over 7 days for staked LP tokens
contract Gauge {

    address public immutable stake; // the LP token that needs to be staked for rewards 需要质押获取奖励的 LP token 合约的地址
    address public immutable _ve; // the ve token used for gauges veNFT 合约的地址
    address public immutable bribe; // 贿赂合约的地址
    address public immutable voter; // 投票合约的地址

    uint public derivedSupply; // sum of all users' derived balance
    mapping(address => uint) public derivedBalances; // user -> his derived balance

    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    uint internal constant PRECISION = 10 ** 18;

    // default snx staking contract implementation
    mapping(address => uint) public rewardRate; // token -> reward rate 每秒奖励 token 的数量
    mapping(address => uint) public periodFinish; // token -> period finish time 奖励 token 的到期时间
    mapping(address => uint) public lastUpdateTime; // token -> last update time
    mapping(address => uint) public rewardPerTokenStored; // token -> its reward amount

    mapping(address => mapping(address => uint)) public lastEarn; // token -> user -> last getReward time
    mapping(address => mapping(address => uint)) public userRewardPerTokenStored; // token -> user -> rewardPerToken

    mapping(address => uint) public tokenIds; // user -> tokenId 用户地址和 tokenId 一一对应；同一地址不能有两个 tokenId

    uint public totalSupply; // 此合约拥有的 pool token 的数量
    mapping(address => uint) public balanceOf; // user -> user owned pool token amount

    address[] public rewards; // 奖励 token 列表
    mapping(address => bool) public isReward; // token -> true/false

    /// @notice A checkpoint for marking balance
    struct Checkpoint {
        uint timestamp;
        uint balanceOf;
    }

    /// @notice A checkpoint for marking reward rate
    struct RewardPerTokenCheckpoint {
        uint timestamp;
        uint rewardPerToken;
    }

    /// @notice A checkpoint for marking supply
    struct SupplyCheckpoint {
        uint timestamp;
        uint supply;
    }

    /// @notice A record of balance checkpoints for each account, by index
    mapping (address => mapping (uint => Checkpoint)) public checkpoints; // user -> checkpoint index -> checkpoint
    /// @notice The number of checkpoints for each account
    mapping (address => uint) public numCheckpoints; // user -> num of checkpoints
    /// @notice A record of balance checkpoints for each token, by index
    mapping (uint => SupplyCheckpoint) public supplyCheckpoints; // index -> supply checkpoint (derivedSupply)
    /// @notice The number of checkpoints
    uint public supplyNumCheckpoints;
    /// @notice A record of balance checkpoints for each token, by index
    mapping (address => mapping (uint => RewardPerTokenCheckpoint)) public rewardPerTokenCheckpoints; // token -> checkpoint index -> checkpoint
    /// @notice The number of checkpoints for each token
    mapping (address => uint) public rewardPerTokenNumCheckpoints; // token -> num of checkpoints

    uint public fees0;
    uint public fees1;

    event Deposit(address indexed from, uint tokenId, uint amount);
    event Withdraw(address indexed from, uint tokenId, uint amount);
    event NotifyReward(address indexed from, address indexed reward, uint amount);
    event ClaimFees(address indexed from, uint claimed0, uint claimed1);
    event ClaimRewards(address indexed from, address indexed reward, uint amount);

    constructor(address _stake, address _bribe, address  __ve, address _voter) {
        stake = _stake;
        bribe = _bribe;
        _ve = __ve;
        voter = _voter;
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() { // 防重入锁
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function claimFees() external lock returns (uint claimed0, uint claimed1) {
        return _claimFees();
    }

    // claim 对应 pool 的费用累积
    function _claimFees() internal returns (uint claimed0, uint claimed1) {
        // 从 pool 那里转入费用到此合约；费用为 pool 中每笔 swap 交易时记录 amountIn 的 1/10000 的积累
        (claimed0, claimed1) = IBaseV1Core(stake).claimFees();
        if (claimed0 > 0 || claimed1 > 0) {
            uint _fees0 = fees0 + claimed0;
            uint _fees1 = fees1 + claimed1;
            (address _token0, address _token1) = IBaseV1Core(stake).tokens();
            if (_fees0 > IBribe(bribe).left(_token0) && _fees0 / DURATION > 0) {
                fees0 = 0; // 费用积累清零
                _safeApprove(_token0, bribe, _fees0);
                // 通知 bribe 更新费用奖励数额
                IBribe(bribe).notifyRewardAmount(_token0, _fees0);
            } else {
                fees0 = _fees0; // 更新费用积累
            }
            if (_fees1 > IBribe(bribe).left(_token1) && _fees1 / DURATION > 0) {
                fees1 = 0;
                _safeApprove(_token1, bribe, _fees1);
                IBribe(bribe).notifyRewardAmount(_token1, _fees1);
            } else {
                fees1 = _fees1;
            }

            emit ClaimFees(msg.sender, claimed0, claimed1);
        }
    }

    /**
    * @notice Determine the prior balance for an account as of a block number
    * 查找指定时刻用户的 checkpoint 的 index
    * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
    * @param account The address of the account to check
    * @param timestamp The timestamp to get the balance at
    * @return The balance the account had as of the given block
    */
    function getPriorBalanceIndex(address account, uint timestamp) public view returns (uint) {
        uint nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].timestamp > timestamp) {
            return 0;
        }

        // 二分查找
        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    // 查找指定时刻的 supply checkpoint 的 index
    function getPriorSupplyIndex(uint timestamp) public view returns (uint) {
        uint nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > timestamp) {
            return 0;
        }

        // 二分查找
        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorRewardPerToken(address token, uint timestamp) public view returns (uint, uint) {
        uint nCheckpoints = rewardPerTokenNumCheckpoints[token];
        if (nCheckpoints == 0) {
            return (0,0);
        }

        // First check most recent balance
        if (rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp <= timestamp) {
            return (rewardPerTokenCheckpoints[token][nCheckpoints - 1].rewardPerToken, rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp);
        }

        // Next check implicit zero balance
        if (rewardPerTokenCheckpoints[token][0].timestamp > timestamp) {
            return (0,0);
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            RewardPerTokenCheckpoint memory cp = rewardPerTokenCheckpoints[token][center];
            if (cp.timestamp == timestamp) {
                return (cp.rewardPerToken, cp.timestamp);
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return (rewardPerTokenCheckpoints[token][lower].rewardPerToken, rewardPerTokenCheckpoints[token][lower].timestamp);
    }

    function _writeCheckpoint(address account, uint balance) internal {
        uint _timestamp = block.timestamp;
        uint _nCheckPoints = numCheckpoints[account];

        if (_nCheckPoints > 0 && checkpoints[account][_nCheckPoints - 1].timestamp == _timestamp) {
            checkpoints[account][_nCheckPoints - 1].balanceOf = balance;
        } else {
            checkpoints[account][_nCheckPoints] = Checkpoint(_timestamp, balance);
            numCheckpoints[account] = _nCheckPoints + 1;
        }
    }

    function _writeRewardPerTokenCheckpoint(address token, uint reward, uint timestamp) internal {
        uint _nCheckPoints = rewardPerTokenNumCheckpoints[token];

        if (_nCheckPoints > 0 && rewardPerTokenCheckpoints[token][_nCheckPoints - 1].timestamp == timestamp) {
            rewardPerTokenCheckpoints[token][_nCheckPoints - 1].rewardPerToken = reward;
        } else {
            rewardPerTokenCheckpoints[token][_nCheckPoints] = RewardPerTokenCheckpoint(timestamp, reward);
            rewardPerTokenNumCheckpoints[token] = _nCheckPoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        uint _nCheckPoints = supplyNumCheckpoints;
        uint _timestamp = block.timestamp;

        if (_nCheckPoints > 0 && supplyCheckpoints[_nCheckPoints - 1].timestamp == _timestamp) {
            supplyCheckpoints[_nCheckPoints - 1].supply = derivedSupply;
        } else {
            supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(_timestamp, derivedSupply);
            supplyNumCheckpoints = _nCheckPoints + 1;
        }
    }

    function rewardsListLength() external view returns (uint) {
        return rewards.length;
    }

    // returns the last time the reward was modified or periodFinish if the reward has ended
    function lastTimeRewardApplicable(address token) public view returns (uint) {
        return Math.min(block.timestamp, periodFinish[token]);
    }

    function getReward(address account, address[] memory tokens) external lock {
        require(msg.sender == account || msg.sender == voter);
        _unlocked = 1; // 临时解一下防重入锁
        Voter(voter).distribute(address(this)); // 让 voter 合约计算一下可提现数额
        _unlocked = 2; // 重新加上防重入锁

        for (uint i = 0; i < tokens.length; i++) {
            (rewardPerTokenStored[tokens[i]], lastUpdateTime[tokens[i]]) = _updateRewardPerToken(tokens[i]);

            uint _reward = earned(tokens[i], account);
            lastEarn[tokens[i]][account] = block.timestamp;
            userRewardPerTokenStored[tokens[i]][account] = rewardPerTokenStored[tokens[i]];
            if (_reward > 0) _safeTransfer(tokens[i], account, _reward); // 把奖励转账给 account

            emit ClaimRewards(msg.sender, tokens[i], _reward);
        }

        uint _derivedBalance = derivedBalances[account];
        derivedSupply -= _derivedBalance;
        _derivedBalance = derivedBalance(account);
        derivedBalances[account] = _derivedBalance;
        derivedSupply += _derivedBalance;

        _writeCheckpoint(account, derivedBalances[account]);
        _writeSupplyCheckpoint();
    }


    function rewardPerToken(address token) public view returns (uint) {
        if (derivedSupply == 0) {
            return rewardPerTokenStored[token];
        }
        return rewardPerTokenStored[token] + ((lastTimeRewardApplicable(token) - Math.min(lastUpdateTime[token], periodFinish[token])) * rewardRate[token] * PRECISION / derivedSupply);
    }

    // 导出的用户余额
    function derivedBalance(address account) public view returns (uint) {
        uint _tokenId = tokenIds[account];
        uint _balance = balanceOf[account];
        uint _derived = _balance * 40 / 100; // 用户存入 pool token 数量的 40%
        uint _adjusted = 0;
        uint _supply = erc20(_ve).totalSupply(); // 投票权数量
        if (account == ve(_ve).ownerOf(_tokenId) && _supply > 0) {
            _adjusted = ve(_ve).balanceOfNFT(_tokenId);
            // 此合约拥有 pool token 数 * 用户投票权数量占总投票权数量的比例 * 60%
            _adjusted = (totalSupply * _adjusted / _supply) * 60 / 100;
        }
        return Math.min((_derived + _adjusted), _balance); // 取较小值
    }

    function batchRewardPerToken(address token, uint maxRuns) external {
        (rewardPerTokenStored[token], lastUpdateTime[token])  = _batchRewardPerToken(token, maxRuns);
    }

    function _batchRewardPerToken(address token, uint maxRuns) internal returns (uint, uint) {
        uint _startTimestamp = lastUpdateTime[token];
        uint reward = rewardPerTokenStored[token];

        if (supplyNumCheckpoints == 0) {
            return (reward, _startTimestamp);
        }

        if (rewardRate[token] == 0) {
            return (reward, block.timestamp);
        }

        uint _startIndex = getPriorSupplyIndex(_startTimestamp);
        uint _endIndex = Math.min(supplyNumCheckpoints-1, maxRuns);

        for (uint i = _startIndex; i < _endIndex; i++) {
            SupplyCheckpoint memory sp0 = supplyCheckpoints[i];
            if (sp0.supply > 0) {
                SupplyCheckpoint memory sp1 = supplyCheckpoints[i+1];
                (uint _reward, uint _endTime) = _calcRewardPerToken(token, sp1.timestamp, sp0.timestamp, sp0.supply, _startTimestamp);
                reward += _reward;
                _writeRewardPerTokenCheckpoint(token, reward, _endTime);
                _startTimestamp = _endTime;
            }
        }

        return (reward, _startTimestamp);
    }

    function _calcRewardPerToken(address token, uint timestamp1, uint timestamp0, uint supply, uint startTimestamp) internal view returns (uint, uint) {
        uint endTime = Math.max(timestamp1, startTimestamp);
        return (((Math.min(endTime, periodFinish[token]) - Math.min(Math.max(timestamp0, startTimestamp), periodFinish[token])) * rewardRate[token] * PRECISION / supply), endTime);
    }

    function _updateRewardPerToken(address token) internal returns (uint, uint) {
        uint _startTimestamp = lastUpdateTime[token];
        uint reward = rewardPerTokenStored[token];

        if (supplyNumCheckpoints == 0) {
            return (reward, _startTimestamp);
        }

        if (rewardRate[token] == 0) {
            return (reward, block.timestamp);
        }

        uint _startIndex = getPriorSupplyIndex(_startTimestamp);
        uint _endIndex = supplyNumCheckpoints-1;

        if (_endIndex - _startIndex > 1) {
            for (uint i = _startIndex; i < _endIndex-1; i++) {
                SupplyCheckpoint memory sp0 = supplyCheckpoints[i];
                if (sp0.supply > 0) {
                    SupplyCheckpoint memory sp1 = supplyCheckpoints[i+1];
                    (uint _reward, uint _endTime) = _calcRewardPerToken(token, sp1.timestamp, sp0.timestamp, sp0.supply, _startTimestamp);
                    reward += _reward;
                    _writeRewardPerTokenCheckpoint(token, reward, _endTime);
                    _startTimestamp = _endTime;
                }
            }
        }

        SupplyCheckpoint memory sp = supplyCheckpoints[_endIndex];
        if (sp.supply > 0) {
            (uint _reward,) = _calcRewardPerToken(token, lastTimeRewardApplicable(token), Math.max(sp.timestamp, _startTimestamp), sp.supply, _startTimestamp);
            reward += _reward;
            _writeRewardPerTokenCheckpoint(token, reward, block.timestamp);
            _startTimestamp = block.timestamp;
        }

        return (reward, _startTimestamp);
    }

    // earned is an estimation, it won't be exact till the supply > rewardPerToken calculations have run
    function earned(address token, address account) public view returns (uint) {
        uint _startTimestamp = Math.max(lastEarn[token][account], rewardPerTokenCheckpoints[token][0].timestamp);
        if (numCheckpoints[account] == 0) {
            return 0;
        }

        uint _startIndex = getPriorBalanceIndex(account, _startTimestamp);
        uint _endIndex = numCheckpoints[account]-1;

        uint reward = 0;

        if (_endIndex - _startIndex > 1) {
            for (uint i = _startIndex; i < _endIndex-1; i++) {
                Checkpoint memory cp0 = checkpoints[account][i];
                Checkpoint memory cp1 = checkpoints[account][i+1];
                (uint _rewardPerTokenStored0,) = getPriorRewardPerToken(token, cp0.timestamp);
                (uint _rewardPerTokenStored1,) = getPriorRewardPerToken(token, cp1.timestamp);
                reward += cp0.balanceOf * (_rewardPerTokenStored1 - _rewardPerTokenStored0) / PRECISION;
            }
        }

        Checkpoint memory cp = checkpoints[account][_endIndex];
        (uint _rewardPerTokenStored,) = getPriorRewardPerToken(token, cp.timestamp);
        reward += cp.balanceOf * (rewardPerToken(token) - Math.max(_rewardPerTokenStored, userRewardPerTokenStored[token][account])) / PRECISION;

        return reward;
    }

    // deposit 用户拥有的 pool token 的所有数量
    function depositAll(uint tokenId) external {
        deposit(erc20(stake).balanceOf(msg.sender), tokenId);
    }

    // 同一地址不能使用两个不同的 tokenId 进行 deposit
    function deposit(uint amount, uint tokenId) public lock {
        require(amount > 0);

        // 把 amount 个 pool token 从发送者转入此合约
        _safeTransferFrom(stake, msg.sender, address(this), amount);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        if (tokenId > 0) {
            require(ve(_ve).ownerOf(tokenId) == msg.sender);
            if (tokenIds[msg.sender] == 0) {
                tokenIds[msg.sender] = tokenId;
                Voter(voter).attachTokenToGauge(tokenId, msg.sender);
            }
            require(tokenIds[msg.sender] == tokenId);
        } else {
            tokenId = tokenIds[msg.sender];
        }

        // 更新用户的 derivedBalance
        uint _derivedBalance = derivedBalances[msg.sender];
        derivedSupply -= _derivedBalance;
        _derivedBalance = derivedBalance(msg.sender);
        derivedBalances[msg.sender] = _derivedBalance;
        derivedSupply += _derivedBalance;

        // 写入检查点
        _writeCheckpoint(msg.sender, _derivedBalance);
        _writeSupplyCheckpoint();

        Voter(voter).emitDeposit(tokenId, msg.sender, amount);
        emit Deposit(msg.sender, tokenId, amount);
    }

    function withdrawAll() external {
        withdraw(balanceOf[msg.sender]);
    }

    function withdraw(uint amount) public {
        uint tokenId = 0;
        if (amount == balanceOf[msg.sender]) {
            tokenId = tokenIds[msg.sender];
        }
        withdrawToken(amount, tokenId);
    }

    function withdrawToken(uint amount, uint tokenId) public lock {
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        _safeTransfer(stake, msg.sender, amount);

        if (tokenId > 0) {
            require(tokenId == tokenIds[msg.sender]);
            tokenIds[msg.sender] = 0;
            Voter(voter).detachTokenFromGauge(tokenId, msg.sender); // 取消 attach
        } else {
            tokenId = tokenIds[msg.sender];
        }

        uint _derivedBalance = derivedBalances[msg.sender];
        derivedSupply -= _derivedBalance;
        _derivedBalance = derivedBalance(msg.sender);
        derivedBalances[msg.sender] = _derivedBalance;
        derivedSupply += _derivedBalance;

        _writeCheckpoint(msg.sender, derivedBalances[msg.sender]);
        _writeSupplyCheckpoint();

        Voter(voter).emitWithdraw(tokenId, msg.sender, amount);
        emit Withdraw(msg.sender, tokenId, amount);
    }

    // 指定 token 的奖励还剩的数量
    function left(address token) external view returns (uint) {
        if (block.timestamp >= periodFinish[token]) return 0;
        uint _remaining = periodFinish[token] - block.timestamp;
        return _remaining * rewardRate[token];
    }

    // 将 token 纳入此合约的奖励代币列表中；从发送者转入 token amount 到此合约
    // 主要由 voter 合约调用用于奖励 $SOLID；然而第三方也可以无许可地添加其他 token 奖励
    function notifyRewardAmount(address token, uint amount) external lock {
        require(token != stake);
        require(amount > 0);
        if (rewardRate[token] == 0) _writeRewardPerTokenCheckpoint(token, 0, block.timestamp);
        (rewardPerTokenStored[token], lastUpdateTime[token]) = _updateRewardPerToken(token);
        _claimFees(); // claim 对应 pool 的交易费用累积

        if (block.timestamp >= periodFinish[token]) {
            _safeTransferFrom(token, msg.sender, address(this), amount); // 从发送者转入 token amount 到此合约
            rewardRate[token] = amount / DURATION; // 计算每秒奖励 token 的数额；相对于 7 天线性释放
        } else {
            uint _remaining = periodFinish[token] - block.timestamp;
            uint _left = _remaining * rewardRate[token];
            require(amount > _left);
            _safeTransferFrom(token, msg.sender, address(this), amount); // 从发送者转入 token amount 到此合约
            rewardRate[token] = (amount + _left) / DURATION; // 重新计算线性释放的数额
        }
        require(rewardRate[token] > 0);
        uint balance = erc20(token).balanceOf(address(this));
        require(rewardRate[token] <= balance / DURATION, "Provided reward too high");
        periodFinish[token] = block.timestamp + DURATION; // 7天线性释放周期从此时重新计算
        if (!isReward[token]) {
            isReward[token] = true;
            rewards.push(token);
        }

        emit NotifyReward(msg.sender, token, amount);
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeApprove(address token, address spender, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.approve.selector, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}

contract BaseV1GaugeFactory {
    address public last_gauge;

    function createGauge(address _pool, address _bribe, address _ve) external returns (address) {
        last_gauge = address(new Gauge(_pool, _bribe, _ve, msg.sender));
        return last_gauge;
    }

    function createGaugeSingle(address _pool, address _bribe, address _ve, address _voter) external returns (address) {
        last_gauge = address(new Gauge(_pool, _bribe, _ve, _voter));
        return last_gauge;
    }
}
