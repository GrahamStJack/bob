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

A build tool suitable for C/C++ and D code, written in D.

Objectives of this build tool are:
* Easy to write and maintain build scripts (Bubfiles):
  - Simple syntax.
  - Automatic determination of which in-project libraries to link.
* Auto execution and evaluation of unit tests.
* Enforcement of dependency rules.
* Support for building source code from multiple repositories.
* Support for C/C++ and D.
* Support for code generation:
  - A source file isn't scanned for imports/includes until after it is up to date.
  - Dependencies inferred from these imports are automatically applied.

Refer to README and INSTRUCTIONS and examples for details on how to use bub.
*/

import bub.planner;
import bub.parser;
import bub.worker;
import bub.support;
import bub.backtrace;

import std.file;
import std.getopt;
import std.process;
import std.string;
import std.concurrency;

import core.bitop;

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
    int returnValue = 0;

    try {
        bool printStatements = false;
        bool printDeps       = false;
        bool printCulprit    = false;
        bool printDetails    = false;
        bool printActions    = false;
        string dotPath;
        bool clean           = false;
        bool help            = false;
        uint numJobs         = 1;
        int  testSecs        = -1;

        try {
            getopt(args,
                   std.getopt.config.caseSensitive,
                   "statements|s",   &printStatements,
                   "deps|d",         &printDeps,
                   "culprit",        &printCulprit,
                   "details|v",      &printDetails,
                   "actions|a",      &printActions,
                   "dot",            &dotPath,
                   "jobs|j",         &numJobs,
                   "test|t",         &testSecs,
                   "clean|c",        &clean,
                   "help|h",         &help,
                   std.getopt.config.passThrough);
        }
        catch (std.conv.ConvException ex) {
            returnValue = 2;
            say(ex.msg);
        }
        catch (object.Exception ex) {
            returnValue = 2;
            say(ex.msg);
        }

        immutable uint maxJobs = 80;

        if (numJobs < 1) {
            returnValue = 2;
            say("Must allow at least one job!");
        }
        if (numJobs > maxJobs) {
            say("Clamping number of jobs at %s", maxJobs);
            numJobs = maxJobs;
        }
        if (returnValue != 0 || help) {
            say("Usage:  bub [options]\n" ~
                "  --statements     print statements\n" ~
                "  --deps           print dependencies\n" ~
                "  --culprit        add dirtying dependency to normal output\n" ~
                "  --actions        print actions\n" ~
                "  --dot=<path>     write dependency graph for dist-exe at <path> to depends.dot\n" ~
                "  --details        print heaps of details\n" ~
                "  --jobs=VALUE     maximum number of simultaneous actions (default is 1)\n" ~
                "  --test=SECS      execute tests with timeout <= SECS (default is TEST or 60)\n" ~
                "  --clean          just remove all built files\n" ~
                "  --help           show this message\n" ~
                "target is everything contained in the project Bubfile and anything referred to.");
            return returnValue;
        }

        if (!"Buboptions".exists) {
            say("This doesn't look like a build directory");
            return 1;
        }

        if (printDetails) {
            printActions = true;
            printDeps = true;
            printCulprit = true;
        }

        if (clean) {
            void rm(string[] paths) {
                foreach (path; paths) {
                    if (path.exists) {
                        rmdirRecurse(path);
                    }
                }
            }
            rm(["tmp", "obj", "priv", "deps", "dist"]);
            return 0;
        }

        // Set environment variables found in the environment file so that workers get them
        if (exists("environment")) {
            auto buildDir = getcwd();
            string envContent = readText("environment");
            foreach (line; splitLines(envContent)) {
                string[] tokens = line.split("=");
                if (tokens.length == 2 && tokens[0][0] != '#') {
                    if (tokens[1][0] == '"') {
                        tokens[1] = tokens[1][1 .. $-1];
                    }
                    string name  = tokens[0];
                    string value = tokens[1];

                    auto tokens2 = name.split;
                    if (tokens2.length > 1) {
                        // strip off "export"
                        name = tokens2[1];
                    }

                    value = value.replace("${BUILD_PATH}", buildDir);

                    if (name != "BUILD_PATH") {
                        environment[name] = value;
                    }
                }
            }
        }

        // Ensure tmp exists so the workers have a sandbox.
        if (!exists("tmp")) {
            mkdir("tmp");
        }

        // set up some globals
        readOptions();
        g_print_rules   = printStatements;
        g_print_deps    = printDeps;
        g_print_culprit = printCulprit;
        g_print_details = printDetails;
        if (testSecs == -1) {
            testSecs = defaultTestSecs;
        }

        // Run the pre-build script if one is specified, passing it any unprocessed command-line arguments
        auto unprocessed = args[1..$];
        auto preBuild = getOption("PRE_BUILD");
        if (preBuild.length > 0) {
            string command = preBuild ~ " " ~ unprocessed.escapeShellCommand;
            say("Running pre-build command: %s", command);
            auto rc = executeShell(command);
            if (rc.status != 0) {
                fatal("%s failed with code %s, output:\n%s", command, rc.status, rc.output);
            }
        }
        else if (unprocessed.length > 0) {
            // There is no pre-build script specified, so there should not have been any unprocessed arguments
            say("Option processing failed. There are %s unprocessed argument(s): ", unprocessed.length);
            foreach (arg; unprocessed) {
                say("  '%s'", arg);
            }
            return 2;
        }

        // Spawn the bailer and workers
        spawn(&doBailer);
        Tid[] workerTids;
        foreach (uint i; 0 .. numJobs) {
            workerTids ~= spawn(&doWork, printActions, i);
        }

        // Build everything
        if (!doPlanning(workerTids, dotPath, testSecs, args[0])) {
            returnValue = 1;
        }
    }
    catch (Exception ex) {
        say("Got unexpected exception: %s", ex.msg);
        returnValue = 1;
    }

    // Our child threads get an exception on receive() after we terminate,
    // so there is no need to do anything special to shut them down.

    return returnValue;
}
