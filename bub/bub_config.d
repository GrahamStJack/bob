/*
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
        chmod(toStringz(path), executable ? octal!755 : octal!644);
    }

    // Make a symbolic link
    private void makeSymlink(string dest, string linkname) {
        symlink(dest, linkname);
    }

    string ENV_DELIM  = ":";
    string ENV_PREFIX = "";
}
version(Windows) {
    // Set the mode of a file
    private void setMode(string path, bool executable) {
        // Setting a file executable is all about the extension in windows,
        // and we let the user decide the filename - so nothing to do.
    }

    // Make a symbolic link
    private void makeSymlink(string dest, string linkname) {
        string command = format("mklink /D %s %s", linkname, dest);
        int ret = std.c.process.system(toStringz(command));
        assert(ret == 0, format("Failed to execute: %s", command));
    }

    string ENV_DELIM = ";";
    string ENV_PREFIX = "set ";
}


//================================================================
// Helpers
//================================================================


//
// Storage for data read from the config file
//

alias string[][string] Vars;      // variable items by variable name
alias string[string]   Locations; // repo, root or package name by path


//
// Enum to control how to append to variables
//
enum AppendType { notExist, mustExist, mayExist }


//
// Append some tokens to the named element in vars, preserving order
//
private void append(ref Vars vars, string name, string[] extra, AppendType appendType) {
    final switch (appendType) {
    case AppendType.notExist:
        assert(name !in vars, format("Cannot create variable '%s' again", name));
        break;
    case AppendType.mustExist:
        assert(name in vars, format("Cannot add to non-existant variable '%s'", name));
        break;
    case AppendType.mayExist:
        break;
    }

    if (name !in vars) {
        vars[name] = null;
    }
    foreach (string item; extra) {
        vars[name] ~= item;
    }
}


//
// Return a string to set an environment variable from an env element
//
string toEnv(const ref Vars env, string name) {
    string result;
    bool[string] got;
    foreach_reverse (token; env[name]) {
        if (token !in got) {
            got[token] = true;
            result ~= token ~ ENV_DELIM;
        }
    }
    if (result.length > 0) {
        result = ENV_PREFIX ~ name ~ `="` ~ result[0..$-ENV_DELIM.length];
    }
    while (result.endsWith(ENV_DELIM)) {
        result = result[0..$-ENV_DELIM.length];
    }
    result ~= "\"\n";
    return result;
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
void establishBuildDir(string          exeName,
                       string          mode,
                       string          configFile,
                       string          buildDir,
                       string          srcDir,
                       const Vars      vars,
                       const Locations repos,
                       const Locations packages,
                       const string[]  pkgNames,
                       const Vars      env) {

    // Create build directory
    if (!exists(buildDir)) {
        mkdirRecurse(buildDir);
    }
    else if (!isDir(buildDir)) {
        writefln("%s is not a directory", buildDir);
        exit(1);
    }

    // Create Buboptions file from vars
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


    // Create environment file.
    string envPath = buildPath(buildDir, "environment");
    string envText;
    version(Posix) {
        envText ~= "export BUILD_PATH=\"$(realpath -s $(dirname \"${BASH_SOURCE[0]}\"))\"\n";
        foreach (name; env.keys) {
            envText ~= "export " ~ env.toEnv(name);
        }
    }
    version(Windows) {
        envText ~= toEnv("PATH", vars, ["LIB_DIRS", "SYS_PATH"], [lib, bin] ~ fromEnv("PATH"));
        envText ~= "set DIST_DATA_PATH=\"" ~ data ~ "\"\n";
    }
    update(envPath, envText, false);


    // Create the run script
    version(Posix) {
        string runText = "#!/bin/bash\n" ~
                         "if [ $# -eq 0 ]; then\n" ~
                         "    echo 'Expected parameters specifying the command to run'\n" ~
                         "    exit 1\n" ~
                         "fi\n" ~
                         "source $(dirname \"${BASH_SOURCE[0]}\")/environment\n" ~
                         "exec \"$@\"\n";
        update(buildPath(buildDir, "run"),  runText, true);
    }
    version(Windows) {
        string runText = envText ~ "\n%1%";
        update(buildPath(buildDir, "run.bat"), runText, true);
    }

    //
    // Create src directory with a subdirectory for each root and a symlink to all
    // top-level packages, and a repos directory with a symlink to each repo
    //

    // Make clean repos and src dirs
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

    // Make symbolic links to each repo
    foreach (name, path; repos) {
        auto repoPath = buildNormalizedPath(srcDir, path).absolutePath;
        makeSymlink(repoPath, buildPath(localReposPath, name));
    }

    // Make a dir for each root and symbolic links in those dirs to the top-level packages
    string prevRoot;
    string[string] texts; // partial Bubfile text by dir
    foreach (key; pkgNames) {
        auto path = packages[key];
        auto root = key.dirName;
        if (root != prevRoot) {
            texts[""] ~= " " ~ root;
            mkdir(buildPath(localSrcPath, root));
            prevRoot = root;
        }
        texts[root] ~= " " ~ key.baseName;
        makeSymlink(buildNormalizedPath(srcDir, path), buildPath(localSrcPath, key));
    }

    // Create the generated Bubfiles
    foreach (key, text; texts) {
        update(buildPath(localSrcPath, key, "Bubfile"), "contain" ~ text ~ ";\n", false);
    }

    // print success
    writefln("Build environment in %s is ready to roll.", buildDir);
}


//
// Return whatever the given string evaluates to, replacing any $(<command>) instances
// with whatever <command> outputs, and expanding any ${<define>} tokens in the given string.
// Multiple levels of expansion are done, so a variable can contain another variable, etc.
//
// ${BUILD_PATH} evaluates to the build directory's path.
//
string evaluate(string text, const ref Vars vars) {
    string working = text;
    string result;
    bool   inCommand;
    bool   inVar;
    char   prev;
    string command;
    string var;

    while (true) {
        bool continuing;
        foreach (i, ch; working) {
            char next = i+1 < working.length ? working[i+1] : '\0';
            if (ch == '(' && prev == '$') {
                enforce(!inCommand, "Nested commands not supported");
                enforce(!inVar, "Commands inside variables not supported");
                inCommand  = true;
                command    = "";
                continuing = true;
            }
            else if (inCommand && ch == ')') {
                auto rc = executeShell(command);
                enforce(rc.status == 0, format("Failed to run '%s', output '%s'", command, rc.output));
                result ~= rc.output.strip;
                inCommand = false;
            }
            else if (ch == '{' && prev == '$') {
                enforce(!inVar, "Nested vars are not supported");
                inVar      = true;
                var        = "";
                continuing = true;
            }
            else if (inVar && ch == '}') {
                enforce(var in vars, format("Variable '%s' not defined", var));
                if (inCommand) {
                    result ~= "$(" ~ command;
                    inCommand = false;
                }
                result ~= vars[var].join(" ").strip;
                result ~= working[i+1..$];
                inVar = false;
                break;
            }
            else if (inVar) {
                var ~= ch;
            }
            else if (inCommand && (ch != '$' || next != '{')) {
                command ~= ch;
            }
            else if (!inCommand && !inVar && (ch != '$' || (next != '(' && next != '{'))) {
                result ~= ch;
            }
            prev = ch;
        }
        result = result.strip;
        enforce(!inCommand && !inVar, format("Unterminated command or variable in '%s'", working));

        //writefln("Converted '%s' into '%s'", working, result);
        if (continuing) {
            // Use result as working, reset everything else, and go arouund again
            working   = result;
            result    = "";
            inCommand = false;
            inVar     = false;
            command   = "";
            prev      = '\0';
        }
        else {
            break;
        }
    }
    return result;
}


//
// Parse a bundle file, which can only contain REPO, ROOT and CONTAIN variables and no sections.
//
// bundleFile is the path to the bundle file relative to the config file.
// Paths in the bundle file are relative to the bundle file's parent directory.
//
void parseBundle(string           bundle,
                 ref Locations    repos,
                 ref Locations    roots,
                 ref Locations    packages,
                 ref string[]     packageNames,
                 ref bool[string] bundlesDone,
                 bool             verbose) {
    if (bundle !in bundlesDone) {
        bundlesDone[bundle] = true;
        if (verbose) { writefln("Incorporating bundle at %s", bundle); }

        string repoPath;
        string rootPath;
        string rootName;

        foreach (string line; bundle.readText.splitLines) {
            if (!line.length || line[0] == '#') continue;

            string[] tokens = line.split(" =");
            if (tokens.length == 2) {
                auto name  = tokens[0].strip;
                auto items = tokens[1].split;

                enforce(name == "REPO" || name == "ROOT" || name == "CONTAIN",
                        "A bundle file can only contain REPO, ROOT or CONTAIN variables - not '" ~ name ~ "'");

                if (name == "REPO") {
                    enforce(repoPath == "", "Only one REPO variable is allowed per bundle file");
                    enforce(items.length == 1, "Exactly one value must be provided in a REPO variable");
                    repoPath = buildNormalizedPath(bundle.dirName, items[0]);
                    auto repoName = repoPath.baseName;
                    auto already = repoName in repos;
                    enforce(already is null || repoPath == *already,
                            format("Found repo %s at both %s and %s", repoName, repoPath, *already));
                    if (already is null) {
                        enforce(repoPath.isDir,
                                "Can't find dir " ~ repoPath ~
                                " - REPO value must be relative path to a repo directory " ~ repoPath);
                        repos[repoName] = repoPath;
                        if (verbose) { writefln("Added repo %s at %s", repoName, repoPath); }
                    }
                }
                else if (name == "ROOT") {
                    enforce (rootPath == "", "Only one ROOT variable allowed per bundle file");
                    enforce(items.length == 1, "Exactly one value must be provided in a ROOT variable");
                    enforce(repoPath != "", "Cannot specify ROOT before REPO");
                    rootPath = buildNormalizedPath(bundle.dirName, items[0]);
                    rootName = rootPath.baseName;
                    roots[rootName] = rootPath;
                }
                else if (name == "CONTAIN") {
                    enforce(rootPath != "", "Connot specify CONTAIN before ROOT");
                    foreach (item; items) {
                        enforce(item.dirName == ".", "CONTAIN values must be simple names");
                        auto packagePath = buildPath(rootPath, item);
                        enforce(packagePath.isDir,
                                "Can't find dir " ~ packagePath ~
                                " - CONTAIN values must be directory names under ROOT " ~ rootPath);
                        string packageName = buildPath(rootName, item);
                        enforce(packageName !in packages, "Duplicate CONTAIN " ~ item);
                        packages[packageName] = packagePath;
                        packageNames ~= packageName;
                        if (verbose) { writefln("Contain top-level package %s at %s", packageName, packagePath); }
                    }
                }
                else {
                    enforce(false, "Unknown bundle variable '" ~ name ~ "'");
                }
            }
        }
    }
}


//
// Parse the config file and any bundles referred to from it, returning the resultant variable definitions.
//
void parseConfig(string        configFile,
                 string        mode,
                 ref Vars      vars,
                 ref Locations repos,
                 ref Locations roots,
                 ref Locations packages,
                 ref string[]  packageNames,
                 ref Vars      env) {

    enum Section { none, defines, modes, syslibCompileFlags, syslibLinkFlags, environment }

    Vars[string]   fragments;
    Vars           modes;
    Vars*          fragment;
    string[string] syslibCompileFlags;
    string[string] syslibLinkFlags;

    Section section = Section.none;
    string  commandType;
    size_t  syslibNum;

    if (!exists(configFile)) {
        writefln("Could not file config file %s", configFile);
        exit(1);
    }
    writefln("Using config file %s", configFile);

    vars.append("CONFIG_FILE", [buildNormalizedPath(std.file.getcwd(), configFile)], AppendType.notExist);

    foreach (string line; configFile.readText.splitLines) {

        // Skip comment lines.
        if (!line.length || line[0] == '#') continue;

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
                    string[] tokens = line.split(" =");
                    if (tokens.length == 2) {
                        // Define a new variable.
                        vars.append(strip(tokens[0]), tokens[1].split, AppendType.notExist);
                    }
                    break;
                }
                case Section.modes: {
                    // Accumulate fragments and modes.
                    // Fragments start with a name on one line and comprise the following indented lines.
                    // Modes are on one line: name = fragments

                    if (line.length == 0) {
                        // Blank line - ignore except to finish an in-progress fragment
                        fragment = null;
                    }
                    else if (!line[0].isWhite) {
                        // Non-indented line - terminate any in-progress fragment and either
                        // start another or define a mode
                        fragment = null;
                        string[] tokens = line.split("=");
                        if (tokens.length == 1) {
                            // Start a fragment
                            string name = tokens[0].strip;
                            fragments[name] = null;
                            fragment = name in fragments;
                        }
                        else if (tokens.length == 2) {
                            // Add a new mode
                            string   name   = tokens[0].strip;
                            string[] values = tokens[1].split;
                            modes[name] = values;
                        }
                        else {
                            enforce(false, format("Invalid mode line '%s'", line));
                        }
                    }
                    else {
                        // Indented line - add to the current fragment
                        enforce(fragment !is null,
                                format("Can't indent a mode line unless inside a fragment: '%s'", line));
                        bool adding;
                        string[] tokens = line.split(" =");
                        if (tokens.length == 1) {
                            tokens = line.split(" +=");
                            adding = true;
                        }
                        enforce(tokens.length == 2, format("Invalid mode line '%s'", line));
                        string   name   = tokens[0].strip;
                        string[] values = tokens[1].split;
                        if (adding) {
                            values = ["+"] ~ values;
                        }
                        (*fragment)[name] = values;
                    }
                    break;
                }

                case Section.syslibCompileFlags: {
                    string[] tokens = line.split(" =");
                    if (tokens.length == 2) {
                        syslibCompileFlags[tokens[0].strip] = tokens[1].strip;
                    }
                    break;
                }

                case Section.syslibLinkFlags: {
                    string[] tokens = line.split(" =");
                    if (tokens.length == 2) {
                        syslibLinkFlags[tokens[0].strip] = tokens[1].strip;
                    }
                    break;
                }

                case Section.environment: {
                    string[] tokens = line.split("+=");
                    if (tokens.length == 2) {
                        string   name   = tokens[0].strip;
                        string[] values = tokens[1].strip.split;
                        env.append(name, values, AppendType.mayExist);
                    }
                    break;
                }
            }
        }
    }

    // Apply the mode
    string[] selectedFragments;
    if (mode in modes) {
        selectedFragments ~= modes[mode];
    }
    else if (modes.length == 0) {
        selectedFragments ~= mode;
    }
    enforce(selectedFragments.length > 0, "Invalid mode " ~ mode);
    foreach (name; selectedFragments) {
        foreach (var, values; fragments[name]) {
            bool adding;
            if (values.length > 0 && values[0] == "+") {
                adding = true;
                values = values[1..$];
            }
            writefln("Applying mode fragment %s %s %s %s", name, adding ? "adding-to" : "setting", var, values);
            append(vars, var, values, adding ? AppendType.mustExist : AppendType.notExist);
        }
    }

    // Evaluate compile and link flags now that the mode consequences are known
    foreach (key, value; syslibCompileFlags) {
        string[] options = evaluate(value, vars).split;
        // Replace any "-I with "-isystem" so that warnings will be ignored in
        // system headers
        foreach (ref option; options) {
            if (option.startsWith("-I")) {
                option = "-isystem" ~ option[2..$];
            }
        }
        vars.append("syslib-compile-flags " ~ key, options, AppendType.notExist);
    }
    foreach (key, value; syslibLinkFlags) {
        string[] options = evaluate(value, vars).split;
        vars.append("syslib-link-flags " ~ key, options, AppendType.notExist);
    }

    enforce("BUNDLES" in vars && vars["BUNDLES"].length, "BUNDLES variable is not set or is empty");
    auto initialBundles = vars["BUNDLES"];
    vars.remove("BUNDLES");

    // Transitively parse the bundle files
    bool[string] bundlesDone;
    foreach (bundle; initialBundles) {
        parseBundle(bundle.absolutePath.buildNormalizedPath, repos, roots, packages, packageNames, bundlesDone, true);
    }

    // Set up ROOTS var
    foreach (rootName, rootPath; roots) {
        vars["ROOTS"] ~= rootName ~ "=" ~ rootPath;
    }
}


//
// Check that the current directory looks like a build directory, and contains a top-level
// Bubfle that is consistent with the configuration file.
//
int performCheck() {
    // Basic checks
    string optionsPath = "Buboptions";
    if (!optionsPath.exists) {
        writefln("Cannot find %s - this doesn't look like a build directory", optionsPath);
        return 1;
    }

    // Read the configuration file's path from Buboptions
    string configPath;
    foreach (line; optionsPath.readText.splitLines) {
        string[] tokens = line.split;
        if (tokens.length == 3 && tokens[0] == "CONFIG_FILE") {
            configPath = tokens[2];
            break;
        }
    }
    if (configPath == "") {
        writefln("Cannot find CONFIG_FILE option");
        return 1;
    }
    if (!configPath.exists) {
        writefln("Cannot find %s - this build directory is broken", configPath);
        return 1;
    }

    // Get the list of bundles files from the config file
    string[] bundles;
    foreach (line; configPath.readText.splitLines) {
        string[] tokens = line.split;
        if (tokens.length > 2 && tokens[0] == "BUNDLES") {
            bundles = tokens[2..$];
            break;
        }
    }
    if (bundles.length == 0) {
        writefln("Cannot find bundles in %s - this build directory is broken", configPath);
        return 1;
    }

    // Read the bundles files and confirm that the two top layers of Bubfiles are as expected

    bool verify(string dir, string[] expected) {
        string bubfilePath = buildPath(dir, "Bubfile");
        if (!bubfilePath.exists) {
            writefln("Cannot find %s", bubfilePath);
            return false;
        }

        string[] content = bubfilePath.readText.splitLines;

        if (content.length != 1) {
            writefln("%s has the wrong number of lines (expected 1)\n\n", bubfilePath);
            return false;
        }

        string text = "contain";
        foreach (item; expected) {
            text ~= " " ~ item;
        }
        text ~= ";";

        // And here is the check we really want to do - is the list of packages as expected?
        if (content[0] != text) {
            writefln("%s is out of date\n\nExpected\n%s\n\nGot\n%s\n\n", bubfilePath, text, content[0]);
            return false;
        }

        return true;
    }

    Locations    repos;
    Locations    roots;
    Locations    packages;
    string[]     packageNames;
    bool[string] done;

    foreach (bundle; bundles) {
        parseBundle(buildNormalizedPath(configPath.dirName, bundle), repos, roots, packages, packageNames, done, false);
    }

    string[]         firstLayerExpected;
    string[][string] secondLayerExpected;
    bool[string]     haveRoot;
    foreach (packageName; packageNames) {
        string root = packageName.dirName;
        string pkg  = packageName.baseName;
        if (root !in haveRoot) {
            haveRoot[root] = true;
            firstLayerExpected ~= root;
            secondLayerExpected[root] = [];
        }
        secondLayerExpected[root] ~= pkg;
    }

    if (!verify("src", firstLayerExpected)) {
        return 1;
    }
    foreach (dir, names; secondLayerExpected) {
        if (!verify(buildPath("src", dir), names)) {
            return 1;
        }
    }

    return 0;
}


//
// Main function
//
int main(string[] args) {

    //
    // Parse command-line arguments.
    //

    bool   help;
    bool   check;
    string mode;
    string configFile = "bub.cfg";

    try {
        getopt(args,
               std.getopt.config.caseSensitive,
               "help",   &help,
               "check",  &check,
               "mode",   &mode,
               "config", &configFile);
    }
    catch (Exception ex) {
        writefln("Invalid argument(s): %s", ex.msg);
        help = true;
    }

    if (help || (!check && (args.length != 2 || !mode.length))) {
        writefln("Usage: %s [options] build-dir-path\n" ~
                 "  --help                Display this message.\n" ~
                 "  --check               Check the top-level Bubfile.\n" ~
                 "  --mode=mode-name      Build mode.\n" ~
                 "  --config=config-file  Specifies the config file. Default bub.cfg.\n" ~
                 "\n" ~
                 "--check prevents setup of the build directory, and instead\n" ~
                 "verifies that the current directory is a build directory with a\n" ~
                 "top-level Bubfile that matches the source repo(s) bundles files.\n" ~
                 "This option used by bub.\n",
                 args[0]);
        exit(1);
    }

    if (check) {
        return performCheck();
    }

    string srcDir   = std.file.getcwd();
    string buildDir = buildNormalizedPath(srcDir, args[1]);

    //
    // Read config file and establish build dir.
    //

    Vars      vars;
    Locations repos;
    Locations roots;
    Locations packages;
    string[]  packageNames;
    Vars      env;

    vars["BUILD_PATH"] = [buildDir];

    env.append("LD_LIBRARY_PATH",  [buildPath("${BUILD_PATH}", "dist", "lib")], AppendType.mayExist);
    env.append("PATH",             ["/bin", "/usr/bin", buildPath("${BUILD_PATH}", "dist", "bin")],
               AppendType.mayExist);
    env.append("SYSTEM_DATA_PATH", [buildPath("${BUILD_PATH}", "dist", "data")], AppendType.mayExist);

    parseConfig(configFile, mode, vars, repos, roots, packages, packageNames, env);
    establishBuildDir(args[0], mode, configFile, buildDir, srcDir, vars, repos, packages, packageNames, env);

    auto postConfigure = "POST_CONFIGURE" in vars;
    if (postConfigure) {
        foreach (relToBuildPath; *postConfigure) {
            // Copy the specified post-configure files into the build directory
            auto fromPath = buildPath(buildDir, relToBuildPath);
            auto toPath   = buildPath(buildDir, relToBuildPath.baseName);
            update(toPath, fromPath.readText, false);
        }
    }

    return 0;
}
