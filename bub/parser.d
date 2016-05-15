/**
 * Copyright 2012-2013, Graham St Jack.
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
Provides support for parsing text files.
*/

module bub.parser;

import bub.support;

import std.ascii;
import std.file;
import std.path;
import std.string;

static import std.array;


//
// Options read from Buboptions file
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

    override bool opEquals(Object o) {
        return this is o;
    }

    override nothrow @trusted size_t toHash() {
      return number;
    }
}


//
// Read an options file, populating option lines
// Format is:   key = value
// value can contain '='
//
void readOptions() {
    string path = "Buboptions";
    Origin origin = Origin(path, 1);

    errorUnless(exists(path) && isFile(path), origin, "can't read Buboptions %s", path);

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
            fatal("Invalid Buboptions line: %s", line);
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
// read a Bubfile, returning all its statements
//
// //  a simple statement
// rulename targets... : arg1... : arg2... : arg3...; // can expand Buboptions variable with ${var-name}
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

Statement[] readBubfile(string path) {
    Statement[] statements;
    Origin origin = Origin(path, 1);
    errorUnless(exists(path) && isFile(path), origin, "can't read Bubfile %s", path);

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
