# AGENTS

## Git

- NEVER commit or push code yourself (`git commit`, `git push`, or anything that lands/pushes code on the user's behalf). Always leave committing and pushing to the user.
- NEVER use git worktrees.

## Style

- **Spelling**: US English everywhere — code, identifiers, comments, strings, prose. (`normalize`, `color`, `behavior`, not `normalise`, `colour`, `behaviour`.)
- **Method order**: within a class, keep natural groups (constructors → public → private; framework lifecycle methods stay where the framework expects them). Alphabetize *within* each group — never flatten into one global alphabetical list.

## Before calling something done

Think from first principles about what the code is trying to achieve, then challenge it:

1. What's unnecessary, overly complicated, or resting on a weak assumption?
2. What can be deleted entirely?
3. What can be simplified once the unnecessary parts are gone?
