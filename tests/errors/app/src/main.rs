fn main() {
    let unused = 1; // always a warning
    println!("{}", mid::widget().0);
}

#[cfg(feature = "broken")]
fn broken() -> u32 {
    "not a number"
}
