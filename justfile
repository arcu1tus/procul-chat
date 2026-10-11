# Procul — a streaming, tool-using chat app (ASP.NET Core backend + Flutter client).
#
# This is the repository front door. Recipes are split into modules:
#
#   just backend  <recipe>     # build/test/run the .NET backend   (see backend/justfile)
#   just frontend <recipe>     # build/test/run the Flutter client  (see frontend/justfile)
#
# Run `just --list` for this file's recipes, `just --list backend` / `just --list frontend`
# for a module's.

mod backend 'backend'
mod frontend 'frontend'

# List the available recipes.
default:
    @just --list

# Run the full check suite: backend tests + frontend tests + frontend analyzer.
check: backend::test frontend::test frontend::analyze
