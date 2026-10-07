namespace SensorsContrast {
    public const double TARGET_PREFERRED = 7.0;
    public const double TARGET_MINIMUM = 4.5;

    public struct Color {
        public double r;
        public double g;
        public double b;
        public double a;

        public Color(double r, double g, double b, double a = 1.0) {
            this.r = r;
            this.g = g;
            this.b = b;
            this.a = a;
        }

        public string to_hex() {
            return "#%02x%02x%02x".printf(to_byte(r), to_byte(g), to_byte(b));
        }
    }

    private uint to_byte(double v) {
        return (uint) Math.round(v.clamp(0.0, 1.0) * 255.0);
    }

    private double linearize(double c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }

    public double relative_luminance(Color c) {
        return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b);
    }

    public double contrast_ratio(Color a, Color b) {
        double la = relative_luminance(a);
        double lb = relative_luminance(b);
        double hi = double.max(la, lb);
        double lo = double.min(la, lb);
        return (hi + 0.05) / (lo + 0.05);
    }

    public Color composite(Color fg, Color under) {
        double a = fg.a.clamp(0.0, 1.0);
        return Color(fg.r * a + under.r * (1.0 - a),
                     fg.g * a + under.g * (1.0 - a),
                     fg.b * a + under.b * (1.0 - a), 1.0);
    }

    public Color mix(Color from, Color to, double t) {
        return Color(from.r + (to.r - from.r) * t,
                     from.g + (to.g - from.g) * t,
                     from.b + (to.b - from.b) * t, 1.0);
    }

    public Color near_black() {
        return Color(0.08, 0.08, 0.08);
    }

    public Color near_white() {
        return Color(0.96, 0.96, 0.96);
    }

    public Color scrim_for(Color theme_bg) {
        bool dark = relative_luminance(theme_bg) < 0.4;
        return dark ? Color(0.09, 0.09, 0.10) : Color(0.96, 0.96, 0.97);
    }

    public Color neutral_for(Color bg) {
        Color dark = near_black();
        Color light = near_white();
        Color best = contrast_ratio(dark, bg) >= contrast_ratio(light, bg) ? dark : light;
        if (contrast_ratio(best, bg) >= TARGET_PREFERRED) {
            return best;
        }
        Color black = Color(0.0, 0.0, 0.0);
        Color white = Color(1.0, 1.0, 1.0);
        return contrast_ratio(black, bg) >= contrast_ratio(white, bg) ? black : white;
    }

    private void to_hsl(Color c, out double h, out double s, out double l) {
        double mx = double.max(c.r, double.max(c.g, c.b));
        double mn = double.min(c.r, double.min(c.g, c.b));
        double d = mx - mn;
        l = (mx + mn) / 2.0;
        h = 0.0;
        s = 0.0;
        if (d < 1e-9) {
            return;
        }
        s = d / (1.0 - Math.fabs(2.0 * l - 1.0));
        if (mx == c.r) {
            h = ((c.g - c.b) / d) % 6.0;
        } else if (mx == c.g) {
            h = (c.b - c.r) / d + 2.0;
        } else {
            h = (c.r - c.g) / d + 4.0;
        }
        h = h * 60.0;
        if (h < 0.0) {
            h += 360.0;
        }
    }

    private Color from_hsl(double h, double s, double l) {
        double c = (1.0 - Math.fabs(2.0 * l - 1.0)) * s;
        double x = c * (1.0 - Math.fabs((h / 60.0) % 2.0 - 1.0));
        double m = l - c / 2.0;
        double r = 0.0, g = 0.0, b = 0.0;
        if (h < 60.0)       { r = c; g = x; }
        else if (h < 120.0) { r = x; g = c; }
        else if (h < 180.0) { g = c; b = x; }
        else if (h < 240.0) { g = x; b = c; }
        else if (h < 300.0) { r = x; b = c; }
        else                { r = c; b = x; }
        return Color(r + m, g + m, b + m);
    }

    public Color ensure_contrast(Color fg, Color bg, double target) {
        if (contrast_ratio(fg, bg) >= target) {
            return Color(fg.r, fg.g, fg.b);
        }
        double h, s, l;
        to_hsl(fg, out h, out s, out l);
        double extreme = contrast_ratio(near_black(), bg) >= contrast_ratio(near_white(), bg)
            ? 0.0 : 1.0;
        if (contrast_ratio(from_hsl(h, s, extreme), bg) < target) {
            return from_hsl(h, s, extreme);
        }
        double near = l;
        double far = extreme;
        for (int i = 0; i < 24; i++) {
            double mid = (near + far) / 2.0;
            if (contrast_ratio(from_hsl(h, s, mid), bg) >= target) {
                far = mid;
            } else {
                near = mid;
            }
        }
        return from_hsl(h, s, far);
    }

    public Color best_contrast(Color fg, Color bg) {
        Color strong = ensure_contrast(fg, bg, TARGET_PREFERRED);
        if (contrast_ratio(strong, bg) >= TARGET_PREFERRED) {
            return strong;
        }
        return ensure_contrast(fg, bg, TARGET_MINIMUM);
    }

    public Color muted_for(Color neutral, Color bg) {
        Color result = neutral;
        for (int i = 1; i <= 20; i++) {
            Color candidate = mix(neutral, bg, i / 40.0);
            if (contrast_ratio(candidate, bg) < 5.0) {
                break;
            }
            result = candidate;
        }
        return result;
    }

    public Color fallback_for(string role, bool dark_background) {
        switch (role) {
            case "error":
                return dark_background ? Color(1.0, 0.45, 0.42) : Color(0.70, 0.06, 0.08);
            case "warning":
                return dark_background ? Color(1.0, 0.72, 0.25) : Color(0.60, 0.33, 0.0);
            case "accent":
                return dark_background ? Color(0.55, 0.75, 1.0) : Color(0.05, 0.30, 0.72);
            default:
                return dark_background ? Color(0.45, 0.90, 0.55) : Color(0.05, 0.42, 0.15);
        }
    }

    public Color median_by_luminance(Color[] samples) {
        if (samples.length == 0) {
            return Color(0.5, 0.5, 0.5);
        }
        int n = samples.length;
        double[] lum = new double[n];
        int[] order = new int[n];
        for (int i = 0; i < n; i++) {
            lum[i] = relative_luminance(samples[i]);
            order[i] = i;
        }
        for (int i = 1; i < n; i++) {
            int key = order[i];
            int j = i - 1;
            while (j >= 0 && lum[order[j]] > lum[key]) {
                order[j + 1] = order[j];
                j--;
            }
            order[j + 1] = key;
        }
        return samples[order[n / 2]];
    }

    public class Palette : Object {
        public Color bg;
        public Color neutral;
        public Color muted;
        public Color ok;
        public Color hot;
        public Color crit;
        public Color accent;

        public Palette(Color bg, Color? theme_ok, Color? theme_hot, Color? theme_crit, Color? theme_accent) {
            this.bg = bg;
            bool dark = relative_luminance(bg) < 0.18;
            neutral = neutral_for(bg);
            muted = muted_for(neutral, bg);
            ok = best_contrast(theme_ok ?? fallback_for("success", dark), bg);
            hot = best_contrast(theme_hot ?? fallback_for("warning", dark), bg);
            crit = best_contrast(theme_crit ?? fallback_for("error", dark), bg);
            accent = best_contrast(theme_accent ?? fallback_for("accent", dark), bg);
        }

        public bool equals(Palette other) {
            return bg.to_hex() == other.bg.to_hex()
                && neutral.to_hex() == other.neutral.to_hex()
                && ok.to_hex() == other.ok.to_hex()
                && hot.to_hex() == other.hot.to_hex()
                && crit.to_hex() == other.crit.to_hex()
                && accent.to_hex() == other.accent.to_hex();
        }
    }
}
