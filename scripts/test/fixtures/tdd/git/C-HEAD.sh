#!/bin/sh
# Scenario: the test-writer's HEAD (a red commit), then the implementer stages a test change and runs
# `git commit -C HEAD`: the new commit reuses HEAD's message AND author, so it is authored by the
# test-writer although the implementer made it (committer: implementer).
# usage: C-HEAD.sh [dir]   (default: a new mktemp directory). Prints the repo path, then the log.
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
printf '@testitem "f" begin\n    @test P.f(1) == 2\nend\n' >"$d/test/t.jl"
tw add test/t.jl
tw commit -q -m "test: f adds one" -m "TDD: red"
printf '@testitem "f" begin\n    @test P.f(1) == 1\nend\n' >"$d/test/t.jl"
impl add test/t.jl && impl commit -q -C HEAD
echo "$d"
git -C "$d" log --format='%h|%an <%ae>|%cn <%ce>|%s' --name-only
