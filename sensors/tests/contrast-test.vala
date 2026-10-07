using SensorsContrast;

Color[] backgrounds() {
    return {
        Color(1.0, 1.0, 1.0),
        Color(0.0, 0.0, 0.0),
        Color(0.96, 0.96, 0.96),
        Color(0.12, 0.12, 0.14),
        Color(0.30, 0.30, 0.30),
        Color(0.50, 0.50, 0.50),
        Color(0.20, 0.35, 0.75),
        Color(1.0, 0.95, 0.6),
        composite(Color(0.0, 0.0, 0.0, 0.3), Color(1.0, 1.0, 1.0)),
        composite(Color(1.0, 1.0, 1.0, 0.4), Color(0.1, 0.1, 0.1))
    };
}

double floor_for(Color bg) {
    return TARGET_MINIMUM;
}

void test_math() {
    assert(Math.fabs(relative_luminance(Color(0, 0, 0))) < 1e-9);
    assert(Math.fabs(relative_luminance(Color(1, 1, 1)) - 1.0) < 1e-9);
    assert(Math.fabs(contrast_ratio(Color(0, 0, 0), Color(1, 1, 1)) - 21.0) < 1e-6);
    Color c = composite(Color(1, 0, 0, 0.5), Color(0, 0, 1));
    assert(Math.fabs(c.r - 0.5) < 1e-9 && Math.fabs(c.b - 0.5) < 1e-9);
}

void test_neutral() {
    foreach (Color bg in backgrounds()) {
        assert(contrast_ratio(neutral_for(bg), bg) >= floor_for(bg));
    }
    assert(contrast_ratio(neutral_for(Color(1, 1, 1)), Color(1, 1, 1)) >= TARGET_PREFERRED);
    assert(contrast_ratio(neutral_for(Color(0, 0, 0)), Color(0, 0, 0)) >= TARGET_PREFERRED);
}

void test_semantic() {
    Color[] themes = {
        Color(0.2, 0.82, 0.48), Color(0.96, 0.83, 0.18), Color(0.88, 0.1, 0.1),
        Color(0.2, 0.5, 1.0), Color(1.0, 1.0, 1.0), Color(0.0, 0.0, 0.0)
    };
    foreach (Color bg in backgrounds()) {
        foreach (Color t in themes) {
            Color fixed = best_contrast(t, bg);
            assert(contrast_ratio(fixed, bg) >= floor_for(bg));
        }
        foreach (string role in new string[] { "success", "warning", "error", "accent" }) {
            bool dark = relative_luminance(bg) < 0.18;
            assert(contrast_ratio(best_contrast(fallback_for(role, dark), bg), bg) >= floor_for(bg));
        }
    }
}

void test_extremes_reach_preferred() {
    Color white = Color(1, 1, 1);
    Color black = Color(0, 0, 0);
    Color red = Color(0.88, 0.1, 0.1);
    assert(contrast_ratio(best_contrast(red, white), white) >= TARGET_PREFERRED);
    assert(contrast_ratio(best_contrast(red, black), black) >= TARGET_PREFERRED);
}

void test_severity_distinct() {
    foreach (Color bg in backgrounds()) {
        if (contrast_ratio(neutral_for(bg), bg) < TARGET_PREFERRED + 2.0) {
            continue;
        }
        bool dark = relative_luminance(bg) < 0.18;
        Color hot = best_contrast(fallback_for("warning", dark), bg);
        Color crit = best_contrast(fallback_for("error", dark), bg);
        Color ok = best_contrast(fallback_for("success", dark), bg);
        assert(Math.fabs(hot.g - crit.g) > 0.08 || Math.fabs(hot.r - crit.r) > 0.08);
        assert(Math.fabs(ok.r - crit.r) > 0.08 || Math.fabs(ok.g - crit.g) > 0.08);
    }
}

void test_muted() {
    foreach (Color bg in backgrounds()) {
        Color n = neutral_for(bg);
        Color m = muted_for(n, bg);
        assert(contrast_ratio(m, bg) >= floor_for(bg));
    }
}

void test_median() {
    Color[] s = { Color(0, 0, 0), Color(1, 1, 1), Color(0.2, 0.2, 0.2), Color(0.21, 0.21, 0.21), Color(0.19, 0.19, 0.19) };
    assert(Math.fabs(median_by_luminance(s).r - 0.2) < 1e-9);
}

void main(string[] args) {
    Test.init(ref args);
    Test.add_func("/sensors/contrast/math", test_math);
    Test.add_func("/sensors/contrast/neutral", test_neutral);
    Test.add_func("/sensors/contrast/semantic", test_semantic);
    Test.add_func("/sensors/contrast/extremes", test_extremes_reach_preferred);
    Test.add_func("/sensors/contrast/distinct", test_severity_distinct);
    Test.add_func("/sensors/contrast/muted", test_muted);
    Test.add_func("/sensors/contrast/median", test_median);
    Test.run();
}
