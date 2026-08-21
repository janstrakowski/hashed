package hashedbuild

source_t :: struct {
  name: string,
  n_bytes: u64,
  data: [^]u8,
}
