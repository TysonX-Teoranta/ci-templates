#!/usr/bin/env sh
# rc-version-proof.sh — unit/dry-run proof for the create-rc RC-version increment (C178220508114290).
# Proves the shared _rc_next() seeding logic deterministically — NO network, NO org writes:
#   case 1: highest existing rc.9 present, NO plain v1.2.3 release tag  -> next = rc.10
#   case 2: first-ever cut (no tags at all)                            -> next = rc.1
# _rc_next below is byte-identical to the copy shipped in the create-rc spine (rc-cut.sh / _create-rc.yml).
set -eu

_rc_next() {
  _v=$1; _max=0
  for _t in $(git tag -l "v${_v}-rc.*"); do
    _n=${_t##*-rc.}
    case $_n in ''|*[!0-9]*) continue ;; esac
    [ "$_n" -gt "$_max" ] && _max=$_n
  done
  echo $((_max + 1))
}

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q
git config user.email proof@local
git config user.name proof
git commit -q --allow-empty -m init

# case 1 — highest rc is 9 (tags shuffled), plain v1.2.3 release tag deliberately absent (tolerance check).
for n in 1 2 3 5 4 9 7 6 8; do git tag "v1.2.3-rc.$n"; done
got=$(_rc_next 1.2.3)
if [ "$got" = 10 ]; then echo "PASS case1: highest-rc=9 -> next=rc.$got"; else echo "FAIL case1: expected 10, got $got"; fail=1; fi

# case 2 — first-ever cut for a version with no tags at all.
got=$(_rc_next 9.9.9)
if [ "$got" = 1 ]; then echo "PASS case2: first-ever -> rc.$got"; else echo "FAIL case2: expected 1, got $got"; fail=1; fi

[ "$fail" = 0 ] && echo "rc-version-proof: ALL PASS" || { echo "rc-version-proof: FAILED"; exit 1; }
