using OS7.Setup.Diagnostics;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

internal enum FlowResult { Finished, Quit, Failed }

/// <summary>
/// The loop: draw, read a key, decide.
///
/// A stack rather than a graph, because "back" has to mean the screen the user
/// came from and nothing else. §3's flow is linear with one branch (`R`), so a
/// graph would be structure without a use.
///
/// Global keys are handled HERE and not by screens, which is the only way they
/// stay global. F3 quits from anywhere; F5 toggles the high-contrast palette
/// from anywhere. A screen that wanted to override one of those would be a
/// screen where a key means two things depending on where you are, which is
/// exactly the property a keyboard-driven installer cannot afford.
/// </summary>
internal sealed class SetupFlow
{
    private readonly Terminal _terminal;
    private readonly Stack<Screen> _stack = new();

    public SetupFlow(Terminal terminal, Screen first)
    {
        _terminal = terminal;
        _stack.Push(first);
    }

    public FlowResult Run()
    {
        bool dirty = true;
        while (true)
        {
            Screen screen = _stack.Peek();

            // Re-measured every time round, not only on SIGWINCH: a font change
            // resizes the console and the SIGWINCH for it can arrive before
            // anything exists to catch it (see Terminal.Measure). An ioctl per
            // frame is free; a frame drawn to the wrong size is the whole screen.
            if (_terminal.Refresh()) dirty = true;

            if (dirty)
            {
                screen.Layout(_terminal.Cols, _terminal.Rows);
                var frame = new Frame(_terminal.Cols, _terminal.Rows);
                frame.Chrome(screen.Title, screen.Status);
                screen.Draw(frame);
                _terminal.Show(frame);
                dirty = false;
            }

            KeyPress key = _terminal.Input.Read();

            // An idle tick. Round again so the console gets re-checked - which
            // is the whole reason the read has a deadline (Terminal.Retake).
            if (key.Key == Key.None) continue;

            if (key.Key == Key.Eof)
            {
                // The terminal went away. There is nobody left to show an error
                // screen to, so there is nothing to do but leave cleanly.
                Log.Warn("input closed; leaving the flow");
                return FlowResult.Quit;
            }

            // F3 = Quit, from every screen. Phase 4 owes it a confirmation.
            if (key.Key == Key.F3)
            {
                Log.Info("F3 — quitting");
                return FlowResult.Quit;
            }

            // F5 = the high-contrast field (D5). The repaint is not optional:
            // the framebuffer is truecolor, so a palette change leaves every
            // pixel already on screen exactly as it was (BUILD-NOTES #25).
            if (key.Key == Key.F5)
            {
                _terminal.TogglePalette();
                Log.Info($"palette: {_terminal.Palette}");
                dirty = true;
                continue;
            }

            Transition t;
            try
            {
                t = screen.Handle(key);
            }
            catch (Exception ex)
            {
                // A screen throwing must not take the console with it. It
                // becomes an error screen, which is a screen, which the loop
                // already knows how to drive.
                _stack.Push(ErrorScreen.ForException(ex));
                dirty = true;
                continue;
            }

            switch (t.Kind)
            {
                case TransitionKind.Stay:
                    break;

                case TransitionKind.Redraw:
                    dirty = true;
                    break;

                case TransitionKind.Goto:
                    _stack.Push(t.Next!);
                    dirty = true;
                    break;

                case TransitionKind.Back:
                    // Never pop the last screen: "back" from the first screen is
                    // not a quit, and turning it into one would lose a plan.
                    if (_stack.Count > 1) { _stack.Pop(); dirty = true; }
                    break;

                case TransitionKind.Quit:
                    return FlowResult.Quit;

                case TransitionKind.Finish:
                    return FlowResult.Finished;
            }
        }
    }
}
