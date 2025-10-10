module scratch_addr::ratio {
    use aptos_std::math64;

    /// A ratio that can be used for multiplication
    struct Ratio has copy, store, drop {
        numerator: u64,
        denominator: u64,
    }

    /// Create a new ratio
    package fun new(numerator: u64, denominator: u64): Ratio {
        Ratio {
            numerator,
            denominator
        }
    }

    /// Multiply by the ratio
    package fun multiply(self: &Ratio, value: u64): u64 {
        math64::mul_div(value, self.numerator, self.denominator)
    }
}