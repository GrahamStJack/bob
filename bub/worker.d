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

import bub.concurrency;
import bub.support;

import std.datetime;
import std.demangle;
import std.file;
import std.path;
import std.process;
import std.string;

static import std.stdio;


//
// The worker function.
//
// Get instructions from the workerChannel, do the work via
// (usually) a spawned process, then give the results back via
// the plannerChannel.
//
void doWork(bool                 printActions,
            uint                 index,
            PlannerProtocol.Chan plannerChannel,
            WorkerProtocol.Chan  workerChannel) {
    bool success;

    string myName = format("worker%d", index);

    string resultsPath = buildPath("tmp", myName);
    string tmpPath;

    void perform(string action, string command, string targets) {
        say("%s", action);
        if (printActions) { say("\n%s\n", command); }

        success = false;

        bool isTest = command.length > 5 && command[0 .. 5] == "TEST ";

        if (command == "DUMMY") {
            // Just write some text into the target file
            std.file.write(targets, "dummy");
            PlannerProtocol.sendSuccess(plannerChannel, action);
            return;
        }

        else if (command.length > 5 && command[0..5] == "COPY ") {
            // Do the copy ourselves because Windows doesn't seem to have an
            // external copy command, and this is faster anyway.
            string[] splitCommand = split(command);
            if (splitCommand.length != 3) {
                fatal("Got invalid copy command '%s'", command);
            }
            string from = splitCommand[1];
            string to   = splitCommand[2];
            std.file.copy(from, to);
            auto now = Clock.currTime();
            to.setTimes(now, now);
            version(Posix) {
                // Preserve executable permission
                to.setExecutableIf(from);
            }
            PlannerProtocol.sendSuccess(plannerChannel, action);
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
            auto splitCommand = split(command); // TODO handle quoted args

            Pid child = spawnProcess(splitCommand, std.stdio.stdin, output, output);

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
                    say("Deleting %s", target);
                    std.file.remove(target);
                }
            }

            bool bailed = killer.bail();

            if (!bailed) {
                // Print error message
                if (isTest) {
                    // For tests, print the test output as-is.
                    say("\n%s", readText(resultsPath));
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
                remove(resultsPath);
            }

            // tell planner the action succeeded
            PlannerProtocol.sendSuccess(plannerChannel, action);
        }
    }


    try {
        while (true) {
            auto msg = workerChannel.receive();
            final switch (msg.type) {
                case WorkerProtocol.Type.Work:
                {
                    perform(msg.work.action, msg.work.command, msg.work.targets);
                }
            }
        }
    }
    catch (ChannelFinalized ex) {}
    catch (BailException ex) {}
    catch (Exception ex)  { say("Unexpected exception: %s", ex.msg); }

    PlannerProtocol.sendBailed(plannerChannel);
}
