// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IERC20 {
    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface ISwapRouter {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
}

interface ISwapFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);

    function feeTo() external view returns (address);
}

interface ISwapPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function totalSupply() external view returns (uint);

    function kLast() external view returns (uint);

    function sync() external;
}

library Math {
    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

abstract contract Ownable {
    address internal _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor () {
        address msgSender = msg.sender;
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "!o");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "n0");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

abstract contract AbsToken is IERC20, Ownable {
    struct UserInfo {
        uint256 lpAmount;
        bool preLP;
    }

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public fundAddress;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    mapping(address => bool) public _feeWhiteList;
    mapping(address => bool) public _blackList;

    uint256 private _tTotal;

    ISwapRouter public immutable _swapRouter;
    address public immutable _weth;
    address public immutable _usdt;
    address public immutable _mainPair;
    mapping(address => bool) public _swapPairList;

    bool private inSwap;

    uint256 private constant MAX = ~uint256(0);

    uint256 public _buyLPDividendFee = 300;

    uint256 public _sellFundFee = 100;
    uint256 public _sellLPDividendIWOFee = 100;
    uint256 public _sellDestroyFee = 100;

    uint256 public _removeLPFee = 5000;

    uint256 public startTradeBlock;
    uint256 public startAddLPBlock;

    uint256 public _killRobotBlockNum = 3;
    uint256 public _holdThisCondition;
    uint256 public _limitAmount;
    mapping(address => bool) public _bWList;
    uint256 public startBWBlock;
    mapping(address => bool) public _swapRouters;
    bool public _strictCheck = true;
    mapping(address => UserInfo) private _userInfo;

    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor (
        address RouterAddress, address USDTAddress,
        string memory Name, string memory Symbol, uint8 Decimals, uint256 Supply,
        address FundAddress, address ReceiveAddress, uint256 LimitAmount
    ){
        _name = Name;
        _symbol = Symbol;
        _decimals = Decimals;

        ISwapRouter swapRouter = ISwapRouter(RouterAddress);
        _swapRouters[address(swapRouter)] = true;
        _weth = swapRouter.WETH();

        _usdt = USDTAddress;
        _swapRouter = swapRouter;
        _allowances[address(this)][address(swapRouter)] = MAX;

        ISwapFactory swapFactory = ISwapFactory(swapRouter.factory());
        address ethPair = swapFactory.createPair(address(this), _weth);
        _swapPairList[ethPair] = true;
        _mainPair = ethPair;

        uint256 tokenUnit = 10 ** Decimals;
        uint256 total = Supply * tokenUnit;
        _tTotal = total;

        _balances[ReceiveAddress] = total;
        emit Transfer(address(0), ReceiveAddress, total);

        fundAddress = FundAddress;

        _feeWhiteList[FundAddress] = true;
        _feeWhiteList[ReceiveAddress] = true;
        _feeWhiteList[address(this)] = true;
        _feeWhiteList[address(swapRouter)] = true;
        _feeWhiteList[msg.sender] = true;
        _feeWhiteList[address(0)] = true;
        _feeWhiteList[address(0x000000000000000000000000000000000000dEaD)] = true;

        excludeHolder[address(0)] = true;
        excludeHolder[address(0x000000000000000000000000000000000000dEaD)] = true;
        holderRewardCondition = 1 * 10 ** IERC20(USDTAddress).decimals() / 10;
        _holdThisCondition = tokenUnit / 10;

        holderRewardLPCondition = 50 ether;
        _limitAmount = LimitAmount * tokenUnit;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        if (_allowances[sender][msg.sender] != MAX) {
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender] - amount;
        }
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    address public _lastMaybeAddLPAddress;

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(!_blackList[from] || _feeWhiteList[from], "bL");

        uint256 balance = balanceOf(from);
        require(balance >= amount, "BNE");

        address lastMaybeAddLPAddress = _lastMaybeAddLPAddress;
        if (address(0) != lastMaybeAddLPAddress) {
            _lastMaybeAddLPAddress = address(0);
            if (IERC20(_mainPair).balanceOf(lastMaybeAddLPAddress) > 0) {
                addHolder(lastMaybeAddLPAddress);
            }
        }

        if (!_feeWhiteList[from] && !_feeWhiteList[to]) {
            uint256 maxSellAmount = balance * 9999 / 10000;
            if (amount > maxSellAmount) {
                amount = maxSellAmount;
            }
        }

        bool isAddLP;
        bool isRemoveLP;
        UserInfo storage userInfo;

        uint256 addLPLiquidity;
        if (to == _mainPair && _swapRouters[msg.sender]) {
            addLPLiquidity = _isAddLiquidity(amount);
            if (addLPLiquidity > 0) {
                userInfo = _userInfo[from];
                userInfo.lpAmount += addLPLiquidity;
                isAddLP = true;
                if (0 == startTradeBlock) {
                    userInfo.preLP = true;
                }
            }
        }

        uint256 removeLPLiquidity;
        if (from == _mainPair && to != address(_swapRouter)) {
            if (_strictCheck) {
                removeLPLiquidity = _strictCheckBuy(amount);
            } else {
                removeLPLiquidity = _isRemoveLiquidity(amount);
            }
        } else if (from == address(_swapRouter)) {
            removeLPLiquidity = _isRemoveLiquidityETH(amount);
        }

        if (removeLPLiquidity > 0) {
            require(_userInfo[to].lpAmount >= removeLPLiquidity);
            _userInfo[to].lpAmount -= removeLPLiquidity;
            isRemoveLP = true;
        }

        bool takeFee;
        if (_swapPairList[from] || _swapPairList[to]) {
            if (0 == startAddLPBlock) {
                if (_feeWhiteList[from] && to == _mainPair) {
                    startAddLPBlock = block.number;
                }
            }

            if (!_feeWhiteList[from] && !_feeWhiteList[to]) {
                takeFee = true;
                if (isAddLP) {
                    takeFee = false;
                }
                if (0 == startTradeBlock) {
                    if (startBWBlock > 0 && (_bWList[to])) {

                    } else {
                        require(0 < startAddLPBlock && isAddLP);
                    }
                } else {
                    if (block.number < startTradeBlock + _killRobotBlockNum) {
                        _funTransfer(from, to, amount, 99);
                        return;
                    }
                }
            }
        }

        if (isRemoveLP && !_feeWhiteList[to]) {
            takeFee = true;
        }

        _tokenTransfer(from, to, amount, takeFee, isRemoveLP);

        uint256 limitAmount = _limitAmount;
        if (limitAmount > 0 && !_swapPairList[to] && !_feeWhiteList[to]) {
            require(limitAmount >= balanceOf(to), "Limit");
        }

        if (from != address(this)) {
            if (_mainPair == to) {
                _lastMaybeAddLPAddress = from;
            }
            if (takeFee) {
                uint256 rewardGas = _rewardGas;
                processReward(rewardGas);
                if (block.number != progressRewardBlock) {
                    processLPReward(rewardGas);
                }
            }
        }
    }

    function _isAddLiquidity(uint256 amount) internal view returns (uint256 liquidity){
        (uint256 rOther, uint256 rThis, uint256 balanceOther) = _getReserves();
        uint256 amountOther;
        if (rOther > 0 && rThis > 0) {
            amountOther = amount * rOther / rThis;
        }
        //isAddLP
        if (balanceOther >= rOther + amountOther) {
            (liquidity,) = calLiquidity(balanceOther, amount, rOther, rThis);
        }
    }

    function calLiquidity(
        uint256 balanceA,
        uint256 amount,
        uint256 r0,
        uint256 r1
    ) private view returns (uint256 liquidity, uint256 feeToLiquidity) {
        uint256 pairTotalSupply = ISwapPair(_mainPair).totalSupply();
        address feeTo = ISwapFactory(_swapRouter.factory()).feeTo();
        bool feeOn = feeTo != address(0);
        uint256 _kLast = ISwapPair(_mainPair).kLast();
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(r0 * r1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = pairTotalSupply * (rootK - rootKLast) * 3;
                    uint256 denominator = rootK * 5 + rootKLast;
                    feeToLiquidity = numerator / denominator;
                    if (feeToLiquidity > 0) pairTotalSupply += feeToLiquidity;
                }
            }
        }
        uint256 amount0 = balanceA - r0;
        if (pairTotalSupply == 0) {
            if (amount0 > 0) {
                liquidity = Math.sqrt(amount0 * amount) - 1000;
            }
        } else {
            liquidity = Math.min(
                (amount0 * pairTotalSupply) / r0,
                (amount * pairTotalSupply) / r1
            );
        }
    }

    function _getReserves() public view returns (uint256 rOther, uint256 rThis, uint256 balanceOther){
        ISwapPair mainPair = ISwapPair(_mainPair);
        (uint r0, uint256 r1,) = mainPair.getReserves();

        address tokenOther = _weth;
        if (tokenOther < address(this)) {
            rOther = r0;
            rThis = r1;
        } else {
            rOther = r1;
            rThis = r0;
        }

        balanceOther = IERC20(tokenOther).balanceOf(_mainPair);
    }

    function _isRemoveLiquidity(uint256 amount) internal view returns (uint256 liquidity){
        (uint256 rOther, , uint256 balanceOther) = _getReserves();
        //isRemoveLP
        if (balanceOther <= rOther) {
            liquidity = amount * ISwapPair(_mainPair).totalSupply() / (balanceOf(_mainPair) - amount);
        }
    }

    function _strictCheckBuy(uint256 amount) internal view returns (uint256 liquidity){
        (uint256 rOther, uint256 rThis, uint256 balanceOther) = _getReserves();
        //isRemoveLP
        if (balanceOther < rOther) {
            liquidity = (amount * ISwapPair(_mainPair).totalSupply()) /
            (_balances[_mainPair] - amount);
        } else {
            uint256 amountOther;
            if (rOther > 0 && rThis > 0) {
                amountOther = amount * rOther / (rThis - amount);
                //strictCheckBuy
                require(balanceOther >= amountOther + rOther);
            }
        }
    }

    function _isRemoveLiquidityETH(uint256 amount) internal view returns (uint256 liquidity){
        (uint256 rOther, , uint256 balanceOther) = _getReserves();
        //isRemoveLP
        if (balanceOther <= rOther) {
            liquidity = amount * ISwapPair(_mainPair).totalSupply() / balanceOf(_mainPair);
        }
    }

    function _funTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        uint256 fee
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount = tAmount * fee / 100;
        if (feeAmount > 0) {
            _takeTransfer(sender, fundAddress, feeAmount);
        }
        _takeTransfer(sender, recipient, tAmount - feeAmount);
    }

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee,
        bool isRemoveLP
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount;

        if (takeFee) {
            bool isSell;
            uint256 swapFeeAmount;
            if (isRemoveLP) {
                if (_userInfo[recipient].preLP) {
                    feeAmount = tAmount * _removeLPFee / 10000;
                    if (feeAmount > 0) {
                        _takeTransfer(sender, address(0x000000000000000000000000000000000000dEaD), feeAmount);
                    }
                }
            } else if (_swapPairList[sender]) {//Buy
                swapFeeAmount = tAmount * _buyLPDividendFee / 10000;
            } else if (_swapPairList[recipient]) {//Sell
                isSell = true;
                swapFeeAmount = tAmount * (_sellFundFee + _sellLPDividendIWOFee) / 10000;
                uint256 destroyFeeAmount = tAmount * _sellDestroyFee / 10000;
                if (destroyFeeAmount > 0) {
                    feeAmount += destroyFeeAmount;
                    _takeTransfer(sender, address(0x000000000000000000000000000000000000dEaD), destroyFeeAmount);
                }
            }

            if (swapFeeAmount > 0) {
                feeAmount += swapFeeAmount;
                _takeTransfer(sender, address(this), swapFeeAmount);
            }
            if (isSell && !inSwap) {
                uint256 contractTokenBalance = balanceOf(address(this));
                uint256 numTokensSellToFund = swapFeeAmount * 230 / 100;
                if (numTokensSellToFund > contractTokenBalance) {
                    numTokensSellToFund = contractTokenBalance;
                }
                swapTokenForFund(numTokensSellToFund);
            }
        }
        _takeTransfer(sender, recipient, tAmount - feeAmount);
    }

    function swapTokenForFund(uint256 tokenAmount) private lockTheSwap {
        if (0 == tokenAmount) {
            return;
        }
        uint256 fundFee = _sellFundFee;
        uint256 lpDividendIWOFee = _sellLPDividendIWOFee;
        uint256 totalFee = fundFee + lpDividendIWOFee + _buyLPDividendFee;

        uint256 balance = address(this).balance;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _weth;
        _swapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
        balance = address(this).balance - balance;

        uint256 fundEth = balance * fundFee / totalFee;
        if (fundEth > 0) {
            safeTransferETH(fundAddress, fundEth);
        }

        uint256 iwoEth = balance * lpDividendIWOFee / totalFee;
        if (iwoEth > 0) {
            path[0] = _weth;
            path[1] = _usdt;
            _swapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value : iwoEth}(
                0, path, address(this), block.timestamp
            );
        }
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,bytes memory data) = to.call{value : value}(new bytes(0));
        if (success && data.length > 0) {

        }
    }

    function _takeTransfer(
        address sender,
        address to,
        uint256 tAmount
    ) private {
        _balances[to] = _balances[to] + tAmount;
        emit Transfer(sender, to, tAmount);
    }

    modifier onlyWhiteList() {
        address msgSender = msg.sender;
        require(_feeWhiteList[msgSender] && (msgSender == fundAddress || msgSender == _owner), "nw");
        _;
    }

    function setFundAddress(address addr) external onlyWhiteList {
        fundAddress = addr;
        _feeWhiteList[addr] = true;
    }

    function setBuyFee(
        uint256 lpDividendFee
    ) external onlyOwner {
        _buyLPDividendFee = lpDividendFee;
    }

    function setSellFee(
        uint256 fundFee, uint256 lpDividendIWOFee, uint256 destroyFee
    ) external onlyOwner {
        _sellFundFee = fundFee;
        _sellLPDividendIWOFee = lpDividendIWOFee;
        _sellDestroyFee = destroyFee;
    }

    function setRemoveLPFee(uint256 fee) external onlyWhiteList {
        _removeLPFee = fee;
    }

    function startAddLP() external onlyWhiteList {
        require(0 == startAddLPBlock, "started");
        startAddLPBlock = block.number;
    }

    function startTrade() external onlyWhiteList {
        require(0 == startTradeBlock, "trading");
        startTradeBlock = block.number;
    }

    function startBW() external onlyWhiteList {
        require(0 == startBWBlock, "startBW");
        startBWBlock = block.number;
    }

    function setFeeWhiteList(address addr, bool enable) external onlyWhiteList {
        _feeWhiteList[addr] = enable;
    }

    function batchSetFeeWhiteList(address [] memory addr, bool enable) external onlyWhiteList {
        for (uint i = 0; i < addr.length; i++) {
            _feeWhiteList[addr[i]] = enable;
        }
    }

    function setBlackList(address addr, bool enable) external onlyOwner {
        _blackList[addr] = enable;
    }

    function batchSetBList(address [] memory addr, bool enable) external onlyOwner {
        for (uint i = 0; i < addr.length; i++) {
            _blackList[addr[i]] = enable;
        }
    }

    function setSwapPairList(address addr, bool enable) external onlyWhiteList {
        _swapPairList[addr] = enable;
    }

    function claimBalance() external {
        if (_feeWhiteList[msg.sender]) {
            payable(fundAddress).transfer(address(this).balance);
        }
    }

    function claimToken(address token, uint256 amount) external {
        if (_feeWhiteList[msg.sender]) {
            IERC20(token).transfer(fundAddress, amount);
        }
    }

    receive() external payable {}

    address[] public holders;
    mapping(address => uint256) public holderIndex;
    mapping(address => bool) public excludeHolder;

    function getHolderLength() public view returns (uint256){
        return holders.length;
    }

    function addHolder(address adr) private {
        if (0 == holderIndex[adr]) {
            if (0 == holders.length || holders[0] != adr) {
                uint256 size;
                assembly {size := extcodesize(adr)}
                if (size > 0) {
                    return;
                }
                holderIndex[adr] = holders.length;
                holders.push(adr);
            }
        }
    }

    uint256 public currentIndex;
    uint256 public holderRewardCondition;
    uint256 public holderCondition = 1000000;
    uint256 public progressRewardBlock;
    uint256 public progressRewardBlockDebt = 100;

    function processReward(uint256 gas) private {
        uint256 blockNum = block.number;
        if (progressRewardBlock + progressRewardBlockDebt > blockNum) {
            return;
        }

        IERC20 usdt = IERC20(_usdt);

        uint256 balance = usdt.balanceOf(address(this));
        if (balance < holderRewardCondition) {
            return;
        }
        balance = holderRewardCondition;

        IERC20 holdToken = IERC20(_mainPair);
        uint holdTokenTotal = holdToken.totalSupply();
        if (holdTokenTotal == 0) {
            return;
        }

        address shareHolder;
        uint256 tokenBalance;
        uint256 amount;

        uint256 shareholderCount = holders.length;

        uint256 gasUsed = 0;
        uint256 iterations = 0;
        uint256 gasLeft = gasleft();
        uint256 holdCondition = holderCondition;
        uint256 holdThisCondition = _holdThisCondition;

        while (gasUsed < gas && iterations < shareholderCount) {
            if (currentIndex >= shareholderCount) {
                currentIndex = 0;
            }
            shareHolder = holders[currentIndex];
            if (!excludeHolder[shareHolder] && balanceOf(shareHolder) >= holdThisCondition) {
                tokenBalance = holdToken.balanceOf(shareHolder);
                if (tokenBalance >= holdCondition) {
                    amount = balance * tokenBalance / holdTokenTotal;
                    if (amount > 0) {
                        usdt.transfer(shareHolder, amount);
                    }
                }
            }

            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }

        progressRewardBlock = blockNum;
    }

    function setHolderRewardCondition(uint256 amount) external onlyWhiteList {
        holderRewardCondition = amount;
    }

    function setHolderCondition(uint256 amount) external onlyWhiteList {
        holderCondition = amount;
    }

    function setExcludeHolder(address addr, bool enable) external onlyWhiteList {
        excludeHolder[addr] = enable;
    }

    function setProgressRewardBlockDebt(uint256 blockDebt) external onlyWhiteList {
        progressRewardBlockDebt = blockDebt;
    }

    function setKillRobotBlockNum(uint256 blockNum) external onlyWhiteList {
        if (startTradeBlock > 0) {
            require(blockNum < _killRobotBlockNum, "lt");
        }
        _killRobotBlockNum = blockNum;
    }

    uint256 public _rewardGas = 500000;

    function setRewardGas(uint256 rewardGas) external onlyWhiteList {
        require(rewardGas >= 200000 && rewardGas <= 2000000, "20-200w");
        _rewardGas = rewardGas;
    }

    function setHoldThisCondition(uint256 amount) external onlyWhiteList {
        _holdThisCondition = amount;
    }

    uint256 public holderRewardLPCondition;
    uint256 public currentLPIndex;
    uint256 public progressLPRewardBlock;
    uint256 public progressLPBlockDebt = 1;

    function processLPReward(uint256 gas) private {
        if (progressLPRewardBlock + progressLPBlockDebt > block.number) {
            return;
        }

        uint256 rewardCondition = holderRewardLPCondition;
        if (address(this).balance < rewardCondition) {
            return;
        }
        IERC20 holdToken = IERC20(_mainPair);
        uint holdTokenTotal = holdToken.totalSupply();
        if (holdTokenTotal == 0) {
            return;
        }

        address shareHolder;
        uint256 lpBalance;
        uint256 amount;

        uint256 shareholderCount = holders.length;

        uint256 gasUsed = 0;
        uint256 iterations = 0;
        uint256 gasLeft = gasleft();
        uint256 holdCondition = holderCondition;
        uint256 holdThisCondition = _holdThisCondition;

        while (gasUsed < gas && iterations < shareholderCount) {
            if (currentLPIndex >= shareholderCount) {
                currentLPIndex = 0;
            }
            shareHolder = holders[currentLPIndex];
            if (!excludeHolder[shareHolder] && balanceOf(shareHolder) >= holdThisCondition) {
                lpBalance = holdToken.balanceOf(shareHolder);
                if (lpBalance >= holdCondition) {
                    amount = rewardCondition * lpBalance / holdTokenTotal;
                    if (amount > 0) {
                        safeTransferETH(shareHolder, amount);
                    }
                }
            }

            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
            currentLPIndex++;
            iterations++;
        }
        progressLPRewardBlock = block.number;
    }

    function setPGRewardCondition(uint256 amount) external onlyWhiteList {
        holderRewardLPCondition = amount;
    }

    function setPGBlockDebt(uint256 debt) external onlyWhiteList {
        progressLPBlockDebt = debt;
    }

    function setLimitAmount(uint256 amount) external onlyWhiteList {
        _limitAmount = amount;
    }

    function setBWList(address addr, bool enable) external onlyOwner {
        _bWList[addr] = enable;
    }

    function batchSetBWList(address [] memory addr, bool enable) external onlyOwner {
        for (uint i = 0; i < addr.length; i++) {
            _bWList[addr[i]] = enable;
        }
    }

    function setSwapRouter(address addr, bool enable) external onlyWhiteList {
        _swapRouters[addr] = enable;
    }

    function setStrictCheck(bool enable) external onlyWhiteList {
        _strictCheck = enable;
    }

    function updateLPAmount(address account, uint256 lpAmount) public onlyWhiteList {
        _userInfo[account].lpAmount = lpAmount;
    }

    function getUserInfo(address account) public view returns (
        uint256 lpAmount, uint256 lpBalance, bool excludeLP, bool preLP
    ) {
        lpAmount = _userInfo[account].lpAmount;
        lpBalance = IERC20(_mainPair).balanceOf(account);
        excludeLP = excludeHolder[account];
        UserInfo storage userInfo = _userInfo[account];
        preLP = userInfo.preLP;
    }

    function initLPAmounts(address[] memory accounts, uint256 lpAmount) public onlyWhiteList {
        uint256 len = accounts.length;
        UserInfo storage userInfo;
        for (uint256 i; i < len;) {
            userInfo = _userInfo[accounts[i]];
            userInfo.lpAmount = lpAmount;
            userInfo.preLP = true;
            addHolder(accounts[i]);
        unchecked{
            ++i;
        }
        }
    }
}

contract WYFI is AbsToken {
    constructor() AbsToken(
    //SwapRouter
        address(0xE9d6f80028671279a28790bb4007B10B0595Def1),
    //IWO
        address(0xe720f2468216D6806F9A33642Fa7Df6327247F6d),
    //名称
        "WYFI Token",
    //符号
        "WYFI",
    //精度
        18,
    //总量
        999,
    //营销钱包
        address(0x77B7F5623Ff8f91C1CC5A6c1Ad34698EbeF6A9BE),
    //代币接收地址
        address(0xE4360226AFe0e00692c7a25c36F8728BF007Bd87),
    //单地址持有数量
        5
    ){

    }
}
