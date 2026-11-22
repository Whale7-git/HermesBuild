# Hermes 2.37.3 / build189 — parallel stability integration

Base: published build188 main `2936de7285e2fe7ea3926e4f8d7ca5c546cdf429`.

Four independent source branches (all branched from this exact main) were integrated without overlapping edited files:
- `fix/189-navigation-lifecycle` (`ef5217b`): a browser-selected chat remains the foreground conversation for notifications; right-swipe from this chat returns to its mounted browser instead of prematurely opening the drawer; navigation remains GET/STOP/POST-neutral
- `fix/189-unified-cache-consistency` (`483a6cc`): bounded per-query scoped search snapshots (up to eight terms); revisit a fresh full-body query without requerying or reverting to title-only results; unchanged successful active-host refresh advances TTL without republishing rows
- `fix/189-run-safety-regression` (`5854bd5`): add 150-tool-history navigation detach and read-only recovery regression, asserting no POST, STOP or draft loss
- `docs/189-chat-experience-audit` (`2999a17`): read-only build190 chat/keyboard/attachment performance test plan

Invariant: navigation does not settle or restart a Hermes Run. All write pathways retain the existing identity checks and safety locks. The repository's standard PR workflow compiles the only release candidate from this integration head; feature branches did not trigger independent PR candidates.

Known boundary: real iPhone drag ergonomics, text selection and keyboard combinations need device acceptance. No change to server protocol, SideStore bundle identifier, queue semantics or attachment transport.
