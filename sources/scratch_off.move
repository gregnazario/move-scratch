/// A module defining scratch cards
///
/// Each card has 12 cells
module scratch_addr::scratch_off {

    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string::utf8;
    use aptos_std::ordered_map::{Self, OrderedMap};
    use aptos_framework::event::emit;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::randomness;
    use aptos_token_objects::collection;
    use aptos_token_objects::token::{Self, Token, BurnRef, MutatorRef};

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
    /// Invalid odds, add up to over 100%
    const E_ODDS_GREATER_THAN_HUNDRED_PERCENT: u64 = 5;
    /// Invalid odds, doesn't match prizes
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

    #[event]
    enum ScratcherEvent has drop, store {
        Buy {
            owner: address,
            card: address,
            usdc_amount: u64,
            bonus_fa: address,
            bonus_amount: u64
        }
        Scratch {
            owner: address,
            card: address,
            usdc_amount: u64,
            bonus_fa: address,
            bonus_amount: u64
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
        /// Bonus prizes, key is odds, value is address of prize metadata
        bonus_prizes: OrderedMap<u64, address>
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
        details: CardSummary,
    }

    struct CardSummary has store, copy {
        /// If the card was scratched
        scratched: bool,
        /// Win amount evaluated over cells
        usdc_amount: u64,
        /// Bonus amount
        bonus_amount: u64,
        /// Bonus FA metadata address
        bonus_fa: address,
        /// A 4 row, 3 column vector of values
        cells: vector<vector<u64>>
    }

    #[randomness]
    /// Buy multiple scratcher cards, this must be private, or can be gamed
    entry fun buy_cards(caller: &signer, num_cards: u64) {
        let buyer = signer::address_of(caller);

        // Take money
        let game_addr = game_object_addr();
        let cost = num_cards * COST_PER_CARD;
        assert!(primary_fungible_store::is_balance_at_least(buyer, usdc(), cost), E_NOT_ENOUGH_USDC);
        primary_fungible_store::transfer(caller, usdc(), game_addr, cost);

        // Give cards
        let game_state = game_state_mut();
        let prizes = &game_state.prizes;
        let game_signer = object::generate_signer_for_extending(&game_state.extend_ref);
        for (i in 0..num_cards) {
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

        // Generate the squares
        let board = vector[
            vector[0, 0, 0],
            vector[0, 0, 0],
            vector[0, 0, 0],
            vector[0, 0, 0],
        ];
        for (y in 0..4) {
            for (x in 0..3) {
                board[y][x] = pick_amount(prizes).destroy_with_default(0);
            }
        };
        let win_amount = evaluate_win_amount(&board);

        // And now do the bonus!
        let game_state = game_state();
        let bonus = pick_amount(&game_state.bonus_prizes);
        let (bonus_addr, bonus_amount) = if (bonus.is_some()) {
            let bonus_addr = bonus.destroy_some();
            (bonus_addr, win_amount)
        } else {
            (@0x0, 0)
        };

        let card_addr = object::address_from_constructor_ref(&const_ref);
        emit(ScratcherEvent::Buy {
            owner: receiver,
            card: card_addr,
            usdc_amount: win_amount,
            bonus_fa: bonus_addr,
            bonus_amount
        });

        // Add details to the card
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
                usdc_amount: win_amount,
                cells: board,
                bonus_amount,
                bonus_fa: bonus_addr
            }
        });

        // Transfer to user
        let token = object::object_from_constructor_ref<Token>(&const_ref);
        object::transfer(game_signer, token, receiver);

        // Then make soulbound (cause why not)
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

            num -= i;
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

        let usdc_amount = Card[card_address].details.usdc_amount;
        primary_fungible_store::transfer(&game_signer, usdc_obj, caller_address, usdc_amount);
        let (bonus_amount, bonus_fa) = if (Card[card_address].details.bonus_amount > 0) {
            let bonus_fa = Card[card_address].details.bonus_fa;
            let bonus_amount = Card[card_address].details.bonus_amount;
            let fa_md = fa_metadata(bonus_fa);
            primary_fungible_store::transfer(&game_signer, fa_md, caller_address, bonus_amount);
            (usdc_amount, bonus_fa)
        } else {
            (0, @0x0)
        };

        emit(ScratcherEvent::Scratch {
            owner: caller_address,
            card: card_address,
            usdc_amount,
            bonus_amount,
            bonus_fa,
        })
    }

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
        let payouts_length = odds.length();
        assert!(odds_length == payouts_length, E_INVALID_ODDS_AND_PRIZES);

        // Verify that the odds are < 100%
        assert!(odds.fold(0, |acc, val| acc + val) <= HUNDRED_PERCENT, E_ODDS_GREATER_THAN_HUNDRED_PERCENT);

        let game_state = game_state_mut();
        game_state.prizes = ordered_map::new_from(odds, payouts);
    }

    /// Odds must be equal length with payouts.  Odds must add up underneath 100%
    entry fun set_bonus_prizes(admin: &signer, odds: vector<u64>, assets: vector<address>) {
        verify_admin(admin);
        let odds_length = odds.length();
        let payouts_length = odds.length();
        assert!(odds_length == payouts_length, E_INVALID_ODDS_AND_PRIZES);

        // Verify that the odds are < 100%
        assert!(odds.fold(0, |acc, val| acc + val) <= HUNDRED_PERCENT, E_ODDS_GREATER_THAN_HUNDRED_PERCENT);

        let game_state = game_state_mut();
        game_state.bonus_prizes = ordered_map::new_from(odds, assets);
    }

    /// Withdraws funds to the destination address
    entry fun withdraw_funds(admin: &signer, destination: address, amount: u64) {
        verify_admin(admin);
        let game_state = game_state();
        let game_signer = object::generate_signer_for_extending(&game_state.extend_ref);
        assert!(primary_fungible_store::is_balance_at_least(game_object_addr(), usdc(), amount), E_NOT_ENOUGH_USDC);
        primary_fungible_store::transfer(&game_signer, usdc(), destination, amount)
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
        let object_signer = object::generate_signer(&const_ref);

        // Initialize game state
        let prizes = ordered_map::new_from(DEFAULT_ODDS, DEFAULT_PAYOUTS);
        move_to(
            &object_signer,
            GameState {
                admin: @scratch_addr,
                extend_ref,
                prizes,
                bonus_prizes: ordered_map::new()
            }
        );

        // Make scratcher collection, owned by object
        let _const_ref = collection::create_unlimited_collection(
            contract,
            utf8(b"Scratchers for prizes"),
            utf8(COLLECTION_NAME),
            option::none(), // royalty
            utf8(COLLECTION_URI)
        );
        // TODO: maybe add collection refs
    }

    inline fun verify_admin(caller: &signer, ): address {
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
}
