/// A module defining scratch cards
///
/// Each card has 12 cells
module scratch_addr::scratch_off {

    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string::utf8;
    use aptos_std::debug;
    use aptos_std::ordered_map::{Self, OrderedMap};
    use aptos_framework::event::emit;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::randomness;
    use aptos_token_objects::collection;
    use aptos_token_objects::token::{Self, Token, BurnRef, MutatorRef};
    use scratch_addr::ratio::Ratio;
    use scratch_addr::ratio;

    /// Cost in smallest unit (e.g., 1 USDC = 1_000_000 micro USDC)
    const COST_PER_CARD: u64 = 1_000_000;
    /// For looking up the object owning the game
    const SEED: vector<u8> = b"scratch_off";
    /// 100% in odds
    const HUNDRED_PERCENT: u64 = 100_000;

    const COLLECTION_NAME: vector<u8> = b"Scratchers";
    // TODO Collection image
    const COLLECTION_URI: vector<u8> = b"";
    // TODO Scratcher image
    const SCRATCHER_URI: vector<u8> = b"";
    /// Default odds 15%, 20%, 40%, 12%, 8%, 3%, 0.35%, 0.07%
    const DEFAULT_ODDS: vector<u64> = vector[15_000, 20_000, 40_000, 12_000, 8_000, 3_000, 350, 70];
    /// Default prizes 0, $0.25, $0.50, $0.75, $2, $5, $25, $100
    const DEFAULT_PAYOUTS: vector<u64> = vector[0, 250_000, 500_000, 750_000, 2_000_000, 5_000_000, 25_000_000, 100_000_000];

    // -- Errors --
    /// Can't withdraw zero USDC
    const E_CANT_WITHDRAW_ZERO_BALANCE: u64 = 3;
    /// Can't buy 0 cards
    const E_CANT_BUY_ZERO_CARDS: u64 = 4;
    /// Invalid odds, add up to over 100%
    const E_ODDS_GREATER_THAN_HUNDRED_PERCENT: u64 = 5;
    /// Invalid odds length, doesn't match assets length
    const E_INVALID_ODDS_AND_PRIZES: u64 = 6;

    /// Not enough balance to buy cards
    const E_NOT_ENOUGH_USDC: u64 = 7;

    /// Already scratched, can't scratch again
    const E_ALREADY_SCRATCHED: u64 = 8;
    /// Not owner of card, cannot scratch
    const E_NOT_CARD_OWNER: u64 = 9;
    /// Not admin, cannot do admin powers
    const E_UNAUTHORIZED: u64 = 10;
    /// Not enough balance to withdraw
    const E_NOT_ENOUGH_USDC_TO_WITHDRAW: u64 = 11;
    /// Invalid numerators length, doesn't match assets length
    const E_INVALID_NUMERATOR_LENGTH: u64 = 12;
    /// Invalid denominators length, doesn't match assets length
    const E_INVALID_DENOMINATOR_LENGTH: u64 = 13;
    /// Invalid denominator, can't be 0
    const E_INVALID_DENOMINATOR: u64 = 14;
    /// Invalid FA conversion ratio, not set
    const E_INVALID_FA_CONVERSION_RATIO: u64 = 15;
    /// Mismatched assets
    const E_MISMATCHED_ASSETS: u64 = 16;

    #[event]
    enum ScratcherEvent has drop, store {
        Buy {
            owner: address,
            card: address,
            fa_metadata: address,
            usd_amount: u64,
            amount: u64,
        }
        Scratch {
            owner: address,
            card: address,
            fa_metadata: address,
            usd_amount: u64,
            amount: u64
        }
    }

    #[resource_group = 0x1::object::ObjectGroup]
    /// Game state, is at the game object, keeps track of admin, and can payout prizes
    ///
    /// This object contains the funds from buying and payouts
    struct GameState has key {
        /// Admin of the contract, can be changed
        admin: address,
        /// Used for transferring funds, and minting
        extend_ref: ExtendRef,
        /// Prizes, key is odds, value is payout
        prizes: OrderedMap<u64, u64>,
        /// Address for each prize associated, defaults to USDC
        fa_prizes: OrderedMap<u64, address>,
        /// Payout ratios for other prizes that aren't USDC
        fa_rates: OrderedMap<address, Ratio>
    }

    #[resource_group = 0x1::object::ObjectGroup]
    /// Game card at initial mint should have a predetermined outcome, however the user
    /// cannot cheat to stop from buying a bad outcome, even with undergasing which would be difficult
    struct Card has key {
        /// For possible future use
        burn_ref: BurnRef,
        /// For possible future use
        mutate_ref: MutatorRef,
        /// To set `scratched` to true
        extend_ref: ExtendRef,
        /// Details about the card
        details: CardSummary,
    }

    /// Details about a card, the state, and what's being won
    struct CardSummary has store, copy {
        /// If the card was scratched
        scratched: bool,
        /// Win amount evaluated over cells
        usd_amount: u64,
        /// FA metadata address
        fa_metadata: address,
        /// Amount of FA to payout
        amount: u64,
        /// A 4 row, 3 column vector of values
        cells: vector<vector<u64>>
    }

    #[randomness]
    /// Buy multiple scratcher cards, this must be private, or can be gamed
    entry fun buy_cards(caller: &signer, num_cards: u64) {
        assert!(num_cards > 0, E_CANT_BUY_ZERO_CARDS);
        let buyer = signer::address_of(caller);

        // Take money
        debug::print(&utf8(b"1"));
        let game_addr = game_object_addr();
        let cost = num_cards * COST_PER_CARD;
        debug::print(&utf8(b"2"));
        assert!(primary_fungible_store::is_balance_at_least(buyer, usdc(), cost), E_NOT_ENOUGH_USDC);
        debug::print(&utf8(b"3"));
        primary_fungible_store::transfer(caller, usdc(), game_addr, cost);

        debug::print(&utf8(b"4"));
        // Give cards
        let game_state = game_state_mut();
        let prizes = &game_state.prizes;
        let game_signer = object::generate_signer_for_extending(&game_state.extend_ref);
        for (i in 0..num_cards) {
            debug::print(&utf8(b"5"));
            init_card(&game_signer, buyer, prizes);
        };
    }

    /// Initializes a single card, uses randomness to generate the grid
    inline fun init_card(game_signer: &signer, receiver: address, prizes: &OrderedMap<u64, u64>) {
        let const_ref = token::create_numbered_token(
            game_signer,
            utf8(COLLECTION_NAME),
            utf8(b"Who will win?"),
            utf8(b"Scratcher "),
            utf8(b""),
            option::none(),
            utf8(SCRATCHER_URI),
        );

        debug::print(&utf8(b"6"));
        // Generate the squares
        let board = vector[
            vector[0, 0, 0],
            vector[0, 0, 0],
            vector[0, 0, 0],
            vector[0, 0, 0],
        ];
        debug::print(&utf8(b"7"));
        for (y in 0..4) {
            for (x in 0..3) {
                board[y][x] = pick_amount(prizes).destroy_with_default(0);
            }
        };
        debug::print(&utf8(b"8"));
        let win_usd_amount = evaluate_win_amount(&board);

        // Now determine the token to return, default to USDC
        debug::print(&utf8(b"9"));
        let game_state = game_state();
        let fa_address = pick_amount(&game_state.fa_prizes).destroy_with_default(@usdc_address);
        debug::print(&utf8(b"10"));
        let amount = if (fa_address != @usdc_address) {
            // Use the fa_rates to do the conversion
            assert!(game_state.fa_rates.contains(&fa_address), E_INVALID_FA_CONVERSION_RATIO);
            let ratio = game_state.fa_rates.borrow(&fa_address);
            ratio.multiply(win_usd_amount)
        } else {
            win_usd_amount
        };

        debug::print(&utf8(b"11"));
        let card_addr = object::address_from_constructor_ref(&const_ref);
        emit(ScratcherEvent::Buy {
            owner: receiver,
            card: card_addr,
            usd_amount: win_usd_amount,
            fa_metadata: fa_address,
            amount
        });

        // Add details to the card
        debug::print(&utf8(b"12"));
        let card_signer = object::generate_signer(&const_ref);
        let extend_ref = object::generate_extend_ref(&const_ref);
        let burn_ref = token::generate_burn_ref(&const_ref);
        let mutate_ref = token::generate_mutator_ref(&const_ref);
        move_to(&card_signer, Card {
            burn_ref,
            mutate_ref,
            extend_ref,
            details: CardSummary {
                scratched: false,
                usd_amount: win_usd_amount,
                cells: board,
                fa_metadata: fa_address,
                amount
            }
        });

        debug::print(&utf8(b"13"));
        // Transfer to user
        let token = object::object_from_constructor_ref<Token>(&const_ref);
        object::transfer(game_signer, token, receiver);

        // Then make soulbound (cause why not)
        debug::print(&utf8(b"14"));
        let transfer_ref = object::generate_transfer_ref(&const_ref);
        object::disable_ungated_transfer(&transfer_ref);
    }

    /// Picks an amount out of the prizes
    ///
    /// The prizes are defined in micro-USD as the values e.g.
    ///
    /// 1000000 = $1 USDC
    ///
    /// The odds are defined as in a percentage, with 3 decimal points e.g.
    ///
    /// 100 = 0.1%
    fun pick_amount<T: copy>(prizes: &OrderedMap<u64, T>): Option<T> {
        let num = randomness::u64_range(0, HUNDRED_PERCENT);
        let odds = prizes.keys();
        let length = odds.length();
        for (i in 0..length) {
            let odd = odds[i];
            if (num < odd) {
                return option::some(*prizes.borrow(&odd))
            };

            num -= odd;
        };

        // Defaults to 0, if you didn't make up the right number of odds
        option::none()
    }

    #[randomness]
    /// Scratches whole card, and pays out the predetermined amount
    entry fun scratch_card(caller: &signer, card: Object<Card>) {
        let caller_address = signer::address_of(caller);
        // Check that they're the owner
        assert!(object::is_owner(card, caller_address), E_NOT_CARD_OWNER);

        // Check that it wasn't already scratched
        let card_address = object::object_address(&card);
        assert!(!Card[card_address].details.scratched, E_ALREADY_SCRATCHED);

        // Set that it's scratched
        Card[card_address].details.scratched = true;

        let game_state = game_state();
        let game_signer = object::generate_signer_for_extending(&game_state.extend_ref);
        let usdc_obj = usdc();

        // Transfer prize
        let fa_address = Card[card_address].details.fa_metadata;
        let amount = Card[card_address].details.amount;
        primary_fungible_store::transfer(&game_signer, fa_metadata(fa_address), caller_address, amount);

        emit(ScratcherEvent::Scratch {
            owner: caller_address,
            card: card_address,
            usd_amount: Card[card_address].details.usd_amount,
            fa_metadata: fa_address,
            amount
        })
    }

    /// Evaluates win amount from a grid
    inline fun evaluate_win_amount(cells: &vector<vector<u64>>): u64 {
        let win_amount = 0;
        // Evaluate win per row
        for (y in 0..4) {
            let row = &cells[y];
            let amount = row[0];

            // Skip 0, you can't win anyways
            if (amount == 0) {
                continue
            };

            // Handle payout
            if (row.all(|val| *val == amount)) {
                win_amount += amount;
            }
        };

        win_amount
    }

    /// Sets odds
    ///
    /// Odds must be equal length with payouts.  Odds must add up underneath 100%
    entry fun set_odds(admin: &signer, odds: vector<u64>, payouts: vector<u64>) {
        verify_admin(admin);
        let odds_length = odds.length();
        let payouts_length = payouts.length();
        assert!(odds_length == payouts_length, E_INVALID_ODDS_AND_PRIZES);

        // Verify that the odds are < 100%
        assert!(odds.fold(0, |acc, val| acc + val) <= HUNDRED_PERCENT, E_ODDS_GREATER_THAN_HUNDRED_PERCENT);

        let game_state = game_state_mut();
        game_state.prizes = ordered_map::new_from(odds, payouts);
    }

    /// Sets prizes, must already have rates for the prizes
    entry fun set_fa_prizes(
        admin: &signer,
        odds: vector<u64>,
        assets: vector<address>,
    ) {
        verify_admin(admin);
        let game_state = game_state_mut();
        // Verify that the prizes have rates

        let rate_assets = game_state.fa_rates.keys();
        assert!(
            rate_assets.length() == assets.length() && rate_assets.all(|prize| assets.contains(prize)),
            E_MISMATCHED_ASSETS
        );
        game_state.set_fa_prizes_i(odds, assets);
    }

    /// Sets rates, must match the existing assets
    entry fun set_fa_rates(
        admin: &signer,
        assets: vector<address>,
        rate_numerators: vector<u64>,
        rate_denominators: vector<u64>,
    ) {
        verify_admin(admin);
        let game_state = game_state_mut();

        // Verify that all assets have rates
        let prize_assets = game_state.fa_prizes.values();
        // This is close enough for now, realistically we want a set... make sure there aren't duplicates
        assert!(
            prize_assets.length() == assets.length() && prize_assets.all(|prize| assets.contains(prize)),
            E_MISMATCHED_ASSETS
        );
        game_state.set_fa_rates_i(assets, rate_numerators, rate_denominators);
    }

    /// Odds must be equal length with payouts.  Odds must add up underneath 100%
    entry fun set_fa_prizes_and_rates(
        admin: &signer,
        odds: vector<u64>,
        assets: vector<address>,
        rate_numerators: vector<u64>,
        rate_denominators: vector<u64>,
    ) {
        verify_admin(admin);
        let game_state = game_state_mut();
        game_state.set_fa_prizes_i(odds, assets);
        game_state.set_fa_rates_i(assets, rate_numerators, rate_denominators);
    }

    /// Sets odds and prizes at the same time
    fun set_fa_prizes_i(
        self: &mut GameState,
        odds: vector<u64>,
        assets: vector<address>,
    ) {
        let odds_length = odds.length();
        let assets_length = assets.length();
        assert!(odds_length == assets_length, E_INVALID_ODDS_AND_PRIZES);

        // Verify that the odds are < 100%
        assert!(odds.fold(0, |acc, val| acc + val) <= HUNDRED_PERCENT, E_ODDS_GREATER_THAN_HUNDRED_PERCENT);

        self.fa_prizes = ordered_map::new_from(odds, assets);
    }

    fun set_fa_rates_i(
        self: &mut GameState,
        assets: vector<address>,
        rate_numerators: vector<u64>,
        rate_denominators: vector<u64>,
    ) {
        let assets_length = assets.length();
        let numer_length = rate_numerators.length();
        let denom_length = rate_denominators.length();
        assert!(assets_length == numer_length, E_INVALID_NUMERATOR_LENGTH);
        assert!(assets_length == denom_length, E_INVALID_DENOMINATOR_LENGTH);
        let rates = rate_numerators.zip_map(rate_denominators, |num, denom| {
            assert!(denom > 0, E_INVALID_DENOMINATOR);
            ratio::new(num, denom)
        });
        self.fa_rates = ordered_map::new_from(assets, rates);
    }

    /// Withdraws funds to the destination address
    entry fun withdraw_funds(admin: &signer, fa_metadata: Object<Metadata>, destination: address, amount: u64) {
        assert!(amount > 0, E_CANT_WITHDRAW_ZERO_BALANCE);
        verify_admin(admin);
        let game_state = game_state();
        let game_signer = object::generate_signer_for_extending(&game_state.extend_ref);
        assert!(
            primary_fungible_store::is_balance_at_least(game_object_addr(), fa_metadata, amount),
            E_NOT_ENOUGH_USDC_TO_WITHDRAW
        );
        primary_fungible_store::transfer(&game_signer, fa_metadata, destination, amount)
    }

    /// Sets the admin to a new admin
    entry fun set_admin(admin: &signer, new_admin: address) {
        verify_admin(admin);
        let game_state = game_state_mut();
        game_state.admin = new_admin;
    }

    /// Initialize the game object so it can be autonomously managed
    fun init_module(contract: &signer) {
        // TODO: Transfer an initial balance?

        // Create object
        let const_ref = object::create_named_object(contract, SEED);
        let extend_ref = object::generate_extend_ref(&const_ref);
        let game_signer = object::generate_signer(&const_ref);

        // Initialize game state
        let prizes = ordered_map::new_from(DEFAULT_ODDS, DEFAULT_PAYOUTS);
        move_to(
            &game_signer,
            GameState {
                admin: @scratch_addr,
                extend_ref,
                prizes,
                fa_prizes: ordered_map::new(),
                fa_rates: ordered_map::new()
            }
        );

        // Make scratcher collection, owned by object
        let _const_ref = collection::create_unlimited_collection(
            &game_signer,
            utf8(b"Scratchers for prizes"),
            utf8(COLLECTION_NAME),
            option::none(), // royalty
            utf8(COLLECTION_URI)
        );
        // TODO: maybe add collection refs
    }

    inline fun verify_admin(caller: &signer): address {
        let caller_address = signer::address_of(caller);
        let game_state = game_state();
        assert!(caller_address == game_state.admin, E_UNAUTHORIZED);
        caller_address
    }

    inline fun game_object_addr(): address {
        object::create_object_address(&@scratch_addr, SEED)
    }

    inline fun collection_addr(): address {
        collection::create_collection_address(&game_object_addr(), &utf8(COLLECTION_NAME))
    }

    inline fun game_state_mut(): &mut GameState {
        &mut GameState[game_object_addr()]
    }

    inline fun game_state(): &GameState {
        &GameState[game_object_addr()]
    }

    inline fun usdc(): Object<Metadata> {
        fa_metadata(@usdc_address)
    }

    inline fun fa_metadata(addr: address): Object<Metadata> {
        object::address_to_object<Metadata>(addr)
    }

    #[view]
    fun get_card(card: Object<Card>): CardSummary {
        let obj_addr = object::object_address(&card);
        Card[obj_addr].details
    }

    // TODO: add tests
}
