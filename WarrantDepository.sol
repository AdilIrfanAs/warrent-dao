// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
pragma abicoder v2;

import "./libs/LowGasSafeMath.sol";
import "./libs/Address.sol";
import "./libs/SafeERC20.sol";
import "./libs/FullMath.sol";
import "./libs/FixedPoint.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IPangolinFactory.sol";
import "./interfaces/IPangolinPair.sol";
import "./utils/Ownable.sol";

contract WorldOneWarrantDepository is Ownable {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint32;

    /* ======== EVENTS ======== */
    event WarrantCreated(
        uint256 deposit,
        uint256 indexed payout,
        uint256 indexed expires,
        uint256 indexed priceInUSD
    );
    event WarrantRedeemed(
        address indexed recipient,
        uint256 payout,
        uint256 remaining
    );
    event WarrantPriceChanged(
        uint256 indexed priceInUSD,
        uint256 indexed internalPrice
    );
    event InitWarrantLot(WarrantLot terms);
    event LogSetFactory(address _factory);
    event LogRecoverLostToken(address indexed tokenToRecover, uint256 amount);

    /* ======== STATE VARIABLES ======== */

    IERC20 public immutable WorldOne; // token given as payment for warrant
    IERC20 public immutable principle; // token used to create warrant
    ITreasury public immutable treasury; // mints WorldOne when receives principle
    address public immutable DAO; // receives profit share from warrant
    IPangolinFactory public immutable dexFactory; // Factory address to get market price

    mapping(address => Warrant) public warrantInfo; // stores warrant information for depositors

    uint256 public warrantLotIndex = 0;

    uint32 constant MAX_PAYOUT_IN_PERCENTAGE = 100000; // in thousandths of a %. i.e. 500 = 0.5%
    uint32 constant MIN_VESTING_TERM =  129600;//129600; // in seconds. i.e. 1 day = 86400 seconds
    uint32 constant MAX_ALLOWED_DISCOUNT = 50000; // in thousandths of a %. i.e. 50000 = 50.00%
    uint8 constant CONVERSION_MIN = 0; // in thousandths of a %. i.e. 50000 = 50.00%
    uint8 constant CONVERSION_MAX = 10; // in thousandths of a %. i.e. 50000 = 50.00%

    /* ======== STRUCTS ======== */

    // Info for warrant holder
    struct Warrant {
        uint256 payout; // WorldOne remaining to be paid
        uint256 pricePaid; // In DAI, for front end viewing
        uint32 purchasedAt; // When the warrant was purchased in block number/timestamp
        uint32 warrantLotID; // ID of warrant lot
    }

    struct WarrantLot {
        uint256 discount; // discount variable
        uint32 vestingTerm; // in seconds
        uint256 totalCapacity; // Maximum amount of tokens that can be issued
        uint256 consumed; // Amount of tokens that have been issued
        uint256 fee; // as % of warrant payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 price; // price of a bond in given bond lot
        uint256 startAt; // price of a bond in given bond lot
        bool status;
        uint8 conversionRate;
    }

    mapping(uint256 => WarrantLot) public warrantLots;

    /* ======== INITIALIZATION ======== */

    constructor(
        address _WorldOne,
        address _principle,
        address _treasury,
        address _DAO,
        address _factory
    ) public {
        require(_WorldOne != address(0));
        WorldOne = IERC20(_WorldOne);
        require(_principle != address(0));
        principle = IERC20(_principle);
        require(_treasury != address(0));
        treasury = ITreasury(_treasury);
        require(_DAO != address(0));
        DAO = _DAO;
        require(_factory != address(0));
        dexFactory = IPangolinFactory(_factory);
    }

    /**
     *  @notice initializes warrant lot parameters
     *  @param _discount uint
     *  @param _vestingTerm uint32
     *  @param _totalCapacity uint
     *  @param _fee uint
     *  @param _maxPayout uint
     *  @param _minimumPrice uint
     */

    function initializeWarrantLot(
        uint8 _conversionRate,
        uint256 _discount,
        uint32 _vestingTerm,
        uint256 _totalCapacity,
        uint256 _fee,
        uint256 _maxPayout,
        uint256 _minimumPrice
    ) external onlyOwner {
        require(
            CONVERSION_MIN < _conversionRate,
            "Must Greater then Zero"
        );
        require(
            CONVERSION_MAX >= _conversionRate,
            "Must less then OR Equal to 10"
        );
        require(_discount > 0, "Discount must be greater than 0");
        require(
            _discount <= MAX_ALLOWED_DISCOUNT,
            "Discount must be greater than 0"
        );
        require(
            _vestingTerm >= MIN_VESTING_TERM,
            "Vesting must be longer than 36 hours"
        );
        require(_totalCapacity > 0, "Total capacity must be greater than 0");
        require(_fee <= 10000, "DAO fee cannot exceed payout");
        require(
            _maxPayout <= MAX_PAYOUT_IN_PERCENTAGE,
            "Payout cannot be above 100 percent"
        );
        require(_minimumPrice > 0, "Minimum price must be greater than 0");
        if (warrantLotIndex > 0) {
            require(
                currentWarrantLot().consumed ==
                    currentWarrantLot().totalCapacity,
                "Warrant lot already in progress"
            );
        }
        uint256 _price = getLatestPrice();
        if (_price < _minimumPrice) {
            _price = _minimumPrice;
        }
        WarrantLot memory warrantLot = WarrantLot({
            discount: _discount,
            vestingTerm: _vestingTerm,
            totalCapacity: _totalCapacity.mul(10**WorldOne.decimals()),
            consumed: 0,
            fee: _fee,
            maxPayout: _maxPayout,
            price: _price,
            startAt: block.timestamp,
            status: true,
            conversionRate: _conversionRate
        });
        warrantLots[warrantLotIndex] = warrantLot;
        warrantLotIndex += 1;
        emit InitWarrantLot(warrantLot);
        emit WarrantPriceChanged(warrantPriceInUSD(), warrantPrice());
    }

    /* ======== POLICY FUNCTIONS ======== */

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit warrant
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     */

    function deposit(
        uint256 _amount,
        uint256 _maxPrice,
        address _depositor
    ) external returns (uint256) {
        require(_depositor != address(0), "Invalid address");
        require(msg.sender == _depositor);
        require(warrantLotIndex > 0, "Warrant lot has not been initialized");
        require(
            isPurchasable(),
            "Market price must be greater than warrant lot price"
        );

        uint256 priceInUSD = warrantPriceInUSD(); // Stored in warrant info
        uint256 nativePrice = warrantPrice();
        require(
            _maxPrice >= nativePrice,
            "Slippage limit: more than max price"
        ); // slippage protection

        uint256 value = treasury.convertToken(address(principle), _amount);

        uint256 payout = payoutFor(value); // payout to warranter is computed
        // payout = payout.mul(currentWarrantLot().conversionRate);

        require(payout >= 10_000_000, "Warrant too small"); // must be > 0.01 WorldOne ( underflow protection )
        // require(payout <= maxPayout(), "Warrant too large"); // size protection because there is no slippage
        require(
            currentWarrantLot().consumed.add(payout) <=
                currentWarrantLot().totalCapacity,
            "Exceeding maximum allowed purchase in current warrant lot"
        );


        uint256 fee = payout.mul(currentWarrantLot().fee) / 100_00;

        principle.safeTransferFrom(msg.sender, address(this), _amount);
        principle.approve(address(treasury), 10**WorldOne.decimals());

        treasury.deposit(payout.mul(10**WorldOne.decimals()), address(principle), fee);
        principle.safeTransferFrom(address(this),address(treasury) ,_amount);

        if (fee != 0) {
            // fee is transferred to dao
            WorldOne.safeTransfer(DAO, fee);
        }

        // depositor info is stored
        warrantInfo[_depositor] = Warrant({
            payout: warrantInfo[_depositor].payout.add(payout),
            warrantLotID: uint32(warrantLotIndex - 1),
            purchasedAt: uint32(block.timestamp),
            pricePaid: priceInUSD
        });

        warrantLots[warrantLotIndex - 1] = WarrantLot({
            discount: currentWarrantLot().discount,
            vestingTerm: currentWarrantLot().vestingTerm,
            totalCapacity: currentWarrantLot().totalCapacity,
            consumed: currentWarrantLot().consumed.add(payout),
            fee: currentWarrantLot().fee,
            maxPayout: currentWarrantLot().maxPayout,
            price: currentWarrantLot().price,
            startAt: currentWarrantLot().startAt,
            status: currentWarrantLot().status,
            conversionRate: currentWarrantLot().conversionRate
        });

        emit WarrantCreated(
            _amount,
            payout,
            block.timestamp.add(currentWarrantLot().vestingTerm),
            priceInUSD
        );

        return payout;
    }

    function updateWarrantLot(
        uint256 _warrantLotIndex,
        uint8 _conversionRate,
        uint256 _discount,
        uint256 _price,
        uint256 _totalCapacity,
        uint32 _maxPayout,
        uint32 _vestingTime,
        bool _status
    ) external onlyOwner {
             require(
            CONVERSION_MIN < _conversionRate,
            "Must Greater then Zero"
        );
        require(
            CONVERSION_MAX >= _conversionRate,
            "Must less then OR Equal to 10"
        );
        require(_totalCapacity > 0, "Total capacity must be greater than 0");
        require(_vestingTime > 0, "Vesting must be greater then zero");
        require(
            _maxPayout <= MAX_PAYOUT_IN_PERCENTAGE,
            "Payout cannot be above 100 percent"
        );
        if (warrantLotIndex > 0) {
            require(
                currentWarrantLot().consumed !=
                    currentWarrantLot().totalCapacity,
                "Warrant lot already in progress"
            );
        }


        warrantLots[_warrantLotIndex - 1] = WarrantLot({
            discount: _discount,
            vestingTerm: _vestingTime,
            totalCapacity: _totalCapacity.mul(10**WorldOne.decimals()),
            consumed: currentWarrantLot().consumed,
            fee: currentWarrantLot().fee,
            maxPayout: _maxPayout,
            price: _price,
            startAt: currentWarrantLot().startAt,
            status: _status,
            conversionRate: _conversionRate
        });

    }

    /**
     *  @notice redeem warrant for user
     *  @param _recipient address
     *  @return uint
     */
    function redeem(address _recipient) external returns (uint256) {
        require(msg.sender == _recipient, "NA");
        Warrant memory info = warrantInfo[_recipient];
        require(
            uint32(block.timestamp) >=
                info.purchasedAt.add32(
                    warrantLots[info.warrantLotID].vestingTerm
                ),
            "Cannot redeem before vesting period is over"
        );
        delete warrantInfo[_recipient]; // delete user info
        emit WarrantRedeemed(_recipient, info.payout, 0); // emit warrant data
        return send(_recipient, info.payout); // pay user everything due
    }

    /**
     *  @notice get remaining WorldOne available in current warrant lot. THIS IS FOR TESTING PURPOSES ONLY
     *  @return uint
     */
    function remainingAvailable() public view returns (uint256) {
        return
            currentWarrantLot().totalCapacity.sub(currentWarrantLot().consumed);
    }

    /**
     *  @notice Get cost of all remaining WorldOne tokens.  THIS IS FOR TESTING PURPOSES ONLY
     *  @return uint
     */
    function allCost() public view returns (uint256) {
        return
            remainingAvailable()
                .mul(10**principle.decimals())
                .mul(warrantPrice())
                .div(10**WorldOne.decimals()) / 100;
    }

    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice check if warrant is purchaseable
     *  @return bool
     */

    function isPurchasable() internal view returns (bool) {
        uint256 price = warrantPrice(); // 1100 x
        price = price.mul(10**principle.decimals()) / 100;
        if (price < getMarketPrice()) {
            //1*000000.019970000099699
            return true;
        } else {
            return false;
        }
    }

    /**
     *  @notice get current market price
     *  @return uint
     */
    function getMarketPrice() internal view returns (uint256) {
        IPangolinPair pair = IPangolinPair(
            dexFactory.getPair(address(principle), address(WorldOne))
        );
        IERC20 token1 = IERC20(pair.token1());
        (uint256 Res0, uint256 Res1, ) = pair.getReserves();

        // decimals
        uint256 res0 = Res0 * (10**token1.decimals());
        return (res0 / Res1); // return _amount of token0 needed to buy token1 :: token0 = DAI, token1 = WorldOne
    }

    /**
     *  @notice allow user to send payout
     *  @param _amount uint
     *  @return uint
     */
    function send(address _recipient, uint256 _amount)
        internal
        returns (uint256)
    {
        WorldOne.transfer(_recipient, _amount); // send payout
        return _amount;
    }

    /**
     *  @notice get current warrant lot terms
     *  @return WarrantLot
     */
    function currentWarrantLot() internal view returns (WarrantLot memory) {
        require(warrantLotIndex > 0, "No bond lot has been initialised");
        return warrantLots[warrantLotIndex - 1];
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum warrant size
     *  @return uint
     */
    function maxPayout() public view returns (uint256) {
        return
            currentWarrantLot().totalCapacity.mul(
                currentWarrantLot().maxPayout
            ) / 100000;
    }

    /**
     *  @notice calculate interest due for new warrant
     *  @param _value uint
     *  @return uint
     */
    function payoutFor(uint256 _value) public view returns (uint256) {
        return
            FixedPoint.fraction(_value.mul(currentWarrantLot().conversionRate), warrantPrice()).decode112with18() /
            1e16;
    }

    /**
     *  @notice calculate value of token via token amount
     *  @param _amount uint
     *  @return uint
     */
    function valueCheckOf(uint256 _amount) external view returns (uint256) {
        return
            FixedPoint.fraction(_amount, warrantPrice()).decode112with18() /
            1e16;
    }

    /**
     *  @notice calculate current warrant premium
     *  @return price_ uint
     */
    function warrantPrice() public view returns (uint256 price_) {
        price_ = currentWarrantLot().price;
    }

    function getLatestPrice() public view returns (uint256 price_) {
        uint256 circulatingSupply = WorldOne.totalSupply();
        uint256 treasuryBalance = treasury.getTotalReserves().mul(1e9); //IERC20(principle).balanceOf(address(treasury));
        if (circulatingSupply == 0) {
            // On first warrant sale, there will be no circulating supply
            price_ = 0;
        } else {
            if (warrantLotIndex > 0) {
                price_ = treasuryBalance
                    .div(circulatingSupply)
                    .mul(getYieldFactor())
                    .div(1e11);
            } else {
                price_ = treasuryBalance.div(circulatingSupply).div(1e11);
            }
        }
    }

    function getYieldFactor() public view returns (uint256) {
        return currentWarrantLot().discount.add(1e4); // add extra 100_00 to add 100% to original discount value
    }

    /**
     *  @notice converts warrant price to DAI value
     *  @return price_ uint
     */
    function warrantPriceInUSD() public view returns (uint256 price_) {
        price_ = warrantPrice().mul(10**principle.decimals()) / 100;
    }

    /* ======= AUXILLIARY ======= */
    /**
     *  @notice allow anyone to send lost tokens (excluding principle or WorldOne) to the DAO
     *  @return bool
     */
     
    function recoverLostToken(IERC20 _token) external returns (bool) {
        require(_token != WorldOne, "NAT");
        require(_token != principle, "NAP");
        uint256 balance = _token.balanceOf(address(this));
        _token.safeTransfer(DAO, balance);
        emit LogRecoverLostToken(address(_token), balance);
        return true;
    }
}
