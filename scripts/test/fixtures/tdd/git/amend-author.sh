#!/bin/sh
# Scenario: the implementer's HEAD (a code commit), then the implementer stages a test change and runs
# `git commit --amend --no-edit --author "test-writer <test-writer@factory.invalid>"`: the amended
# commit is authored by the test-writer, committed by the implementer.
# usage: amend-author.sh [dir]   (default: a new mktemp directory). Prints the repo path, then the log.
set -eu
d=${1:-$(mktemp -d)}
mkdir -p "$d"
git -C "$d" init -q -b main
lead() { git -C "$d" -c user.name=lead -c user.email=lead@factory.invalid -c commit.gpgsign=false "$@"; }
impl() { git -C "$d" -c user.name=implementer -c user.email=implementer@factory.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$d/src" "$d/test"
printf 'module P\nf(x) = x\nend\n' >"$d/src/P.jl"
lead add src/P.jl
lead commit -q -m "chore: base"
printf 'module P\nf(x) = x + 1\nend\n' >"$d/src/P.jl"
impl add src/P.jl
impl commit -q -m "feat: f adds one" -m "TDD: green"
printf '@testitem "f" begin\n    @test P.f(1) == 2\nend\n' >"$d/test/t.jl"
impl add test/t.jl && impl commit -q --amend --no-edit --author "test-writer <test-writer@factory.invalid>"
echo "$d"
git -C "$d" log --format='%h|%an <%ae>|%cn <%ce>|%s' --name-only
