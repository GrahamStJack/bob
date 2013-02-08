/* Reproduction of bug 9122 */
import std.stdio;
import std.concurrency;

void child() {
    bool done;
    while (!done) {
        receive(
            (bool)      { done = true; },
            (Variant v) { writeln("XXX"); }
        );
    }
}

void main() {
    auto tid = spawn(&child);
    scope(exit) tid.send(true);
    // OK with 2.060, assertion failure with 2.061:
    tid.send("a", "b", true);
}
