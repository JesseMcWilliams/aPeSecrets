# aPeSecrets: Claude Code project notes

A shared PowerShell module (`CredentialResolver.psm1`) that resolves a `PSCredential` from pluggable sources: CurrentUser, PSCredential (DPAPI file), WindowsCredentialManager, CP, CCP and Conjur. Its **runtime target is Windows PowerShell 5.1**, with no PS 7 dependency. The module deliberately does **not** use `Set-StrictMode`; see the comment at `Modules/CredentialResolver.psm1:43`. The test runner does use strict mode.

## Folder map
- `Modules/CredentialResolver.psm1`: the whole module (~400 lines). It exports only `Get-ResolvedCredential` and `Set-ResolvedCredential`. There's one private `Get-/Set-CredentialFrom<Source>` function per source.
- `Tests/Run-Tests.ps1` runs the tests, and `Tests/Unit/CredentialResolver.Tests.ps1` holds them.
- `Claude_Docs/Reference_Configuration.md`: the `Params` reference for each source, and which sources have been live-verified.
- Consumers: aPeDiscovery (discovery scans) and aPePAS (`Sync-AutomationCredential.ps1`). Changing either exported function's signature or `Params` shape breaks them, so check both before you change it.
- External references are in `C:\Code\References\`. Check there before guessing at API behavior.

## Tests
```
pwsh -NoProfile -File Tests/Run-Tests.ps1 > <scratchpad>/test.txt 2>&1; tail -40 <scratchpad>/test.txt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1   # PS 5.1 check
```
- `-Path <file>` runs one file. `-Verbosity` accepts None, Normal (the default), Detailed or Diagnostic. Pester 5 or later is required.
- CurrentUser, PSCredential and WindowsCredentialManager are tested with real round-trips. CP, CCP and Conjur get parameter validation only, because testing them live needs real infrastructure (see Live testing).
- Redirect test output to a file and read only the summary or failures. Don't stream full test output into the conversation.
- The suite must stay at 100% pass. Run the single test file while iterating and the full suite before you commit.

## Code rules
- Save `.ps1`/`.psm1` files as UTF-8 with BOM, and use no PS 7-only syntax. See aPePAS `Claude_Docs/Reference_Lessons-Learned-PowerShell.md` §1 and §2.
- A new source needs: a `Get-CredentialFrom<Source>` function (plus `Set-` if the source is writable), a branch in `Get-/Set-ResolvedCredential`, a row in the `Claude_Docs/Reference_Configuration.md` table, a `## <Source>` section, and tests.
- Conjur has not been live-verified. Don't describe it as verified.

## Documentation layout
- `README.md` (root): an **overview only**. It covers purpose, requirements, a quick start and a short feature list, and links to `User_Docs/` and `Claude_Docs/` for everything else. Put detail in a doc and link to it rather than adding it to the README.
- `Claude_Docs/` holds every doc Claude creates or works from, named `<Stage>_<Topic-With-Hyphens>.md`:
  - `Planning_`: proposals and backlogs that aren't built yet. Once built, the doc becomes `Design_` or is renamed `Archive_Planning_...`.
  - `Design_`: how the current system works. Keep it current. Archive it only when the feature is removed or replaced.
  - `Testing_`: test plans, open findings and known issues. Closed findings move to `Archive_Testing_...`.
  - `Reference_`: rules that apply at every stage (lessons learned, conventions, interface contracts).
  - `Archive_<OriginalStage>_<Topic>.md`: finished or superseded material. **Don't read `Archive_*` unless the user asks or the task needs history.**
- `User_Docs/`: end-user documentation, usually written near the end of the project from `Claude_Docs/Planning_User-Docs-Backlog.md`. It's output, not a source of facts. Take facts from the code and `Claude_Docs/`.
- When you make a user-visible change, add one line for it to `Planning_User-Docs-Backlog.md`.
- Keep each doc to about 500 lines. Past that, move closed or old content into an `Archive_` file. Don't keep revision logs, because git has the history. Put dates in file names only for point-in-time snapshots, such as reviews.
- Rename docs with `git mv`, and update every link to them in the same change.
- If a doc is large, find the target with grep and read a narrow range. Keep table rows to one or two sentences.


## Docs: what to update for each kind of change
| Change | Update |
|---|---|
| New or changed source, or a `Params` change | `Claude_Docs/Reference_Configuration.md` table and that source's section; the `README.md` "Sources supported" section |
| A source verified live | `Claude_Docs/Reference_Configuration.md` verification notes; the `README.md` "Origin" section |
| A consumer-visible change | `README.md` "Consumers"; tell the user which consumer repos need follow-up |
| Any user-visible change | One line in `Claude_Docs/Planning_User-Docs-Backlog.md` |


## Git
- Don't work directly on `main`. Create a topic branch named `YYYY-MM-DD-<topic>` and open a PR into `main` with `gh`.
- Commit, push, open a PR or merge only when asked. "Commit and push" means both.

## Live testing
- Lab environment details (PVWA/CCP host, AppID, safe, test objects) are in `Live-Testing.local.md` in the project root. That file is gitignored. **Read it only when a task involves live testing.** Never copy its contents into tracked files, commit messages or PR descriptions.
- If `Live-Testing.local.md` is missing, ask for the details. Don't guess.
- Live tests are defined by label (`LT-*`) in `Claude_Docs/Testing_Live-Test-Definitions.md`, with `{Placeholder}` values only. `Live-Testing.local.md` fills in the placeholders per environment and tracks which labels have run. Add new tests to the definitions file, never lab values.
- Never write secrets into any file, log or commit message, including `Live-Testing.local.md`. That file names *where* the credentials live, not the credentials themselves.
- When an example, doc or test needs a password placeholder, use `ThisIsMy_FAKE_Password6!`. It's obviously fake, and it satisfies typical complexity rules.
