source_t :: struct {
  name: string,
  n_bytes: u64,
  data: [^]u8,
}

load_source_file :: proc(dirfd: int, path: cstring) -> (res: source_t, errno: int) {
}
