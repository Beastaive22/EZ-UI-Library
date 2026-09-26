#!/usr/bin/env bash
# Keeps the hub's game list honest.
#
# Run before pushing anything that touches games/ or loader.lua:
#     bash tools/check-hub.sh
#
# It fails when the list and the modules disagree, which is the failure mode
# that actually happens: a module gets written but never registered (so the game
# is undetectable), or a slug gets registered but the file was never committed
# (so the loader 404s for anyone in that game).
#
# CI runs this too, so a mismatch cannot be merged.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
say() { printf '%s\n' "$*"; }
bad() { printf '::error::%s\n' "$*"; fail=1; }

[ -d games ] || { bad "no games/ directory"; exit 1; }

# slugs registered in loader.lua's GAMES list
registered=$(sed -n '/^local GAMES = {/,/^}/p' loader.lua \
	| grep -oE 'slug = "[a-z0-9-]+"' \
	| sed 's/slug = "//; s/"$//' \
	| sort)

# module files on disk
modules=$(for f in games/*.luau; do basename "$f" .luau; done | sort)

if [ -z "$registered" ]; then
	bad "could not read any slug out of loader.lua's GAMES list — did the table shape change?"
fi

# Modules that are deliberately NOT in the catalog: dev diagnostics you reach
# with getgenv().EZHubForceGame = "<slug>". They still need a game guard, but
# they are not shown to users, so they are exempt from check 1.
EXTRAS="levelmoba-kill-aura levelmoba-combat-capture"

is_extra() {
	printf '%s\n' $EXTRAS | grep -qx "$1"
}

# 1. every module is registered (or is a known force-only extra)
for m in $modules; do
	if is_extra "$m"; then continue; fi
	if ! printf '%s\n' "$registered" | grep -qx "$m"; then
		bad "games/$m.luau exists but is not in loader.lua's GAMES list — nobody can reach it (add it, or list it in EXTRAS above)"
	fi
done

# 2. every registered slug has a module
for r in $registered; do
	if [ ! -f "games/$r.luau" ]; then
		bad "loader.lua registers '$r' but games/$r.luau does not exist — the loader will 404"
	fi
done

# 3. every module opens with a game guard, so it can never half-run in the wrong game
for f in games/*.luau; do
	if ! head -8 "$f" | grep -qE '^if game\.GameId ~= [0-9]+'; then
		bad "$f has no game guard in its first 8 lines — add: if game.GameId ~= <universe> then return end"
	fi
done

# 4. catalog entries carry a name, since the unsupported-place window shows them
for r in $registered; do
	if ! sed -n '/^local GAMES = {/,/^}/p' loader.lua | grep -qE "slug = \"$r\"[^}]*name = \""; then
		bad "'$r' has no name = \"...\" next to its slug — the catalog window would show a blank row"
	fi
done

if [ "$fail" -eq 0 ]; then
	count=$(printf '%s\n' "$registered" | grep -c .)
	say "hub list is consistent: $count registered game(s), $(printf '%s\n' "$modules" | grep -c .) module(s), all guarded"
fi

exit "$fail"
