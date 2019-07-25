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

module bub.worker;

import bub.support;

import std.datetime;
import std.demangle;
import std.file;
import std.path;
import std.process;
import std.string;
import std.concurrency;
import std.conv;

static import std.stdio;


// Attempt to remove a file, quashing any exceptions
void tryRemove(string path) {
    try {
        std.file.remove(path);
    }
    catch (Exception ex) {
        if (path.exists) {
            say("Failed to remove %s", path);
        }
    }
}

//
// The worker function.
//
// Get instructions from our mailbox, do the work via (usually) a spawned process,
// then give the results back via our owner's mailbox.
//
void doWork(bool printActions, uint index) {
    bool success;

    string myName = format("worker%d", index);

    string         resultsPath = buildPath("tmp", myName);
    string         tmpPath     = buildPath("tmp", myName ~ "-tmp");
    string[string] env;

    env["TMP_PATH"] = tmpPath;

    void perform(string action, string command, string targets, int secs) {
        success = false;
        if (printActions) { say("\n%s", command); }

        if (tmpPath.exists) {
            rmdirRecurse(tmpPath);
        }

        bool isTest = command.startsWith("TEST ");

        if (command.startsWith("COPY ")) {
            // Do the copy ourselves because Windows doesn't seem to have an
            // external copy command, and this is faster anyway.
            string[] splitCommand = split(command);
            if (splitCommand.length != 3) {
                fatal("Got invalid copy command '%s'", command);
            }
            string from = splitCommand[1];
            string to   = splitCommand[2];
            try {
                std.file.copy(from, to);
                version(Posix) {
                    // Preserve permissions
                    to.setPermissions(from);
                }
                auto now = Clock.currTime();
                to.setTimes(now, now);
                ownerTid.send(index, action);
                return;
            }
            catch (Exception ex) {
                say("%s: FAILED\n%s\n%s", action, command, ex.msg);
                throw new BailException();
            }
        }

        else if (command.startsWith("DUMMY ")) {
            // Create a dummy file
            string[] splitCommand = split(command);
            if (splitCommand.length != 2) {
                fatal("Got invalid dummy-file command '%s'", command);
            }
            string target = splitCommand[1];
            std.file.write(target, "dummy");
            ownerTid.send(index, action);
            return;
        }

        else if (isTest) {
            // Do test preparation - make the tmp dir as a convenience
            // FIXME - remove the need to create it
            mkdir(tmpPath);
            command = command[5 .. $];
        }

        string[] targs = split(targets, "|");

        // delete any pre-existing files that we are about to build
        foreach (target; targs) {
            if (exists(target)) {
                target.tryRemove;
            }
        }

        // launch child process to do the action, then wait for it to complete
        auto output = std.stdio.File(resultsPath, "w");
        try {
            Pid child = spawnShell(command, std.stdio.stdin, output, output, env);
            killer.launched(myName, action, child, secs);
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
                    say("Deleting %s", target);
                    target.tryRemove;
                }
            }

            if (killer.bail(myName)) {
                // Print error message
                if (isTest) {
                    // For tests, move the test output to a file alongside the success file,
                    // then write to the console with leading text to
                    // prompt an editor to open the failure file
                    string failurePath = targs[0][0..$-"-passed".length] ~ "-failed";
                    resultsPath.rename(failurePath);
                    say("%s:1: error", failurePath);
                    say("\n%s", readText(failurePath));
                }
                else {
                    // For non-tests, attempt to provide demangled versions of symbol names.
                    say("\n");
                    foreach (line; readText(resultsPath).splitLines()) {
                        say("%s", line);
                        string[] tokens = line.split();
                        foreach (token; tokens) {
                            if (token.length > 2 && token[0..2] == "`_") {
                                token = token[1..$-1];
                                if (token[$-1] == '\'') token = token[0..$-1];
                                string nice = demangle(token);
                                if (nice != token) {
                                    say("[%s]", nice);
                                }
                            }
                        }
                    }
                }
                say("%s: FAILED\n%s", action, command);
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
                if (printActions) {
                    // Print the results of successful non-tests in case the
                    // build command printed something useful.
                    say("\n%s", readText(resultsPath));
                }
                resultsPath.tryRemove;
            }

            // tell planner the action succeeded
            ownerTid.send(index, action);
        }
    }


    // Carry out actions received from owner until something goes wrong.
    try {
        while (true) {
            receive(
                (string action, string command, string targets, string secs) {
                    perform(action, command, targets, to!int(secs));
                }
            );
        }
    }
    catch (BailException ex) {}
    catch (Exception ex) {}

    try {
        ownerTid.send(true);
    }
    catch (Exception ex) {}
}
