using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

internal enum TransitionKind { Stay, Redraw, Goto, Back, Quit, Finish }

internal readonly record struct Transition(TransitionKind Kind, Screen? Next = null)
{
    /// <summary>The key meant nothing here; do not repaint.</summary>
    public static readonly Transition Stay = new(TransitionKind.Stay);

    /// <summary>Something on this screen changed.</summary>
    public static readonly Transition Redraw = new(TransitionKind.Redraw);

    public static readonly Transition Back = new(TransitionKind.Back);
    public static readonly Transition Quit = new(TransitionKind.Quit);
    public static readonly Transition Finish = new(TransitionKind.Finish);
    public static Transition To(Screen next) => new(TransitionKind.Goto, next);
}

/// <summary>
/// One screen from SETUP-PLAN §3.
///
/// A screen draws itself into a frame and answers keys. It does NOT own the
/// terminal, the flow or the palette — those belong to the loop above it, which
/// is what makes a screen testable against a golden frame without a VM (§6.5's
/// OS7.Setup.Tests, Phase 1's other half).
///
/// The title and the status bar are properties rather than drawn by the screen,
/// because they are chrome: full-bleed, identical on every screen, and the one
/// part of the layout a screen must not be free to get wrong.
/// </summary>
internal abstract class Screen
{
    public virtual string Title => "OS/7 Setup";

    /// <summary>The key legend, e.g. "ENTER=Continue   R=Repair   F3=Quit".</summary>
    public abstract string Status { get; }

    /// <summary>Draw the body. Chrome is already on the frame.</summary>
    public abstract void Draw(Frame f);

    public abstract Transition Handle(KeyPress key);

    /// <summary>
    /// Called before the first Draw and again after a resize, so a screen that
    /// sizes a widget to the frame gets to do it again. Most screens do not
    /// need it.
    /// </summary>
    public virtual void Layout(int cols, int rows) { }

    /// <summary>
    /// True for a screen that changes on its own — one watching work happen on
    /// another thread.
    ///
    /// The input loop already wakes every 200 ms whether or not a key arrived
    /// (Input.Read's idle tick, which exists for a different reason entirely).
    /// A screen that opts in gets redrawn on those ticks and gets Handle called
    /// with Key.None, so "the work finished" can move the flow on without
    /// anybody pressing anything.
    /// </summary>
    public virtual bool Ticks => false;
}
