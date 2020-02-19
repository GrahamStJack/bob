/**
 * Copyright 2012-2020, Graham St Jack.
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
import std.process;
import std.algorithm;
import std.exception;

static import std.array;


//
// Options read from Buboptions file
//

// General variables
string[string] options;

// Build options
// Rules to generate files other than reserved extensions

struct Rule {
    string[] suffixes; // the suffixes of files produced by the command
    string   command;  // the command
}

// Rules whose first suffix is the primary target, and the others are optional
Rule[string] compileRules; // Compile rule by input extension
Rule[string] slibRules;    // Static lib rule by source extension
Rule[string] dlibRules;    // Dynamic lib rule by source extension
Rule[string] exeRules;     // Exe rule by source extension

// Rules with all-madatory target suffixes
Rule[string] generateRules; // Gernerate rule by input extension

// Extra flags to apply if a SysLib is depended on
struct SysLibDefinition {
    string[] compileFlags;
    string[] linkFlags;
}
SysLibDefinition[string] sysLibDefinitions; // by syslib name

bool[string] reservedExts;
static this() {
    reservedExts = [".obj":true, ".slib":true, ".dlib":true, ".exe":true];
}


//
// Read an options file, populating option lines
// Format is:   key = value
// value can't contain " = ".
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
                    fatal("Rules require at least two extensions: %s", line);
                }
                string   input   = extensions[0];
                string[] outputs = extensions[1 .. $];

                errorUnless(input !in reservedExts, origin,
                            "Cannot use %s as source ext in rules", input);

                if (outputs[0] == ".obj") {
                    errorUnless(input !in compileRules && input !in generateRules,
                                origin, "Multiple compile/generate rules using %s", input);
                    compileRules[input] = Rule(outputs, value);
                }
                else if (outputs[0] == ".slib") {
                    errorUnless(input !in slibRules, origin, "Multiple .slib rules using %s", input);
                    slibRules[input] = Rule(outputs, value);
                }
                else if (outputs[0] == ".dlib") {
                    errorUnless(input !in dlibRules, origin, "Multiple .dlib rules using %s", input);
                    dlibRules[input] = Rule(outputs, value);
                }
                else if (outputs[0] == ".exe") {
                    errorUnless(input !in exeRules, origin, "Multiple .exe rules using %s", input);
                    exeRules[input] = Rule(outputs, value);
                }
                else {
                    // A generate command
                    errorUnless(input !in compileRules && input !in generateRules,
                                origin, "Multiple compile/generate rules using %s", input);
                    foreach (ext; outputs) {
                        errorUnless(ext !in reservedExts, origin,
                                    "Cannot use %s in a generate command: %s", ext, line);
                    }
                    generateRules[input] = Rule(outputs, value);
                }
            }
            else if (key.startsWith("syslib-")) {
                // A syslib's compile or link flags
                auto words = split(key);
                if (words.length != 2) {
                    fatal("syslib options require a two-word key: ", key);
                }
                auto name = words[1];
                if (name !in sysLibDefinitions) {
                    sysLibDefinitions[name] = SysLibDefinition();
                }
                if (words[0] == "syslib-compile-flags") {
                    sysLibDefinitions[name].compileFlags = value.split;
                }
                else {
                    sysLibDefinitions[name].linkFlags = value.split;
                }
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

    // Hard-coded options
    foreach (root; options["ROOTS"].split) {
        options["PROJ_INC"] ~= buildPath("src", root) ~ " " ~ buildPath("gen", root) ~ " ";
    }
    options["PROJ_INC"] ~= ".";
    options["PROJ_LIB"] = buildPath("dist", "lib") ~ " obj";
}


// Return the specified option, or an empty string if it isn't present.
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
// Return a fully resolved command by transitively replacing its ${<option>} tokens
// with tokens from options, extras or environment, cross-multiplying with adjacent text.
// After all that is done, add sysLibFlags
//
string resolveCommand(string command, string[string] extras, string[] sysLibFlags) {
    //say("resolving command %s with extras=%s", command, extras);

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
                auto option = varname in options;
                if (option is null) {
                    option = varname in extras;
                }
                if (option !is null) {
                    values = split(resolve(*option));
                }
                else {
                    try {
                        string env = environment[varname];
                        values = split(resolve(env));
                    }
                    catch (Exception ex) {
                        values = [];
                    }
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
        return result.strip();
    }

    string result = resolve(command);
    foreach (flag; sysLibFlags) {
        result ~= " " ~ flag;
    }
    //say("resolved command = %s", result);
    return result;
}


//
// Read paths for files depended on from a deps output and return them,
// together with the inputs used to produce the output files.
//
// Any out-of-project dependencies are discarded.
//
// The deps output is expected to contain either:
// * A lot of junk with paths of interest in parentheses, or
// * Leading junk terminated with a colon, then just the paths,
//   possibly with backslashes escaping newlines, or
// * Just the whitespace-separated paths.
//
// The first two formats are produced by the dmd D compiler and C/C++
// compilers respectively. The third format is supported as a convenient format
// for in-project generation tools.
//
// Note that spaces in paths are only supported in the first format.
//
string[] parseDeps(string path, string[] inputs) {
    string[] deps;

    if (path.exists) {
        auto content = path.readText;
        path.remove;

        bool parens;
        foreach (ch; content) {
            if (ch == '\\') {
                break;
            }
            if (ch == '(') {
                parens = true;
                break;
            }
        }

        if (parens) {
            // The paths are enclosed in parentheses
            size_t anchor;
            bool   inWord;
            foreach (i, ch; content) {
                if (ch == '(') {
                    enforce(!inWord);
                    inWord = true;
                    anchor = i + 1;
                }
                else if (ch == ')') {
                    enforce(inWord);
                    inWord = false;
                    if (i > anchor) {
                        deps ~= content[anchor..i].dup;
                    }
                }
            }
        }
        else {
            // Everything except backslashes are paths, other than any paths
            // preceding the first colon in the file
            bool   seenFirstColon;
            size_t anchor;
            bool   inWord;
            foreach (i, ch; content) {
                if (ch == ':' && !seenFirstColon) {
                    // First colon in file - discard anything already found
                    seenFirstColon = true;
                    deps = [];
                    inWord = false;
                }
                else if (!inWord && !ch.isWhite && ch != '\\') {
                    inWord = true;
                    anchor = i;
                }
                else if (inWord && (ch.isWhite || ch == '\\')) {
                    inWord = false;
                    enforce(i > anchor);
                    deps ~= content[anchor..i].dup;
                }
            }
            if (inWord) {
                deps ~= content[anchor..$].dup;
            }
        }
    }

    // Remove duplicates and out-of-project paths, then return the result
    bool[string] got;
    foreach (input; inputs) {
        got[input] = true;
    }
    string cwd = getcwd ~ dirSeparator;
    foreach (dep; deps) {
        string abs = buildNormalizedPath(cwd, dep);
        if (abs.startsWith(cwd)) {
            string rel = abs[cwd.length..$];
            if (rel.startsWith("src" ~ dirSeparator) ||
                rel.startsWith("gen" ~ dirSeparator) ||
                rel.dirName == ".")
            {
                got[rel] = true;
            }
        }
    }
    return got.keys();
}


//
// read a Bubfile, returning all its statements
//
// //  a simple statement
// rulename targets... : arg1... : arg2... : arg3...;
//

struct Statement {
    Origin   origin;
    int      phase; // 0==>empty, 1==>rule populated, 2==rule,targets populated, etc
    string   rule;
    string[] targets;
    string[] arg1;
    string[] arg2;
    string[] arg3;
    string[] arg4;

    string toString() const {
        string result;
        if (phase >= 1) result ~= rule;
        if (phase >= 2) result ~= format(" : %s", targets);
        if (phase >= 3) result ~= format(" : %s", arg1);
        if (phase >= 4) result ~= format(" : %s", arg2);
        if (phase >= 5) result ~= format(" : %s", arg3);
        if (phase >= 6) result ~= format(" : %s", arg4);
        return result;
    }
}

Statement[] readBubfile(string path) {
    Statement[] statements;
    Origin origin = Origin(path, 1);
    errorUnless(exists(path) && isFile(path), origin, "can't read Bubfile %s", path);

    string content = readText(path);

    size_t       anchor;
    bool         inWord;
    bool         inComment;
    bool         waitingForOpeningParen;
    bool         waitingForClosingParen;
    bool         usingText = true;
    Statement    statement;
    bool[string] conditionals;

    foreach (conditional; split(getOption("CONDITIONALS"))) {
        // Special case - allow resolvable conditionals
        string[string] noExtras;
        string cond = resolveCommand(conditional, noExtras, []);
        conditionals[cond] = true;
    }

    void processWord(size_t pos, char ch) {
        if (inWord) {
            inWord = false;
            string word = content[anchor .. pos];

            if (word.length > 2 && word[0] == '[' && ch == ']') {
                // Start of a conditional
                waitingForOpeningParen = true;
                usingText              = (word[1..$].strip in conditionals) !is null;
            }
            else {
                if (word.length > 0) {
                    if (statement.phase == 0) {
                        statement.origin = origin;
                        statement.rule = word;
                        ++statement.phase;
                    }
                    else if (statement.phase == 1) {
                        statement.targets ~= word;
                    }
                    else if (statement.phase == 2) {
                        statement.arg1 ~= word;
                    }
                    else if (statement.phase == 3) {
                        statement.arg2 ~= word;
                    }
                    else if (statement.phase == 4) {
                        statement.arg3 ~= word;
                    }
                    else if (statement.phase == 5) {
                        statement.arg4 ~= word;
                    }
                    else {
                        error(origin, "Too many arguments in %s", path);
                    }
                }
            }
        }
    }

    foreach (pos, ch; content) {
        if (ch == '\n') {
            ++origin.line;
        }

        if (usingText && ch == '#') {
            processWord(pos, ch);
            inComment = true;
            inWord    = false;
        }

        if (inComment) {
            if (ch == '\n') {
                inComment = false;
            }
        }
        else if (waitingForOpeningParen) {
            if (ch == '(') {
                waitingForOpeningParen = false;
                waitingForClosingParen = true;
            }
            else {
                errorUnless(isWhite(ch), origin, "Unexpected non-whitespace between '[' and '('");
            }
        }
        else if (waitingForClosingParen && !usingText) {
            if (ch == ')') {
                waitingForClosingParen = false;
                usingText              = true;
            }
        }
        else if (ch == '(') {
            error(origin, "Unexpected opening brace");
        }
        else if (ch == ')') {
            errorUnless(waitingForClosingParen, origin, "Unexpected closing brace");
            waitingForClosingParen = false;
            processWord(pos, ch);
        }
        else if (isWhite(ch)) {
            processWord(pos, ch);
        }
        else if (ch == ']') {
            errorUnless(content[anchor] == '[', origin, "Unexpected ']'");
            processWord(pos, ch);
        }
        else if (ch == ':' || ch == ';') {
            processWord(pos, ch);
            ++statement.phase;
            if (ch == ';') {
                errorUnless(statement.phase > 1, origin, "Incomplete statement");
                statements ~= statement;
                statement = statement.init;
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
