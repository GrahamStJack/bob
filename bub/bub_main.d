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


Relationships Between Files
---------------------------

Files are arranged in a tree that represents containment, with additional
references between them implied by includes/imports in the code and explicit
refer statements in the Bubfiles. These references are used to manage dependencies.

An Action that builds Files depends on other Files. The Action cannot be issued
until all the its dependencies are satisfied, and will be issued if any of its
built Files are out of date wrt any of its dependencies. Each dependency has a
matching reference.

A scannable File may include/import (include) other Files. If File A directly or
transitively includes File B, then all files that depend on File A also depend
on File B.


Reference Rules
---------------

Each Node in the tree can be public or protected. The root of the tree contains
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
that should not be accessible. Bub therefore enforces all visibility
rules before invoking the compiler.


The build process
-----------------

Bub reads the project Bubfile, transiting into
other-package Bubfiles as packages are mentioned.

Bub assumes that new packages, libraries, etc are mentioned in dependency order.
That is, when each thing is mentioned, everything it depends on, including
dependencies inferred by include/import statements in source code, has already
been mentioned. Exception: a Bubfile can refer to previously-unknown top-level
packages.

The planner thread scans the Bubfiles, binding files to specific
locations in the filesystem as it goes, and builds the dependency graph.

The file state sequence is:
    initial
    dependencies_clean         skipped if no dependencies
    building                   skipped if no build action
    up_to_date
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

import bub.planner;
import bub.worker;
import bub.support;
import bub.concurrency;

import std.file;
import std.getopt;
import std.process;
import std.string;

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
    int  returnValue    = 0;
    auto plannerChannel = new PlannerProtocol.Chan(100);
    auto workerChannel  = new WorkerProtocol.Chan(1000);
    // bailerChannel is used by mySignalHandler, so we create that statically.

    // TODO add a thread between the priority queue and the workerChannel so
    // there is no risk of the planner thread blocking, and reduce the channel sizes
    // to something sensible, like 10.

    try {
        bool printStatements = false;
        bool printDeps       = false;
        bool printDetails    = false;
        bool printActions    = false;
        bool help            = false;
        uint numJobs         = 1;

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
        if (numJobs > 20) {
            say("Clamping number of jobs at 20");
            numJobs = 20;
        }
        if (returnValue != 0 || help) {
            say("Usage:  bub [options]\n"
                "  --statements     print statements\n"
                "  --deps           print dependencies\n"
                "  --actions        print actions\n"
                "  --details        print heaps of details\n"
                "  --jobs=VALUE     maximum number of simultaneous actions\n"
                "  --help           show this message\n"
                "target is everything contained in the project Bubfile and anything referred to.");
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
                    string name  = tokens[0];
                    string value = tokens[1];

                    version(Windows) {
                        name = name[4..$]; // strip off "set "
                    }

                    environment[name] = value;
                }
            }
        }

        // Spawn the bailer and workers
        spawn(&doBailer);
        foreach (uint i; 0 .. numJobs) {
            spawn(&doWork, printActions, i, plannerChannel, workerChannel);
        }

        // Build everything
        returnValue = doPlanning(numJobs,
                                 printStatements,
                                 printDeps,
                                 printDetails,
                                 plannerChannel,
                                 workerChannel) ? 0 : 1;
    }
    catch (Exception ex) {
        say("Got unexpected exception: %s", ex.msg);
        returnValue = 1;
    }

    // Shut down the bailer and all the workers.
    bailerChannel.finalize();
    workerChannel.finalize();

    return returnValue;
}
