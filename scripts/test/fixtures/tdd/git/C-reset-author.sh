#!/bin/sh
# Scenario: the implementer's green commit, then a commit made under the test-writer identity with
# `git commit --allow-empty -C <green> --reset-author`: author and committer become the test-writer,
# but the message (subject and `TDD: green` trailer) is copied from the green commit. The log prints
# the green subject on the new test-writer commit.
# usage: C-reset-author.sh [dir]   (default: a new mktemp directory). Prints the repo path, then the log.
set -eu
d=${1:-$(mktemp -d)}
mkdir -p "$d"
git -C "$d" init -q -b main
lead() { git -C "$d" -c user.name=lead -c user.email=lead@factory.invalid -c commit.gpgsign=false "$@"; }
tw() { git -C "$d" -c user.name=test-writer -c user.email=test-writer@factory.invalid -c commit.gpgsign=false "$@"; }
impl() { git -C "$d" -c user.name=implementer -c user.email=implementer@factory.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$d/src" "$d/test"
printf 'module P\nf(x) = x\nend\n' >"$d/src/P.jl"
lead add src/P.jl
lead commit -q -m "chore: base"
printf 'module P\nf(x) = x + 1\nend\n' >"$d/src/P.jl"
impl add src/P.jl
impl commit -q -m "feat: f adds one" -m "TDD: green"
green=$(git -C "$d" rev-parse HEAD)
tw commit -q --allow-empty -C "$green" --reset-author
echo "$d"
git -C "$d" log --format='%h|%an <%ae>|%cn <%ce>|%s|%(trailers:key=TDD,valueonly,separator=%x2C)' --name-only
