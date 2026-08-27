// How tall the advisory surface is allowed to be.
//
// Extracted from the widget for the same reason `host_advisory.dart` and
// `session_reference.dart` were: the rule is a decision, decisions are
// worth testing, and a rule that only exists inside a `build()` can only
// be tested through a layout. In particular the SHORT-terminal branch is
// unreachable from a widget test that supplies the ceiling itself — and
// that branch is the one protecting the only control that gets this
// surface off the user's screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/domain/advisory_surface_bounds.dart';

void main() {
  group('advisorySurfaceMaxHeight', () {
    test('is a minority of a normal terminal area', () {
      // 509.78pt is what an iPhone 17 Pro genuinely has with the custom
      // keyboard shown. The surface explains the terminal, so it must
      // never become the larger half of it.
      final cap = advisorySurfaceMaxHeight(509.78);

      expect(cap, lessThan(509.78 / 2));
      expect(cap, closeTo(203.9, 0.1));
    });

    test('scales with the area rather than being a fixed number', () {
      expect(
        advisorySurfaceMaxHeight(800),
        greaterThan(advisorySurfaceMaxHeight(400)),
      );
    });

    test(
      'stops shrinking before the dismiss button would be cut in half',
      () {
        // 12pt of padding above a 32pt minimum-height IconButton. Below
        // 56pt the one control that removes this surface is itself
        // clipped — which is the defect, not a smaller version of the fix.
        // A strict fraction would hand back 40pt here.
        final cap = advisorySurfaceMaxHeight(100);

        expect(cap, greaterThanOrEqualTo(56));
      },
    );

    test('never exceeds the area it is drawn over, however short', () {
      // Landscape with the keyboard up. There is no good answer at this
      // size; painting outside the terminal is still not one of them.
      for (final area in [0.0, 10.0, 30.0, 55.9]) {
        expect(
          advisorySurfaceMaxHeight(area),
          lessThanOrEqualTo(area),
          reason: 'overflowed a ${area}pt terminal area',
        );
      }
    });

    test('the floor and the fraction meet without a jump', () {
      // At the crossover the two branches must agree, or the surface
      // visibly snaps as the keyboard animates the area past it.
      const crossover = 56 / 0.4; // 140pt

      expect(advisorySurfaceMaxHeight(crossover), closeTo(56, 0.001));
      expect(
        advisorySurfaceMaxHeight(crossover + 1),
        greaterThanOrEqualTo(56),
      );
      expect(advisorySurfaceMaxHeight(crossover - 1), closeTo(56, 0.001));
    });

    test('is never negative', () {
      expect(advisorySurfaceMaxHeight(0), 0);
    });
  });
}
