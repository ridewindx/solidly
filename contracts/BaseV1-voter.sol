// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

library Math {
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
    function attach(uint tokenId) external;
    function detach(uint tokenId) external;
    function voting(uint tokenId) external;
    function abstain(uint tokenId) external;
}

interface IBaseV1Factory {
    function isPair(address) external view returns (bool);
}

interface IBaseV1Core {
    function claimFees() external returns (uint, uint);
    function tokens() external returns (address, address);
}

interface IBaseV1GaugeFactory {
    function createGauge(address, address, address) external returns (address);
}

interface IBaseV1BribeFactory {
    function createBribe() external returns (address);
}

interface IGauge {
    function notifyRewardAmount(address token, uint amount) external;
    function getReward(address account, address[] memory tokens) external;
    function claimFees() external returns (uint claimed0, uint claimed1);
    function left(address token) external view returns (uint);
}

interface IBribe {
    function _deposit(uint amount, uint tokenId) external;
    function _withdraw(uint amount, uint tokenId) external;
    function getRewardForOwner(uint tokenId, address[] memory tokens) external;
}

interface IMinter {
    function update_period() external returns (uint);
}

contract BaseV1Voter {

    address public immutable _ve; // the ve token that governs these contracts
    address public immutable factory; // the BaseV1Factory
    address internal immutable base; // $SOLID 代币合约的地址
    address public immutable gaugefactory;
    address public immutable bribefactory;
    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    address public minter;

    uint public totalWeight; // total voting weight 所有投票数量的总和（包括反对票）

    address[] public pools; // all pools viable for incentives 所有允许的 pool token 合约地址们
    mapping(address => address) public gauges; // pool => gauge 一一对应
    mapping(address => address) public poolForGauge; // gauge => pool
    mapping(address => address) public bribes; // gauge => bribe 一一对应
    mapping(address => int256) public weights; // pool => weight 每个 pool 获得的投票数量
    mapping(uint => mapping(address => int256)) public votes; // nft tokenId => pool => votes
    mapping(uint => address[]) public poolVote; // nft tokenId => pools（此 tokenId 投票的 pool 们）
    mapping(uint => uint) public usedWeights;  // nft tokenId => total voting weight of user 此 tokenId 投出的投票数量（包括反对票）
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isWhitelisted; // 被白名单的 token 合约地址们；添加的 pool token 的两个 token 必须是被白名单的

    event GaugeCreated(address indexed gauge, address creator, address indexed bribe, address indexed pool);
    event Voted(address indexed voter, uint tokenId, int256 weight);
    event Abstained(uint tokenId, int256 weight);
    event Deposit(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event Withdraw(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event NotifyReward(address indexed sender, address indexed reward, uint amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint amount);
    event Attach(address indexed owner, address indexed gauge, uint tokenId);
    event Detach(address indexed owner, address indexed gauge, uint tokenId);
    event Whitelisted(address indexed whitelister, address indexed token);

    constructor(address __ve, address _factory, address  _gauges, address _bribes) {
        _ve = __ve;
        factory = _factory;
        base = ve(__ve).token();
        gaugefactory = _gauges;
        bribefactory = _bribes;
        minter = msg.sender;
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() { // 防重入锁
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function initialize(address[] memory _tokens, address _minter) external {
        require(msg.sender == minter);
        for (uint i = 0; i < _tokens.length; i++) {
            _whitelist(_tokens[i]);
        }
        minter = _minter;
    }

    // 将某 token 添加到白名单所需要的上架费 $SOLID 数量
    // 为 $SOLID 流通量的 1/200
    function listing_fee() public view returns (uint) {
        return (erc20(base).totalSupply() - erc20(_ve).totalSupply()) / 200;
    }

    // 取消此 tokenId 的所有投票
    function reset(uint _tokenId) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        _reset(_tokenId);
        ve(_ve).abstain(_tokenId); // 向 ve 表明取消此 tokenId 的投票
    }

    function _reset(uint _tokenId) internal {
        address[] storage _poolVote = poolVote[_tokenId];
        uint _poolVoteCnt = _poolVote.length;
        int256 _totalWeight = 0;

        for (uint i = 0; i < _poolVoteCnt; i ++) {
            address _pool = _poolVote[i];
            int256 _votes = votes[_tokenId][_pool];

            if (_votes != 0) {
                _updateFor(gauges[_pool]);
                weights[_pool] -= _votes;
                votes[_tokenId][_pool] -= _votes;
                if (_votes > 0) {
                    IBribe(bribes[gauges[_pool]])._withdraw(uint256(_votes), _tokenId);
                    _totalWeight += _votes;
                } else {
                    _totalWeight -= _votes;
                }
                emit Abstained(_tokenId, _votes);
            }
        }
        totalWeight -= uint256(_totalWeight);
        usedWeights[_tokenId] = 0;
        delete poolVote[_tokenId];
    }

    // 投票，其实是根据此 tokenId 最新的持有投票权数量情况，把已投的票进行重新整理（每个 pool 的占比不变）
    function poke(uint _tokenId) external {
        address[] memory _poolVote = poolVote[_tokenId];
        uint _poolCnt = _poolVote.length;
        int256[] memory _weights = new int256[](_poolCnt);

        for (uint i = 0; i < _poolCnt; i ++) {
            _weights[i] = votes[_tokenId][_poolVote[i]];
        }

        _vote(_tokenId, _poolVote, _weights);
    }

    function _vote(uint _tokenId, address[] memory _poolVote, int256[] memory _weights) internal {
        _reset(_tokenId); // 先取消此 tokenId 的所有投票
        uint _poolCnt = _poolVote.length;
        int256 _weight = int256(ve(_ve).balanceOfNFT(_tokenId)); // 此 tokenId 拥有的投票权数量
        int256 _totalVoteWeight = 0;
        int256 _totalWeight = 0;
        int256 _usedWeight = 0;

        // 你对你投票的所有 pool 的投票权重的总和
        for (uint i = 0; i < _poolCnt; i++) {
            _totalVoteWeight += _weights[i] > 0 ? _weights[i] : -_weights[i];
        }

        for (uint i = 0; i < _poolCnt; i++) {
            address _pool = _poolVote[i];
            address _gauge = gauges[_pool];

            if (isGauge[_gauge]) {
                // 把你的投票权数量按你对 pool 们的投票权重来分配
                int256 _poolWeight = _weights[i] * _weight / _totalVoteWeight;
                require(votes[_tokenId][_pool] == 0);
                require(_poolWeight != 0); // 对每个 pool 的投票权数量不能为 0
                _updateFor(_gauge);

                poolVote[_tokenId].push(_pool);

                weights[_pool] += _poolWeight; // 若是反对票，则会减少
                votes[_tokenId][_pool] += _poolWeight; // 若是反对票，则会减少
                if (_poolWeight > 0) {
                    IBribe(bribes[_gauge])._deposit(uint256(_poolWeight), _tokenId);
                } else {
                    _poolWeight = -_poolWeight;
                }
                _usedWeight += _poolWeight;
                _totalWeight += _poolWeight;
                emit Voted(msg.sender, _tokenId, _poolWeight);
            }
        }
        if (_usedWeight > 0) ve(_ve).voting(_tokenId); // 向 ve 表明 tokenId 投票了
        totalWeight += uint256(_totalWeight);
        usedWeights[_tokenId] = uint256(_usedWeight);
    }

    // 使用 tokenId 的投票权数量对指定的 pool 们进行投票
    // 这里的 _weights 决定了投票权数量对指定 pool 们的分配比例
    // _weights 中的元素可以是负的，表示投反对票
    function vote(uint tokenId, address[] calldata _poolVote, int256[] calldata _weights) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, tokenId));
        require(_poolVote.length == _weights.length);
        _vote(tokenId, _poolVote, _weights);
    }

    // 将指定 token 合约添加到白名单
    function whitelist(address _token, uint _tokenId) public {
        if (_tokenId > 0) {
            // 若指定了 tokenId，则会看发送者拥有的这个 tokenId 所拥有的投票权数量 > 上架费
            require(msg.sender == ve(_ve).ownerOf(_tokenId));
            require(ve(_ve).balanceOfNFT(_tokenId) > listing_fee());
        } else {
            // 若没有指定 tokenId，则直接从发送者转账上架费到 minter 合约
            _safeTransferFrom(base, msg.sender, minter, listing_fee());
        }

        _whitelist(_token);
    }

    function _whitelist(address _token) internal {
        require(!isWhitelisted[_token]);
        isWhitelisted[_token] = true;
        emit Whitelisted(msg.sender, _token);
    }

    // 为指定的 pool token 合约创建 gauge
    function createGauge(address _pool) external returns (address) {
        require(gauges[_pool] == address(0x0), "exists");
        require(IBaseV1Factory(factory).isPair(_pool), "!_pool");
        (address tokenA, address tokenB) = IBaseV1Core(_pool).tokens();
        require(isWhitelisted[tokenA] && isWhitelisted[tokenB], "!whitelisted"); // pool 的两个 token 必须在白名单里
        address _bribe = IBaseV1BribeFactory(bribefactory).createBribe();
        address _gauge = IBaseV1GaugeFactory(gaugefactory).createGauge(_pool, _bribe, _ve);
        erc20(base).approve(_gauge, type(uint).max);
        bribes[_gauge] = _bribe;
        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;
        isGauge[_gauge] = true;
        _updateFor(_gauge);
        pools.push(_pool);
        emit GaugeCreated(_gauge, msg.sender, _bribe, _pool);
        return _gauge;
    }

    function attachTokenToGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]); // 只能由 gauge 合约调用
        if (tokenId > 0) ve(_ve).attach(tokenId);
        emit Attach(account, msg.sender, tokenId);
    }

    function emitDeposit(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        emit Deposit(account, msg.sender, tokenId, amount);
    }

    function detachTokenFromGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]);
        if (tokenId > 0) ve(_ve).detach(tokenId);
        emit Detach(account, msg.sender, tokenId);
    }

    function emitWithdraw(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        emit Withdraw(account, msg.sender, tokenId, amount);
    }

    function length() external view returns (uint) {
        return pools.length;
    }

    uint internal index; // 每个投票可以获得的奖励（乘以了 1e18）
    mapping(address => uint) internal supplyIndex; // gauge -> gauge's last updated index
    mapping(address => uint) public claimable; // gauge -> claimable amount

    // 由 minter 合约调用把每周的新发射 $SOLID 数量转入此合约
    function notifyRewardAmount(uint amount) external {
        _safeTransferFrom(base, msg.sender, address(this), amount); // transfer the distro in 转账 $SOLID 到此合约
        uint256 _ratio = amount * 1e18 / totalWeight; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index += _ratio;
        }
        emit NotifyReward(msg.sender, base, amount);
    }

    function updateFor(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            _updateFor(_gauges[i]);
        }
    }

    function updateForRange(uint start, uint end) public {
        for (uint i = start; i < end; i++) {
            _updateFor(gauges[pools[i]]);
        }
    }

    function updateAll() external {
        updateForRange(0, pools.length);
    }

    function updateGauge(address _gauge) external {
        _updateFor(_gauge);
    }

    // 更新此 gauge 的可 claim 的 $SOLID 奖励数量
    function _updateFor(address _gauge) internal {
        address _pool = poolForGauge[_gauge];
        int256 _supplied = weights[_pool];
        if (_supplied > 0) {
            uint _supplyIndex = supplyIndex[_gauge];
            uint _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
                uint _share = uint(_supplied) * _delta / 1e18; // add accrued difference for each supplied token
                claimable[_gauge] += _share;
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    function claimRewards(address[] memory _gauges, address[][] memory _tokens) external {
        for (uint i = 0; i < _gauges.length; i++) {
            IGauge(_gauges[i]).getReward(msg.sender, _tokens[i]);
        }
    }

    function claimBribes(address[] memory _bribes, address[][] memory _tokens, uint _tokenId) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint i = 0; i < _bribes.length; i++) {
            IBribe(_bribes[i]).getRewardForOwner(_tokenId, _tokens[i]);
        }
    }

    function claimFees(address[] memory _fees, address[][] memory _tokens, uint _tokenId) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint i = 0; i < _fees.length; i++) {
            IBribe(_fees[i]).getRewardForOwner(_tokenId, _tokens[i]);
        }
    }

    function distributeFees(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            IGauge(_gauges[i]).claimFees();
        }
    }

    function distribute(address _gauge) public lock {
        IMinter(minter).update_period(); // 调用 minter 合约更新计算奖励，并转入到此合约
        _updateFor(_gauge);
        uint _claimable = claimable[_gauge];
        // 可 claim 的数量必须积累到大于 DURATION
        if (_claimable > IGauge(_gauge).left(base) && _claimable / DURATION > 0) {
            claimable[_gauge] = 0;
            IGauge(_gauge).notifyRewardAmount(base, _claimable); // 通知 gauge 分发奖励
            emit DistributeReward(msg.sender, _gauge, _claimable);
        }
    }

    function distro() external {
        distribute(0, pools.length);
    }

    function distribute() external {
        distribute(0, pools.length);
    }

    function distribute(uint start, uint finish) public {
        for (uint x = start; x < finish; x++) {
            distribute(gauges[pools[x]]);
        }
    }

    function distribute(address[] memory _gauges) external {
        for (uint x = 0; x < _gauges.length; x++) {
            distribute(_gauges[x]);
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
