// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "./Pauseable.sol";
import "./MultiStaticCall.sol";
import "./Bullet.sol";
import "./Checker.sol";
import "./Whitelist.sol";

contract WorldBossGame is
    ReentrancyGuardUpgradeable,
    Multicall,
    MultiStaticCall,
    Pauseable,
    Checker,
    Whitelist,
    Bullet,
    AutomationCompatible
{
    struct Config {
        uint256 base_hp;
        uint256 hp_scale_numerator;
        uint256 hp_scale_denominator;
        uint256 lock_lv;
        uint256 lock_percent;
        uint256 lv_reward_percent;
        uint256 prize_percent;
        uint256 attack_cd;
        uint256 escape_cd;
    }

    struct Boss {
        uint256 hp;
        uint256 born_time;
        uint256 attack_time;
        uint256 escape_time;
    }

    struct Level {
        uint256 hp;
        uint256 total_bullet;
        mapping(address => uint256) user_bullet;
        mapping(address => uint256) user_bullet_recycled;
        mapping(address => uint256) user_kill_reward_claimed;
    }

    struct Round {
        uint256 lv;
        uint256 prize;
        Config config;
        uint256[] prize_config;
        address[] prize_users;
        mapping(address => uint256) prize_claimed;
        mapping(uint256 => Level) levels;
    }

    struct RoundLevel {
        uint256 roundId;
        uint256 lv;
    }

    struct LevelDetail {
        uint256 total_bullet;
        uint256 user_bullet;
        uint256 user_damage;
        uint256 recycled_bullet;
        uint256 kill_reward;
    }

    event NewBoss(
        uint256 roundId,
        uint256 lv,
        uint256 hp,
        uint256 born_time,
        uint256 attack_time,
        uint256 escape_time
    );
    event PreAttack(address user, uint256 roundId, uint256 lv, uint256 bullet_mount);
    event Attack(address user, uint256 roundId, uint256 lv, uint256 bullet_mount);
    event Killed(uint256 roundId, uint256 lv, uint256 boss_hp, uint256 total_bullet);
    event Escaped(uint256 roundId, uint256 lv, uint256 boss_hp, uint256 total_bullet);

    event RecycleLevelBullet(address user, uint256 roundId, uint256 lv, uint256 amount);
    event ClaimKillReward(address user, uint256 roundId, uint256 lv, uint256 amount);
    event ClaimPrizeReward(address user, uint256 roundId, uint256 amount);
    event PrizeWinner(uint256 roundId, address[] winners);
    event IncreasePrize(uint256 roundId, address user, uint256 amount);

    uint256 public roundId;
    Config public global_config;
    uint256[] public global_prize_config;
    Boss public boss;
    mapping(uint256 => Round) public rounds;
    mapping(address => RoundLevel) public recycleRoundLevel;
    mapping(address => RoundLevel) public prizeRoundLevel;
    mapping(address => RoundLevel[]) public killRewardRoundLevels;
    mapping(address => mapping(uint256 => uint256[])) public attacked_lvs;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address admin_,
        address system_wallet_,
        address fee_wallet_,
        address token_,
        uint256 fee_
    ) public initializer {
        _initOwnable(owner_, admin_);
        _initBullet(token_, system_wallet_, fee_wallet_, fee_);
    }

    function setConfig(
        uint256 base_hp_,
        uint256 hp_scale_numerator,
        uint256 hp_scale_denominator,
        uint256 lock_lv_,
        uint256 lock_percent_,
        uint256 lv_reward_percent_,
        uint256 prize_percent_,
        uint256 attack_cd,
        uint256 escape_cd,
        uint256[] memory prize_config_
    ) external onlyOwner {
        require(base_hp_ > 0);
        require(hp_scale_numerator > 0);
        require(hp_scale_denominator > 0);
        require(lock_lv_ > 0);
        require(lock_percent_ > 0 && lock_percent_ < Constant.E4);
        require(lv_reward_percent_ > 0 && lv_reward_percent_ < Constant.E4);
        require(prize_percent_ > 0 && prize_percent_ < Constant.E4);
        require(attack_cd > 0);
        require(escape_cd > 0);
        global_config = Config(
            base_hp_,
            hp_scale_numerator,
            hp_scale_denominator,
            lock_lv_,
            lock_percent_,
            lv_reward_percent_,
            prize_percent_,
            attack_cd,
            escape_cd
        );
        uint256 _total;
        for (uint i = 0; i < prize_config_.length; i++) {
            _total += prize_config_[i];
        }
        require(_total == Constant.E4, "The sum of the prize pool shares is not 100%");
        global_prize_config = prize_config_;
    }

    function _cloneConfigToRound() internal {
        Round storage round = rounds[roundId];
        require(round.config.base_hp == 0);
        round.config.base_hp = global_config.base_hp;
        round.config.hp_scale_numerator = global_config.hp_scale_numerator;
        round.config.hp_scale_denominator = global_config.hp_scale_denominator;
        round.config.lock_lv = global_config.lock_lv;
        round.config.lock_percent = global_config.lock_percent;
        round.config.lv_reward_percent = global_config.lv_reward_percent;
        round.config.prize_percent = global_config.prize_percent;
        round.config.attack_cd = global_config.attack_cd;
        round.config.escape_cd = global_config.escape_cd;

        round.prize_config = global_prize_config;
    }

    function startGame() external onlyAdmin whenNotPaused {
        require(global_config.base_hp > 0);
        roundId = 1;
        rounds[roundId].lv = 1;
        _cloneConfigToRound();
        _bornBoss();
    }

    function _increaseHp() internal view returns (uint256 _hp) {
        Config storage _round_config = _roundConfigOf(roundId);
        if (rounds[roundId].lv == 1) {
            _hp = _round_config.base_hp;
        } else {
            _hp = (boss.hp * _round_config.hp_scale_numerator) / _round_config.hp_scale_denominator;
        }
    }

    function _bornBoss() internal {
        Config storage _round_config = _roundConfigOf(roundId);
        uint256 _hp = _increaseHp();
        uint256 _born_time = block.timestamp + Constant.CD - (block.timestamp % Constant.CD);
        uint256 _attack_time = _born_time + _round_config.attack_cd;
        uint256 _escape_time = _attack_time + _round_config.escape_cd;
        boss = Boss(_hp, _born_time, _attack_time, _escape_time);
        rounds[roundId].levels[rounds[roundId].lv].hp = _hp;
        emit NewBoss(
            roundId,
            rounds[roundId].lv,
            boss.hp,
            boss.born_time,
            boss.attack_time,
            boss.escape_time
        );
    }

    function _frozenLevelReward(uint256 roundId_) internal {
        Config storage _round_config = _roundConfigOf(roundId_);
        uint256 _lv_reward = (boss.hp * _round_config.lv_reward_percent) / Constant.E4;
        _addFrozenBullet(_lv_reward);
    }

    function preAttack(
        uint256 roundId_,
        uint256 lv_,
        uint256 bullet_amount_,
        MerkleParam calldata merkleParam
    ) external nonReentrant whenNotPaused onlyEOA onlyWhitlist(merkleParam) {
        require(roundId == roundId_, "invalid roundId_");
        require(rounds[roundId].lv == lv_, "invalid lv_");
        require(block.timestamp > boss.born_time, "boss isn't born yet");
        require(block.timestamp <= boss.attack_time, "invalid time");
        _autoClaim();
        _pushRoundLevel();
        _reduceBullet(msg.sender, bullet_amount_);
        Level storage level = rounds[roundId].levels[lv_];
        level.user_bullet[msg.sender] += bullet_amount_;
        level.total_bullet += bullet_amount_;
        _updatePrizeUser(bullet_amount_);
        emit PreAttack(msg.sender, roundId_, lv_, bullet_amount_);
    }

    function attack(
        uint256 roundId_,
        uint256 lv_,
        uint256 bullet_amount_,
        MerkleParam calldata merkleParam
    ) external nonReentrant whenNotPaused onlyEOA onlyWhitlist(merkleParam) {
        require(roundId == roundId_, "invalid roundId_");
        require(rounds[roundId].lv == lv_, "invalid lv_");
        require(block.timestamp > boss.attack_time, "invalid time");
        require(block.timestamp <= _bossEscapeTime(), "boss escaped");
        Level storage level = rounds[roundId].levels[rounds[roundId].lv];
        require(boss.hp > level.total_bullet, "boss was dead");

        if (bullet_amount_ > boss.hp - level.total_bullet) {
            bullet_amount_ = boss.hp - level.total_bullet;
        }
        _attack(bullet_amount_);
    }

    function decideEscapedOrDead() public nonReentrant whenNotPaused {
        Level storage level = rounds[roundId].levels[rounds[roundId].lv];
        if (boss.hp <= level.total_bullet) {
            require(block.timestamp > boss.attack_time, "invalid time");
            _dead();
        } else {
            require(block.timestamp > _bossEscapeTime(), "invalid time");
            _escape();
        }
    }

    function checkUpkeep(
        bytes calldata /**checkData */
    ) external view override returns (bool upkeepNeeded, bytes memory performData) {
        performData = bytes("");

        if (!isPausing && roundId > 0) {
            Level storage level = rounds[roundId].levels[rounds[roundId].lv];
            if (boss.hp <= level.total_bullet) {
                upkeepNeeded = block.timestamp > boss.attack_time;
            } else {
                upkeepNeeded = block.timestamp > _bossEscapeTime();
            }
        }
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        decideEscapedOrDead();
    }

    /**
     * on boss dead
     */
    function _dead() internal {
        emit Killed(
            roundId,
            rounds[roundId].lv,
            boss.hp,
            rounds[roundId].levels[rounds[roundId].lv].total_bullet
        );
        _frozenLevelReward(roundId);
        _frozenPrizeReward(roundId);
        _nextLevel();
    }

    /**
     * on boss escaped
     */
    function _escape() internal {
        require(block.timestamp > _bossEscapeTime());
        Level storage level = rounds[roundId].levels[rounds[roundId].lv];
        require(boss.hp > level.total_bullet);
        _unfrozenLevelRewardAndClaimBulletToSystem();
        emit Escaped(roundId, rounds[roundId].lv, boss.hp, level.total_bullet);
        emit PrizeWinner(roundId, rounds[roundId].prize_users);
        _nextRound();
    }

    function _attack(uint256 bullet_amount_) internal {
        _autoClaim();
        _pushRoundLevel();
        _reduceBullet(msg.sender, bullet_amount_);
        Level storage level = rounds[roundId].levels[rounds[roundId].lv];
        level.user_bullet[msg.sender] += bullet_amount_;
        level.total_bullet += bullet_amount_;
        _updatePrizeUser(bullet_amount_);
        emit Attack(msg.sender, roundId, rounds[roundId].lv, bullet_amount_);
        if (level.total_bullet >= boss.hp) {
            _dead();
        }
    }

    function _pushRoundLevel() internal {
        if (rounds[roundId].levels[rounds[roundId].lv].user_bullet[msg.sender] > 0) return;
        attacked_lvs[msg.sender][roundId].push(rounds[roundId].lv);
        recycleRoundLevel[msg.sender] = RoundLevel(roundId, rounds[roundId].lv);
        prizeRoundLevel[msg.sender] = RoundLevel(roundId, rounds[roundId].lv);
        killRewardRoundLevels[msg.sender].push(RoundLevel(roundId, rounds[roundId].lv));
    }

    function autoClaim() external nonReentrant whenNotPaused onlyEOA {
        _autoClaim();
    }

    function _autoClaim() internal {
        if (canRecycleLevelBullet(msg.sender)) {
            _recycleLevelBullet();
        }

        if (canClaimPrizeReward(msg.sender)) {
            _claimPrizeReward();
        }

        RoundLevel[] memory kr_lvs = killRewardRoundLevels[msg.sender];
        for (uint i = 0; i < kr_lvs.length; i++) {
            if (canClaimKillReward(kr_lvs[i].roundId, kr_lvs[i].lv, msg.sender)) {
                _claimKillReward(kr_lvs[i].roundId, kr_lvs[i].lv);
            } else {
                if (roundId > kr_lvs[i].roundId) {
                    _removeFromKillRewardRoundLevel(kr_lvs[i].roundId, kr_lvs[i].lv);
                }
            }
        }
    }

    function claimableRewardOf(address user) public view returns (uint256 total_reward) {
        total_reward = 0;
        if (canRecycleLevelBullet(user)) {
            (, , uint256 recycled_total, ) = levelBulletOf(
                recycleRoundLevel[user].roundId,
                recycleRoundLevel[user].lv,
                user
            );
            total_reward += recycled_total;
        }

        if (canClaimPrizeReward(user)) {
            uint256 prize_reward = userPrizeRewardOf(prizeRoundLevel[user].roundId, user);
            total_reward += prize_reward;
        }

        RoundLevel[] storage _lvs = killRewardRoundLevels[user];
        for (uint i = 0; i < _lvs.length; i++) {
            if (canClaimKillReward(_lvs[i].roundId, _lvs[i].lv, user)) {
                uint256 kill_reward = killRewardOf(_lvs[i].roundId, _lvs[i].lv, user);
                total_reward += kill_reward;
            }
        }
    }

    function bulletAndClaimableOf(
        address user
    ) public view returns (uint256 bullet_, uint256 claimable_) {
        bullet_ = bulletOf(user);
        claimable_ = claimableRewardOf(user);
    }

    function _frozenPrizeReward(uint256 roundId_) internal {
        Config storage _round_config = _roundConfigOf(roundId_);
        uint256 _add_prize = (boss.hp * _round_config.prize_percent) / Constant.E4;
        rounds[roundId].prize += _add_prize;
        _addFrozenBullet(_add_prize);
    }

    function _nextLevel() internal {
        delete rounds[roundId].prize_users;
        rounds[roundId].lv++;
        _bornBoss();
    }

    //--------------------------------------------------

    function recycleLevelBullet() public nonReentrant whenNotPaused onlyEOA {
        require(canRecycleLevelBullet(msg.sender), "Error");
        _recycleLevelBullet();
    }

    function canRecycleLevelBullet(address user) public view returns (bool) {
        // if (recycleRoundLevel[user].roundId == 0 || recycleRoundLevel[user].lv == 0) return false;
        uint256 roundId_ = recycleRoundLevel[user].roundId;
        uint256 lv_ = recycleRoundLevel[user].lv;
        if (rounds[roundId_].lv == lv_) return false;
        Level storage level = rounds[roundId_].levels[lv_];
        if (level.user_bullet[user] == 0) return false;
        if (level.user_bullet_recycled[user] > 0) return false;
        return true;
    }

    function levelBulletOf(
        uint256 roundId_,
        uint256 lv_,
        address user_
    )
        public
        view
        returns (
            uint256 recycled_bullet,
            uint256 unused_bullet,
            uint256 recycled_total,
            uint256 user_bullet
        )
    {
        Level storage level = rounds[roundId_].levels[lv_];
        Config storage _round_config = _roundConfigOf(roundId_);
        uint256 _hp = _bossHpOf(roundId_, lv_);
        user_bullet = level.user_bullet[user_];
        if (level.total_bullet >= _hp) {
            uint256 _damage = (_hp * user_bullet) / level.total_bullet;
            if (user_bullet > _damage) unused_bullet = user_bullet - _damage;
            recycled_bullet = (_damage * (Constant.E4 - _round_config.lock_percent)) / Constant.E4;
            recycled_total = unused_bullet + recycled_bullet;
        }
    }

    function _recycleLevelBullet() internal {
        uint256 roundId_ = recycleRoundLevel[msg.sender].roundId;
        uint256 lv_ = recycleRoundLevel[msg.sender].lv;
        Level storage level = rounds[roundId_].levels[lv_];
        (, , uint256 total, ) = levelBulletOf(roundId_, lv_, msg.sender);
        level.user_bullet_recycled[msg.sender] = total;
        _addBullet(msg.sender, total);
        emit RecycleLevelBullet(msg.sender, roundId_, lv_, total);
    }

    //--------------------------------------------------

    function claimKillReward(
        uint256 roundId_,
        uint256 lv_
    ) public nonReentrant whenNotPaused onlyEOA {
        require(canClaimKillReward(roundId_, lv_, msg.sender), "Error");
        _claimKillReward(roundId_, lv_);
    }

    function canClaimKillReward(
        uint256 roundId_,
        uint256 lv_,
        address user
    ) public view returns (bool) {
        Config storage _round_config = _roundConfigOf(roundId_);
        if (rounds[roundId_].lv <= lv_ + _round_config.lock_lv) return false;
        Level storage level = rounds[roundId_].levels[lv_];
        if (level.user_bullet[user] == 0) return false;
        if (level.user_kill_reward_claimed[user] > 0) return false;
        return true;
    }

    function killRewardOf(
        uint256 roundId_,
        uint256 lv_,
        address user_
    ) public view returns (uint256 total_reward) {
        Config storage _round_config = _roundConfigOf(roundId_);
        require(rounds[roundId_].lv > lv_ + _round_config.lock_lv);
        Level storage level = rounds[roundId_].levels[lv_];
        require(level.user_bullet[user_] > 0, "0 bullet");
        require(level.user_kill_reward_claimed[user_] == 0, "claimed already");
        uint256 _boss_hp = _bossHpOf(roundId_, lv_);
        uint256 _damage = (_boss_hp * level.user_bullet[user_]) / level.total_bullet;
        total_reward =
            (_damage * (_round_config.lock_percent + _round_config.lv_reward_percent)) /
            Constant.E4;
    }

    function _claimKillReward(uint256 roundId_, uint256 lv_) internal {
        uint256 total_reward = killRewardOf(roundId_, lv_, msg.sender);
        Level storage level = rounds[roundId_].levels[lv_];
        level.user_kill_reward_claimed[msg.sender] = total_reward;
        _addBullet(msg.sender, total_reward);
        emit ClaimKillReward(msg.sender, roundId_, lv_, total_reward);
        _removeFromKillRewardRoundLevel(roundId_, lv_);
    }

    function _removeFromKillRewardRoundLevel(uint256 roundId_, uint256 lv_) internal {
        uint256 index = 0;
        bool _to_remove = false;
        RoundLevel[] storage _lvs = killRewardRoundLevels[msg.sender];
        for (uint i = 0; i < _lvs.length; i++) {
            if (_lvs[i].roundId == roundId_ && _lvs[i].lv == lv_) {
                index = i;
                _to_remove = true;
            }
        }
        if (_to_remove) {
            _lvs[index] = _lvs[_lvs.length - 1];
            _lvs.pop();
        }
    }

    function levelInfoOf(
        uint256 roundId_,
        uint256 lv_
    ) public view returns (uint256 boss_hp, uint256 _total_bullet) {
        Level storage level = rounds[roundId_].levels[lv_];
        boss_hp = level.hp;
        _total_bullet = level.total_bullet;
    }

    function levelDetailOf(
        uint256 roundId_,
        uint256 lv_,
        address user_
    ) public view returns (LevelDetail memory detail) {
        uint256 recycled_bullet;
        uint256 unused_bullet;
        uint256 recycled_total;
        uint256 user_bullet;
        if (roundId_ > roundId || lv_ > rounds[roundId_].lv) {
            detail = LevelDetail(0, 0, 0, 0, 0);
        } else {
            Level storage level = rounds[roundId_].levels[lv_];
            Config storage _round_config = _roundConfigOf(roundId_);
            uint256 _hp = _bossHpOf(roundId_, lv_);
            user_bullet = level.user_bullet[user_];
            if (_hp <= level.total_bullet) {
                uint256 _damage = (_hp * user_bullet) / level.total_bullet;
                if (user_bullet > _damage) unused_bullet = user_bullet - _damage;
                recycled_bullet =
                    (_damage * (Constant.E4 - _round_config.lock_percent)) /
                    Constant.E4;
                recycled_total = unused_bullet + recycled_bullet;
                uint256 kill_reward = (_damage *
                    (_round_config.lock_percent + _round_config.lv_reward_percent)) / Constant.E4;

                detail = LevelDetail(
                    level.total_bullet,
                    user_bullet,
                    _damage,
                    recycled_total,
                    kill_reward
                );
            } else {
                detail = LevelDetail(level.total_bullet, user_bullet, 0, 0, 0);
            }
        }
    }

    function levelDetailListOf(
        uint256 roundId_,
        address user
    ) public view returns (uint256[] memory lvs, LevelDetail[] memory list) {
        lvs = attacked_lvs[user][roundId_];
        list = new LevelDetail[](lvs.length);
        for (uint i = 0; i < lvs.length; i++) {
            list[i] = levelDetailOf(roundId_, lvs[i], user);
        }
    }

    function _bossHpOf(uint256 roundId_, uint256 lv_) internal view returns (uint256) {
        return rounds[roundId_].levels[lv_].hp;
    }

    function _bossEscapeTime() internal view returns (uint256) {
        if (isPausing) return type(uint256).max;

        if (pauseTime > boss.born_time) {
            return boss.escape_time + _pauseDuration;
        } else {
            return boss.escape_time;
        }
    }

    function _roundConfigOf(uint256 roundId_) internal view returns (Config storage) {
        return rounds[roundId_].config;
    }

    function _unfrozenLevelRewardAndClaimBulletToSystem() internal {
        uint256 _lastLv = rounds[roundId].lv;
        Config storage _round_config = _roundConfigOf(roundId);
        for (uint i = 1; i <= _round_config.lock_lv; i++) {
            if (_lastLv > i) {
                uint256 _lv = _lastLv - i;
                uint256 _boss_hp = _bossHpOf(roundId, _lv);
                // //unfrozen level reward
                uint256 _lv_reward = (_boss_hp * _round_config.lv_reward_percent) / Constant.E4;
                _reduceFrozenBullet(_lv_reward);
                //claim locked bullet to system
                _addSystemBullet(_boss_hp * _round_config.lock_percent);
            } else {
                break;
            }
        }
    }

    function _nextRound() internal {
        roundId++;
        rounds[roundId].lv = 1;
        _cloneConfigToRound();
        _bornBoss();
        rounds[roundId].prize = _leftPrizeRewardOf(roundId - 1);
    }

    function canClaimPrizeReward(address user) public view returns (bool) {
        uint256 roundId_ = prizeRoundLevel[user].roundId;
        uint256 lv_ = prizeRoundLevel[user].lv;

        if (roundId == roundId_) return false;
        if (rounds[roundId_].lv != lv_) return false;

        Round storage round = rounds[roundId_];
        if (round.prize_claimed[user] > 0) return false;

        Level storage level = round.levels[lv_];
        if (level.user_bullet[user] == 0) return false;

        return true;
    }

    /**
     * prize + user_bullet
     */
    function userPrizeRewardOf(
        uint256 roundId_,
        address user
    ) public view returns (uint256 reward) {
        if (roundId_ == roundId) reward = 0;
        Round storage round = rounds[roundId_];
        address[] storage prize_users = round.prize_users;
        uint256[] storage prize_config = round.prize_config;
        uint256 offset = prize_config.length - prize_users.length;
        for (uint256 i = 0; i < prize_users.length; i++) {
            if (user == prize_users[i]) {
                reward += (round.prize * prize_config[i + offset]) / Constant.E4;
            }
        }

        Level storage level = round.levels[round.lv];
        reward += level.user_bullet[user];
    }

    function prizeWinnersOf(
        uint256 roundId_
    ) public view returns (address[] memory users, uint256 prize) {
        Round storage round = rounds[roundId_];
        address[] storage prize_users = round.prize_users;
        users = prize_users;
        prize = round.prize;
    }

    function _leftPrizeRewardOf(uint256 roundId_) internal view returns (uint256 left) {
        require(roundId_ < roundId);
        Round storage round = rounds[roundId_];
        address[] storage prize_users = round.prize_users;
        uint256[] storage prize_config = round.prize_config;
        uint256 length = prize_config.length - prize_users.length;
        uint256 _left_percent;
        for (uint256 i = 0; i < length; i++) {
            _left_percent += prize_config[i];
        }
        left = (round.prize * _left_percent) / Constant.E4;
    }

    /**
     * Claim the prize and recover all bullets of the last level
     */
    function claimPrizeReward() public nonReentrant whenNotPaused onlyEOA {
        require(canClaimPrizeReward(msg.sender), "Error");
        _claimPrizeReward();
    }

    function _claimPrizeReward() internal {
        uint256 roundId_ = prizeRoundLevel[msg.sender].roundId;
        Round storage round = rounds[roundId_];
        uint256 _reward = userPrizeRewardOf(roundId_, msg.sender);
        round.prize_claimed[msg.sender] = _reward;
        _addBullet(msg.sender, _reward);
        emit ClaimPrizeReward(msg.sender, roundId_, _reward);
    }

    function increasePrize(uint256 amount) external payable nonReentrant whenNotPaused {
        require(roundId > 0, "game don't start");
        if (token == address(0)) {
            require(amount == msg.value, "invalid msg.value");
        } else {
            require(0 == msg.value, "invalid msg.value");
            SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        }
        rounds[roundId].prize += amount;
        emit IncreasePrize(roundId, msg.sender, amount);
    }

    function _updatePrizeUser(uint256 bullet_) internal {
        Round storage round = rounds[roundId];
        // Level storage level = round.levels[rounds[roundId].lv];
        // if (level.total_bullet >= boss.hp) return;
        if (block.timestamp + Constant.PRIZE_BLACK_TIME > _bossEscapeTime()) return;

        if (bullet_ >= boss.hp / 100) {
            address[] storage prize_users = round.prize_users;
            if (prize_users.length < round.prize_config.length) {
                prize_users.push(msg.sender);
            } else {
                for (uint i = 1; i < prize_users.length; i++) {
                    prize_users[i - 1] = prize_users[i];
                }
                prize_users[prize_users.length - 1] = msg.sender;
            }
            require(prize_users.length <= round.prize_config.length);
        }
    }

    function _beforeWithdraw() internal override {
        _autoClaim();
    }

    function levelOf(
        uint256 roundId_,
        uint256 lv_,
        address user_
    ) public view returns (uint256 total_bullet, uint256 user_bullet) {
        total_bullet = rounds[roundId_].levels[lv_].total_bullet;
        user_bullet = rounds[roundId_].levels[lv_].user_bullet[user_];
    }

    function theLastLevel() public view returns (uint256 roundId_, uint256 lv_) {
        roundId_ = roundId;
        lv_ = rounds[roundId].lv;
    }

    uint256[64] private __gap;
}
