## HIGH
### [H-1] In `TSwapPool::getInputAmountBasedOnOutput` function, fee calculation is wrong, disrupts the input amount, can become an undesired swap.

**Description:** In `TSwapPool::getInputAmountBasedOnOutput` function when calculating the input amount based on the output, the 100% percentage magic number has one zero more, so when calculating the fee `997` we get a fee of a `91.3%`, and when is used in other functions to make the swap (like in `TSwapPool::swapExactOutput` function) can generate an unfair swap for user becoming loss of funds for the user itself and Breaking as well the invariant `x * y = k`.

<details>
<summary>getInputAmountBasedOnOutput function</summary>

```javascript
function getInputAmountBasedOnOutput(
        uint256 outputAmount,
        uint256 inputReserves,
        uint256 outputReserves
    )
        public
        pure
        revertIfZero(outputAmount)
        revertIfZero(outputReserves)
        returns (uint256 inputAmount)
    {
        return
            // @writen-audit-info magic numbers
            // @audit-HIGH we are getting a fee of 91.3% fee because inestead of 1_000 is 10_000
            // 997 / 10_000 = 0.0997
            // 91.3%
            ((inputReserves * outputAmount) * 10000) /
            ((outputReserves - outputAmount) * 997);
    }
```

</details>

**Impact:** Unfair swap for the users and breaking the invariant protocol.

**Proof of Concept:** Made two tests:
First, in a more realistic scenario where the user wants to get `5e18` of `poolToken` output, but it reverts because we only approved to put in `10e18` of `weth`, so it reverts with `ERC20InsufficientAllowance` error.

<details>
<summary>First test</summary>

```javascript
function testRevertsSwapOfWrongCalculationFee() public {
    vm.startPrank(liquidityProvider);
    weth.approve(address(pool), 100e18);
    poolToken.approve(address(pool), 100e18);
    pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
    vm.stopPrank();

    vm.startPrank(user);
    weth.approve(address(pool), 10e18);
        
    // It will revert because we didn't had that much money to put in, the input would 53 ether (explanation below)
    // and we have and approved only 10 ether. But for the users that has enough money can be a huge loss of funds (second scenario later)
    vm.expectRevert();
    pool.swapExactOutput(weth, poolToken, 5e18, uint64(block.timestamp));
    vm.stopPrank();

    // Based on math (expected outcome):
    // Input amount = (wethReserves * output) * 1_000 / (poolTokenReserves - output) * 997
    // Input amount = (100e18 * 5e18) * 1_000 / (100e18 - 5e18) * 997 = 5.3e18
        
    // Math on current statements (wrong outcome):
    // Input amount = (wethReserves * output) * 10_000 / (poolTokenReserves - output) * 997
    // Input amount = (100e18 * 5e18) * 10_000 / (100e18 - 5e18) * 997 = 53e18
    // 53e18 --> loss of funds of the user and breaks the invariant
}
```

</details>


The second test is in a scenario that the user is approved and has enough weth to send even if the input is too high, causing loss of funds of the user and breaking the invariant itself:

<details>
<summary>Second Test</summary>

```javascript
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
```

</details>

**Recommended Mitigation:** Consider changing the following:
```diff
function getInputAmountBasedOnOutput(
        uint256 outputAmount,
        uint256 inputReserves,
        uint256 outputReserves
    )
        public
        pure
        revertIfZero(outputAmount)
        revertIfZero(outputReserves)
        returns (uint256 inputAmount)
    {
        return
-           ((inputReserves * outputAmount) * 10000) /
+           ((inputReserves * outputAmount) * 1000) /
            ((outputReserves - outputAmount) * 997);
    }
```



### [H-2] `TSwapPool::swapExactOutput` function has no slippage protection, potential high input amount on the swap getting less output.

**Description:** In `TSwapPool::swapExactOutput` function doens't check for the maximum value you want to input on swap, so if there is a big change on the price pool, when calculating `getInputAmountBasedOnOutput` can execute a swap with unexpected input.

<deatils>
<summary>swapExactOutput function</summary>

```javascript
function swapExactOutput(
        IERC20 inputToken,
        IERC20 outputToken,
        uint256 outputAmount,
        uint64 deadline
    )
        public
        revertIfZero(outputAmount)
        revertIfDeadlinePassed(deadline)
        returns (uint256 inputAmount)
    {
        uint256 inputReserves = inputToken.balanceOf(address(this));
        uint256 outputReserves = outputToken.balanceOf(address(this));

        inputAmount = getInputAmountBasedOnOutput(
            outputAmount,
            inputReserves,
            outputReserves
        );

        // @audit no slippage protection
        // Need a "maxInputAmount" param in case the price changes is too high and we can end up spending too much

        _swap(inputToken, inputAmount, outputToken, outputAmount);
    }
```

</details>

**Impact:** Potential swapping with unexpected input amount

**Proof of Concept:** If someone wants to swap the exact output, and before someone do a big swap on `swapExactOutput`, the user can get an input higher that the desired.

1. Balances:
    - Balance of the `poolToken` in pool = `100e18`
    - Balance of `weth` in the pool = `100e18`
    - Balance of `user1` on both tokens = `50e18`
    - Balance of `user2` on both tokens = `10e18`
2. user1 uses `swapExactOutput` and wants to get an output `50e18 poolTokens`:
    - The input would be: `100e18` aprox in `weth`.
    - Now the ratio of the pool changed `50%`.
3. user2 uses `swapExactOutput` and wants to get `5e18 poolTokens`:
    - The input on `weth` would be: `22.3e18`
    - As there is not checks on the maximum amount to input on the swap, user2 would spend `22.3e18` of `weth` to get `5e18` of `poolTokens`

**Recommended Mitigation:** Consider adding a parameter of `maxInputAmount` and then check if the `inputAmount` calculated is less than the `maxInputAmount`, if not revert.

```diff
function swapExactOutput(
        IERC20 inputToken,
        IERC20 outputToken,
        uint256 outputAmount,
        uint256 maxInputAmount
        uint64 deadline
    )
        public
        revertIfZero(outputAmount)
        revertIfDeadlinePassed(deadline)
        returns (uint256 inputAmount)
    {
        uint256 inputReserves = inputToken.balanceOf(address(this));
        uint256 outputReserves = outputToken.balanceOf(address(this));

        inputAmount = getInputAmountBasedOnOutput(
            outputAmount,
            inputReserves,
            outputReserves
        );

        if (inputAmount > maxInputAmount) {
            revert TSwapPool__InputTooHigh(inputAmount, maxInputAmount);
        }

        _swap(inputToken, inputAmount, outputToken, outputAmount);
    }
```

Add the custom error at the top of the contract to use it.




### [H-3] `TSwapPool::sellPoolTokens` function instead of selling the tokenPool is buying it with weth causing a backwards swap with for the user.

**Description:** In `TSwapPool::sellPoolTokens` function takes as a parameter `poolTokenAmount`, and is intended to sell these `poolTokens`, but instead of using `swapExactInput` putting the input parameter the `poolTokenAmount` is using `swapExactOutput` using the `poolTokenAmount` as the `outputAmount` of `weth` parameter. Meaning, that what is doing in reality is selling X amount of poolTokens to get the amount of weth specified by `poolTokenAmount`. Is still selling the `poolTokens` but it won't sell the desired amount, will sell depending on the ratio of the pool of that exact moment.

<details>
<summary>`TSwapPool::sellPoolTokens` function</summary>

```javascript
function sellPoolTokens(
        uint256 poolTokenAmount
    ) external returns (uint256 wethAmount) {
        return
            swapExactOutput(i_poolToken, i_wethToken, poolTokenAmount, uint64(block.timestamp));
    }
```

</details>

**Impact:** Selling an undesired number of `poolTokens` for the user.

**Proof of Concept:** For purpose of the good functionality of this test simulating is working good, first you need to arrange the bug of the function `TSwapPool::getInputAmountBasedOnOutput` changing the `10_000` to `1_000`. Then you can paste the following test to the `TSwapPool.t.sol`.

<details>
<summary>Test</summary>

1. Liquidity provider deposits 100e18 on the pool on both tokenns.
2. User wants to sell `8e18 tokenPool` from the `10e18` already minted.
3. It sells x amount of `poolTokens` getting as output `10e18` of `weth` because was used as parameter inside the `sellPoolTokens` function.

```javascript
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
```

</details>

**Recommended Mitigation:** Instead of using `swapExactOutput` you can use `swapExactInput` and putting the parameter input the `poolTokenAmount` and adding as well a paremeter to the `sellPoolTokens` function of `minOutputAmount` stating the minimum  output amount you want get to see those pool tokens:
```diff
function sellPoolTokens(
        uint256 poolTokenAmount
+       uint256 minOutputAmount
    ) external returns (uint256 wethAmount) {
        return
-           swapExactOutput(i_poolToken, i_wethToken, poolTokenAmount, uint64(block.timestamp));
+           swapExactInput(i_poolToken, poolTokenAmount, i_wethToken, minOutputAmount, uint64(block.timestamp));
    }
```


### [H-4] `TSwapPool::_swap` function has a `swap_count` variable that breaks the invariant `x * y = k` every ten swaps sending extra tokens to the users.

**Description:** In function `TSwapPool::_swap` has `swap_count` variable that gets increased every swap, then when it arrives to `10 swaps` it will send extra tokens for free to the users breaking totally the invariant and unbalance the weights of the tokens inside the pool.

<details>
<summary>`TSwapPool::_swap` function</summary>

```javascript
function _swap(
        IERC20 inputToken,
        uint256 inputAmount,
        IERC20 outputToken,
        uint256 outputAmount
    ) private {
        if (
            _isUnknown(inputToken) ||
            _isUnknown(outputToken) ||
            inputToken == outputToken
        ) {
            revert TSwapPool__InvalidToken();
        }

        // @audit-HIGH breaks protocol invariant!
        swap_count++;
        if (swap_count >= SWAP_COUNT_MAX) {
            swap_count = 0;
            outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
        }
        emit Swap(
            msg.sender,
            inputToken,
            inputAmount,
            outputToken,
            outputAmount
        );

        inputToken.safeTransferFrom(msg.sender, address(this), inputAmount);
        outputToken.safeTransfer(msg.sender, outputAmount);
    }
```

</details>

**Impact:** Breaks the main invariant of the protocol `x * y = k`

**Proof of Concept:** Before pasting the test on `TSwapPool.t.sol`, we assumed that the bug of the bad return statement of the function `swapExactInput` is arranged and it returns the `outputAmount`.

<details>
<summary>Test</summary>

```javascript
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
```

</details>

**Recommended Mitigation:** Consider deleting the following lines on `_swap` function:
```diff
- swap_count++;
-         if (swap_count >= SWAP_COUNT_MAX) {
-             swap_count = 0;
-             outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
-         }
```

## MEDIUMS

### [M-1] `TSwapPool::deposit` function is missing a check on the parameter `deadline` causing transactions to complete even after the deadline.

**Description:** The `deposit` function accepts a `deadline` parameter which according to documentation is "The deadline for the transaction to be completed by". However this parameter is never used. As a consequence, operations that add liquidity to the pool, migh be executed at unexpected times, inmarket conditions where the deposit rate is unfavorable.

**Impact:** Transactions could be sent when market conditions are unfavorable to deposit, even when adding a deadline parameter.

**Proof of Concept:** The `deadline` parameter is unused.

**Recommended Mitigation:** Consider making the following change to function:
```diff
function deposit(
    uint256 wethToDeposit,
    uint256 minimumLiquidityTokensToMint,
    uint256 maximumPoolTokensToDeposit,
    uint64 deadline
    )
    external
    revertIfZero(wethToDeposit)
+   revertIfDeadlinePassed(deadline)
    returns (uint256 liquidityTokensToMint)
{   
    ...
}
```





## LOWS

### [L-1] In the function `TSwapPool::_addLiquidityMintAndTransfer`, in the `LiquidityAdded` event, the parameters are backwards.

```diff
function _addLiquidityMintAndTransfer(
        uint256 wethToDeposit,
        uint256 poolTokensToDeposit,
        uint256 liquidityTokensToMint
    ) private {
        _mint(msg.sender, liquidityTokensToMint);
        // @audit-low event is backwards, should be
+       emit LiquidityAdded(msg.sender, wethDeposited, poolTokensDeposited)
-       emit LiquidityAdded(msg.sender, poolTokensToDeposit, wethToDeposit);

        // Interactions
        i_wethToken.safeTransferFrom(msg.sender, address(this), wethToDeposit);
        i_poolToken.safeTransferFrom(msg.sender, address(this), poolTokensToDeposit);
    }
```

### [L-2] `TSwapPool::swapExactInput` function doesn't return nothing and the function itself says that is going to return a `uin256 output` to know the output you got. Consider adding this line:

```diff
function swapExactInput(
        IERC20 inputToken,
        uint256 inputAmount,
        IERC20 outputToken,
        uint256 minOutputAmount,
        uint64 deadline
    )
        // @written- audit-info can be replaced as external if not used internally
        public
        revertIfZero(inputAmount)
        revertIfDeadlinePassed(deadline)
        // @audit-LOW 
        // IMPACT: LOW because is giving the wrong return, but the functionality is still good
        // LIKELYHOOD: HIGH- allways the case
        returns (uint256 output)
    {
        uint256 inputReserves = inputToken.balanceOf(address(this));
        uint256 outputReserves = outputToken.balanceOf(address(this));

        uint256 outputAmount = getOutputAmountBasedOnInput(
            inputAmount,
            inputReserves,
            outputReserves
        );

        if (outputAmount < minOutputAmount) {
            revert TSwapPool__OutputTooLow(outputAmount, minOutputAmount);
        }

        _swap(inputToken, inputAmount, outputToken, outputAmount);
+       return outputAmount;
    }
```




## INFORMATIONALS
### [I-1] `PoolFactory::PoolFactory__PoolDoesNotExist()` custom error is not used

```diff
- error PoolFactory__PoolDoesNotExist(address tokenAddress);
```


### [I-2] `PoolFactory::constructor` lack of zero address check in `wethToken param`

```diff
    constructor(address wethToken) {
+       if(wethToken == address(0)) {
+           revert();
+       }
        i_wethToken = wethToken;
    }
```

### [I-3] `PoolFactory::liquidityTokenSymbol` is going to get the `name()` of the token address not the `symbol()`

```diff
function createPool(address tokenAddress) external returns (address) {
        if (s_pools[tokenAddress] != address(0)) {
            revert PoolFactory__PoolAlreadyExists(tokenAddress);
        }
        string memory liquidityTokenName = string.concat("T-Swap ", IERC20(tokenAddress).name());
-       string memory liquidityTokenSymbol = string.concat("ts", IERC20(tokenAddress).name());
+       string memory liquidityTokenSymbol = string.concat("ts", IERC20(tokenAddress).symbol()); 
        TSwapPool tPool = new TSwapPool(tokenAddress, i_wethToken, liquidityTokenName, liquidityTokenSymbol);
        s_pools[tokenAddress] = address(tPool);
        s_tokens[address(tPool)] = tokenAddress;
        emit PoolCreated(tokenAddress, address(tPool));
        return address(tPool);
    }
```


### [I-4] In `TSwapPool::deposit` function the last statement `liquidityTokensToMint = wethToDeposit;` even though `liquidityTokensToMint` is not a state variable for better practices and follow the CEI, better to set it before calling the `_addLiquidityMintAndTransfer` function. Change  the following:

```diff
else {
+           liquidityTokensToMint = wethToDeposit;
            // This will be the "initial" funding of the protocol. We are starting from blank here!
            // We just have them send the tokens in, and we mint liquidity tokens based on the weth
            _addLiquidityMintAndTransfer(
                wethToDeposit,
                maximumPoolTokensToDeposit,
                wethToDeposit
            );
-           liquidityTokensToMint = wethToDeposit;
    }
```


### [I-5] `TSwapPool::getOutputAmountBasedOnInput`, `TSwapPool::getInputAmountBasedOnOutput`, `TSwapPool::getPriceOfOneWethInPoolTokens` and `TSwapPool::getPriceOfOnePoolTokenInWeth` functions some statements has magic numbers, consider to make a `constant` variable for that numbers for better pratices and avoid mistakes.

Consider adding the constant variables at the top of the contract
```diff
+ uint256 private constant PERCENTAGE = 1000;
+ uint256 private constant PERCENTAGE_MINUS_FEE = 997;
+ uint256 private constant UNIT = 1e18;
```

```diff
function getOutputAmountBasedOnInput(
        uint256 inputAmount,
        uint256 inputReserves,
        uint256 outputReserves
    )
        public
        pure
        revertIfZero(inputAmount)
        revertIfZero(outputReserves)
        returns (uint256 outputAmount)
    {
        // x * y = k
        // numberOfWeth * numberOfPoolTokens = constant k
        // k must not change during a transaction (invariant)
        // with this math, we want to figure out how many PoolTokens to deposit
        // since weth * poolTokens = k, we can rearrange to get:
        // (currentWeth + wethToDeposit) * (currentPoolTokens + poolTokensToDeposit) = k
        // **************************
        // ****** MATH TIME!!! ******
        // **************************
        // FOIL it (or ChatGPT): https://en.wikipedia.org/wiki/FOIL_method
        // (totalWethOfPool * totalPoolTokensOfPool) + (totalWethOfPool * poolTokensToDeposit) + (wethToDeposit *
        // totalPoolTokensOfPool) + (wethToDeposit * poolTokensToDeposit) = k
        // (totalWethOfPool * totalPoolTokensOfPool) + (wethToDeposit * totalPoolTokensOfPool) = k - (totalWethOfPool *
        // poolTokensToDeposit) - (wethToDeposit * poolTokensToDeposit)
        // @audit-info magic numbers
-       uint256 inputAmountMinusFee = inputAmount * 997;
+       uint256 inputAmountMinusFee = inputAmount * PERCENTAGE_MINUS_FEE;
        uint256 numerator = inputAmountMinusFee * outputReserves;
        // @audit-info magic numbers
-       uint256 denominator = (inputReserves * 1000) + inputAmountMinusFee;
+       uint256 denominator = (inputReserves * PERCENTAGE) + inputAmountMinusFee;
        return numerator / denominator;
    }

    function getInputAmountBasedOnOutput(
        uint256 outputAmount,
        uint256 inputReserves,
        uint256 outputReserves
    )
        public
        pure
        revertIfZero(outputAmount)
        revertIfZero(outputReserves)
        returns (uint256 inputAmount)
    {
        return
            // @audit-info magic numbers
            // @audit-HIGH we are getting a fee of 91.3% fee because inestead of 1_000 is 10_000
            // 997 / 10_000 = 0.0997
            // 91.3%
-           ((inputReserves * outputAmount) * 10000) /
-           ((outputReserves - outputAmount) * 997);
+           ((inputReserves * outputAmount) * PERCENTAGE) /
+           ((outputReserves - outputAmount) * PERCENTAGE_MINUS_FEE);
    }
```

```diff
function getPriceOfOneWethInPoolTokens() external view returns (uint256) {
        return
            getOutputAmountBasedOnInput(
                // @audit-info magic numbers
-               1e18,
+               UNIT,
                i_wethToken.balanceOf(address(this)),
                i_poolToken.balanceOf(address(this))
            );
    }

    function getPriceOfOnePoolTokenInWeth() external view returns (uint256) {
        return
            getOutputAmountBasedOnInput(
                // @audit-info magic numbers
-               1e18,
+               UNIT,
                i_poolToken.balanceOf(address(this)),
                i_wethToken.balanceOf(address(this))
            );
    }
```

### [I-6] `TSwapPool::swapExactInput` function can be set as `external` not `public` if it's not used internally.




