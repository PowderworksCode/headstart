# Writes slow/src/lib.rs: a tiny interface over bodies that are expensive to
# type-check (long iterator chains of closures), so the crate's metadata is
# ready long before its bodies are checked.
lines = ["pub struct Widget(pub u64);", "", "pub fn make() -> Widget { Widget(busy_0()) }", ""]
for i in range(80):
    chain = "(0..10u64)" + "".join(f".map(|x| x.wrapping_mul({j + 3}).wrapping_add({i}))" for j in range(40))
    lines.append(f"pub fn busy_{i}() -> u64 {{ {chain}.sum() }}")
open("slow/src/lib.rs", "w").write("\n".join(lines) + "\n")
