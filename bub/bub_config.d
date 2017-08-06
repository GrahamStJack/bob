/*
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
 * along with Foobar.  If not, see <http://www.gnu.org/licenses/>.
 */

//
// The bub-config utility. Sets up a build directory from which
// a project can be built from source by the 'bub' build utility.
// The built files are all located in the build directory, away from the
// source. Multiple source repositories are supported.
//
// Refer to the example bub.cfg file for details of bub configuration.
//
// Note that bub-config does not check for or locate external dependencies.
// You have to use other tools to check out your source and make sure that
// all the external dependencies of your project are satisfied.
// Often this means a 'prepare' script that unpacks a number of packages
// into a project-specific local directory.
//

import std.algorithm.sorting;
import std.string;
import std.getopt;
import std.path;
import std.file;
import std.stdio;
import std.conv;
import std.ascii;
import std.process;
import std.exception;

import core.stdc.stdlib;

//
// Some platform-dependent stuff
//
version(Posix) {
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;

    // Set the mode of a file
    private void setMode(string path, bool executable) {
        chmod(toStringz(path), executable ? octal!744 : octal!644);
    }

    // Make a symbolic link
    private void makeSymlink(string dest, string linkname) {
        writefln("making link %s to %s", linkname, dest);
        symlink(dest, linkname);
    }

    string ENV_DELIM  = ":";
    string ENV_PREFIX = "";

    string CLEAN_TEXT = "rm -rf dist priv obj tmp\n";
}
version(Windows) {
    // Set the mode of a file
    private void setMode(string path, bool executable) {
        // Setting a file executable is all about the extension in windows,
        // and we let the user decide the filename - so nothing to do.
    }

    // Make a symbolic link
    private void makeSymlink(string dest, string linkname) {
        writefln("making link %s to %s", linkname, dest);

        string command = format("mklink /D %s %s", linkname, dest);
        int ret = std.c.process.system(toStringz(command));
        assert(ret == 0, format("Failed to execute: %s", command));
    }

    string ENV_DELIM = ";";
    string ENV_PREFIX = "set ";

    string CLEAN_TEXT = "rmdir /s /q dist priv obj tmp\n";
}


//================================================================
// Helpers
//================================================================


//
// Storage for data read from the config file
//
alias string[][string] Vars;


//
// Enum to control how to append to variables
//
enum AppendType { notExist, mustExist }


//
// Append some tokens to the named element in vars,
// optionally not appending if already present, and preserving order.
//
private void append(ref Vars vars, string name, string[] extra, AppendType appendType) {
    final switch (appendType) {
    case AppendType.notExist:
        assert(name !in vars, format("Cannot create variable '%s' again", name));
        break;
    case AppendType.mustExist:
        assert(name in vars, format("Cannot add to non-existant variable '%s'", name));
        break;
    }

    if (name !in vars) {
        vars[name] = null;
    }
    foreach (string item; extra) {
        bool got = false;
        if (appendType != AppendType.notExist) {
            foreach (string have; vars[name]) {
                if (item == have) {
                    got = true;
                    break;
                }
            }
        }
        if (!got) {
            vars[name] ~= item;
        }
    }
}


//
// Return a string to set an environment variable from one or more bub variables.
//
string toEnv(string envName, const ref Vars vars, string[] varNames, string[] extras) {
    string result;
    bool[string] got;
    string[] candidates = extras;
    foreach (name; varNames) {
        if (name in vars) {
            candidates ~= vars[name];
        }
    }
    foreach (token; candidates) {
        if (token !in got) {
            got[token] = true;
            result ~= token ~ ENV_DELIM;
        }
    }
    if (result) {
        result = ENV_PREFIX ~ envName ~ "=\"" ~ result[0..$-ENV_DELIM.length];
    }
    if (result[$-ENV_DELIM.length..$] == ENV_DELIM) {
        result = result[0..$-ENV_DELIM.length];
    }
    result ~= "\"\n"; 
    return result;
}


//
// Return an array of strings parsed from an environment variable.
//
string[] fromEnv(string varname) {
    return split(environment.get(varname), ENV_DELIM);
}


//
// Write content to path if it doesn't already match, creating the file
// if it doesn't already exist. The file's executable flag is set to the
// value of executable.
//
void update(string path, string content, bool executable) {
    if (!exists(path) || content != readText(path)) {
        std.file.write(path, content);
    }

    setMode(path, executable);
}


//================================================================
// Down to business
//================================================================

//
// Set up build directory.
//
void establishBuildDir(string buildDir, string srcDir, const Vars vars) {

    // Create build directory.
    if (!exists(buildDir)) {
        mkdirRecurse(buildDir);
    }
    else if (!isDir(buildDir)) {
        writefln("%s is not a directory", buildDir);
        exit(1);
    }


    // Create Buboptions file from vars.
    string bubText;
    foreach (string var; vars.keys().sort()) {
        const string[] tokens = vars[var];
        if (tokens.length) {
            bubText ~= var ~ " =";
            foreach (token; tokens) {
                bubText ~= " " ~ token;
            }
            bubText ~= '\n';
        }
    }
    update(buildPath(buildDir, "Buboptions"), bubText, false);


    // Create clean script.
    version(Posix) {
        update(buildPath(buildDir, "clean"), CLEAN_TEXT, true);
    }
    version(Windows) {
        update(buildPath(buildDir, "clean.bat"), CLEAN_TEXT, true);
    }


    // Create environment file.
    string lib  = buildPath("dist", "lib");
    string bin  = buildPath("dist", "bin");
    string data = buildPath("dist", "data");
    string env  = buildPath(buildDir, "environment");
    string envText;
    version(Posix) {
        envText ~= "#!/bin/bash\n";
        envText ~= "export " ~ toEnv("LD_LIBRARY_PATH",
                                     vars,
                                     ["SYS_LIB"],
                                     [lib] ~ fromEnv("LD_LIBRARY_PATH"));
        envText ~= "export " ~ toEnv("PATH",
                                     vars,
                                     ["SYS_PATH"],
                                     [bin] ~ fromEnv("PATH"));
        envText ~= "export DIST_DATA_PATH=\"" ~ data ~ "\"\n";
        envText ~= "export SYSTEM_DATA_PATH=\"" ~ data ~ "\"\n";
    }
    version(Windows) {
        envText ~= toEnv("PATH", vars, ["SYS_LIB", "SYS_PATH"], [lib, bin] ~ fromEnv("PATH"));
        envText ~= "set DIST_DATA_PATH=\"" ~ data ~ "\"\n";
    }
    update(env, envText, false);


    // Create run script
    version(Posix) {
        string runText =
            "#!/bin/bash\n" ~
            "source environment\n" ~
            "export TMP_PATH=\"tmp/tmp-$(basename \"${1}\")\"\n" ~
            "rm -rf \"${TMP_PATH}\" && mkdir \"${TMP_PATH}\" && exec \"$@\"";
        update(buildPath(buildDir, "run"), runText, true);
    }
    version(Windows) {
        string runText = envText ~ "\n%1%";
        update(buildPath(buildDir, "run.bat"), runText, true);
    }


    //
    // Create src directory with symbolic links to all top-level packages in all
    // specified repositories.
    //

    // Make clean repos and src dirs.
    string localReposPath = buildPath(buildDir, "repos");
    if (exists(localReposPath)) {
        rmdirRecurse(localReposPath);
    }
    mkdir(localReposPath);
    string localSrcPath = buildPath(buildDir, "src");
    if (exists(localSrcPath)) {
        rmdirRecurse(localSrcPath);
    }
    mkdir(localSrcPath);

    assert("REPOS"   in vars && vars["REPOS"].length,   "REPOS variable is not set");
    assert("ROOTS"   in vars && vars["ROOTS"].length,   "ROOTS variable is not set");
    assert("CONTAIN" in vars && vars["CONTAIN"].length, "CONTAIN variable is not set");

    // Make symbolic links to each repo
    foreach (relPath; vars["REPOS"]) {
        auto repoPath = buildNormalizedPath(srcDir, relPath).absolutePath;
        auto repoName = repoPath.baseName;
        makeSymlink(repoPath, buildPath(localReposPath, repoName));
    }

    // Make a symbolic link to each top-level package specified in CONTAIN, and looked
    // for in all of ROOTS - then write the project Bubfile.
    string[string] pkgPaths;
    string contain;
    foreach (name; vars["CONTAIN"]) {
        contain ~= " " ~ name;
        string pkgPath;
        foreach (repo; vars["ROOTS"]) {
            auto candidate = buildPath(repo, name);
            if (candidate.exists) {
                assert(pkgPath is null, format("%s found in both %s and %s", name, pkgPath, candidate));
                pkgPath = candidate;
            }
        }
        assert(pkgPath !is null, format("Could not find %s in any of %s", name, vars["ROOTS"]));
        pkgPaths[name] = pkgPath;
    }
    foreach (name, path; pkgPaths) {
        makeSymlink(buildNormalizedPath(srcDir, path), buildPath(localSrcPath, name));
    }

    // Create the top-level Bubfile
    update(buildPath(localSrcPath, "Bubfile"), "contain" ~ contain ~ ";", false);

    // print success
    writefln("Build environment in %s is ready to roll.", buildDir);
}


//
// Return whatever the given string evaluates to, replacing any $(<command>) instances
// with whatever <command> outputs.
//
string evaluate(string text) {
    string result;
    bool   inCommand;
    char   prev;
    size_t commandStart;

    foreach (i, ch; text) {
        if (ch == '(' && prev == '$') {
            enforce(!inCommand, "Nested commands not supported");
            inCommand    = true;
            commandStart = i + 1;
            result       = result[0..$-1];
        }
        else if (inCommand && ch == ')') {
            auto command = text[commandStart..i];
            auto rc      = executeShell(command);
            enforce(rc.status == 0, format("Failed to run '%s', output '%s'", command, rc.output));
            result ~= rc.output;
            inCommand = false;
        }
        else if (!inCommand) {
            result ~= ch;
        }
        prev = ch;
    }
    result = result.strip;
    enforce(!inCommand, format("Unterminated command in '", text, "'"));
    //writeln("'", text, "' evaluated to '", result, "'");
    return result;
}


//
// Parse the config file, returning the variable definitions it contains.
//
Vars parseConfig(string configFile, string mode) {

    enum Section { none, defines, modes, syslibCompileFlags, syslibLinkFlags }

    Section section = Section.none;
    bool    inMode;
    bool    foundMode;
    string  commandType;
    Vars    vars;
    size_t  syslibNum;

    if (!exists(configFile)) {
        writefln("Could not file config file %s", configFile);
        exit(1);
    }

    string content = readText(configFile);
    foreach (string line; splitLines(content)) {

        // Skip comment lines.
        if (!line.length || line[0] == '#') continue;

        //writefln("Processing line: %s", line);

        if (line.length && line[0] == '[' && line[$-1] == ']') {
            // Start of a section
            section = to!Section(line[1..$-1]);
            //writefln("Entered section %s", to!string(section));
        }

        else {
            final switch (section) {
                case Section.none: {
                    writeln("Found line outside of a section");
                    exit(1);
                    break;
                }
                case Section.defines: {
                    string[] tokens = split(line, " =");
                    if (tokens.length == 2) {
                        // Define a new variable.
                        vars.append(strip(tokens[0]), split(tokens[1]), AppendType.notExist);
                    }
                    break;
                }
                case Section.modes: {
                    if (!line.length) {
                        // Blank line - mode ended.
                        inMode = false;
                    }
                    else if (!isWhite(line[0])) {
                        // We are in a mode, which might be the one we want.
                        inMode = strip(line) == mode;
                        if (inMode) {
                            foundMode = true;
                            //writefln("Found mode %s", mode);
                        }
                    }
                    else if (inMode) {
                        // Add to an existing variable
                        string[] tokens = split(line, " +=");
                        if (tokens.length == 2) {
                            vars.append(strip(tokens[0]), split(tokens[1]), AppendType.mustExist);
                        }
                    }
                    break;
                }

                case Section.syslibCompileFlags: {
                    string[] tokens = split(line, " =");
                    if (tokens.length == 2) {
                        vars.append("syslib-compile-flags " ~ strip(tokens[0]),
                                    split(evaluate(strip(tokens[1]))),
                                    AppendType.notExist);
                    }
                    break;
                }

                case Section.syslibLinkFlags: {
                    string[] tokens = split(line, " =");
                    if (tokens.length == 2) {
                        vars.append("syslib-link-flags " ~ strip(tokens[0]),
                                    split(evaluate(strip(tokens[1]))),
                                    AppendType.notExist);
                    }
                    break;
                }
            }
        }
    }

    if (!foundMode) {
        writefln("Could not find mode %s in config file", mode);
        exit(1);
    }

    return vars;
}


//
// Main function
//
int main(string[] args) {

    //
    // Parse command-line arguments.
    //

    bool     help;
    string   mode;
    string   configFile = "bub.cfg";

    try {
        getopt(args,
               std.getopt.config.caseSensitive,
               "help",   &help,
               "mode",   &mode,
               "config", &configFile);
    }
    catch (Exception ex) {
        writefln("Invalid argument(s): %s", ex.msg);
        help = true;
    }

    if (help || args.length != 2 || !mode.length) {
        writefln("Usage: %s [options] build-dir-path\n" ~
                 "  --help                Display this message.\n" ~
                 "  --mode=mode-name      Build mode.\n" ~
                 "  --config=config-file  Specifies the config file. Default bub.cfg.\n",
                 args[0]);
        exit(1);
    }

    string buildDir = args[1];
    string srcDir   = std.file.getcwd();


    //
    // Read config file and establish build dir.
    //

    Vars vars = parseConfig(configFile, mode);
    vars["SRCDIR"] = [srcDir];
    establishBuildDir(buildDir, srcDir, vars);

    auto postConfigure = "POST_CONFIGURE" in vars;
    if (postConfigure) {
        foreach (relToBuildPath; *postConfigure) {
            auto fromPath = buildPath(buildDir, relToBuildPath);
            auto toPath   = buildPath(buildDir, relToBuildPath.baseName);
            std.file.write(toPath, std.file.read(fromPath));
        }
    }

    return 0;
}
