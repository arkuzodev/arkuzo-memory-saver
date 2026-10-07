namespace Launcher;

public static class LauncherUi
{
    private static readonly string[] Logo =
    [
        @"  █████╗ ██████╗ ██╗  ██╗██╗   ██╗███████╗ ██████╗ ",
        @" ██╔══██╗██╔══██╗██║ ██╔╝██║   ██║╚══███╔╝██╔═══██╗",
        @" ███████║██████╔╝█████═╝ ██║   ██║  ███╔╝ ██║   ██║",
        @" ██╔══██║██╔══██╗██╔═██╗ ██║   ██║ ███╔╝  ██║   ██║",
        @" ██║  ██║██║  ██║██║ ╚██╗╚██████╔╝███████╗╚██████╔╝",
        @" ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝ ╚═════╝ "
    ];

    public static void ShowBanner()
    {
        if (Console.IsOutputRedirected) return;
        try
        {
            Console.Clear();
            Console.ForegroundColor = ConsoleColor.Cyan;
            foreach (var line in Logo)
            {
                Console.WriteLine(line);
                Thread.Sleep(18);
            }
            Console.ForegroundColor = ConsoleColor.White;
            Console.WriteLine("              M E M O R Y   S A V E R");
            Console.ForegroundColor = ConsoleColor.DarkCyan;
            Console.WriteLine("   ── MULTI-INSTANCE STABILITY · VOLT RECOVERY CORE ──\n");
            Console.ResetColor();
        }
        catch { }
    }

    public static void Step(string tag, string message, ConsoleColor tagColor = ConsoleColor.Cyan)
    {
        if (Console.IsOutputRedirected) return;
        try
        {
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.Write("  [ ");
            Console.ForegroundColor = tagColor;
            Console.Write(tag.PadRight(4));
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.Write(" ] ");
            Console.ForegroundColor = ConsoleColor.Gray;
            Console.WriteLine(message);
            Console.ResetColor();
            Thread.Sleep(30);
        }
        catch { }
    }

    public static void ProgressAnimation(string label)
    {
        if (Console.IsOutputRedirected) return;
        try
        {
            Console.ForegroundColor = ConsoleColor.DarkCyan;
            Console.Write($"  {label} [");
            for (int i = 0; i <= 28; i++)
            {
                Console.ForegroundColor = i > 20 ? ConsoleColor.Cyan : ConsoleColor.DarkCyan;
                Console.Write("█");
                Thread.Sleep(10);
            }
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("] 100%");
            Console.ResetColor();
            Thread.Sleep(40);
        }
        catch { }
    }

    public static void WaitForDismissal(bool verifyOnly)
    {
        WaitForDismissal(verifyOnly,Console.IsInputRedirected,Console.IsOutputRedirected,
            () => { Console.ReadKey(intercept: true); });
    }

    internal static void WaitForDismissal(bool verifyOnly,bool inputRedirected,bool outputRedirected,Action readKey)
    {
        if (verifyOnly || inputRedirected || outputRedirected) return;
        Console.WriteLine("\n  Press any key to close this launcher window. The running saver will not be stopped.");
        try { readKey(); }
        catch (InvalidOperationException) { }
        catch (System.IO.IOException) { }
    }

    public static void ShowAlreadyRunning(string message)
    {
        try
        {
            if (!Console.IsOutputRedirected) Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine("\n  [ALREADY RUNNING] " + message);
            Console.WriteLine("  Your existing Memory Saver is still running and has not been changed.");
            Console.WriteLine("  No second controller was started. Use the existing saver, or stop it normally before switching copies.");
        }
        finally
        {
            if (!Console.IsOutputRedirected) Console.ResetColor();
        }
    }

    public static void ShowError(string message)
    {
        if (Console.IsOutputRedirected)
        {
            Console.Error.WriteLine("Launcher error: " + message);
            return;
        }
        try
        {
            Console.WriteLine();
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("  ┌────────────────────────────────────────────────────────┐");
            Console.WriteLine($"  │ [ERROR] {FitText(message, 46)} │");
            Console.WriteLine("  └────────────────────────────────────────────────────────┘");
            Console.ResetColor();
        }
        catch
        {
            Console.Error.WriteLine("Launcher error: " + message);
        }
    }

    private static string FitText(string text, int width)
    {
        if (string.IsNullOrEmpty(text)) return new string(' ', width);
        if (text.Length > width) return text[..(width - 3)] + "...";
        return text.PadRight(width);
    }
}
