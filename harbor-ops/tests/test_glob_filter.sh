#!/bin/sh
. "$(dirname "$0")/lib.sh"

run() {
    bash -c "
        export PATH='$PATH'
        . '$BIN/_common.sh'
        glob_to_regex '$1'
    "
}

assert_eq "$(run 'foo')" '^foo$' "literal"
assert_eq "$(run 'foo*')" '^foo.*$' "trailing star"
assert_eq "$(run '*foo')" '^.*foo$' "leading star"
assert_eq "$(run 'fo?')" '^fo.$' "question mark"
assert_eq "$(run 'a.b')" '^a\.b$' "dot escaped"
assert_eq "$(run 'a+b')" '^a\+b$' "plus escaped"
assert_eq "$(run 'a(b)')" '^a\(b\)$' "parens escaped"
assert_eq "$(run 'a[b]')" '^a\[b\]$' "brackets escaped"
assert_eq "$(run 'a|b')" '^a\|b$' "pipe escaped"
assert_eq "$(run 'v1.*')" '^v1\..*$' "dot then star"

echo "OK test_glob_filter"
