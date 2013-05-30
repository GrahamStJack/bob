/**
 * Copyright 2012-2013, Graham St Jack.
 *
 * This file is part of bob, a software build tool.
 *
 * Bob is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bob is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Bob.  If not, see <http://www.gnu.org/licenses/>.
 */

// TODO:
// * Port to windows.
//
// Lower priority wish-list:
// * Conditional Bobfile statements.
// * Add a mechanism to scrape the names of additional output filenames from
//   a source file using (say) a regex.
// * Generation of documentation from the code.
// * Support code coverage analysis for test-exe.
// * Improve correctness of scanning for imports and includes.

/*

A build tool suitable for C/C++ and D code, written in D.

Objectives of this build tool are:
* Easy to write and maintain build scripts (Bobfiles):
  - Simple syntax.
  - Automatic determination of which in-project libraries to link.
* Auto execution and evaluation of unit tests.
* Enforcement of dependency rules.
* Support for building source code from multiple repositories.
* Support for C/C++ and D.
* Support for code generation:
  - A source file isn't scanned for imports/includes until after it is up to date.
  - Dependencies inferred from these imports are automatically applied.

Refer to README and INSTRUCTIONS and examples for details on how to use bob.


Relationships Between Files
---------------------------

Files are arranged in a tree that represents containment, with additional
references between them implied by includes/imports in the code and explicit
refer statements in the Bobfiles. These references are used to manage dependencies.

An Action that builds Files depends on other Files. The Action cannot be issued
until all the its dependencies are satisfied, and will be issued if any of its
built Files are out of date wrt any of its dependencies. Each dependency has a
matching reference.

A scannable File may include/import (include) other Files. If File A directly or
transitively includes File B, then all files that depend on File A also depend
on File B.


Reference Rules
---------------

Each Node in the tree can be public or protected. The Node of the tree contains
its children publicly.

The reference rules are:
* A protected Node can only be referred to by sibling Nodes or Nodes contained
  by those siblings.
* A Node can only refer to another Node if its parent transitively refers to or
  transitively contains that other Node.
* Circular references are not allowed.

An object file can only be used once - either in a library or an executable.
Dynamic libraries don't count as a use - they effectively replace the static library.

A dynamic library cannot contain the same static library as another dynamic library.


Search paths
------------

Compilers are told to look in 'src' and 'obj' directories for input files.
The src directory contains links to each top-level package in all the
repositories that comprise the project.

Therefore, include directives have to include the path starting from
the top-level package names, which must be unique.

This namespacing avoids problems of duplicate filenames
at the cost of the compiler being able to find everything, even files
that should not be accessible. Bob therefore enforces all visibility
rules before invoking the compiler.


The build process
-----------------

Bob reads the project Bobfile, transiting into
other-package Bobfiles as packages are mentioned.

Bob assumes that new packages, libraries, etc are mentioned in dependency order.
That is, when each thing is mentioned, everything it depends on, including
dependencies inferred by include/import statements in source code, has already
been mentioned. Exception: a Bobfile can refer to previously-unknown top-level
packages.

The planner thread scans the Bobfiles, binding files to specific
locations in the filesystem as it goes, and builds the dependency graph.

The file state sequence is:
    initial
    dependencies_clean         skipped if no dependencies
    building                   skipped if no build action
    up-to-date
    scanning_for_includes      skipped if not scannable
    includes_known
    clean

As files become buildable, actions are put into a PriorityQueue ordered by
the File.number. As workers become available, actions are issued to them for
processing.

Build results cause the dependency graph to be updated, allowing more actions to
be issued. Specifically, generated source files are scanned for import/include
after they are up to date, and the dependency graph and action commands are
adjusted accordingly.
*/

import process;

import std.stdio;
import std.ascii;
import std.string;
import std.format;
import std.algorithm;
import std.range;
import std.file;
import std.path;
import std.conv;
import std.datetime;
import std.getopt;
import std.concurrency;
import std.functional;
import std.exception;

//----------------------------------------------------------------------------------------
// Platform-specific stuff
//----------------------------------------------------------------------------------------

version(Posix) {
    import core.sys.posix.signal;

    string copyCmd = "cp -f";

    int mykill(int pid, int sig) {
        return kill(pid, sig);
    }
}
else version(Windows) {
    // NOTE:
    // The Windows port is a work in progress and hasn't been tested yet.
    // The main sticking point is killing spawned processes - there doesn't seem to be
    // a way of doing that for third-party processes (ie ones whose source you can't change).
    // The work in progress is all those little issues like slash vs backslash.

    import core.stdc.signal;

    string copyCmd = "copy /Y";

    int mykill(int pid, int sig) {
        return 0;
    }
}


//-----------------------------------------------------------------------------------------
// PriorityQueue - insert items in any order, and remove largest-first
// (or smallest-first if "a > b" is passed for less).
//
// It is a simple input range (empty(), front() and popFront()).
//
// Notes from Wikipedia article on Binary Heap:
// * Tree is concocted using index arithetic on underlying array, as follows:
//   First layer is 0. Second is 1,2. Third is 3,4,5,6, etc.
//   Therefore parent of index i is (i-1)/2 and children of index i are 2*i+1 and 2*i+2
// * Tree is balanced, with incomplete population to right of bottom layer.
// * A parent is !less all its children.
// * Insert:
//   - Append to array.
//   - Swap new element with parent until parent !less child.
// * Remove:
//   - Replace root with the last element and reduce the length of the array.
//   - If moved element is less than a child, swap with largest child.
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
//
// bail() is called by the error() functions, which then throw an exception.
//------------------------------------------------------------------------------

class Killer {
    private {
        bool      bailed;
        bool[Pid] children;
    }

    // remember that a process has been launched, killing it if we have bailed
    void launched(string worker, Pid child) {
        synchronized(this) {
            if (bailed) {
                mykill(child.processID, SIGTERM);
            }
            else {
                children[child] = true;
            }
        }
    }

    // a child has been finished with
    void completed(string worker, Pid child) {
        synchronized(this) {
            children.remove(child);
        }
    }

    // bail, doing nothing if we had already bailed
    bool bail() {
        synchronized(this) {
            if (!bailed) {
                bailed = true;
                foreach (child; children.keys()) {
                    mykill(child.processID, SIGTERM);
                }
                return false;
            }
            else {
                return true;
            }
        }
    }
}

__gshared Killer killer;

shared static this() {
    killer = new Killer();
}


//-----------------------------------------------------------------------
// Signal handling to bail on SIGINT or SIGHUP.
//-----------------------------------------------------------------------

__gshared Tid bailerTid;

void doBailer() {
    try {
        bool done;
        while (!done) {
            receive( (int sig)      { killer.bail(); },
                    (string dummy) { done = true; }
                   );
        }
    }
    catch (Exception ex) {}
}

extern (C) void mySignalHandler(int sig) nothrow {
    try {
        bailerTid.send(sig);
    }
    catch (Exception ex) { assert(0, format("Unexpected exception: %s", ex)); }
}

shared static this() {
    bailerTid = spawn(&doBailer);

    signal(SIGINT, &mySignalHandler);
    version(Posix) {
        signal(SIGHUP, &mySignalHandler);
    }
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
    killer.bail();
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
            say("%-15s %s", "Mkdir", dir);
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
// return the privacy implied by args
//
Privacy privacyOf(ref Origin origin, string[] args) {
    if (!args.length ) return Privacy.PUBLIC;
    else if (args[0] == "protected")      return Privacy.PROTECTED;
    else if (args[0] == "semi-protected") return Privacy.SEMI_PROTECTED;
    else if (args[0] == "private")        return Privacy.PRIVATE;
    else if (args[0] == "public")         return Privacy.PUBLIC;
    else error(origin, "privacy must be one of public, semi-protected, protected or private");
    assert(0);
}


//
// Return true if the given suffix implies a scannable file.
//
bool isScannable(string suffix) {
    string ext = extension(suffix);
    if (ext is null) ext = suffix;
    return
        ext == ".c"   ||
        ext == ".h"   ||
        ext == ".cc"  ||
        ext == ".hh"  ||
        ext == ".cxx" ||
        ext == ".hxx" ||
        ext == ".cpp" ||
        ext == ".hpp" ||
        ext == ".d";
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


//------------------------------------------------------------------------
// File parsing
//------------------------------------------------------------------------

//
// Options read from Boboptions file
//

// General variables
string[string] options;

// Commmands to compile a source file into an object file
struct CompileCommand {
    string   command;
}
CompileCommand[string] compileCommands; // keyed on input extension

// Commands to generate files other than reserved extensions
struct GenerateCommand {
    string[] suffixes;
    string   command;
}
GenerateCommand[string] generateCommands; // keyed on input extension

// Commands that work with object files
struct LinkCommand {
    string staticLib;
    string dynamicLib;
    string executable;
}
LinkCommand[string] linkCommands; // keyed on source extension

bool[string] reservedExts;
static this() {
    reservedExts = [".obj":true, ".slib":true, ".dlib":true, ".exe":true];
}

//
// Read an options file, populating option lines
// Format is:   key = value
// value can contain '='
//
void readOptions() {
    string path = "Boboptions";
    Origin origin = Origin(path, 1);

    errorUnless(exists(path) && isFile(path), origin, "can't read Boboptions %s", path);

    string content = readText(path);
    foreach (line; splitLines(content)) {
        string[] tokens = split(line, " = ");
        if (tokens.length == 2) {
            string key   = strip(tokens[0]);
            string value = strip(tokens[1]);

            if (key[0] == '.') {
                // A command of some sort

                string[] extensions = split(key);
                if (extensions.length < 2) {
                    fatal("Commands require at least two extensions: %s", line);
                }
                string   input   = extensions[0];
                string[] outputs = extensions[1 .. $];

                errorUnless(input !in reservedExts, origin,
                            "Cannot use %s as source ext in commands", input);

                if (outputs.length == 1 && (outputs[0] == ".slib" ||
                                            outputs[0] == ".dlib" ||
                                            outputs[0] == ".exe")) {
                    // A link command
                    if (input !in linkCommands) {
                        linkCommands[input] = LinkCommand("", "", "");
                    }
                    LinkCommand *linkCommand = input in linkCommands;
                    if (outputs[0] == ".slib") linkCommand.staticLib  = value;
                    if (outputs[0] == ".dlib") linkCommand.dynamicLib = value;
                    if (outputs[0] == ".exe")  linkCommand.executable = value;
                }
                else if (outputs.length == 1 && outputs[0] == ".obj") {
                    // A compile command
                    errorUnless(input !in compileCommands && input !in generateCommands,
                                origin, "Multiple compile/generate commands using %s", input);
                    compileCommands[input] = CompileCommand(value);
                }
                else {
                    // A generate command
                    errorUnless(input !in compileCommands && input !in generateCommands,
                                origin, "Multiple compile/generate commands using %s", input);
                    foreach (ext; outputs) {
                        errorUnless(ext !in reservedExts, origin,
                                    "Cannot use %s in a generate command: %s", ext, line);
                    }
                    generateCommands[input] = GenerateCommand(outputs, value);
                }
            }
            else if (key.length > 6 && key[0 .. 6] == "syslib") {
                // syslib declaration
                SysLib.create(split(key[9 .. $]), split(value));
            }
            else {
                // A variable
                options[key] = value;
            }
        }
        else {
            fatal("Invalid Boboptions line: %s", line);
        }
    }
}

string getOption(string key) {
    auto value = key in options;
    if (value) {
        return *value;
    }
    else {
        return "";
    }
}


//
// Scan file for includes, returning an array of included trails
//   #   include   "trail"
//
// All of the files found should have trails relative to "src" (if source)
// or "obj" (if generated). All system includes must use angle-brackets,
// and are not returned from a scan.
//
struct Include {
    string trail;
    uint   line;
    bool   quoted;
}

Include[] scanForIncludes(string path) {
    Include[] result;
    Origin origin = Origin(path, 1);

    enum Phase { START, HASH, WORD, INCLUDE, QUOTE, ANGLE, NEXT }

    if (exists(path) && isFile(path)) {
        string content = readText(path);
        int anchor = 0;
        Phase phase = Phase.START;

        foreach (int i, char ch; content) {
            if (ch == '\n') {
                phase = Phase.START;
                ++origin.line;
            }
            else {
                switch (phase) {
                case Phase.START:
                    if (ch == '#') {
                        phase = Phase.HASH;
                    }
                    else if (!isWhite(ch)) {
                        phase = Phase.NEXT;
                    }
                    break;
                case Phase.HASH:
                    if (!isWhite(ch)) {
                        phase = Phase.WORD;
                        anchor = i;
                    }
                    break;
                case Phase.WORD:
                    if (isWhite(ch)) {
                        if (content[anchor .. i] == "include") {
                            phase = Phase.INCLUDE;
                        }
                        else {
                            phase = Phase.NEXT;
                        }
                    }
                    break;
                case Phase.INCLUDE:
                    if (ch == '"') {
                        phase = Phase.QUOTE;
                        anchor = i+1;
                    }
                    else if (ch == '<') {
                        phase = Phase.ANGLE;
                        anchor = i+1;
                    }
                    else if (isWhite(ch)) {
                        phase = Phase.NEXT;
                    }
                    break;
                case Phase.QUOTE:
                    if (ch == '"') {
                        result ~= Include(fixTrail(content[anchor .. i]), origin.line, true);
                        phase = Phase.NEXT;
                        //say("%s: found quoted include of %s", path, content[anchor .. i]);
                    }
                    else if (isWhite(ch)) {
                        phase = Phase.NEXT;
                    }
                    break;
                case Phase.ANGLE:
                    if (ch == '>') {
                        result ~= Include(fixTrail(content[anchor .. i]), origin.line, false);
                        phase = Phase.NEXT;
                        //say("%s: found system include of %s", path, content[anchor .. i]);
                    }
                    else if (isWhite(ch)) {
                        phase = Phase.NEXT;
                    }
                    break;
                case Phase.NEXT:
                    break;
                default:
                    error(origin, "invalid phase");
                }
            }
        }
    }
    return result;
}


//
// Scan a D source file for imports.
//
// The parser is simple and fast, but can't deal with version
// statements or mixins. This is ok for now because it only needs
// to work for source we have control over.
//
// The approach is:
// * Scan for a line starting with "static", "public", "private" or ""
//   followed by "import".
// * Then look for:
//     ':' - module is previous word, and then skip to next ';'.
//     ',' - module is previous word.
//     ';' - module is previous word.
//   The import is terminated by a ';'.
//
Include[] scanForImports(string path) {
    Include[] result;
    string content = readText(path);
    string word;
    int anchor, line=1;
    bool inWord, inImport, ignoring;

    string[] externals = [ "core", "std" ];

    foreach (int pos, char ch; content) {
        if (ch == '\n') {
            line++;
        }
        if (ignoring) {
            if (ch == ';' || ch == '\n') {
                // resume looking for imports
                ignoring = false;
                inWord   = false;
                inImport = false;
            }
            else {
                // ignore
            }
        }
        else {
            // we are not ignoring

            if (inWord && (isWhite(ch) || ch == ':' || ch == ',' || ch == ';')) {
                inWord = false;
                word = content[anchor .. pos];

                if (!inImport) {
                    if (isWhite(ch)) {
                        if (word == "import") {
                            inImport = true;
                        }
                        else if (word != "public" && word != "private" && word != "static") {
                            ignoring = true;
                        }
                    }
                    else {
                        ignoring = true;
                    }
                }
            }

            if (inImport && word && (ch == ':' || ch == ',' || ch == ';')) {
                // previous word is a module name

                string trail = std.array.replace(word, ".", dirSeparator) ~ ".d";

                bool ignored = false;
                foreach (external; externals) {
                    string ignoreStr = external ~ dirSeparator;
                    if (trail.length >= ignoreStr.length &&
                        trail[0 .. ignoreStr.length] == ignoreStr)
                    {
                        ignored = true;
                        break;
                    }
                }

                if (!ignored) {
                    result ~= Include(trail, line, true);
                }
                word = null;

                if      (ch == ':') ignoring = true;
                else if (ch == ';') inImport = false;
            }

            if (!inWord && !(isWhite(ch) || ch == ':' || ch == ',' || ch == ';')) {
                inWord = true;
                anchor = pos;
            }
        }
    }

    return result;
}


//
// Return the SysLibs implied by include/import of the specified header/module,
// or an empty array if none are implied.
//
// The libs are keyed on either a full trail to a header/module, or an ancestor
// of the trail. eg: one/two/three.h, one/two, or one.
//
SysLib[] knownSystemHeader(string header, SysLib[][string] libs) {
    string trail = header;
    while (trail != ".") {
        if (trail in libs) {
            return libs[trail];
        }
        trail = dirName(trail);
    }
    return [];
}


//
// read a Bobfile, returning all its statements
//
// //  a simple statement
// rulename targets... : arg1... : arg2... : arg3...; // can expand Boboptions variable with ${var-name}
//

struct Statement {
    Origin   origin;
    int      phase;    // 0==>empty, 1==>rule populated, 2==rule,targets populated, etc
    string   rule;
    string[] targets;
    string[] arg1;
    string[] arg2;
    string[] arg3;

    string toString() const {
        string result;
        if (phase >= 1) result ~= rule;
        if (phase >= 2) result ~= format(" : %s", targets);
        if (phase >= 3) result ~= format(" : %s", arg1);
        if (phase >= 4) result ~= format(" : %s", arg2);
        if (phase >= 5) result ~= format(" : %s", arg3);
        return result;
    }
}

Statement[] readBobfile(string path) {
    Statement[] statements;
    Origin origin = Origin(path, 1);
    errorUnless(exists(path) && isFile(path), origin, "can't read Bobfile %s", path);

    string content = readText(path);

    int       anchor;
    bool      inWord;
    bool      inComment;
    Statement statement;

    foreach (int pos, char ch ; content) {
        if (ch == '\n') {
            ++origin.line;
        }
        if (ch == '#') {
            inComment = true;
            inWord = false;
        }
        if (inComment) {
            if (ch == '\n') {
                inComment = false;
                anchor = pos;
            }
        }
        else if ((isWhite(ch) || ch == ':' || ch == ';')) {
            if (inWord) {
                inWord = false;
                string word = content[anchor .. pos];

                // should be a word in a statement

                string[] words = [word];

                if (word.length > 3 && word[0 .. 2] == "${" && word[$-1] == '}') {
                    // macro substitution
                    words = split(getOption(word[2 .. $-1]));
                }

                if (word.length > 0) {
                    if (statement.phase == 0) {
                        statement.origin = origin;
                        statement.rule = words[0];
                        ++statement.phase;
                    }
                    else if (statement.phase == 1) {
                        statement.targets ~= words;
                    }
                    else if (statement.phase == 2) {
                        statement.arg1 ~= words;
                    }
                    else if (statement.phase == 3) {
                        statement.arg2 ~= words;
                    }
                    else if (statement.phase == 4) {
                        statement.arg3 ~= words;
                    }
                    else {
                        error(origin, "Too many arguments in %s", path);
                    }
                }
            }

            if (ch == ':' || ch == ';') {
                ++statement.phase;
                if (ch == ';') {
                    if (statement.phase > 1) {
                        statements ~= statement;
                    }
                    statement = statement.init;
                }
            }
        }
        else if (!inWord) {
            inWord = true;
            anchor = pos;
        }
    }
    errorUnless(statement.phase == 0, origin, "%s ends in unterminated statement", path);
    return statements;
}


//-------------------------------------------------------------------------
// Planner
//
// Planner reads Bobfiles, understands what they mean, builds
// a tree of packages, etc, understands what it all means, enforces rules,
// binds everything to filenames, discovers modification times, scans for
// includes, and schedules actions for processing by the worker.
//
// Also receives results of successful actions from the Worker,
// does additional scanning for includes, updates modification
// times and schedules more work.
//
// A critical feature is that scans for includes are deferred until
// a file is up-to-date.
//-------------------------------------------------------------------------


// some thread-local "globals" to make things easier
bool g_print_rules;
bool g_print_deps;
bool g_print_details;


//
// Action - specifies how to build some files, and what they depend on
//
final class Action {
    static Action[string]       byName;
    static int                  nextNumber;
    static PriorityQueue!Action queue;

    string  name;      // the name of the action
    string  command;   // the action command-string
    int     number;    // influences build order
    File[]  inputs;    // files the action directly relies on, specified with initial depends
    File[]  builds;    // files that this action builds
    File[]  depends;   // files that the action depend on
    bool    finalised; // true if the action command has been finalised
    bool    issued;    // true if the action has been issued to a worker

    this(Origin origin, Pkg pkg, string name_, string command_, File[] builds_, File[] inputs_) {
        name     = name_;
        command  = command_;
        number   = nextNumber++;
        inputs   = inputs_;
        builds   = builds_;
        depends  = inputs_;
        errorUnless(!(name in byName), origin, "Duplicate command name=%s", name);
        byName[name] = this;

        // All the files built by this action depend on the Bobfile
        depends ~= pkg.bobfile;

        // Recognise in-project tools in the command.
        foreach (token; split(command)) {
            if (token.startsWith([buildPath("dist", "bin"), "priv"])) {
                // Find the tool
                File *tool = token in File.byPath;
                errorUnless(tool !is null, origin, "Unknown in-project tool %s", token);

                // Is the tool already involved in this action?
                bool involved;
                foreach (file; chain(builds, depends)) {
                    if (file is *tool) {
                        involved = true;
                    }
                }

                if (!involved) {
                    // Verify that these built files can refer to it.
                    foreach (file; builds) {
                        if (!is(typeof(file.parent) : Pkg) &&
                            !file.parent.allowsRefTo(origin, *tool))
                        {
                            // Add enabling reference from parent to tool
                            file.parent.addReference(origin, *tool);
                        }
                        // Add reference to tool
                        file.addReference(origin, *tool);
                    }

                    // Add the dependency.
                    depends ~= *tool;
                }
            }
        }

        // set up reverse dependencies between builds and depends
        foreach (depend; depends) {
            foreach (built; builds) {
                depend.dependedBy[built] = true;
                if (g_print_deps) say("%s depends on %s", built.path, depend.path);
            }
        }
    }

    // add an extra depend to this action
    void addDependency(File depend) {
        if (issued) fatal("Cannot add a dependancy to issued action %s", this);
        if (builds.length != 1) {
            fatal("cannot add a dependency to an action that builds more than one file: %s", name);
        }
        if (builds[0] !in depend.dependedBy) {
            depends ~= depend;
            depend.dependedBy[builds[0]] = true;
            if (g_print_deps) say("%s depends on %s", builds[0].path, depend.path);
        }
    }

    // Finalise the action command.
    // Commands can contain any number of ${varname} instances, which are
    // replaced with the content of the named variable, cross-multiplied with
    // any adjacent text.
    // Special variables are:
    //   INPUT    -> Paths of the input files.
    //   OUTPUT   -> Paths of the built files.
    //   PROJ_INC -> Paths of project include/import dirs relative to build dir.
    //   PROJ_LIB -> Paths of project library dirs relative to build dir.
    //   LIBS     -> Names of all required libraries, without lib prefix or extension.
    void finaliseCommand(string[] libs) {
        assert(!issued);
        finalised = true;

        // Local function to expand variables in a string.
        string resolve(string text) {
            string result;

            bool   inToken, inCurly;
            size_t anchor;
            char   prev;
            string prefix, varname, suffix;

            // Local function to finish processing a token.
            void finishToken(size_t pos) {
                suffix = text[anchor .. pos];
                size_t start = result.length;

                string[] values;
                if (varname.length) {
                    // Get the variable's values
                    if      (varname == "INPUT") {
                        foreach (file; inputs) {
                            values ~= file.path;
                        }
                    }
                    else if (varname == "OUTPUT") {
                        foreach (file; builds) {
                            values ~= file.path;
                        }
                    }
                    else if (varname == "PROJ_INC") {
                        values = ["src", "obj"];
                    }
                    else if (varname == "PROJ_LIB") {
                        values = [buildPath("dist", "lib"), "obj"];
                    }
                    else if (varname == "LIBS") {
                        values = libs;
                    }
                    else if (varname in options) {
                        values = split(resolve(options[varname]));
                    }
                    else {
                        // Not in Boboptions, so it evaluated to empty.
                        values = [];
                    }

                    // Cross-multiply with prefix and suffix
                    foreach (value; values) {
                        result ~= prefix ~ value ~ suffix ~ " ";
                    }
                }
                else {
                    // No variable - just use the suffix
                    result ~= suffix ~ " ";
                }

                // Clean up for next token
                prefix  = "";
                varname = "";
                suffix  = "";
                inToken = false;
                inCurly = false;
            }

            foreach (pos, ch; text) {
                if (!inToken && !isWhite(ch)) {
                    // Starting a token
                    inToken = true;
                    anchor  = pos;
                }
                else if (inToken && ch == '{' && prev == '$') {
                    // Starting a varname within a token
                    prefix  = text[anchor .. pos-1];
                    inCurly = true;
                    anchor  = pos + 1;
                }
                else if (ch == '}') {
                    // Finished a varname within a token
                    if (!inCurly) {
                        fatal("Unmatched '}' in '%s'", text);
                    }
                    varname = text[anchor .. pos];
                    inCurly = false;
                    anchor  = pos + 1;
                }
                else if (inToken && isWhite(ch)) {
                    // Finished a token
                    finishToken(pos);
                }
                prev = ch;
            }
            if (inToken) {
                finishToken(text.length);
            }
            return result;
        }

        command = resolve(command);
    }

    // issue this action
    void issue() {
        assert(!issued);
        if (!finalised) {
            finaliseCommand([]);
        }
        issued = true;
        queue.insert(this);
    }

    override string toString() {
        return name;
    }
    override int opCmp(Object o) const {
        // reverse order
        if (this is o) return 0;
        Action a = cast(Action)o;
        if (a is null) return  -1;
        return a.number - number;
    }
}


//
// SysLib - represents a library outside the project.
//
// It is automatically required by an in-project shared library or exe
// if any of its outside-the-project headers are imported/included.
//
final class SysLib {
    static SysLib[string]   byName;
    static SysLib[][string] byHeader;
    static int              nextNumber;

    string name;
    int    number;

    static create(string[] libNames, string[] headers) {
        SysLib[] libs;
        foreach (name; libNames) {
            libs ~= new SysLib(name);
        }
        foreach (header; headers) {
            if (header in byHeader) {
                fatal("System header %s used in multiple syslib variables", header);
            }
            byHeader[header] = libs;
        }
    }

    private this(string name_) {
        name         = name_;
        number       = nextNumber++;
        byName[name] = this;
    }

    override string toString() const {
        return name;
    }

    override int opCmp(Object o) const {
        // reverse order
        if (this is o) return 0;
        SysLib a = cast(SysLib)o;
        if (a is null) return  -1;
        return a.number - number;
    }
}


//
// Node - abstract base class for things in an ownership tree
// with cross-linked dependencies. Used to manage allowed references.
//

// additional constraint on allowed references
enum Privacy { PUBLIC,           // no additional constraint
               SEMI_PROTECTED,   // only accessable to descendents of grandparent
               PROTECTED,        // only accessible to children of parent
               PRIVATE }         // not accessible

class Node {
    static Node[string] byTrail;

    string  name;    // simple name this node adds to parent
    string  trail;   // slash-separated name components from after-root to this
    Node    parent;
    Privacy privacy;
    Node[]  children;
    Node[]  refers;

    override string toString() const {
        return trail;
    }

    // create the root of the tree
    this() {
        trail = "root";
        assert(trail !in byTrail, "already have root node");
        byTrail[trail] = this;
    }

    // create a node and place it into the tree
    this(Origin origin, Node parent_, string name_, Privacy privacy_) {
        assert(parent_);
        errorUnless(dirName(name_) == ".",
                    origin,
                    "Cannot define node with multi-part name '%s'", name_);
        parent  = parent_;
        name    = name_;
        privacy = privacy_;
        if (parent.parent) {
            // child of non-root
            trail = buildPath(parent.trail, name);
        }
        else {
            // child of the root
            trail = name;
        }
        parent.children ~= this;
        errorUnless(trail !in byTrail, origin, "%s already known", trail);
        byTrail[trail] = this;
    }

    // return true if this is a descendant of other
    private bool isDescendantOf(Node other) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other) return true;
        }
        return false;
    }

    // return true if this is a visible descendant of other
    private bool isVisibleDescendantOf(Node other, Privacy allowed) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other)            return true;
            if (node.privacy > allowed)   break;
            if (allowed > Privacy.PUBLIC) allowed--;
        }
        return false;
    }

    // return true if other is a visible-child or reference of this,
    // or is a visible-descendant of them
    bool allowsRefTo(ref Origin origin,
                     Node       other,
                     size_t     depth        = 0,
                     Privacy    allowPrivacy = Privacy.PROTECTED,
                     bool[Node] checked      = null) {
        errorUnless(depth < 100, origin,
                    "circular reference involving %s referring to %s",
                    this,
                    other);
        //say("for %s: checking if %s allowsReferenceTo %s", origin.path, this, other);
        if (other is this || other.isVisibleDescendantOf(this, allowPrivacy)) {
            if (g_print_details) say("%s allows reference to %s via containment", this, other);
            return true;
        }
        foreach (node; refers) {
            // referred-to nodes grant access to their public children, and referred-to
            // siblings grant access to their semi-protected children
            if (node !in checked) {
                checked[node] = true;
                if (node.allowsRefTo(origin,
                                     other,
                                     depth+1,
                                     node.parent is this.parent ?
                                     Privacy.SEMI_PROTECTED : Privacy.PUBLIC,
                                     checked)) {
                    if (g_print_details) {
                        say("%s allows reference to %s via explicit reference", this, other);
                    }
                    return true;
                }
            }
        }
        return false;
    }

    // Add a reference to another node. Cannot refer to:
    // * Nodes that aren't defined yet.
    // * Self.
    // * Ancestors.
    // * Nodes whose selves or ancestors have not been referred to by our parent.
    // Also can't explicitly refer to children - you get that implicitly.
    final void addReference(ref Origin origin, Node other, string cause = null) {
        errorUnless(other !is null,
                    origin, "%s cannot refer to NULL node", this);

        errorUnless(other != this,
                    origin, "%s cannot refer to self", this);

        errorUnless(!this.isDescendantOf(other),
                    origin, "%s cannot refer to ancestor %s", this, other);

        errorUnless(!other.isDescendantOf(this),
                    origin, "%s cannnot explicitly refer to descendant %s", this, other);

        errorUnless(this.parent.allowsRefTo(origin, other),
                    origin, "Parent %s does not allow %s to refer to %s", parent, this, other);

        errorUnless(!other.allowsRefTo(origin, this),
                    origin, "%s cannot refer to %s because of a circularity", this, other);

        if (g_print_deps) say("%s refers to %s%s", this, other, cause);
        refers ~= other;
    }
}


//
// Pkg - a package (directory containing a Bobfile).
// Has a Bobfile, assorted source and built files, and sub-packages
// Used to group files together for dependency control, and to house a Bobfile.
//
final class Pkg : Node {

    File bobfile;

    this(Origin origin, Node parent_, string name_, Privacy privacy_) {
        super(origin, parent_, name_, privacy_);
        bobfile = File.addSource(origin, this, "Bobfile", Privacy.PRIVATE, false);
    }
}


//
// A file
//
class File : Node {
    static File[string]   byPath;      // Files by their path
    static bool[File]     allBuilt;    // all built files
    static bool[File]     outstanding; // outstanding buildable files
    static int            nextNumber;

    // Statistics
    static uint numBuilt;              // number of files targeted
    static uint numUpdated;            // number of files successfully updated by actions

    string     path;                   // the file's path
    int        number;                 // order of file creation
    bool       scannable;              // true if the file should be scanned
    bool       built;                  // true if this file will be built by an action
    Action     action;                 // the action used to build this file (null if non-built)

    long       modTime;                // the modification time of this file
    bool       used;                   // true if this file has been used already

    // state-machine stuff
    bool         scanned;                // true if this has already been scanned for includes
    Origin[File] includes;               // Origins by the Files this includes
    bool[File]   includedBy;             // Files that include this
    bool[File]   dependedBy;             // Files that depend on this
    bool         clean;                  // true if usable by higher-level files

    // return a prospective path to a potential file.
    static string prospectivePath(string start, Node parent, string extra) {
        Node node = parent;
        while (node !is null) {
            Pkg pkg = cast(Pkg) node;
            if (pkg) {
                return buildPath(start, pkg.trail, extra);
            }
            node = node.parent;
        }
        fatal("prospective file %s's parent %s has no package in its ancestry", extra, parent);
        assert(0);
    }

    this(ref Origin origin, Node parent_, string name_, Privacy privacy_, string path_,
         bool scannable_, bool built_)
    {
        super(origin, parent_, name_, privacy_);

        path      = path_;
        scannable = scannable_;
        built     = built_;

        number    = nextNumber++;

        modTime   = modifiedTime(path, built);

        errorUnless(path !in byPath, origin, "%s already defined", path);
        byPath[path] = this;

        if (built) {
            ++numBuilt;
            allBuilt[this] = true;
            outstanding[this] = true;
        }
    }

    // Add a source file specifying its trail within its package
    static File addSource(ref Origin origin, Node parent, string extra, Privacy privacy, bool scannable) {

        // possible paths to the file
        string path1 = prospectivePath("obj", parent, extra);  // a built file in obj directory tree
        string path2 = prospectivePath("src", parent, extra);  // a source file in src directory tree

        string name  = baseName(extra);

        File * file = path1 in byPath;
        if (file) {
            // this is a built source file we already know about
            errorUnless(!file.used, origin, "%s has already been used", path1);
            return *file;
        }
        else if (exists(path2)) {
            // a source file under src
            return new File(origin, parent, name, privacy, path2, scannable, false);
        }
        else {
            error(origin, "Could not find source file %s in %s, or %s", name, path1, path2);
            assert(0);
        }
    }

    // This file has been updated
    final void updated() {
        ++numUpdated;
        modTime = modifiedTime(path, true);
        if (g_print_details) say("Updated %s, mod_time %s", this, modTime);
        if (action !is null) {
            action = null;
            outstanding.remove(this);
        }
        touch();
    }

    // Scan this file for includes/imports, incorporating them into the
    // dependency graph.
    private void scan() {
        errorUnless(!scanned, Origin(path, 1), "%s has been scanned for includes twice!", this);
        scanned = true;
        if (scannable) {

            // scan for includes
            Include[] entries;
            string ext = extension(path);

            switch (ext) {
              case ".c":
              case ".h":
              case ".cc":
              case ".hh":
              case ".cxx":
              case ".hxx":
              case ".cpp":
              case ".hpp":
                entries = scanForIncludes(path);
                break;
              case ".d":
                entries = scanForImports(path);
                break;
              default:
                fatal("Don't know how to scan %s for includes/imports", path);
            }

            foreach (entry; entries) {
                Origin origin = Origin(this.path, entry.line);

                // try to find the included file within the project or in the known system headers

                File *file;
                // under src?
                File *include = buildPath("src", entry.trail) in byPath;
                if (include is null) {
                    // under obj?
                    include = buildPath("obj", entry.trail) in byPath;
                }
                if (include is null) {
                    // Last chance - it might be a known system header or header directory.

                    SysLib[] libs = knownSystemHeader(entry.trail, SysLib.byHeader);
                    if (libs.length > 0) {
                        // known system header or system header directory -
                        // tell containers about it so they can pick up SysLibs
                        //say("included external header %s", entry.trail);
                        systemHeaderIncluded(origin, this, libs);
                        continue;
                    }
                    else if (!entry.quoted) {
                        // Ignore unknown C/C++ <system> includes, hoping they are from std libs
                        continue;
                    }
                }
                errorUnless(include !is null,
                            origin,
                            "included/imported unknown file %s",
                            entry.trail);

                // add the include
                if (g_print_deps) say("%s includes/imports %s", this.path, include.path);
                includes[*include] = origin;
                include.includedBy[this] = true;
            }
        }
    }

    // Add all the relationships implied by this file's includes.
    // IMPORTANT - called once, just before this file becomes clean,
    // which means that it is up to date and all its includes are also clean.
    // The delayed resolution is necessary because includes are discovered in
    // an arbitrary order, so we have to wait till all the down-stream includes
    // are discovered before we can work out what they mean.
    // Here are the implications of an include:
    // * Each direct or transitive include adds a dependency to this file's dependents.
    // * This file's dependents (see Binary) may infer extra things from the direct includes.
    // * Each direct include implies a reference from this to the include.
    void resolveIncludes() {

        bool[File] got;

        // Resolve consequences of transitive include
        void resolve(Origin origin, File includer, File included) {

            if (included in got) {
                return;
            }
            got[included] = true;

            // Our dependents also depend on the included file.
            foreach (dependent; dependedBy.keys()) {
                errorUnless(dependent.action !is null, origin, "%s has no action", dependent.path);
                dependent.action.addDependency(included);
            }

            // Transit into included's includes
            foreach (included2, origin2; included.includes) {
                resolve(origin2, included, included2);
            }
        }

        foreach (included, origin; includes) {
            // This file's dependents may want to know about the include too.
            includeAdded(origin, this, included);

            // Now (after includeAdded calls so this File's parents have had a chance to
            // add an enabling reference), add a reference between this file and the
            // included one.
            addReference(origin, included);

            // This file's dependents depend on this file's transitive includes.
            resolve(origin, this, included);
        }
    }

    // An include has been added from includer to included.
    // Specialisations of File override to infer linking to in-project libraries.
    void includeAdded(ref Origin origin, File includer, File included) {
        foreach (depend; dependedBy.keys()) {
            depend.includeAdded(origin, includer, included);
        }
    }

    // A system header has been included by includer (which is this or a file this depends on).
    // Specialisations of File override to infer linking to SysLibs.
    void systemHeaderIncluded(ref Origin origin, File includer, SysLib[] libs) {
        foreach (depend; dependedBy.keys()) {
            depend.systemHeaderIncluded(origin, includer, libs);
        }
    }

    // This file's action is about to be issued, and this is the last chance to
    // add dependencies to it. Specialisations should override this method, and at the
    // very least finalise the action's command.
    // Return true if dependencies were added.
    bool augmentAction() {
        if (action) {
            action.finaliseCommand([]);
        }
        return false;
    }

    // Work out if this File's state should change, and if its Action should be issued.
    final void touch() {
        if (clean) return;
        if (g_print_details) say("touching %s", path);
        long newest;

        if (action && !action.issued) {
            // this item's action may need to be issued
            //say("file %s touched", this);

            for (;;) {
                foreach (depend; action.depends) {
                    if (!depend.clean) {
                        if (g_print_details) {
                            say("%s waiting for %s to become clean", path, depend.path);
                        }
                        return;
                    }
                    if (newest < depend.modTime) {
                        newest = depend.modTime;
                    }
                }
                // all files this one depends on are clean

                // give this file a chance to augment its action
                if (!augmentAction()) {
                    // No dependencies added - we know our newest dependency modTime
                    break;
                }

                // Dependency added - go around again to re-check dependencies
            }

            // We can issue the action now if this file is out of date
            if (modTime < newest) {
                // Out of date - issue action to worker
                if (g_print_details) {
                    say("%s is out of date with mod_time %s", this, modTime);
                }
                action.issue();
                return;
            }
            else {
                // already up to date - no need for building
                if (g_print_details) say("%s is up to date", path);
                action = null;
                outstanding.remove(this);
            }
        }

        if (action) {
            // Still waiting for action to be issued or complete
            return;
        }
        errorUnless(modTime > 0, Origin(path, 1),
                    "%s (%s) is up to date with zero mod_time!", path, trail);
        // This file is up to date

        // If we haven't already scanned for includes, do it now.
        if (!scanned) scan();

        foreach (include; includes.keys()) {
            if (!include.clean) {
                // Can't progress until all our includes are clean
                return;
            }
        }

        // Work through all the implications of this file's includes, now that
        // all owr down-stream includes are clean.
        resolveIncludes();

        // We are now squeaky clean
        clean = true;

        // touch everything that includes or depends on this
        foreach (other; chain(includedBy.keys(), dependedBy.keys())) {
            other.touch();
        }
    }

    // Sort Files by decreasing number order. Used to determine the order
    // in which libraries are linked.
    override int opCmp(Object o) const {
        // reverse order
        if (this is o) return 0;
        File a = cast(File)o;
        if (a is null) return  -1;
        return a.number - number;
    }

    // Print a file as its path.
    override string toString() const {
        return path;
    }

}


// Free function to validate the compatibility of a source extension
// given that sourceExt is already being used.
string validateExtension(Origin origin, string newExt, string usingExt) {
    string result = usingExt;
    if (usingExt == null || usingExt == ".c") {
        result = newExt;
    }
    errorUnless(result == newExt || newExt == ".c", origin,
                "Cannot use object file compiled from %s when already using %s",
                newExt, usingExt);
    return result;
}

//
// Binary - a binary file which incorporates object files and 'owns' source files.
// Concrete implementations are StaticLib and Exe.
//
abstract class Binary : File {
    static Binary[File] byContent; // binaries by the header and body files they 'contain'

    File[]       objs;
    File[]       headers;
    bool[File]   publics;
    bool[SysLib] reqSysLibs;
    bool[Binary] reqBinaries;
    string       sourceExt;  // The source extension object files are compiled from.

    // create a binary using files from this package.
    // The sources may be already-known built files or source files in the repo,
    // but can't already be used by another Binary.
    this(ref Origin origin, Pkg pkg, string name_, string path_,
         string[] publicSources, string[] protectedSources) {

        super(origin, pkg, name_, Privacy.PUBLIC, path_, false, true);

        // Local function to add a source file to this Binary
        void addSource(string name, Privacy privacy) {

            // Create a File to represent the named source file.
            string ext = extension(name);
            File sourceFile = File.addSource(origin, this, name, privacy, isScannable(ext));

            errorUnless(sourceFile !in byContent, origin, "%s already used", sourceFile.path);
            byContent[sourceFile] = this;

            if (g_print_deps) say("%s contains %s", this.path, sourceFile.path);

            // Look for a command to do something with the source file.

            CompileCommand  *compile  = ext in compileCommands;
            GenerateCommand *generate = ext in generateCommands;

            if (compile) {
                // Compile an object file from this source.

                // Remember what source extension this binary uses.
                sourceExt = validateExtension(origin, ext, sourceExt);

                string destName = stripExtension(sourceFile.name) ~ ".o";
                string destPath = prospectivePath("obj", sourceFile.parent, destName);
                File obj = new File(origin, this, destName, Privacy.PUBLIC, destPath, false, true);
                objs ~= obj;

                errorUnless(obj !in byContent, origin, "%s already used", obj.path);
                byContent[obj] = this;

                string actionName = format("%-15s %s", "Compile", sourceFile.path);

                obj.action = new Action(origin, pkg, actionName, compile.command,
                                        [obj], [sourceFile]);
            }
            else if (generate) {
                // Generate more source files from sourceFile.

                File[] files;
                string suffixes;
                foreach (suffix; generate.suffixes) {
                    string destName = stripExtension(name) ~ suffix;
                    string destPath = buildPath("obj", parent.trail, destName);
                    File gen = new File(origin, this, destName, privacy, destPath,
                                        isScannable(suffix), true);
                    files    ~= gen;
                    suffixes ~= suffix ~ " ";
                }
                Action action = new Action(origin,
                                           pkg,
                                           format("%-15s %s", ext ~ "->" ~ suffixes, sourceFile.path),
                                           generate.command,
                                           files,
                                           [sourceFile]);
                foreach (gen; files) {
                    gen.action = action;
                }

                // And add them as sources too.
                foreach (gen; files) {
                    addSource(gen.name, privacy);
                }
            }
            else {
                // No compile or generate commands - assume it is a header file.
                headers ~= sourceFile;
            }

            if (privacy == Privacy.PUBLIC) {
                // This file may need to be exported
                publics[sourceFile] = true;
            }
        }

        errorUnless(publicSources.length + protectedSources.length > 0,
                    origin,
                    "binary must have at least one source file");

        foreach (source; publicSources) {
            addSource(source, Privacy.PUBLIC);
        }
        foreach (source; protectedSources) {
            addSource(source, Privacy.SEMI_PROTECTED);
        }
    }

    override void includeAdded(ref Origin origin, File includer, File included) {
        // A file we depend on (includer) has included another file (included).
        // This might mean that this Binary requires another (this is how we find out
        // out which libraries to link).
        Binary *includerContainer = includer in byContent;
        if (includerContainer && *includerContainer is this) {
            Binary *includedContainer = included in byContent;
            errorUnless(includedContainer !is null,
                        origin,
                        "included file is not contained in a library");
            if (*includedContainer !is this && *includedContainer !in reqBinaries) {

                // we require the container of the included file
                if (g_print_deps) say("%s requires %s", this.path, includedContainer.path);
                reqBinaries[*includedContainer] = true;

                // add a reference
                addReference(origin, *includedContainer,
                             format(" because %s includes %s", includer.path, included.path));

                // Insist that if includer is a public file in a public static lib,
                // all its includes have to also be public files in public static libs.
                // This is necessary because they all need to be copied into dist/include
                // for export.
                StaticLib slib = cast(StaticLib) *includerContainer;
                if (slib !is null && slib.isPublic && includer in slib.publics) {
                    StaticLib other = cast(StaticLib) *includedContainer;
                    errorUnless(other !is null && other.isPublic && included in other.publics,
                                origin,
                                "Exported %s cannot include non-exported %s",
                                includer,
                                included);
                }
            }
        }
    }

    override void systemHeaderIncluded(ref Origin origin, File includer, SysLib[] libs) {
        // A file we depend on (includer) has included an external header (included)
        // that isn't for one of the standard system libraries. Add the SysLib(s) to reqSysLibs.
        Binary *container = includer in byContent;
        if (container && *container is this) {
            foreach (lib; libs) {
                if (lib !in reqSysLibs) {
                    reqSysLibs[lib] = true;
                    if (g_print_deps) say("%s requires external lib '%s'", this, lib);
                }
            }
        }
    }
}


//
// StaticLib - a static library.
//
final class StaticLib : Binary {

    string uniqueName;
    bool   isPublic;

    this(ref Origin origin, Pkg pkg, string name_,
         string[] publicSources, string[] protectedSources, bool isPublic_) {

        isPublic = isPublic_;

        // Decide on a name for the library.
        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-") ~ "-s";
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-") ~ "-s";
        string _basename = format("lib%s.a", uniqueName);

        // Decide on a path for the library.
        string _path;
        if (isPublic) {
            // The library is distributable.
            _path = buildPath("dist", "lib", _basename);
        }
        else {
            // The library is private to the project.
            _path = buildPath("obj", _basename);
        }

        // Super-constructor takes care of code generation and compiling to object files.
        super(origin, pkg, name_, _path, publicSources, protectedSources);

        // Decide on an action.
        string actionName = format("%-15s %s", "StaticLib", path);
        if (objs.length > 0) {
          // A proper static lib with object files
          LinkCommand *linkCommand = sourceExt in linkCommands;
          errorUnless(linkCommand && linkCommand.staticLib.length, origin,
                      "No link command for static lib from '%s'", sourceExt);
          action = new Action(origin, pkg, actionName, linkCommand.staticLib, [this], objs);

          // Add dependencies on the headers too so that includeAdded() will be called on us
          // for includes those headers make.
          foreach (header; headers) {
              action.addDependency(header);
          }
        }
        else {
          // A place-holder file to fit in with dependency tracking
          action = new Action(origin, pkg, actionName, "DUMMY", [this], headers);
        }

        if (isPublic) {
            // This library's public sources are distributable, so we copy them into dist/include
            // TODO Convert from "" to <> #includes in .h files
            string copyBase = buildPath("dist", "include");
            foreach (source; publics.keys()) {
                string destPath = prospectivePath(copyBase, this, source.name);
                File copy = new File(origin, this, source.name ~ "-copy",
                                     Privacy.PRIVATE, destPath, false, true);

                copy.action = new Action(origin, pkg,
                                         format("%-15s %s", "Export", source.path),
                                         copyCmd ~ " ${INPUT} ${OUTPUT}",
                                         [copy], [source]);
            }
        }
    }
}

// Free function used by DynamicLib and Exe to determine which libraries they
// need to link with.
//
// target is the File that will use the libraries.
// binaries is all the static and system libraries known to be needed from
// source-code import/include statements.
//
// Returns the needed libraries sorted in descending number order,
// which is the appropriate order for linking.
void neededLibs(File             target,
                Binary[]         binaries,
                ref StaticLib[]  staticLibs,
                ref DynamicLib[] dynamicLibs,
                ref SysLib[]     sysLibs) {

    bool[Object] done;   // Everything already considered

    staticLibs  = [];
    dynamicLibs = [];
    sysLibs     = [];

    void accumulate(Object obj) {
        if (obj in done) return;
        done[obj] = true;

        Exe        exe  = cast(Exe)        obj;
        StaticLib  slib = cast(StaticLib)  obj;
        DynamicLib dlib = cast(DynamicLib) obj;
        SysLib     sys  = cast(SysLib)     obj;

        if (exe !is null) {
            foreach (other; exe.reqBinaries.keys) {
                accumulate(other);
            }
            foreach (other; exe.reqSysLibs.keys) {
                accumulate(other);
            }
        }
        else if (slib !is null) {
            foreach (other; slib.reqBinaries.keys) {
                accumulate(other);
            }
            foreach (other; slib.reqSysLibs.keys) {
                accumulate(other);
            }
            DynamicLib* dynamic = slib in DynamicLib.byContent;
            if (dynamic is null || dynamic.number > target.number) {
                if (slib.objs.length > 0) {
                    staticLibs ~= slib;
                }
            }
            else if (*dynamic !is target) {
                accumulate(*dynamic);
            }
        }
        else if (dlib !is null) {
            dynamicLibs ~= dlib;
        }
        else if (sys !is null) {
            sysLibs ~= sys;
        }
        else {
            fatal("logic error");
        }
    }

    foreach (obj; binaries) {
        accumulate(obj);
    }
    staticLibs.sort();
    dynamicLibs.sort();
    sysLibs.sort();

    //say("%s requires %s,%s,%s", target, staticLibs, dynamicLibs, sysLibs);
}


//
// DynamicLib - a dynamic library. Contains all of the object files
// from a number of specified StaticLibs. If defined prior to an Exe, the Exe will
// link with the DynamicLib instead of those StaticLibs.
//
// Any StaticLibs required by the incorporated StaticLibs must also be incorporated
// into DynamicLibs.
//
// The static lib names are relative to pkg, and therefore only descendants of the DynamicLib's
// parent can be incorporated.
//
final class DynamicLib : File {
    static DynamicLib[StaticLib] byContent; // dynamic libs by the static libs they 'contain'
    Origin origin;
    bool   augmented;
    string uniqueName;

    StaticLib[] staticLibs;
    string      sourceExt;

    this(ref Origin origin_, Pkg pkg, string name_, string[] staticTrails) {
        origin = origin_;

        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-");
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-");
        string _path = buildPath("dist", "lib", format("lib%s.so", uniqueName));

        super(origin, pkg, name_ ~ "-dynamic", Privacy.PUBLIC, _path, false, true);

        foreach (trail; staticTrails) {
            string trail1 = buildPath(pkg.trail, trail, baseName(trail));
            string trail2 = buildPath(pkg.trail, trail);
            Node* node = trail1 in Node.byTrail;
            if (node is null || cast(StaticLib*) node is null) {
                node = trail2 in Node.byTrail;
                if (node is null || cast(StaticLib*) node is null) {
                    error(origin,
                          "Unknown static-lib %s, looked for with trails %s and %s",
                          trail, trail1, trail2);
                }
            }
            StaticLib* staticLib = cast(StaticLib*) node;
            errorUnless(*staticLib !in byContent, origin,
                        "static lib %s already used by dynamic lib %s",
                        *staticLib, byContent[*staticLib]);
            addReference(origin, *staticLib);
            staticLibs ~= *staticLib;
            byContent[*staticLib] = this;

            sourceExt = validateExtension(origin, staticLib.sourceExt, sourceExt);
        }
        errorUnless(staticLibs.length > 0, origin, "dynamic-lib must have at least one static-lib");

        // action
        string actionName = format("%-15s %s", "DynamicLib", path);
        LinkCommand *linkCommand = sourceExt in linkCommands;
        errorUnless(linkCommand !is null && linkCommand.dynamicLib != null, origin,
                    "No link command for %s -> .dlib", sourceExt);
        File[] objs;
        foreach (staticLib; staticLibs) {
            foreach (obj; staticLib.objs) {
                objs ~= obj;
            }
        }
        action = new Action(origin, pkg, actionName, linkCommand.dynamicLib, [this], objs);
    }


    // Called just before our action is issued.
    // Verify that all the StaticLibs we now know that we depend on are contained by this or
    // another earlier-defined-than-this DynamicLib.
    // Add any required SysLibs to our action.
    override bool augmentAction() {
        if (augmented) return false;
        augmented = true;

        StaticLib[]  neededStaticLibs;
        DynamicLib[] neededDynamicLibs;
        SysLib[]     neededSysLibs;

        neededLibs(this, cast(Binary[]) staticLibs,
                   neededStaticLibs, neededDynamicLibs, neededSysLibs);

        string[] libs;
        bool added;

        if (neededStaticLibs !is null) {
            fatal("Dynamic lib %s cannot require static libs, but requires %s",
                  path, neededStaticLibs);
        }
        foreach (lib; neededDynamicLibs) {
            if (lib !is this) {
                action.addDependency(lib);
                libs ~= lib.uniqueName;
                added = true;
            }
        }
        foreach (lib; neededSysLibs) {
            libs ~= lib.name;
        }
        action.finaliseCommand(libs);
        return added;
    }
}


//
// Exe - An executable file
//
final class Exe : Binary {

    bool augmented;

    // create an executable using files from this package, linking to libraries
    // that contain any included header files, and any required system libraries.
    // Note that any system libraries required by inferred local libraries are
    // automatically linked to.
    this(ref Origin origin, Pkg pkg, string kind, string name_, string[] sourceNames) {
        // interpret kind
        string dest, desc;
        switch (kind) {
            case "dist-exe": desc = "DistExe"; dest = buildPath("dist", "bin", name_);     break;
            case "priv-exe": desc = "PrivExe"; dest = buildPath("priv", pkg.trail, name_); break;
            case "test-exe": desc = "TestExe"; dest = buildPath("priv", pkg.trail, name_); break;
            default: assert(0, "invalid Exe kind " ~ kind);
        }

        super(origin, pkg, name_ ~ "-exe", dest, sourceNames, []);

        LinkCommand *linkCommand = sourceExt in linkCommands;
        errorUnless(linkCommand && linkCommand.executable != null, origin,
                    "No command to link and executable from sources of extension %s", sourceExt);

        action = new Action(origin, pkg, format("%-15s %s", desc, dest),
                            linkCommand.executable, [this], objs);

        if (kind == "test-exe") {
            File result = new File(origin, pkg, name ~ "-result",
                                   Privacy.PRIVATE, dest ~ "-passed", false, true);
            result.action = new Action(origin,
                                       pkg,
                                       format("%-15s %s", "TestResult", result.path),
                                       format("TEST %s", this.path),
                                       [result],
                                       [this]);
        }
    }

    // Called just before our action is issued - augment the action's command string
    // with the library dependencies that we should now know about via includeAdded().
    // Return true if dependencies were added.
    override bool augmentAction() {
        if (augmented) return false;
        augmented = true;

        StaticLib[]  neededStaticLibs;
        DynamicLib[] neededDynamicLibs;
        SysLib[]     neededSysLibs;

        neededLibs(this, [this], neededStaticLibs, neededDynamicLibs, neededSysLibs);

        string[] libs;
        bool added;

        foreach (lib; neededStaticLibs) {
            action.addDependency(lib);
            libs ~= lib.uniqueName;
            added = true;
        }
        foreach (lib; neededDynamicLibs) {
            action.addDependency(lib);
            libs ~= lib.uniqueName;
            added = true;
        }
        foreach (lib; neededSysLibs) {
            libs ~= lib.name;
        }
        action.finaliseCommand(libs);
        return added;
    }
}


//
// Add a misc file and its target(s), either copying the specified path into
// destDir, or using a configured command to create the target file(s) if the
// specified source file has a command extension.
//
// If the specified path is a directory, add all its contents instead.
//
void miscFile(ref Origin origin, Pkg pkg, string dir, string name, string dest) {
    if (name[0] == '.') return;

    string fromPath = buildPath("src", pkg.trail, dir, name);

    if (isDir(fromPath)) {
        foreach (string path; dirEntries(fromPath, SpanMode.shallow)) {
            miscFile(origin, pkg, buildPath(dir, name), path.baseName(), dest);
        }
    }
    else {
        // Create the source file
        string ext        = extension(name);
        string relName    = buildPath(dir, name);
        File   sourceFile = File.addSource(origin, pkg, relName, Privacy.PUBLIC, false);

        // Decide on the destination directory.
        string destDir = dest.length == 0 ?
            buildPath("priv", pkg.trail, dir) :
            buildPath("dist", dest, dir);

        GenerateCommand *generate = ext in generateCommands;
        if (generate is null) {
            // Target is a simple copy of source file,
            // set to executable if dest is bin.
            File destFile = new File(origin, pkg, relName ~ "-copy", Privacy.PUBLIC,
                                     buildPath(destDir, name), false, true);
            destFile.action = new Action(origin,
                                         pkg,
                                         format("%-15s %s", "Copy", destFile.path),
                                         format("%s %s %s", copyCmd, sourceFile.path, destFile.path),
                                         [destFile],
                                         [sourceFile]);
        }
        else {
            // Generate the target file(s) using a configured command.
            File[] files;
            string suffixes;
            foreach (suffix; generate.suffixes) {
                string destName = stripExtension(name) ~ suffix;
                File gen = new File(origin, pkg, destName, Privacy.PRIVATE,
                                    buildPath(destDir, destName), false, true);
                files    ~= gen;
                suffixes ~= suffix ~ " ";
            }
            errorUnless(files.length > 0, origin, "Must have at least one destination suffix");
            Action action = new Action(origin,
                                       pkg,
                                       format("%-15s %s", ext ~ "->" ~ suffixes, sourceFile.path),
                                       generate.command,
                                       files,
                                       [sourceFile]);
            foreach (gen; files) {
                gen.action = action;
            }
        }
    }
}


//
// Process a Bobfile
//
void processBobfile(string indent, Pkg pkg) {
    static bool[Pkg] processed;
    if (pkg in processed) return;
    processed[pkg] = true;

    if (g_print_rules) say("%sprocessing %s", indent, pkg.bobfile);
    indent ~= "  ";
    foreach (statement; readBobfile(pkg.bobfile.path)) {
        if (g_print_rules) say("%s%s", indent, statement.toString());
        switch (statement.rule) {

            case "contain":
                foreach (name; statement.targets) {
                    errorUnless(dirName(name) == ".", statement.origin,
                                "Contained packages have to be relative");
                    Privacy privacy = privacyOf(statement.origin, statement.arg1);
                    Pkg newPkg = new Pkg(statement.origin, pkg, name, privacy);
                    processBobfile(indent, newPkg);
                }
            break;

            case "refer":
                foreach (trail; statement.targets) {
                    Pkg* other = cast(Pkg*) (trail in Node.byTrail);
                    if (other is null) {
                        // create the referenced package which must be top-level, then refer to it
                        errorUnless(dirName(trail) == ".",
                                    statement.origin,
                                    "Previously-unknown referenced package %s has to be top-level",
                                    trail);
                        Pkg newPkg = new Pkg(statement.origin,
                                             Node.byTrail["root"],
                                             trail,
                                             Privacy.PUBLIC);
                        processBobfile(indent, newPkg);
                        pkg.addReference(statement.origin, newPkg);
                    }
                    else {
                        // refer to the existing package
                        errorUnless(other !is null, statement.origin,
                                    "Cannot refer to unknown pkg %s", trail);
                        pkg.addReference(statement.origin, *other);
                    }
                }
            break;

            case "static-lib":
            case "public-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one static-lib name per statement");
                StaticLib lib = new StaticLib(statement.origin,
                                              pkg,
                                              statement.targets[0],
                                              statement.arg1,
                                              statement.arg2,
                                              statement.rule == "public-lib");
            }
            break;

            case "dynamic-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one dynamic-lib name per statement");
                new DynamicLib(statement.origin,
                               pkg,
                               statement.targets[0],
                               statement.arg1);
            }
            break;

            case "dist-exe":
            case "priv-exe":
            case "test-exe":
            {
                errorUnless(statement.targets.length == 1,
                            statement.origin,
                            "Can only have one exe name per statement");
                Exe exe = new Exe(statement.origin,
                                  pkg,
                                  statement.rule,
                                  statement.targets[0],
                                  statement.arg1);
            }
            break;

            case "misc":
            {
                foreach (name; statement.targets) {
                    miscFile(statement.origin,
                             pkg,
                             "",
                             name,
                             statement.arg1.length == 0 ? "" : statement.arg1[0]);
                }
            }
            break;

            default:
            {
                error(statement.origin, "Unsupported statement '%s'", statement.rule);
            }
        }
    }
}


//
// Remove any files in obj, priv and dist that aren't marked as needed
//
void cleandirs() {
    void cleanDir(string name) {
        //say("cleaning dir %s, cdw=%s", name, getcwd);
        if (exists(name) && isDir(name)) {
            bool[string] dirs;
            foreach (DirEntry entry; dirEntries(name, SpanMode.depth, false)) {
                //say("  considering %s", entry.name);
                bool isDir = attrIsDir(entry.linkAttributes);

                if (!isDir) {
                    File* file = entry.name in File.byPath;
                    if (file is null || (*file) !in File.allBuilt) {
                        say("Removing unwanted file %s", entry.name);
                        std.file.remove(entry.name);
                    }
                    else {
                        // leaving a file in place
                        dirs[entry.name.dirName()] = true;
                    }
                }
                else {
                    if (entry.name !in dirs) {
                        //say("removing empty dir %s", entry.name);
                        rmdir(entry.name);
                    }
                    else {
                        //say("  keeping non-empty dir %s", entry.name);
                        dirs[entry.name.dirName()] = true;
                    }
                }
            }
        }
    }
    cleanDir("obj");
    cleanDir("priv");
    cleanDir("dist");
}


//
// Planner function
//
bool doPlanning(int numJobs,
                bool printStatements,
                bool printDeps,
                bool printDetails) {

    // state variables
    size_t       inflight;
    bool[string] workers;
    bool[string] idlers;
    bool         exiting;
    bool         success = true;


    // receive registration message from each worker and remember its name
    while (workers.length < numJobs) {
        receive( (string worker) { workers[worker] = true; idlers[worker] = true; } );
    }

    // Ensure tmp exists so the workers have a sandbox.
    if (!exists("tmp")) {
        mkdir("tmp");
    }

    // local function: an action has completed successfully - update all files built by it
    void actionCompleted(string worker, string action) {
        //say("%s %s succeeded", action, worker);
        --inflight;
        idlers[worker] = true;
        try {
            foreach (file; Action.byName[action].builds) {
                file.updated();
            }
        }
        catch (BailException ex) { exiting = true; success = false; }
    }

    // local function: a worker has terminated - remove it from workers and remember we are exiting
    void workerTerminated(string worker) {
        exiting = true;
        workers.remove(worker);
        //say("%s has terminated - %s workers remaining", worker, workers.length);
    }


    // set up some globals
    readOptions();
    g_print_rules   = printStatements;
    g_print_deps    = printDeps;
    g_print_details = printDetails;

    string projectPackage = getOption("PROJECT");
    errorUnless(projectPackage.length > 0, Origin(), "No project directory specified");

    int needed;
    try {
        // read the project Bobfile and descend into all those it refers to
        auto root = new Node();
        auto project = new Pkg(Origin(), root, projectPackage, Privacy.PRIVATE);
        processBobfile("", project);

        // clean out unwanted files from the build dir
        cleandirs();

        // Now that we know about all the files and have the mostly-complete
        // dependency graph (just includes to go), touch all source files, which is
        // enough to trigger building everything.
        foreach (path, file; File.byPath) {
            if (!file.built) {
                file.touch();
            }
        }
    }
    catch (BailException ex) { exiting = true; success = false; }

    while (workers.length) {

        // give any idle workers something to do
        //say("%s idle workers and %s actions in priority queue", idlers.length, Action.queue.length);
        string[] toilers;
        foreach (idler, dummy; idlers) {

            if (!exiting && !File.outstanding.length) exiting = true;

            Tid tid = std.concurrency.locate(idler);

            if (exiting) {
                // tell idle worker to terminate
                tid.send(true);
                toilers ~= idler;
            }
            else if (!Action.queue.empty) {
                // give idle worker an action to perform

                const Action next = Action.queue.front();
                Action.queue.popFront();

                string targets;
                foreach (target; next.builds) {
                    ensureParent(target.path);
                    if (targets.length > 0) {
                        targets ~= "|";
                    }
                    targets ~= target.path;
                }
                //say("issuing action %s", next.name);
                tid.send(next.name.idup, next.command.idup, targets.idup);
                toilers ~= idler;
                ++inflight;
            }
            else if (!inflight) {
                fatal("nothing to do and no inflight actions");
            }
            else {
                // nothing to do
                //say("nothing to do - waiting for results");
                break;
            }
        }
        foreach (toiler; toilers) idlers.remove(toiler);

        // Receive a completion or failure.
        receive( (string worker, string action) { actionCompleted(worker, action); },
                 (string worker)                { workerTerminated(worker); } );
    }

    // Shut down the bailer.
    send(bailerTid, "goodnight");

    // Print some statistics.
    if (!File.outstanding.length && success) {
        say("\n"
            "Total number of files:             %s\n"
            "Number of target files:            %s\n"
            "Number of files updated:           %s\n",
            File.byPath.length, File.numBuilt, File.numUpdated);
        return true;
    }
    return false;
}


//-----------------------------------------------------
// Worker
//-----------------------------------------------------


void doWork(bool printActions, uint index, Tid plannerTid) {
    bool success;

    string myName = format("worker%d", index);
    std.concurrency.register(myName, thisTid);
    //say("%s starting", myName);

    string resultsPath = buildPath("tmp", myName);
    string tmpPath;

    void perform(string action, string command, string targets) {
        say("%s", action);
        if (printActions) { say("\n%s\n", command); }

        success = false;

        bool isTest = command.length > 5 && command[0 .. 5] == "TEST ";

        if (command == "DUMMY ") {
            // Just write some text into the target file
            std.file.write(targets, "dummy");
            plannerTid.send(myName, action);
            return;
        }

        else if (isTest) {
            // Do test preparation - choose tmp dir and remove it if present
            tmpPath = buildPath("tmp", myName ~ "-test");
            if (exists(tmpPath)) {
                rmdirRecurse(tmpPath);
            }
            command = command[5 .. $] ~ " --tmp=" ~ tmpPath;
        }

        string[] targs = split(targets, "|");

        // delete any pre-existing files that we are about to build
        foreach (target; targs) {
            if (exists(target)) {
                std.file.remove(target);
            }
        }

        // launch child process to do the action, then wait for it to complete

        auto output = std.stdio.File(resultsPath, "w");
        try {
            Pid  child = spawnProcess(command, std.stdio.stdin, output, output);

            killer.launched(myName, child);
            success = wait(child) == 0;
            killer.completed(myName, child);
        }
        catch (Exception ex) {
            success = false;
            say(ex.msg);
        }

        if (!success) {
            // delete built files so the failure is tidy
            foreach (target; targs) {
                if (exists(target)) {
                    say("  Deleting %s", target);
                    std.file.remove(target);
                }
            }

            bool bailed = killer.bail();

            if (!bailed) {
                // Print error message
                say("\n%s", readText(resultsPath));
                say("%s: FAILED\n%s", action, command);
                say("Aborting build due to action failure");
            }
            throw new BailException();
        }
        else {
            // Success.

            if (isTest) {
                // Remove tmpPath and copy results file onto build target
                if (exists(tmpPath)) {
                    rmdirRecurse(tmpPath);
                }
                if (targs.length != 1) {
                    fatal("Expected exactly one target for a test, but got '%s'", targets);
                }
                rename(resultsPath, targs[0]);
                append(targs[0], "PASSED\n");
            }
            else
            {
                remove(resultsPath);
            }

            // tell planner the action succeeded
            plannerTid.send(myName, action);
        }
    }


    try {
        plannerTid.send(myName);
        bool done;
        while (!done) {
            receive( (string action, string command, string targets) { perform(action, command, targets); },
                     (bool dummy) { done = true; } );
        }
    }
    catch (BailException) {}
    catch (Exception ex)  { say("Unexpected exception: %s", ex.msg); }

    // tell planner we are terminating
    //say("%s terminating", myName);
    plannerTid.send(myName);
}


//--------------------------------------------------------------------------------------
// main
//
// Assumes that the top-level source packages are all located in a src subdirectory,
// and places build outputs in obj, priv and dist subdirectories.
// The local source paths are necessary to minimise the length of actions,
// and is usually achieved by a configure step setting up sym-links to the
// actual source locations.
//--------------------------------------------------------------------------------------

int main(string[] args) {
    try {
        bool printStatements = false;
        bool printDeps       = false;
        bool printDetails    = false;
        bool printActions    = false;
        bool help            = false;
        uint numJobs         = 1;

        int returnValue = 0;
        try {
            getopt(args,
                   std.getopt.config.caseSensitive,
                   "statements|s",   &printStatements,
                   "deps|d",         &printDeps,
                   "details|v",      &printDetails,
                   "actions|a",      &printActions,
                   "jobs|j",         &numJobs,
                   "help|h",         &help);
        }
        catch (std.conv.ConvException ex) {
            returnValue = 2;
            say(ex.msg);
        }
        catch (object.Exception ex) {
            returnValue = 2;
            say(ex.msg);
        }

        if (args.length != 1) {
            say("Option processing failed. There are %s unprocessed argument(s): ", args.length - 1);
            foreach (uint i, arg; args[1 .. args.length]) {
                say("  %s. \"%s\"", i + 1, arg);
            }
            returnValue = 2;
        }
        if (numJobs < 1) {
            returnValue = 2;
            say("Must allow at least one job!");
        }
        if (returnValue != 0 || help) {
            say("Usage:  bob [options]\n"
                "  --statements     print statements\n"
                "  --deps           print dependencies\n"
                "  --actions        print actions\n"
                "  --details        print heaps of details\n"
                "  --jobs=VALUE     maximum number of simultaneous actions\n"
                "  --help           show this message\n"
                "target is everything contained in the project Bobfile and anything referred to.");
            return returnValue;
        }

        if (printDetails) {
            printActions = true;
            printDeps = true;
        }

        // Set environment variables found in the environment file
        if (exists("environment")) {
            string envContent = readText("environment");
            foreach (line; splitLines(envContent)) {
                string[] tokens = split(line, "=");
                if (tokens.length == 2 && tokens[0][0] != '#') {
                    if (tokens[1][0] == '"') {
                        tokens[1] = tokens[1][1 .. $-1];
                    }
                    Environment[tokens[0]] = tokens[1];
                }
            }
        }

        // spawn the workers
        foreach (uint i; 0 .. numJobs) {
            //say("spawning worker %s", i);
            spawn(&doWork, printActions, i, thisTid);
        }

        // build everything
        returnValue = doPlanning(numJobs,
                                 printStatements,
                                 printDeps,
                                 printDetails) ? 0 : 1;

        return returnValue;
    }
    catch (Exception ex) {
        say("Got unexpected exception: %s", ex.msg);
        return 1;
    }
}
