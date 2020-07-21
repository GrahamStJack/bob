/**
 * Copyright 2012-2016, Graham St Jack.
 *
 * This file is part of bub, a software build tool.
 *
 * Bub is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bub is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Bub.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
This module provides assorted low-level support code for bub.
*/

module bub.support;

import std.algorithm;
import std.array;
import std.ascii;
import std.datetime;
import std.exception;
import std.file;
import std.format;
import std.functional;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.concurrency;

import core.time;
import core.volatile;
import core.thread;

import core.sys.posix.signal;
import core.sys.posix.sys.stat;
import core.sys.posix.unistd;


// Set the permissions of target to match the source
void setPermissions(string target, string source) {
    stat_t sourceStat;
    stat_t targetStat;
    int rc = stat(toStringz(source), &sourceStat);
    if (rc != 0) fatal("Unable to stat %s", source);
    rc = stat(toStringz(target), &targetStat);
    if (rc != 0) fatal("Unable to stat %s", target);
    if (sourceStat.st_mode != targetStat.st_mode) {
        // change target's permissions
        rc = chmod(toStringz(target), sourceStat.st_mode);
        if (rc != 0) fatal("Unable to chmod %s", target);
    }
}


//-----------------------------------------------------------------------------------------
// PriorityQueue - insert items in any order, and remove largest-first
// (or smallest-first if "a > b" is passed for less).
//
// It is a simple input range (empty(), front() and popFront()).
//
// Notes from Wikipedia article on Binary Heap:
// * Tree is concocted using index arithmetic on underlying array, as follows:
//   First layer is 0. Second is 1,2. Third is 3,4,5,6, etc.
//   Therefore parent of index i is (i-1)/2 and children of index i are 2*i+1 and 2*i+2
// * Tree is balanced, with incomplete population to right of bottom layer.
// * A parent is !less all its children.
// * Insert:
//   - Append to array.
//   - Swap new element with parent until parent !less child.
// * Remove:
//   - Replace root with the last element and reduce the length of the array.
//   - If the new root element is less than a child, swap with largest child.
//-----------------------------------------------------------------------------------------

struct PriorityQueue(T, alias less = "a < b") {
private:

    T[]    _store;  // underlying store, whose length is the queue's capacity
    size_t _used;   // the used length of _store

    alias binaryFun!(less) comp;

public:

    @property size_t   length()   const nothrow { return _used; }
    @property size_t   capacity() const nothrow { return _store.length; }
    @property bool     empty()    const nothrow { return !length; }

    @property const(T) front()    const         { enforce(!empty); return _store[0]; }

    // Insert a value into the queue
    size_t insert(T value)
    {
        // put the new element at the back of the store
        if ( length == capacity) {
            _store.length = (capacity + 1) * 2;
        }
        _store[_used] = value;

        // percolate-up the new element
        for (size_t n = _used; n; )
        {
            auto parent = (n - 1) / 2;
            if (!comp(_store[parent], _store[n])) break;
            swap(_store[parent], _store[n]);
            n = parent;
        }
        ++_used;
        return 1;
    }

    void popFront()
    {
        enforce(!empty);

        // replace the front element with the back one
        if (_used > 1) {
            _store[0] = _store[_used-1];
        }
        --_used;

        // percolate-down the front element (which used to be at the back)
        size_t parent = 0;
        for (;;)
        {
            auto left = parent * 2 + 1, right = left + 1;
            if (right > _used) {
                // no children - done
                break;
            }
            if (right == _used) {
                // no right child - possibly swap parent with left, then done
                if (comp(_store[parent], _store[left])) swap(_store[parent], _store[left]);
                break;
            }
            // both left and right children - swap parent with largest of itself and left or right
            auto largest = comp(_store[parent], _store[left])
                ? (comp(_store[left], _store[right])   ? right : left)
                : (comp(_store[parent], _store[right]) ? right : parent);
            if (largest == parent) break;
            swap(_store[parent], _store[largest]);
            parent = largest;
        }
    }
}


//------------------------------------------------------------------------------
// Synchronized object that keeps track of which spawned processes
// are in play, and raises SIGTERM on them when told to bail.
// If SIGTERM doesn't get it done, raise SIGKILL after a short delay.
//
// bail() is called by the error() functions, which then throw an exception.
//------------------------------------------------------------------------------

class Killer {
    private {
        enum Had { nothing, term, kill }

        // Information about a child
        struct Info {
            string   action;
            Had      had;
            Duration untilNextStep;

            this(string action, Duration duration) {
                this.action   = action;
                had           = Had.nothing;
                untilNextStep = duration;
            }

            // Advance to the next step if there is one
            void takeNextStep(Pid child, bool timeout) {
                if (had == Had.nothing) {
                    if (timeout) {
                        say("Timeout on [%s]", action);
                    }
                    untilNextStep = 6.seconds;
                    had           = Had.term;
                    kill(child.processID, SIGTERM);
                }
                else if (had == had.term) {
                    say("Raising SIGKILL on [%s]", action);
                    had = Had.kill;
                    kill(child.processID, SIGKILL);
                }
            }

            // Do what this child is due for, returning true if a timeout occurred
            bool doWhatIsDue(Pid child, Duration interval) {
                if (had == Had.kill) return false;
                untilNextStep -= interval;
                if (untilNextStep <= 0.seconds) {
                    takeNextStep(child, true);
                    return true;
                }
                return false;
            }

            // Start down the path of terminating this child if we haven't already
            void terminate(Pid child) {
                if (had == Had.nothing) {
                    takeNextStep(child, false);
                }
            }
        }

        bool      bailed;
        bool      timeout;
        Info[Pid] children;
    }

    // remember that a process has been launched, killing it if we have bailed
    void launched(string worker, string action, Pid child, int secs) {
        synchronized(this) {
            children[child] = Info(action, secs.seconds);
            if (bailed) {
                children[child].terminate(child);
            }
        }
    }

    // a child has been finished with
    void completed(string worker, Pid child) {
        synchronized(this) {
            children.remove(child);
        }
    }

    // Do periodic processing, returning true if children remain
    bool periodic(Duration interval) {
        synchronized(this) {
            foreach (child, ref info; children) {
                if (info.doWhatIsDue(child, interval)) {
                    timeout = true;
                }
            }
            return children.length > 0;
        }
    }

    // initiate termination of all remaining children
    bool bail(string initiator) {
        synchronized(this) {
            if (!bailed) {
                say("%s terminating the build", initiator);
                bailed = true;
                foreach (child, ref info; children) {
                    info.terminate(child);
                }
                return true;
            }
            else {
                return false;
            }
        }
    }

    bool timeoutOccurred() {
        synchronized(this) {
            return timeout;
        }
    }
}

__gshared Killer killer;

shared static this() {
    killer = new Killer();
}


//-----------------------------------------------------------------------
// Signal handling to bail on SIGINT, SIGTERM or SIGHUP.
//-----------------------------------------------------------------------

__gshared ubyte bailSignal = 0;

void doBailer() {
    Duration interval = 50.msecs;

    try {
        // Wait until it is time to call killer.bail(), or to terminate
        while (volatileLoad(&bailSignal) == 0)
        {
            // Wait for a short while to see if our owner has terminated,
            // in which case we get an exception.
            receiveTimeout(interval, (bool bogus) {});

            // Poll the killer for anything it wants to do
            killer.periodic(interval);
        }
    }
    catch (Exception ex) {}

    auto sig = volatileLoad(&bailSignal);
    if (sig != 0) {
        // We got a signal - initiate death of all remaining children
        killer.bail(format("Got signal %s - ", sig));
    }

    // Animate the killer until all children have terminated
    do {
        Thread.sleep(interval);
    }
    while (killer.periodic(interval));
    if (killer.timeoutOccurred) {
        say("******** Command timed out ********");
    }
}

extern (C) void mySignalHandler(int sig) nothrow @nogc @system {
    volatileStore(&bailSignal, cast(ubyte)sig);
}

shared static this() {
    // Register a signal handler for SIGTERM, SIGINT and SIGHUP.
    signal(SIGTERM, &mySignalHandler);
    signal(SIGINT,  &mySignalHandler);
    signal(SIGHUP,  &mySignalHandler);
}


//------------------------------------------------------------------------------
// Exception thrown when the build has failed.
//------------------------------------------------------------------------------

class BailException : Exception {
    this() {
        super("Bail");
    }
}

//------------------------------------------------------------------------------
// printing utility functions
//------------------------------------------------------------------------------

// where something originated from
struct Origin {
    string path;
    uint   line;
}

private void sayNoNewline(A...)(string fmt, A a) {
    auto w = appender!(char[])();
    formattedWrite(w, fmt, a);
    stderr.write(w.data);
}

void say(A...)(string fmt, A a) {
    auto w = appender!(char[])();
    formattedWrite(w, fmt, a);
    stderr.writeln(w.data);
}

void fatal(A...)(string fmt, A a) {
    say(fmt, a);
    killer.bail("fatal error");
    throw new BailException();
}

void error(A...)(Origin origin, string fmt, A a) {
    sayNoNewline("%s|%s| ERROR: ", origin.path, origin.line);
    fatal(fmt, a);
}

void errorUnless(A...)(bool condition, Origin origin, lazy string fmt, lazy A a) {
    if (!condition) {
        error(origin, fmt, a);
    }
}


//-------------------------------------------------------------------------
// path/filesystem utility functions
//-------------------------------------------------------------------------

//
// Ensure that the parent dir of path exists
//
void ensureParent(string path) {
    static bool[string] doesExist;

    string dir = dirName(path);
    if (dir !in doesExist) {
        if (!exists(dir)) {
            ensureParent(dir);
            mkdir(dir);
        }
        else if (!isDir(dir)) {
            error(Origin(), "%s is not a directory!", dir);
        }
        doesExist[path] = true;
    }
}


//
// Return a copy of the given relative path trail that has the
// appropriate directory separators for this platform.
//
string fixTrail(const char[] trail) {
    char[] fixed = trail.dup;

    assert(dirSeparator.length == 1);
    foreach (ref c; fixed) {
        if ((c == '/' || c == '\\') && c != dirSeparator[0]) {
            c = dirSeparator[0];
        }
    }

    return cast(immutable(char)[]) fixed;
}


//
// return the modification time of the file at path
// Note: A zero-length target file is treated as if it doesn't exist.
//
long modifiedTime(string path, bool isTarget) {
    if (!exists(path) || (isTarget && getSize(path) == 0)) {
        return 0;
    }
    SysTime fileAccessTime, fileModificationTime;
    getTimes(path, fileAccessTime, fileModificationTime);
    return fileModificationTime.stdTime;
}


//
// Return true if str starts with any of the given prefixes
//
bool startsWith(string str, string[] prefixes) {
    foreach (prefix; prefixes) {
        size_t len = prefix.length;
        if (str.length >= len && str[0 .. len] == prefix)
        {
            return true;
        }
    }
    return false;
}


//
// some thread-local "globals" to make things easier
//
bool g_print_rules;
bool g_print_deps;
bool g_print_culprit;
bool g_print_details;
bool g_touch;
