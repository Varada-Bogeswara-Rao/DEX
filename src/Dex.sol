// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/LP/lib/forge-std/src/interfaces/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ---------------------------
// Factory
// ---------------------------
contract Factory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint
    );

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        require(tokenA != tokenB, "Identical addresses");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
        require(getPair[token0][token1] == address(0), "Pair exists");

        bytes memory bytecode = type(Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        Pair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}

// ---------------------------
// LP Token (ERC20)
// ---------------------------
contract LPToken is ERC20 {
    address public pair;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        pair = msg.sender;
    }

    modifier onlyPair() {
        require(msg.sender == pair, "Only pair");
        _;
    }

    function mint(address to, uint256 amount) external onlyPair {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPair {
        _burn(from, amount);
    }
}

// ---------------------------
// Pair (AMM Pool)
// ---------------------------
contract Pair is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;

    LPToken public lpToken;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(
        address indexed sender,
        uint amount0,
        uint amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint amountIn,
        uint amountOut,
        address indexed tokenIn,
        address indexed tokenOut
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "Only factory");
        token0 = _token0;
        token1 = _token1;
        lpToken = new LPToken("DEX LP Token", "DLP");
    }

    function getReserves() public view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function _update(uint balance0, uint balance1) private {
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Sync(reserve0, reserve1);
    }

    function mint(address to) external nonReentrant returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0 - _reserve0;
        uint amount1 = balance1 - _reserve1;

        if (_reserve0 == 0 && _reserve1 == 0) {
            liquidity = sqrt(amount0 * amount1);
        } else {
            liquidity = min(
                (amount0 * lpToken.totalSupply()) / _reserve0,
                (amount1 * lpToken.totalSupply()) / _reserve1
            );
        }
        require(liquidity > 0, "Insufficient liquidity");
        lpToken.mint(to, liquidity);

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(
        address to
    ) external nonReentrant returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint liquidity = lpToken.balanceOf(address(this));

        amount0 = (liquidity * balance0) / lpToken.totalSupply();
        amount1 = (liquidity * balance1) / lpToken.totalSupply();
        require(amount0 > 0 && amount1 > 0, "Insufficient amounts");

        lpToken.burn(address(this), liquidity);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(
        uint amountIn,
        address tokenIn,
        address to
    ) external nonReentrant {
        require(tokenIn == token0 || tokenIn == token1, "Invalid tokenIn");
        (uint112 _reserve0, uint112 _reserve1) = getReserves();

        bool isToken0 = tokenIn == token0;
        (uint112 reserveIn, uint112 reserveOut) = isToken0
            ? (_reserve0, _reserve1)
            : (_reserve1, _reserve0);
        address tokenOut = isToken0 ? token1 : token0;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint amountInWithFee = (amountIn * 997) / 1000; // 0.3% fee
        uint amountOut = (amountInWithFee * reserveOut) /
            (reserveIn + amountInWithFee);

        IERC20(tokenOut).safeTransfer(to, amountOut);

        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1);
        emit Swap(msg.sender, amountIn, amountOut, tokenIn, tokenOut);
    }

    function min(uint x, uint y) private pure returns (uint) {
        return x < y ? x : y;
    }

    function sqrt(uint y) private pure returns (uint z) {
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

// ---------------------------
// Router
// ---------------------------
contract Router {
    using SafeERC20 for IERC20;

    address public factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountA,
        uint amountB
    ) external {
        address pair = Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = Factory(factory).createPair(tokenA, tokenB);
        }

        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        Pair(pair).mint(msg.sender);
    }

    function swap(address tokenIn, address tokenOut, uint amountIn) external {
        address pair = Factory(factory).getPair(tokenIn, tokenOut);
        require(pair != address(0), "Pair doesn't exist");

        IERC20(tokenIn).safeTransferFrom(msg.sender, pair, amountIn);
        Pair(pair).swap(amountIn, tokenIn, msg.sender);
    }
}
