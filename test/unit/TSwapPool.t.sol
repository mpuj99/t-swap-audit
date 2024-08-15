// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { TSwapPool } from "../../src/PoolFactory.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract TSwapPoolTest is Test {
    TSwapPool pool;
    ERC20Mock poolToken;
    ERC20Mock weth;

    address liquidityProvider = makeAddr("liquidityProvider");
    address user = makeAddr("user");

    function setUp() public {
        poolToken = new ERC20Mock();
        weth = new ERC20Mock();
        pool = new TSwapPool(address(poolToken), address(weth), "LTokenA", "LA");

        weth.mint(liquidityProvider, 200e18);
        poolToken.mint(liquidityProvider, 200e18);

        weth.mint(user, 10e18);
        poolToken.mint(user, 10e18);
    }

    function testDeposit() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));

        assertEq(pool.balanceOf(liquidityProvider), 100e18);
        assertEq(weth.balanceOf(liquidityProvider), 100e18);
        assertEq(poolToken.balanceOf(liquidityProvider), 100e18);

        assertEq(weth.balanceOf(address(pool)), 100e18);
        assertEq(poolToken.balanceOf(address(pool)), 100e18);
    }

    function testDepositSwap() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        vm.startPrank(user);
        poolToken.approve(address(pool), 10e18);
        // After we swap, there will be ~110 tokenA, and ~91 WETH
        // 100 * 100 = 10,000
        // 110 * ~91 = 10,000
        uint256 expected = 9e18;

        pool.swapExactInput(poolToken, 10e18, weth, expected, uint64(block.timestamp));
        assert(weth.balanceOf(user) >= expected);
    }

    function testWithdraw() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));

        pool.approve(address(pool), 100e18);
        pool.withdraw(100e18, 100e18, 100e18, uint64(block.timestamp));

        assertEq(pool.totalSupply(), 0);
        assertEq(weth.balanceOf(liquidityProvider), 200e18);
        assertEq(poolToken.balanceOf(liquidityProvider), 200e18);
    }

    function testCollectFees() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        vm.startPrank(user);
        uint256 expected = 9e18;
        poolToken.approve(address(pool), 10e18);
        pool.swapExactInput(poolToken, 10e18, weth, expected, uint64(block.timestamp));
        vm.stopPrank();

        vm.startPrank(liquidityProvider);
        pool.approve(address(pool), 100e18);
        pool.withdraw(100e18, 90e18, 100e18, uint64(block.timestamp));
        assertEq(pool.totalSupply(), 0);
        assert(weth.balanceOf(liquidityProvider) + poolToken.balanceOf(liquidityProvider) > 400e18);
    }


    function testRevertsSwapOfWrongCalculationFee() public {
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        vm.startPrank(user);
        weth.approve(address(pool), 10e18);
        
        // It will revert because we didn't had that much money to put in, the input would 53 ether (explanation below)
        // and we have and approved only 10 ether. But for the users that has enough money can be a huge loss of funds
        vm.expectRevert();
        pool.swapExactOutput(weth, poolToken, 5e18, uint64(block.timestamp));
        vm.stopPrank();

        // Based on math (expected outcome):
        // Input amount = (wethReserves * output) * 1_000 / (poolTokenReserves - output) * 997
        // Input amount = (100e18 * 5e18) * 1_000 / (100e18 - 5e18) * 997 = 5.3e18
        
        // Math on current statments (wrong outcome):
        // Input amount = (wethReserves * output) * 10_000 / (poolTokenReserves - output) * 997
        // Input amount = (100e18 * 5e18) * 10_000 / (100e18 - 5e18) * 997 = 53e18
        // 53e18 --> loss of funds of the user and breaks the invariant
    }


    function testUndesiredSwapLossOfUserFunds() public {
        uint256 amountToMint = 60e18;
        uint256 amountToApprove = 70e18;
        uint256 desiredOuputPoolToken = 5e18;
        uint256 amountMintedBefore = 10e18;
        uint256 liquidityDeposit = 100e18;
        
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), liquidityDeposit);
        poolToken.approve(address(pool), liquidityDeposit);
        pool.deposit(liquidityDeposit, liquidityDeposit, liquidityDeposit, uint64(block.timestamp));
        vm.stopPrank();

        // We mint couple of  tokens more for the user
        weth.mint(user, amountToMint);
        poolToken.mint(user, amountToMint);

        vm.startPrank(user);
        // We approve all the users funds for "future swaps"
        weth.approve(address(pool), amountToApprove);
        
        // We swap  and the input amount would be 53e18 (bad).
        pool.swapExactOutput(weth, poolToken, desiredOuputPoolToken, uint64(block.timestamp));
        vm.stopPrank();

        // User had 70 ether and to get 5e18 of poolTokens he spent 53 ether
        assert(poolToken.balanceOf(user) == desiredOuputPoolToken + amountMintedBefore + amountToMint);
        assert(weth.balanceOf(user) < 20e18);
        // Invariant brake
        assert(weth.balanceOf(address(pool)) > 150e18);
        assert(poolToken.balanceOf(address(pool)) == 95e18);

    }


    function testSellPoolTokensBuysPoolTokens() public {
        uint256 liquidityDeposit = 100e18;
        uint256 poolTokensMinted = 10e18;
        uint256 wethTokensMinted = 10e18;
        uint256 poolTokenToSell = 8e18;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), liquidityDeposit);
        poolToken.approve(address(pool), liquidityDeposit);
        pool.deposit(liquidityDeposit, liquidityDeposit, liquidityDeposit, uint64(block.timestamp));
        vm.stopPrank();

        // User wants to sell most of their poolTokens minted with the weth
        vm.startPrank(user);
        poolToken.approve(address(pool), poolTokensMinted);
        // You expect to swap 8e18 of poolTokens to weth but what is doing is selling a X amount of poolTokens
        // to get 8e18 weth.
        pool.sellPoolTokens(poolTokenToSell);
        vm.stopPrank();

        assert(poolToken.balanceOf(user) != poolTokensMinted - poolTokenToSell);
        assert(poolToken.balanceOf(address(pool)) != liquidityDeposit + poolTokenToSell);
        assert(weth.balanceOf(user) == wethTokensMinted + poolTokenToSell);

    }



    function testBreakingInvariantOnSwap() public {
        uint256 tokensMinted = 10e18;
        uint256 expectedExtraTokens = 1e18;
        uint256 swapAmount = 5e18;
        uint256 totalOutputAmount;
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        // Mint some extra weth for the user to make 10 swaps
        weth.mint(user, 50e18);
        
        
        vm.startPrank(user);
        weth.approve(address(pool), 50e18 + tokensMinted);
        // We do the 9 swaps from weth to poolToken normal
        for(uint256 i = 0; i < 9; i++) {
            // Assuming of course that the return statement of the swapExactInput function is arranged
            totalOutputAmount += pool.swapExactInput(weth, swapAmount, poolToken, 1e18, uint64(block.timestamp));
        }
        // We start calculating the invariant
        int256 startingY = int256(weth.balanceOf(address(pool)));
        int256 startingX = int256(poolToken.balanceOf(address(pool)));
        int256 expectedDeltaY = int256(swapAmount);

        // Make the 10th swap and continue calculating
        uint256 outputOnTenthSwap = pool.swapExactInput(weth, swapAmount, poolToken, 1e18, uint64(block.timestamp));

        int256 endingY = int256(weth.balanceOf(address(pool)));
        int256 endingX = int256(poolToken.balanceOf(address(pool)));
        int256 actualDeltaY = endingY - startingY;
        int256 actualDeltaX = endingX - startingX;
        int256 expectedDeltaX = int256(outputOnTenthSwap);

        vm.stopPrank();

        uint256 expectedPoolTokenBalanceUser = totalOutputAmount + tokensMinted + outputOnTenthSwap + expectedExtraTokens;
        uint256 expectedWethBalanceUser = (50e18 + tokensMinted) - (swapAmount * 10);
        assert(poolToken.balanceOf(user) == expectedPoolTokenBalanceUser);
        assert(weth.balanceOf(user) == expectedWethBalanceUser);
        assert(actualDeltaY == expectedDeltaY);
        assert(actualDeltaX != expectedDeltaX);


    }
}
