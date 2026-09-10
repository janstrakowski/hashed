#!/bin/bash
cd $(dirname "$0")

ensure_cc () {
  if [[ -n "$CC" ]]; then
    return 0
  fi
  if which gcc >/dev/null 2>/dev/null; then
    CC=gcc
    return 0
  fi
  if which clang >/dev/null 2>/dev/null; then
    CC=clang
    return 0
  fi
}
ensure_cc

ensure_parent_dirs () {
  mkdir -p $(dirname $1)
  echo $1
}

remove_file () {
  if [ ! -f "$1" ]; then
    return 0
  fi
  (set -x; rm "$1")
}

map_space_separated () {
  local func=$1
  shift

  local out=()
  for arg in "$@"; do
    out+=("$("$func" "$arg")")
  done
  echo ${out[@]}
}

get_c_files () {
  echo src/*.c
}

c_file_to_o_file () {
  echo "${1%.c}.o"
}

o_file_to_c_file () {
  echo "${1%.o}.c"
}

compile_c_file () {
  local o_file=$(c_file_to_o_file "$1")

  if [ "$o_file" -nt "$1" ]; then
    return 0
  fi

  (set -x; "$CC" -c "$1" -o "$o_file")
}

link () {
  local c_files=$(get_c_files)
  local output_executable=$(ensure_parent_dirs bin/hashed)
  (set -x; "$CC" $c_files -o $output_executable)
}

src_gitignore () {
  if [ ! -e src/.gitignore ]; then
    touch src/.gitignore
  fi
  cp -a src/.gitignore src/.gitignore.old

  truncate --size 0 src/.gitignore
  for c_file in $(get_c_files); do
    echo "$(basename "$(c_file_to_o_file "$c_file")")" >> src/.gitignore
  done

  if ! cmp -s src/.gitignore.old src/.gitignore; then
    echo "Updated src/.gitignore"
    diff -u src/.gitignore.old src/.gitignore
  fi
  rm src/.gitignore.old
}

build () {
    src_gitignore
    for c_file in $(get_c_files); do
      compile_c_file $c_file
    done
    link
}

clean () {
    remove_file bin/hashed
    for c_file in $(get_c_files); do
      remove_file $(c_file_to_o_file $c_file)
    done
}

run () {
  build
  (set -x; bin/hashed $@)
}

cmd=$1
shift

case "$cmd" in
  src-gitignore)
    src_gitignore
    ;;
  build)
    build
    ;;
  clean)
    clean
    ;;
  run)
    run $@
    ;;
  *)
    echo "Unknown subcommand: $cmd" >&2
    echo "Usage: $0 {build|clean|src-gitignore}" >&2
    echo "  or $0 run {args...}" >&2
    exit 1
    ;;
esac
