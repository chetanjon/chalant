# Chalant

Instructions for agents working in this repository.

`Dictation/CLAUDE.md` governs `Dictation/` and outranks this file inside that
directory. This file governs everything else, and the git workflow below applies
everywhere without exception.

## Git workflow

- Never commit directly to main.
- Create a branch for each unit of work (feat/*, fix/*, chore/*).
- Commit to the branch, push, then open a PR with `gh pr create`.
- Reference issues in the PR body ("Closes #N") when one exists.
- Do not merge. Leave the PR open for me.
