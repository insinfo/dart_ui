/// The performance budgets of section 36.3, as data rather than as prose.
///
/// ## Why this file exists at all
///
/// The suite proves correctness: 4111 tests say the framework computes the
/// right answer. Almost nothing said what it *costs*. With five GPU backends
/// in the tree and no rendering budget, a regression in submit or present
/// would have reached a release without anyone being able to name the commit.
///
/// A benchmark that only prints numbers does not fix that either. Numbers in a
/// log are read once, by the person who ran them, on the day they ran them.
/// A budget is the number written down *before* the change, so the machine can
/// say "this got slower" instead of a human noticing months later.
///
/// ## What a budget here is, and is not
///
/// It is a **ceiling that must not be crossed**, not a target to hit. Passing
/// says only "not worse than we decided to tolerate"; it is not a claim of
/// speed. Each one carries its reasoning, because a number with no argument
/// is a number the next person will raise when it fails.
///
/// The budgets are deliberately loose. A tight budget on a shared CI runner
/// measures the runner's neighbours, and a flaky performance gate is worse
/// than none: it teaches everyone to re-run until green, which is the same as
/// deleting it. These are set to catch a *regression in kind* - an accidental
/// O(n²), a cache that stopped hitting, a per-frame allocation in a hot loop -
/// not a ten-percent drift.
///
/// ## How a benchmark participates
///
/// It prints one line per measured case, in a fixed shape that
/// `tool/check_budgets.dart` parses:
///
/// ```text
/// BUDGET <id> <median_microseconds>
/// ```
///
/// Anything else it prints is for humans and is ignored. A case with no entry
/// in [budgets] is reported and **not** enforced, so adding a measurement is
/// never blocked on agreeing a ceiling for it.
library;

/// One ceiling, with the argument for it.
final class Budget {
  const Budget({
    required this.id,
    required this.medianMicroseconds,
    required this.rationale,
  });

  /// Matches the `BUDGET <id>` line a benchmark prints.
  final String id;

  /// The ceiling. A median above this fails the gate.
  final int medianMicroseconds;

  /// Why this number and not another. Read this before raising it.
  final String rationale;
}

/// One 60 Hz frame. The unit most of these are argued against.
const int frameBudgetMicroseconds = 16667;

/// Every enforced ceiling.
const List<Budget> budgets = <Budget>[
  Budget(
    id: 'widget.setState-one-leaf',
    medianMicroseconds: frameBudgetMicroseconds,
    rationale: 'A setState on one leaf of a 10 000-node tree must fit in a '
        'frame with room to spare. This is the budget that catches the whole '
        'tree being rebuilt: before the identity short circuit in '
        'Element.updateChild, a rebuilt parent dragged its entire subtree, so '
        'this case measured the tree rather than the leaf.',
  ),
  Budget(
    id: 'widget.rebuild-unchanged',
    medianMicroseconds: frameBudgetMicroseconds,
    rationale: 'Re-running a build that describes exactly the same tree is the '
        'cheapest thing a framework does, and the one an animation does sixty '
        'times a second. If this approaches a frame, nothing that animates can '
        'also do anything else.',
  ),
  Budget(
    id: 'widget.layout-only',
    medianMicroseconds: frameBudgetMicroseconds,
    rationale: 'Layout of 10 000 nodes with no build and no paint. Relayout '
        'boundaries are what keep this sublinear in practice; an accidental '
        'full-tree relayout shows up here first.',
  ),
  Budget(
    id: 'widget.hit-test',
    medianMicroseconds: 2000,
    rationale: 'A hit test runs on every pointer move - many times per frame '
        'during a drag - so it gets a budget an order of magnitude under a '
        'frame rather than a frame. It walks one path down the tree, so a '
        'number near the frame budget means it is walking the whole tree.',
  ),
  Budget(
    id: 'text.shape-line',
    medianMicroseconds: frameBudgetMicroseconds,
    rationale: 'Shaping one line of Latin text with GSUB and GPOS. The '
        'shaper caches parsed font tables per face, so a budget breach here is '
        'usually that cache missing rather than shaping being slow.',
  ),
];

/// The budget for [id], or null when the case is measured but not enforced.
Budget? budgetFor(String id) {
  for (final Budget budget in budgets) {
    if (budget.id == id) return budget;
  }
  return null;
}
