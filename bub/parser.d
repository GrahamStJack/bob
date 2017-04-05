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

static import std.array;


//
// Options read from Buboptions file
//

// General variables
string[string] options;

// Build options
string[string] compileCommands; // Compile command by input extension
string[string] slibCommands;    // Static lib command by source extension
string[string] dlibCommands;    // Dynamic lib command by source extension
string[string] exeCommands;     // Exe command by source extension

// Commands to generate files other than reserved extensions
struct GenerateCommand {
    string[] suffixes;
    string   command;
}
GenerateCommand[string] generateCommands; // Gernerate command by input extension

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

                if (outputs.length == 1 && outputs[0] == ".obj") {
                    errorUnless(input !in compileCommands && input !in generateCommands,
                                origin, "Multiple compile/generate commands using %s", input);
                    compileCommands[input] = value;
                }
                else if (outputs.length == 1 && outputs[0] == ".slib") {
                    errorUnless(input !in slibCommands, origin, "Multiple .slib commands using %s", input);
                    slibCommands[input] = value;
                }
                else if (outputs.length == 1 && outputs[0] == ".dlib") {
                    errorUnless(input !in dlibCommands, origin, "Multiple .dlib commands using %s", input);
                    dlibCommands[input] = value;
                }
                else if (outputs.length == 1 && outputs[0] == ".exe") {
                    errorUnless(input !in exeCommands, origin, "Multiple .exe commands using %s", input);
                    exeCommands[input] = value;
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
    options["PROJ_INC"] = "src obj";
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
//
string resolveCommand(string command, string[string] extras) {
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
    //say("resolved command = %s", result);
    return result;
}


//
// Read paths for files depended on from a deps output and return them,
// together with the inputs used to produce the output files.
//
// In-project files have relative paths, and system files have
// absolute paths.
//
// The deps output contains either:
// * A lot of junk with paths of interest in parentheses, or
// * Leading junk terminated with a colon, then just the paths,
//   possibly with backslashes escaping newlines.
//
string[] parseDeps(string path, string[] inputs) {
    bool[string] got;

    foreach (input; inputs) {
        got[input] = true;
    }

    if (path.exists) {
        auto content = path.readText;
        path.remove;

        bool parens;
        foreach (ch; content) {
            if (ch == '\\') break;
            if (ch == '(') {
                parens = true;
                break;
            }
        }

        if (parens) {
            // The paths are enclosed in parentheses
            foreach (word; content.splitter(' ')) {
                if (word.length > 2 && word[0] == '(' && word[$-1] == ')') {
                    got[word[1..$-1]] = true;
                }
            }
        }
        else {
            // Everything after the first ':' except backslashes are paths
            bool started;
            foreach (word; content.splitter(' ')) {
                if (started) {
                    word = word.strip;
                    if (word.length > 0 && word[0] != '\\') {
                        got[word] = true;
                    }
                }
                else if (word[$-1] == ':') {
                    started = true;
                }
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

    int          anchor;
    bool         inWord;
    bool         inComment;
    bool         waitingForOpeningBrace;
    bool         waitingForClosingBrace;
    bool         usingText = true;
    Statement    statement;
    bool[string] architectures;

    foreach (architecture; split(getOption("ARCHITECTURE"))) {
        architectures[architecture] = true;
    }

    void processWord(int pos, char ch) {
        if (inWord) {
            inWord = false;
            string word = content[anchor .. pos];

            if (word.length > 2 && word[0] == '[' && ch == ']') {
                // Start of a conditional
                waitingForOpeningBrace = true;
                usingText              = (word[1..$] in architectures) !is null;
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
                    else {
                        error(origin, "Too many arguments in %s", path);
                    }
                }
            }
        }
    }

    foreach (int pos, char ch; content) {
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
        else if (waitingForOpeningBrace) {
            if (ch == '{') {
                waitingForOpeningBrace = false;
                waitingForClosingBrace = true;
            }
            else {
                errorUnless(isWhite(ch), origin, "Unexpected non-whitespace between '[' and '{'");
            }
        }
        else if (waitingForClosingBrace && !usingText) {
            if (ch == '}') {
                waitingForClosingBrace = false;
                usingText              = true;
            }
        }
        else if (ch == '{') {
            error(origin, "Unexpected opening brace");
        }
        else if (ch == '}') {
            errorUnless(waitingForClosingBrace, origin, "Unexpected closing brace");
            waitingForClosingBrace = false;
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
