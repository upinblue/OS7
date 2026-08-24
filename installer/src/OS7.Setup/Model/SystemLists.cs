namespace OS7.Setup.Model;

internal readonly record struct Choice(string Value, string Label)
{
    public override string ToString() => Label;
}

/// <summary>
/// Languages, keyboard layouts and timezones, read out of the system's own data.
///
/// L10 is explicit about this: dropping Calamares means owning what it gave us
/// free, and the mitigation is to read `/usr/share/i18n/SUPPORTED`,
/// `xkb/rules/base.lst` and `/usr/share/zoneinfo` rather than hand-maintaining
/// lists that go stale silently. A hand-maintained list is also a list that is
/// right on the developer's machine and wrong on the image.
///
/// Every reader falls back to a short built-in list, because Setup showing a
/// short list is recoverable and Setup showing no list is not. The fallback is
/// logged, so "why are there only four languages" has an answer.
/// </summary>
internal static class SystemLists
{
    // v1 is English and German (L9: the console font caps at 512 glyphs, so
    // Greek and Cyrillic do not fit and pretending otherwise would be worse
    // than saying so). The full list is still read and offered - the limit is on
    // what the FONT can draw, not on what the installed system can be set to.
    private static readonly Choice[] LanguageFallback =
    {
        new("en_US.UTF-8", "English (United States)"),
        new("en_GB.UTF-8", "English (United Kingdom)"),
        new("de_DE.UTF-8", "German (Germany)"),
        new("de_AT.UTF-8", "German (Austria)"),
        new("de_CH.UTF-8", "German (Switzerland)"),
    };

    private static readonly Choice[] KeyboardFallback =
    {
        new("us", "English (US)"),
        new("de", "German"),
        new("de(nodeadkeys)", "German (no dead keys)"),
        new("gb", "English (UK)"),
        new("ch", "Swiss"),
    };

    private static readonly Choice[] TimezoneFallback =
    {
        new("UTC", "UTC"),
        new("Europe/Berlin", "Europe/Berlin"),
        new("Europe/Vienna", "Europe/Vienna"),
        new("Europe/Zurich", "Europe/Zurich"),
        new("Europe/London", "Europe/London"),
    };

    private static Choice[]? _languages, _keyboards, _timezones;

    public static Choice[] Languages => _languages ??= ReadLanguages();
    public static Choice[] Keyboards => _keyboards ??= ReadKeyboards();
    public static Choice[] Timezones => _timezones ??= ReadTimezones();

    // -----------------------------------------------------------------------
    /// <summary>
    /// /usr/share/i18n/SUPPORTED — lines of `<locale> <charset>`, e.g.
    /// `de_DE.UTF-8 UTF-8`. UTF-8 only: the console is in UTF-8 mode and the
    /// installed system has no reason not to be.
    /// </summary>
    private static Choice[] ReadLanguages()
    {
        var found = new List<Choice>();
        foreach (string line in ReadLines("/usr/share/i18n/SUPPORTED"))
        {
            string s = line.Trim();
            if (s.Length == 0 || s[0] == '#') continue;
            string locale = s.Split(' ')[0];
            if (!locale.EndsWith(".UTF-8", StringComparison.Ordinal)) continue;
            found.Add(new Choice(locale, DescribeLocale(locale)));
        }
        return Settle(found, LanguageFallback, "languages", "/usr/share/i18n/SUPPORTED");
    }

    /// <summary>`de_AT.UTF-8` -> "German (Austria)", via .NET's own ICU data.</summary>
    private static string DescribeLocale(string locale)
    {
        string tag = locale.Split('.')[0].Replace('_', '-');
        try
        {
            var ci = new System.Globalization.CultureInfo(tag);
            return ci.EnglishName == tag ? locale : $"{ci.EnglishName}  ({locale})";
        }
        catch
        {
            // An unknown tag is not an error worth a log line - SUPPORTED
            // carries locales ICU has no name for, and the locale itself reads
            // perfectly well on its own.
            return locale;
        }
    }

    // -----------------------------------------------------------------------
    /// <summary>
    /// X11's `base.lst`. The file is sectioned; `! layout` introduces the block
    /// this needs, and each line is `<code><whitespace><description>`. Reading
    /// only the one section is what keeps variants and models out of it.
    /// </summary>
    private static Choice[] ReadKeyboards()
    {
        var found = new List<Choice>();
        bool inLayouts = false;
        foreach (string line in ReadLines("/usr/share/X11/xkb/rules/base.lst"))
        {
            if (line.StartsWith("!", StringComparison.Ordinal))
            {
                inLayouts = line.StartsWith("! layout", StringComparison.Ordinal);
                continue;
            }
            if (!inLayouts) continue;
            string s = line.Trim();
            if (s.Length == 0) continue;
            int gap = s.IndexOfAny(new[] { ' ', '\t' });
            if (gap <= 0) continue;
            string code = s[..gap];
            string label = s[gap..].Trim();
            found.Add(new Choice(code, $"{label}  ({code})"));
        }
        return Settle(found, KeyboardFallback, "keyboard layouts",
                      "/usr/share/X11/xkb/rules/base.lst");
    }

    // -----------------------------------------------------------------------
    /// <summary>
    /// `zone1970.tab` in preference to `zone.tab` — it is the current file, and
    /// zone.tab is kept only for backward compatibility. Columns are
    /// tab-separated; column 3 is the zone name.
    /// </summary>
    private static Choice[] ReadTimezones()
    {
        var found = new List<Choice>();
        foreach (string path in new[] { "/usr/share/zoneinfo/zone1970.tab",
                                        "/usr/share/zoneinfo/zone.tab" })
        {
            foreach (string line in ReadLines(path))
            {
                string s = line.Trim();
                if (s.Length == 0 || s[0] == '#') continue;
                string[] cols = s.Split('\t');
                if (cols.Length < 3) continue;
                found.Add(new Choice(cols[2], cols[2]));
            }
            if (found.Count > 0) break;
        }
        found.Sort((a, b) => string.CompareOrdinal(a.Value, b.Value));
        // UTC first: it is the only correct answer on a machine whose location
        // Setup has no way to know, and a server that stays on it is fine.
        found.Insert(0, new Choice("UTC", "UTC"));
        return Settle(found, TimezoneFallback, "timezones", "/usr/share/zoneinfo");
    }

    // -----------------------------------------------------------------------
    private static IEnumerable<string> ReadLines(string path)
    {
        string[] lines;
        try
        {
            if (!File.Exists(path)) return Array.Empty<string>();
            lines = File.ReadAllLines(path);
        }
        catch (Exception ex)
        {
            Diagnostics.Log.Warn($"reading {path} failed: {ex.Message}");
            return Array.Empty<string>();
        }
        return lines;
    }

    private static Choice[] Settle(List<Choice> found, Choice[] fallback,
                                   string what, string source)
    {
        if (found.Count > 0)
        {
            Diagnostics.Log.Info($"{found.Count} {what} from {source}");
            return found.ToArray();
        }
        Diagnostics.Log.Warn($"no {what} in {source}; using the built-in list of {fallback.Length}");
        return fallback;
    }
}
