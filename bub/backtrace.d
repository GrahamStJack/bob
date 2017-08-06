module bub.backtrace;

//
// Provides support for a readable backtrace on a program crash.
//
// Everything is private - build this into a library and
// link to the library, and bingo (via shared static this).
//
// It works by registering a stacktrace handler with the runtime,
// which, unlike the default one, provides demangled symbols
// rather than just a list of addresses.
//

private {

    import core.runtime         : Runtime;
    import core.stdc.signal     : SIGSEGV, SIGFPE, SIGILL, SIGABRT, signal;
    import core.stdc.stdlib     : free;
    import core.stdc.string     : strlen;
    import core.sys.posix.unistd: STDERR_FILENO;
    import std.demangle         : demangle;
    import std.exception        : assumeWontThrow;
    import std.string           : format, lastIndexOf;


    // Signal handler providing basic stack information.
    // The limitations are due to the more stringent 'nothrow @nogc' attributes
    // being placed on external routines. The signal handler is unable to use
    // the more verbose backtrace capability in the D code below.
    extern (C) nothrow @nogc
    {
        size_t readlink(const char *pathname, char *buf, size_t bufsiz);
        int backtrace(void** buffer, int size);
        char** backtrace_symbols(const(void*)* buffer, int size);
        void exit(int status);
        int sprintf(char *str, const char *format, ...);
        int system(const char *command);

        // signal handler for otherwise-fatal thread-specific signals
        void signal_handler(int sig)
        {
            enum STACK_HIST = 6;
            void*[STACK_HIST] array;
            int size;

            string signal_string;
            switch (sig)
            {
            case SIGSEGV: signal_string = "SIGSEGV"; break;
            case SIGFPE:  signal_string = "SIGFPE"; break;
            case SIGILL:  signal_string = "SIGILL"; break;
            case SIGABRT: signal_string = "SIGABRT"; break;
            default:      signal_string = "unknown"; break;
            }

            import core.stdc.stdio: fprintf, stderr;
            fprintf(stderr, "-------------------------------------------------------------------+\r\n");
            fprintf(stderr, "Received signal %s (%d)\r\n", signal_string.ptr, sig);
            fprintf(stderr, "-------------------------------------------------------------------+\r\n");

            // get void*'s for all entries on the stack
            size = backtrace(&array[0], STACK_HIST);

            enum BUF_SIZE = 1024;
            char[BUF_SIZE] syscom;
            char[BUF_SIZE] my_exe;
            ulong path_size = readlink("/proc/self/exe", &my_exe[0], BUF_SIZE);
            my_exe[path_size] = 0;

            for (auto i = 2; i < size; ++i)
            {
                sprintf(&syscom[0],"addr2line %p -f -e %s | ddemangle",array[i], &my_exe[0]);
                system(&syscom[0]);
            }

            exit(-1);
        }
    }


    // set up the signal handler
    shared static this()
    {
        // set up shared signal handlers for fatal thread-specific signals
        signal(SIGABRT, &signal_handler);
        signal(SIGFPE,  &signal_handler);
        signal(SIGILL,  &signal_handler);
        signal(SIGSEGV, &signal_handler);
    }
}



// Backtrace capability for exception - full debug and symbol information.
// Original code from https://github.com/yazd/backtrace-d

version(linux)
{
  // allow only linux platform
}
else
{
    pragma(msg, "backtrace only works in a Linux environment");
}



version(linux):

import std.stdio: File, stderr;

private enum MAX_BACKTRACE_SIZE = 32;
private alias TraceHandler = Throwable.TraceInfo function(void* ptr);

extern (C) void* thread_stackBottom();

struct Trace
{
    string file;
    uint   line;
}

struct Symbol
{
    string line;

    string demangled() const
    {
        import std.demangle : demangle;
        import std.algorithm: find, until;
        import std.range    : retro, dropOne, array;
        import std.conv     : to;

        dchar[] symbolWith0x = line.retro().find(")").dropOne().until("(").array().retro().array();
        if (symbolWith0x.length == 0)
            return "";
        else
            return demangle(symbolWith0x.until("+").to!string());
    }
}

struct PrintOptions
{
    uint detailedForN        = 2;
    bool colored             = false;
    uint numberOfLinesBefore = 3;
    uint numberOfLinesAfter  = 3;
    bool stopAtDMain         = true;
}

version(DigitalMars)
{
    void*[] get_backtrace()
    {
        enum CALL_INST_LENGTH = 1;      // I don't know the size of the call instruction
                                        // and whether it is always 5. I picked 1 instead
                                        // because it is enough to get the backtrace
                                        // to point at the call instruction
        void*[MAX_BACKTRACE_SIZE] buffer;

        static void** get_base_ptr()
        {
            version(D_InlineAsm_X86)
            {
                asm { naked; mov EAX, EBP; ret; }
            }
            else version(D_InlineAsm_X86_64)
            {
                asm { naked; mov RAX, RBP; ret; }
            }
            else
                return null;
        }

        auto stack_top = get_base_ptr();
        auto stack_bottom = cast(void**) thread_stackBottom();
        void* dummy;
        uint traceSize = 0;

        if (stack_top && (&dummy < stack_top) && (stack_top < stack_bottom))
        {
            auto stackPtr = stack_top;

            for (traceSize = 0; stack_top <= stackPtr && stackPtr < stack_bottom && traceSize < buffer.length;)
            {
                buffer[traceSize++] = (*(stackPtr + 1)) - CALL_INST_LENGTH;
                stackPtr = cast(void**) *stackPtr;
            }
        }

        return buffer[0 .. traceSize].dup;
    }

}
else // ldc2, gdc
{
    void*[] get_backtrace()
    {
        void*[MAX_BACKTRACE_SIZE] buffer;
        auto size = backtrace(buffer.ptr, buffer.length);

        return buffer[0 .. size].dup;
    }
}

Symbol[] getBacktraceSymbols(const(void*[]) backtrace)
{
    import core.stdc.stdlib: free;
    import std.conv        : to;

    Symbol[] symbols = new Symbol[backtrace.length];
    char** c_symbols = backtrace_symbols(backtrace.ptr, cast(int) backtrace.length);
    foreach (i; 0 .. backtrace.length)
    {
        symbols[i] = Symbol(c_symbols[i].to!string());
    }
    free(c_symbols);

    return symbols;
}

Trace[] getLineTrace(const(void*[]) backtrace)
{
    import std.algorithm: equal, findSplit;
    import std.conv     : to;
    import std.process  : pipeProcess, executeShell, Redirect, wait;
    import std.range    : retro;
    import std.string   : chomp;

    auto addr2line = pipeProcess(["addr2line", "-e" ~ exePath()], Redirect.stdin | Redirect.stdout);
    scope(exit) addr2line.pid.wait();

    Trace[] trace = new Trace[backtrace.length];

    foreach (i, bt; backtrace)
    {
        addr2line.stdin.writefln("0x%X", bt);
        addr2line.stdin.flush();
        dstring reply = addr2line.stdout.readln!dstring().chomp();
        with (trace[i])
        {
            auto split = reply.retro().findSplit(":");
            if (split[0].equal("?")) line = 0;
            else line = split[0].retro().to!uint;
            file = split[2].retro().to!string;
        }
    }

    executeShell("kill -INT " ~ addr2line.pid.processID.to!string);
    return trace;
}

private string exePath()
{
    import std.file: readLink;
    import std.path: absolutePath;
    string link = readLink("/proc/self/exe");
    string path = absolutePath(link, "/proc/self/");
    return path;
}

void print_backtrace(PrintOptions options = PrintOptions(3, true, 4, 4, true), uint frames_to_skip = 7) @trusted
{
    print_pretty_trace(stderr, options, frames_to_skip);
}

void print_pretty_trace(File output, PrintOptions options = PrintOptions.init, uint framesToSkip = 1)
{
    void*[] bt = get_backtrace();
    output.write(getPrettyTrace(bt, options, framesToSkip));
}

string prettyTrace(PrintOptions options = PrintOptions.init, uint framesToSkip = 1) {
    void*[] bt = get_backtrace();
    return getPrettyTrace(bt, options, framesToSkip);
}

private string getPrettyTrace(const(void*[]) bt, PrintOptions options = PrintOptions.init, uint framesToSkip = 1)
{
    import std.algorithm : max;
    import std.range;
    import std.format;

    Symbol[] symbols = getBacktraceSymbols(bt);
    Trace[] trace = getLineTrace(bt);

    enum Color : char
    {
        black = '0',
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white
    }

    string forecolor(Color color)
    {
        if (!options.colored)
            return "";
        else
            return "\u001B[3" ~ color ~ "m";
    }

    string backcolor(Color color)
    {
        if (!options.colored)
            return "";
        else
            return "\u001B[4" ~ color ~ "m";
    }

    string reset()
    {
        if (!options.colored)
            return "";
        else
            return "\u001B[0m";
    }

    auto output = appender!string();

    output.put("Stack trace:\n");

    foreach(i, t; trace.drop(framesToSkip))
    {
        auto symbol = symbols[framesToSkip + i].demangled;

        formattedWrite(
            output,
            "#%d: %s%s%s line %s(%s)%s%s%s%s%s @ %s0x%s%s\n",
            i + 1,
            forecolor(Color.red),
            t.file,
            reset(),
            forecolor(Color.yellow),
            t.line,
            reset(),
            symbol.length == 0 ? "" : " in ",
            forecolor(Color.green),
            symbol,
            reset(),
            forecolor(Color.green),
            bt[i + 1],
            reset()
            );

        if (i < options.detailedForN)
        {
            uint offset_start = (i==0)?(options.numberOfLinesBefore + 3):(options.numberOfLinesBefore + 1);
            uint offset_end   = (i==0)?(2):(0);
            uint startingLine = max(t.line - offset_start, 0);
            uint endingLine = t.line + options.numberOfLinesAfter - offset_end;

            if (t.file == "??") continue;

            File code;
            try
            {
                code = File(t.file, "r");
            }
            catch (Exception ex)
            {
                continue;
            }

            auto lines = code.byLine();

            lines.drop(startingLine);
            auto lineNumber = (i==0)?(startingLine + 3):(startingLine + 1);
            output.put("\n");
            foreach (line; lines.take(endingLine - startingLine))
            {
                formattedWrite(
                    output,
                    "%s%s(%d)%s%s%s\n",
                    forecolor(t.line == lineNumber ? Color.yellow : Color.cyan),
                    t.line == lineNumber ? ">" : " ",
                    lineNumber,
                    forecolor(t.line == lineNumber ? Color.yellow : Color.white),
                    line,
                    reset(),
                    );
                lineNumber++;
            }
            output.put("\n");
        }

        if (options.stopAtDMain && symbol == "_Dmain") break;
    }
    return output.data;
}

private class BTTraceHandler : Throwable.TraceInfo
{
    import std.algorithm;

    void*[] backtrace;
    PrintOptions options;
    uint framesToSkip;

    this(PrintOptions options, uint framesToSkip)
    {
        this.options = options;
        this.framesToSkip = framesToSkip;
        backtrace = get_backtrace();
    }

    override int opApply(scope int delegate(ref const(char[])) dg) const {
        return opApply((ref size_t i, ref const(char[]) s) {
                       return dg(s);
                       });
    }

    override int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const
    {
        int result = 0;
        auto prettyTrace = getPrettyTrace(backtrace, options, framesToSkip);
        auto bylines = prettyTrace.splitter("\n");
        size_t i = 0;
        foreach (l; bylines)
        {
            result = dg(i, l);
            if (result)
                break;
            ++i;
        }
        return result;
    }

    override string toString() const
    {
        return getPrettyTrace(backtrace, options, framesToSkip);
    }
}

private static PrintOptions g_runtime_print_options;
private static uint         g_runtime_frames_to_skip;

private Throwable.TraceInfo btTraceHandler(void* ptr)
{
    return new BTTraceHandler(g_runtime_print_options, g_runtime_frames_to_skip);
}

// This is kept for backwards compatibility, however, file was never used so it is redundant.
void install(File file, PrintOptions options = PrintOptions.init, uint frames_to_skip = 5)
{
    install(options, frames_to_skip);
}

void install(PrintOptions options = PrintOptions.init, uint frames_to_skip = 5)
{
    import core.runtime;
    g_runtime_print_options = options;
    g_runtime_frames_to_skip = frames_to_skip;
    Runtime.traceHandler = &btTraceHandler;
}




